// Package treasury holds the funds and accounting for Shared Budget programs.
package treasury

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/budget/v1"
)

const (
	packagePath = "gno.land/r/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/treasury/v2"
	maxScheduleBlocks int64 = 2147483647

	Draft          = "draft"
	Active         = "active"
	IssuanceClosed = "issuance_closed"
	Closed         = "closed"

	Reserved = "reserved"
	Approved = "approved"
	Rejected = "rejected"
	Expired  = "expired"
)

type policy struct {
	path       string
	addr       address
	periodCap  int64
	itemCap    int64
	registered bool
	usage      map[int64]int64
	items      map[int64]*reservation
	itemIDs    []int64
}

type claim struct {
	recipient address
	amount    int64
	paid      bool
}

type reservation struct {
	payment  claim
	status   string
	period   int64
	deadline int64
}

type program struct {
	sponsor        address
	status         string
	periodBlocks   int64
	issueBlocks    int64
	maxHold        int64
	start          int64
	issueEnd       int64
	maintenance    policy
	reimbursements policy
	ledger         budget.Ledger
	activeCount    int64
	refund         claim
}

var (
	programs        = make(map[int64]*program)
	latestProgramID int64
	outstanding     int64
)

// CreateProgram pins both policy packages. The sponsor can fund the program
// after each policy has configured its roles and registered.
func CreateProgram(cur realm, maintenancePath, reimbursementsPath string, maintenancePeriodCap, maintenanceItemCap, reimbursementsPeriodCap, reimbursementsItemCap, periodBlocks, issueBlocks, maxHold int64) int64 {
	runtime.AssertOriginCall()
	sponsor := userCaller(cur, false)
	if maintenancePath == reimbursementsPath {
		panic("policies must use distinct realm paths")
	}
	if periodBlocks <= 0 || issueBlocks <= 0 || maxHold <= 0 {
		panic("program durations must be positive")
	}
	if periodBlocks > maxScheduleBlocks || issueBlocks > maxScheduleBlocks || maxHold > maxScheduleBlocks {
		panic("program durations cannot exceed 2147483647 blocks")
	}
	p := &program{
		sponsor:        sponsor,
		status:         Draft,
		periodBlocks:   periodBlocks,
		issueBlocks:    issueBlocks,
		maxHold:        maxHold,
		maintenance:    newPolicy(maintenancePath, maintenancePeriodCap, maintenanceItemCap),
		reimbursements: newPolicy(reimbursementsPath, reimbursementsPeriodCap, reimbursementsItemCap),
	}
	id := budget.Add(latestProgramID, 1)
	programs[id] = p
	latestProgramID = id
	chain.Emit("ProgramCreated", "program", number(id), "sponsor", string(sponsor))
	return id
}

func RegisterPolicy(cur realm, programID int64) {
	requireTreasury(cur)
	p := mustProgram(programID)
	lane, rule := p.policyCaller(cur)
	if p.status != Draft || rule.registered {
		panic("policy registration requires an unconfigured draft")
	}
	rule.registered = true
	chain.Emit("PolicyRegistered", "program", number(programID), "lane", lane, "path", rule.path)
}

func Open(cur realm, programID int64) {
	runtime.AssertOriginCall()
	sponsor := userCaller(cur, true)
	p := sponsorProgram(programID, sponsor)
	if p.status != Draft || !p.maintenance.registered || !p.reimbursements.registered {
		panic("opening requires a draft with both policies registered")
	}
	amount := fundingAmount()
	p.start = runtime.ChainHeight()
	p.issueEnd = budget.Add(p.start, p.issueBlocks)
	p.credit(amount)
	p.status = Active
	chain.Emit("ProgramOpened", "program", number(programID), "sponsor", string(sponsor), "amount", number(amount), "start", number(p.start), "issue_end", number(p.issueEnd))
}

func Fund(cur realm, programID int64) {
	runtime.AssertOriginCall()
	sponsor := userCaller(cur, true)
	p := sponsorProgram(programID, sponsor)
	if p.statusAt(runtime.ChainHeight()) != Active {
		panic("program is not accepting funds")
	}
	amount := fundingAmount()
	p.credit(amount)
	chain.Emit("ProgramFunded", "program", number(programID), "sponsor", string(sponsor), "amount", number(amount))
}

// Reserve is callable by the registered policy for its own spending lane.
func Reserve(cur realm, programID, itemID int64, recipient address, amount, deadline int64) int64 {
	requireTreasury(cur)
	p := mustProgram(programID)
	lane, rule := p.policyCaller(cur)
	height := runtime.ChainHeight()
	if !rule.registered || p.statusAt(height) != Active {
		panic("program is not accepting reservations")
	}
	if itemID <= 0 || rule.items[itemID] != nil {
		panic("item ID must be positive and unused in this lane")
	}
	budget.RequireAddress(recipient)
	if recipient == cur.Address() {
		panic("the treasury cannot be an item recipient")
	}
	budget.RequirePositive(amount)
	budget.CheckDeadline(height, deadline, p.maxHold)
	if amount > rule.itemCap {
		panic("item cap exceeded")
	}
	period := p.periodAt(height)
	if amount > rule.periodCap-rule.usage[period] {
		panic("period cap exceeded")
	}
	if amount > p.ledger.Available {
		panic("shared balance exceeded")
	}

	p.ledger = p.ledger.Reserve(amount)
	p.activeCount = budget.Add(p.activeCount, 1)
	rule.usage[period] = budget.Add(rule.usage[period], amount)
	item := &reservation{
		payment:  claim{recipient: recipient, amount: amount},
		status:   Reserved,
		period:   period,
		deadline: deadline,
	}
	rule.items[itemID] = item
	rule.itemIDs = append(rule.itemIDs, itemID)
	emitItem("Reserved", programID, lane, itemID, item)
	return p.ledger.Available
}

func Approve(cur realm, programID, itemID int64) {
	requireTreasury(cur)
	p := mustProgram(programID)
	lane, rule := p.policyCaller(cur)
	item := rule.pendingBeforeDeadline(itemID)
	p.ledger = p.ledger.Approve(item.payment.amount)
	p.activeCount = budget.Subtract(p.activeCount, 1)
	item.status = Approved
	emitItem("Approved", programID, lane, itemID, item)
}

func Reject(cur realm, programID, itemID int64) {
	requireTreasury(cur)
	p := mustProgram(programID)
	lane, rule := p.policyCaller(cur)
	item := rule.pendingBeforeDeadline(itemID)
	p.release(rule, item, Rejected)
	emitItem("Rejected", programID, lane, itemID, item)
}

func Expire(cur realm, programID int64, lane string, itemID int64) {
	runtime.AssertOriginCall()
	userCaller(cur, false)
	p := mustProgram(programID)
	rule := p.rule(lane)
	item := rule.pending(itemID)
	if runtime.ChainHeight() < item.deadline {
		panic("reservation has not reached its deadline")
	}
	p.release(rule, item, Expired)
	emitItem("Expired", programID, lane, itemID, item)
}

func CloseIssuance(cur realm, programID int64) {
	runtime.AssertOriginCall()
	sponsor := userCaller(cur, false)
	p := sponsorProgram(programID, sponsor)
	if p.statusAt(runtime.ChainHeight()) != Active {
		panic("issuance is not active")
	}
	p.status = IssuanceClosed
	chain.Emit("IssuanceClosed", "program", number(programID), "sponsor", string(sponsor))
}

// FinalizeClose turns the remainder into a sponsor claim. Recipient claims
// continue to be payable after the program closes.
func FinalizeClose(cur realm, programID int64) {
	runtime.AssertOriginCall()
	caller := userCaller(cur, false)
	p := mustProgram(programID)
	if p.statusAt(runtime.ChainHeight()) != IssuanceClosed {
		panic("close issuance before finalization")
	}
	if p.activeCount != 0 {
		panic("program still has active reservations")
	}
	amount := p.ledger.Available
	if amount > 0 {
		p.refund = claim{recipient: p.sponsor, amount: amount}
	}
	p.ledger = p.ledger.RefundAvailable()
	p.status = Closed
	chain.Emit("ProgramClosed", "program", number(programID), "actor", string(caller), "refund", number(amount))
}

// Withdraw pays an approved item. Use lane "refund" and item ID 0 for the
// sponsor claim created by FinalizeClose.
func Withdraw(cur realm, programID int64, lane string, itemID int64) {
	runtime.AssertOriginCall()
	caller := userCaller(cur, false)
	p := mustProgram(programID)
	payment := p.findClaim(lane, itemID)
	if payment == nil || payment.recipient != caller {
		panic("claim is payable only to its recipient")
	}
	if payment.paid {
		panic("claim already paid")
	}

	p.ledger = p.ledger.Pay(payment.amount)
	outstanding = budget.Subtract(outstanding, payment.amount)
	payment.paid = true
	coins := chain.Coins{chain.NewCoin(budget.Denom, payment.amount)}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), payment.recipient, coins)
	chain.Emit("Withdrawn", "program", number(programID), "lane", lane, "item", number(itemID), "recipient", string(caller), "amount", number(payment.amount))
}

func newPolicy(path string, periodCap, itemCap int64) policy {
	const prefix = "gno.land/r/"
	if len(path) > 256 || !strings.HasPrefix(path, prefix) {
		panic("expected a versioned policy realm path")
	}
	parts := strings.Split(path[len(prefix):], "/")
	version := parts[len(parts)-1]
	if len(parts) < 3 || len(version) < 2 || version[0] != 'v' || path == packagePath {
		panic("expected a versioned policy realm path")
	}
	for _, part := range parts {
		if !validPathSegment(part) {
			panic("expected a versioned policy realm path")
		}
	}
	n, err := strconv.ParseInt(version[1:], 10, 64)
	if err != nil || n < 0 || version != "v"+number(n) {
		panic("expected a versioned policy realm path")
	}
	if itemCap <= 0 || itemCap > periodCap {
		panic("policy caps require 0 < item cap <= period cap")
	}
	return policy{
		path:      path,
		addr:      chain.PackageAddress(path),
		periodCap: periodCap,
		itemCap:   itemCap,
		usage:     make(map[int64]int64),
		items:     make(map[int64]*reservation),
	}
}

// Follow the Gno package path rules for each namespace and package segment.
func validPathSegment(part string) bool {
	if part == "" || part[0] < 'a' || part[0] > 'z' {
		return false
	}
	separator := false
	for i := 1; i < len(part); i++ {
		c := part[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			separator = false
		case (c == '-' || c == '_') && !separator:
			separator = true
		default:
			return false
		}
	}
	return !separator
}

func (p *program) credit(amount int64) {
	p.ledger = p.ledger.Fund(amount)
	outstanding = budget.Add(outstanding, amount)
}

func (p *program) release(rule *policy, item *reservation, status string) {
	amount := item.payment.amount
	p.ledger = p.ledger.Release(amount)
	p.activeCount = budget.Subtract(p.activeCount, 1)
	rule.usage[item.period] = budget.Subtract(rule.usage[item.period], amount)
	item.status = status
}

func (p *program) statusAt(height int64) string {
	if p.status == Active && height >= p.issueEnd {
		return IssuanceClosed
	}
	return p.status
}

func (p *program) periodAt(height int64) int64 {
	return budget.PeriodAt(height, p.start, p.periodBlocks)
}

func (p *program) rule(lane string) *policy {
	switch lane {
	case budget.Maintenance:
		return &p.maintenance
	case budget.Reimbursements:
		return &p.reimbursements
	default:
		panic("unknown policy lane")
	}
}

func (p *program) policyCaller(cur realm) (string, *policy) {
	caller := cur.Previous()
	if caller.PkgPath() == p.maintenance.path && caller.Address() == p.maintenance.addr {
		return budget.Maintenance, &p.maintenance
	}
	if caller.PkgPath() == p.reimbursements.path && caller.Address() == p.reimbursements.addr {
		return budget.Reimbursements, &p.reimbursements
	}
	panic("caller is not a pinned policy realm")
}

func (p *program) findClaim(lane string, itemID int64) *claim {
	if lane == budget.Refund {
		if itemID == 0 && p.refund.amount > 0 {
			return &p.refund
		}
		return nil
	}
	item := p.rule(lane).items[itemID]
	if item == nil || item.status != Approved {
		return nil
	}
	return &item.payment
}

func (rule *policy) pending(itemID int64) *reservation {
	item := rule.items[itemID]
	if item == nil || item.status != Reserved {
		panic("reservation is not pending")
	}
	return item
}

func (rule *policy) pendingBeforeDeadline(itemID int64) *reservation {
	item := rule.pending(itemID)
	if runtime.ChainHeight() >= item.deadline {
		panic("reservation deadline reached")
	}
	return item
}

func mustProgram(id int64) *program {
	p := programs[id]
	if p == nil {
		panic("program not found")
	}
	return p
}

func sponsorProgram(id int64, caller address) *program {
	p := mustProgram(id)
	if p.sponsor != caller {
		panic("only the program sponsor can do that")
	}
	return p
}

func fundingAmount() int64 {
	coins := unsafe.OriginSend()
	if len(coins) != 1 || coins[0].Denom != budget.Denom || coins[0].Amount <= 0 {
		panic("attach a positive amount of ugnot")
	}
	return coins[0].Amount
}

func requireTreasury(cur realm) {
	if !cur.IsCurrent() || cur.PkgPath() != packagePath {
		panic("invalid treasury context")
	}
}

func userCaller(cur realm, payable bool) address {
	requireTreasury(cur)
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("direct treasury call required")
	}
	if !payable && len(unsafe.OriginSend()) != 0 {
		panic("unexpected attached coins")
	}
	return caller.Address()
}

func emitItem(event string, programID int64, lane string, id int64, item *reservation) {
	chain.Emit(event, "program", number(programID), "lane", lane, "item", number(id),
		"recipient", string(item.payment.recipient), "amount", number(item.payment.amount),
		"period", number(item.period), "deadline", number(item.deadline))
}

func number(n int64) string {
	return strconv.FormatInt(n, 10)
}
