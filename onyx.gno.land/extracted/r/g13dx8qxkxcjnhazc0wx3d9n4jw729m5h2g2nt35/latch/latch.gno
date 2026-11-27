// Package latch implements a milestone escrow and micro-bounty realm on Gno.land.
// Every ugnot deposited into a deal has a deterministic exit path regardless of
// whether the client, worker, or arbiter stops responding.
package latch

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	ugnotDenom             = "ugnot"
	ugnotPerGNOT           = int64(1_000_000)
	maxDurationMinutes     = int64(525600)
	disputeWindowSeconds   = int64(7 * 86400)
	maxClaimTimeoutSeconds = int64(86400)
	minClaimTimeoutSeconds = int64(60)
	maxMilestones          = 10
	maxTitleRunes          = 80
	maxMilestoneTitleRunes = 60
	maxDeliverableRunes    = 160
	maxInt64               = int64(1<<63 - 1)
)

// DealStatus tracks the lifecycle state of an escrow deal.
type DealStatus string

const (
	DealOpen      DealStatus = "Open"
	DealActive    DealStatus = "Active"
	DealDisputed  DealStatus = "Disputed"
	DealCompleted DealStatus = "Completed"
	DealCancelled DealStatus = "Cancelled"
)

// MilestoneStatus tracks the lifecycle state of an individual milestone.
type MilestoneStatus string

const (
	MilestonePending   MilestoneStatus = "Pending"
	MilestoneSubmitted MilestoneStatus = "Submitted"
	MilestoneReleased  MilestoneStatus = "Released"
	MilestoneRefunded  MilestoneStatus = "Refunded"
)

// Milestone is one payable unit of work inside a Deal.
type Milestone struct {
	Index          int
	Title          string
	Amount         int64
	Status         MilestoneStatus
	DeliverableRef string
}

// Deal represents a multi-milestone escrow or open micro-bounty.
type Deal struct {
	ID              int
	Title           string
	Client          address
	Worker          address
	Arbiter         address
	WasOpenBounty   bool
	TotalDeposited  int64
	Remaining       int64
	CreatedAt       int64
	ClaimedAt       int64
	Deadline        int64
	DisputeDeadline int64
	Milestones      []Milestone
	Status          DealStatus
}

// ProtocolStats holds O(1) incremental counters across all deals.
type ProtocolStats struct {
	TotalDeals     int
	OpenDeals      int
	ActiveDeals    int
	DisputedDeals  int
	CompletedDeals int
	CancelledDeals int
	TotalDeposited int64
	TotalReleased  int64
	TotalRefunded  int64
}

var (
	deals      []Deal
	nextDealID = 1
	stats      ProtocolStats
)

func mustDeal(id int) *Deal {
	if id < 1 || id > len(deals) {
		panic("deal not found")
	}
	return &deals[id-1]
}

func adjustStatusCount(st DealStatus, delta int) {
	switch st {
	case DealOpen:
		stats.OpenDeals += delta
	case DealActive:
		stats.ActiveDeals += delta
	case DealDisputed:
		stats.DisputedDeals += delta
	case DealCompleted:
		stats.CompletedDeals += delta
	case DealCancelled:
		stats.CancelledDeals += delta
	}
}

func setDealStatus(d *Deal, next DealStatus) {
	if d.Status == next {
		return
	}
	if d.Status != "" {
		adjustStatusCount(d.Status, -1)
	}
	d.Status = next
	adjustStatusCount(next, 1)
}

func isBlankRune(r rune) bool {
	if r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\v' || r == '\f' || r == 0x85 || r == 0xa0 || r == 0x1680 || r == 0x2028 || r == 0x2029 || r == 0x202f || r == 0x205f || r == 0x3000 {
		return true
	}
	return r >= 0x2000 && r <= 0x200a
}

func isControlOrInvisible(r rune) bool {
	if r == '\n' || r == '\r' || r == '\t' {
		return false
	}
	if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
		return true
	}
	if (r >= 0x200b && r <= 0x200f) || (r >= 0x2028 && r <= 0x202e) || (r >= 0x2060 && r <= 0x206f) || r == 0xfeff {
		return true
	}
	return false
}

func validateText(raw string, maxRunes int, disallowPipe bool) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		panic("text must not be empty")
	}
	if disallowPipe && strings.Contains(trimmed, "|") {
		panic("pipe character '|' is reserved as milestone delimiter")
	}
	var clean strings.Builder
	visible := 0
	for _, r := range trimmed {
		if r == '\n' || r == '\r' || r == '\t' {
			clean.WriteByte(' ')
			continue
		}
		if isControlOrInvisible(r) {
			continue
		}
		clean.WriteRune(r)
		if !isBlankRune(r) {
			visible++
		}
	}
	if visible == 0 {
		panic("text must contain visible characters")
	}
	res := strings.TrimSpace(clean.String())
	if utf8.RuneCountInString(res) > maxRunes {
		panic("text exceeds maximum rune length")
	}
	return res
}

func parseMilestones(titlesCSV string, amountsCSV string) ([]Milestone, int64) {
	rawTitles := strings.Split(titlesCSV, "|")
	rawAmounts := strings.Split(amountsCSV, ",")
	if len(rawTitles) == 0 || len(rawTitles) > maxMilestones {
		panic("milestone count must be between 1 and 10")
	}
	if len(rawTitles) != len(rawAmounts) {
		panic("milestone titles and amounts length mismatch")
	}
	ms := make([]Milestone, len(rawTitles))
	var total int64
	for i := 0; i < len(rawTitles); i++ {
		title := validateText(rawTitles[i], maxMilestoneTitleRunes, true)
		amtStr := strings.TrimSpace(rawAmounts[i])
		amt, err := strconv.ParseInt(amtStr, 10, 64)
		if err != nil || amt <= 0 {
			panic("milestone amount must be a positive integer")
		}
		if total > maxInt64-amt {
			panic("milestone sum overflow")
		}
		total += amt
		ms[i] = Milestone{
			Index:  i,
			Title:  title,
			Amount: amt,
			Status: MilestonePending,
		}
	}
	return ms, total
}

func validateOptionalAddress(addr address, field string) {
	if addr == "" {
		return
	}
	if !addr.IsValid() {
		panic("invalid " + field + " address")
	}
}

func claimTimeoutSeconds(d *Deal) int64 {
	half := (d.Deadline - d.CreatedAt) / 2
	if half < minClaimTimeoutSeconds {
		return minClaimTimeoutSeconds
	}
	if half > maxClaimTimeoutSeconds {
		return maxClaimTimeoutSeconds
	}
	return half
}

func hasSubmittedMilestone(d *Deal) bool {
	for _, m := range d.Milestones {
		if m.Status == MilestoneSubmitted {
			return true
		}
	}
	return false
}

func hasReleasedMilestone(d *Deal) bool {
	for _, m := range d.Milestones {
		if m.Status == MilestoneReleased {
			return true
		}
	}
	return false
}

func finalizeStatus(d *Deal) {
	if d.Remaining != 0 {
		return
	}
	if hasReleasedMilestone(d) {
		setDealStatus(d, DealCompleted)
		return
	}
	setDealStatus(d, DealCancelled)
}

// -----------------------------------------------------------------------------
// Internal testable state transitions
// -----------------------------------------------------------------------------

func createDeal(
	caller address,
	realmAddr address,
	sentAmount int64,
	title string,
	worker address,
	arbiter address,
	durationMinutes int64,
	milestoneTitles string,
	milestoneAmounts string,
	now int64,
) int {
	cleanTitle := validateText(title, maxTitleRunes, false)
	if durationMinutes < 1 || durationMinutes > maxDurationMinutes {
		panic("duration must be between 1 and 525600 minutes")
	}
	validateOptionalAddress(worker, "worker")
	validateOptionalAddress(arbiter, "arbiter")
	if worker != "" && (worker == caller || worker == realmAddr) {
		panic("invalid worker address")
	}
	if arbiter != "" && (arbiter == caller || arbiter == worker || arbiter == realmAddr) {
		panic("invalid arbiter address")
	}
	ms, total := parseMilestones(milestoneTitles, milestoneAmounts)
	if sentAmount <= 0 || sentAmount != total {
		panic("attached ugnot must equal milestone sum")
	}

	status := DealOpen
	wasOpen := true
	if worker != "" {
		status = DealActive
		wasOpen = false
	}
	id := nextDealID
	nextDealID++

	deal := Deal{
		ID:             id,
		Title:          cleanTitle,
		Client:         caller,
		Worker:         worker,
		Arbiter:        arbiter,
		WasOpenBounty:  wasOpen,
		TotalDeposited: total,
		Remaining:      total,
		CreatedAt:      now,
		Deadline:       now + durationMinutes*60,
		Milestones:     ms,
	}
	deals = append(deals, deal)
	d := &deals[len(deals)-1]
	stats.TotalDeals++
	stats.TotalDeposited += total
	setDealStatus(d, status)
	return id
}

func claimDeal(caller address, dealID int, now int64) {
	d := mustDeal(dealID)
	if d.Status != DealOpen {
		panic("deal is not open")
	}
	if now >= d.Deadline {
		panic("deal deadline has passed")
	}
	if caller == d.Client || (d.Arbiter != "" && caller == d.Arbiter) {
		panic("client or arbiter cannot claim bounty")
	}
	d.Worker = caller
	d.ClaimedAt = now
	setDealStatus(d, DealActive)
}

func reclaimInactiveDeal(caller address, dealID int, now int64) {
	d := mustDeal(dealID)
	if caller != d.Client {
		panic("only client can reclaim inactive deal")
	}
	if d.Status != DealActive || !d.WasOpenBounty {
		panic("deal is not an active open bounty")
	}
	if hasSubmittedMilestone(d) || hasReleasedMilestone(d) {
		panic("cannot reclaim after worker progress")
	}
	if now < d.ClaimedAt+claimTimeoutSeconds(d) {
		panic("inactivity window has not elapsed")
	}
	d.Worker = ""
	d.ClaimedAt = 0
	setDealStatus(d, DealOpen)
}

func cancelDeal(caller address, dealID int) int64 {
	d := mustDeal(dealID)
	if caller != d.Client {
		panic("only client can cancel deal")
	}
	if d.Status != DealOpen || d.Remaining <= 0 {
		panic("only open funded deals can be cancelled")
	}
	refund := d.Remaining
	for i := range d.Milestones {
		if d.Milestones[i].Status == MilestonePending {
			d.Milestones[i].Status = MilestoneRefunded
		}
	}
	d.Remaining = 0
	stats.TotalRefunded += refund
	setDealStatus(d, DealCancelled)
	return refund
}

func submitMilestone(caller address, dealID int, milestoneIdx int, deliverableRef string, now int64) {
	d := mustDeal(dealID)
	if d.Status != DealActive {
		panic("deal is not active")
	}
	if caller != d.Worker {
		panic("only worker can submit milestone")
	}
	if now >= d.Deadline {
		panic("deal deadline has passed")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(d.Milestones) {
		panic("milestone index out of range")
	}
	m := &d.Milestones[milestoneIdx]
	if m.Status != MilestonePending && m.Status != MilestoneSubmitted {
		panic("milestone already finalized")
	}
	m.DeliverableRef = validateText(deliverableRef, maxDeliverableRunes, false)
	m.Status = MilestoneSubmitted
}

func releaseMilestone(caller address, dealID int, milestoneIdx int) (address, int64) {
	d := mustDeal(dealID)
	if d.Status != DealActive {
		panic("deal is not active")
	}
	if caller != d.Client {
		panic("only client can release milestone")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(d.Milestones) {
		panic("milestone index out of range")
	}
	m := &d.Milestones[milestoneIdx]
	if m.Status != MilestonePending && m.Status != MilestoneSubmitted {
		panic("milestone already finalized")
	}
	amt := m.Amount
	m.Status = MilestoneReleased
	d.Remaining -= amt
	stats.TotalReleased += amt
	finalizeStatus(d)
	return d.Worker, amt
}

func refundExpired(caller address, dealID int, now int64) int64 {
	d := mustDeal(dealID)
	if caller != d.Client {
		panic("only client can refund expired deal")
	}
	if d.Status != DealOpen && d.Status != DealActive {
		panic("deal cannot be refunded in current status")
	}
	if now < d.Deadline {
		panic("deadline has not passed")
	}
	var refund int64
	for i := range d.Milestones {
		m := &d.Milestones[i]
		if m.Status == MilestonePending || (m.Status == MilestoneSubmitted && d.Arbiter == "") {
			m.Status = MilestoneRefunded
			refund += m.Amount
		}
	}
	if refund <= 0 {
		panic("no refundable milestones")
	}
	d.Remaining -= refund
	stats.TotalRefunded += refund
	finalizeStatus(d)
	return refund
}

func raiseDispute(caller address, dealID int, now int64) {
	d := mustDeal(dealID)
	if d.Status != DealActive {
		panic("deal is not active")
	}
	if d.Arbiter == "" {
		panic("deal has no arbiter")
	}
	if caller != d.Client && caller != d.Worker {
		panic("only client or worker can raise dispute")
	}
	if !hasSubmittedMilestone(d) {
		panic("cannot dispute before at least one milestone is submitted")
	}
	d.DisputeDeadline = now + disputeWindowSeconds
	setDealStatus(d, DealDisputed)
}

func resolveDispute(caller address, dealID int, workerWins bool) (address, int64, address, int64) {
	d := mustDeal(dealID)
	if d.Status != DealDisputed {
		panic("deal is not disputed")
	}
	if caller != d.Arbiter {
		panic("only arbiter can resolve dispute")
	}
	var workerPayout, clientRefund int64
	for i := range d.Milestones {
		m := &d.Milestones[i]
		switch m.Status {
		case MilestonePending:
			m.Status = MilestoneRefunded
			clientRefund += m.Amount
		case MilestoneSubmitted:
			if workerWins {
				m.Status = MilestoneReleased
				workerPayout += m.Amount
			} else {
				m.Status = MilestoneRefunded
				clientRefund += m.Amount
			}
		}
	}
	d.Remaining = 0
	stats.TotalReleased += workerPayout
	stats.TotalRefunded += clientRefund
	finalizeStatus(d)
	return d.Worker, workerPayout, d.Client, clientRefund
}

func resolveDisputeTimeout(caller address, dealID int, now int64) (address, int64, address, int64) {
	d := mustDeal(dealID)
	if d.Status != DealDisputed {
		panic("deal is not disputed")
	}
	if caller != d.Client && caller != d.Worker {
		panic("only client or worker can trigger timeout fallback")
	}
	if now < d.DisputeDeadline {
		panic("dispute timeout has not elapsed")
	}
	var pendingSum, submittedSum int64
	for i := range d.Milestones {
		m := &d.Milestones[i]
		if m.Status == MilestonePending {
			m.Status = MilestoneRefunded
			pendingSum += m.Amount
		} else if m.Status == MilestoneSubmitted {
			submittedSum += m.Amount
		}
	}
	workerPayout := submittedSum / 2
	clientRefund := pendingSum + (submittedSum - workerPayout)
	for i := range d.Milestones {
		if d.Milestones[i].Status == MilestoneSubmitted {
			if workerPayout > 0 {
				d.Milestones[i].Status = MilestoneReleased
			} else {
				d.Milestones[i].Status = MilestoneRefunded
			}
		}
	}
	d.Remaining = 0
	stats.TotalReleased += workerPayout
	stats.TotalRefunded += clientRefund
	finalizeStatus(d)
	return d.Worker, workerPayout, d.Client, clientRefund
}

// -----------------------------------------------------------------------------
// Security guards & exported crossing entrypoints
// -----------------------------------------------------------------------------

func requireDirectUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("direct user calls only")
	}
	return cur.Previous().Address()
}

func rejectAttachedCoins() {
	if len(unsafe.OriginSend()) != 0 {
		panic("no coins accepted")
	}
}

func sendUgnot(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
		cur.Address(), to, chain.NewCoins(chain.NewCoin(ugnotDenom, amount)),
	)
}

// CreateDeal creates a new funded deal or open micro-bounty and returns its ID.
func CreateDeal(
	cur realm,
	title string,
	worker address,
	arbiter address,
	durationMinutes int64,
	milestoneTitles string,
	milestoneAmounts string,
) int {
	caller := requireDirectUserCall(cur)
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != ugnotDenom || sent[0].Amount <= 0 {
		panic("attach exactly one ugnot payment")
	}
	return createDeal(
		caller, cur.Address(), sent[0].Amount,
		title, worker, arbiter, durationMinutes,
		milestoneTitles, milestoneAmounts, time.Now().Unix(),
	)
}

// ClaimDeal assigns the caller as worker on an open micro-bounty.
func ClaimDeal(cur realm, dealID int) {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	claimDeal(caller, dealID, time.Now().Unix())
}

// ReclaimInactiveDeal lets the client unassign an inactive claimer on an open bounty.
func ReclaimInactiveDeal(cur realm, dealID int) {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	reclaimInactiveDeal(caller, dealID, time.Now().Unix())
}

// CancelDeal refunds an unclaimed open deal to the client and returns refunded ugnot.
func CancelDeal(cur realm, dealID int) int64 {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	refund := cancelDeal(caller, dealID)
	sendUgnot(cur, caller, refund)
	return refund
}

// SubmitMilestone attaches a deliverable reference to a pending or submitted milestone.
func SubmitMilestone(cur realm, dealID int, milestoneIdx int, deliverableRef string) {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	submitMilestone(caller, dealID, milestoneIdx, deliverableRef, time.Now().Unix())
}

// ReleaseMilestone pays a milestone out to the worker and returns released ugnot.
func ReleaseMilestone(cur realm, dealID int, milestoneIdx int) int64 {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	worker, amt := releaseMilestone(caller, dealID, milestoneIdx)
	sendUgnot(cur, worker, amt)
	return amt
}

// RefundExpired refunds eligible milestones after deadline and returns refunded ugnot.
func RefundExpired(cur realm, dealID int) int64 {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	refund := refundExpired(caller, dealID, time.Now().Unix())
	sendUgnot(cur, caller, refund)
	return refund
}

// RaiseDispute freezes an active arbiter-backed deal with >=1 submitted milestone.
func RaiseDispute(cur realm, dealID int) {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	raiseDispute(caller, dealID, time.Now().Unix())
}

// ResolveDispute settles a disputed deal by arbiter decision.
func ResolveDispute(cur realm, dealID int, workerWins bool) (int64, int64) {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	worker, workerPayout, client, clientRefund := resolveDispute(caller, dealID, workerWins)
	sendUgnot(cur, worker, workerPayout)
	sendUgnot(cur, client, clientRefund)
	return workerPayout, clientRefund
}

// ResolveDisputeTimeout settles a disputed deal 50/50 on submitted milestones after 7 days.
func ResolveDisputeTimeout(cur realm, dealID int) (int64, int64) {
	caller := requireDirectUserCall(cur)
	rejectAttachedCoins()
	worker, workerPayout, client, clientRefund := resolveDisputeTimeout(caller, dealID, time.Now().Unix())
	sendUgnot(cur, worker, workerPayout)
	sendUgnot(cur, client, clientRefund)
	return workerPayout, clientRefund
}

// -----------------------------------------------------------------------------
// Read-only JSON export for vm/qeval
// -----------------------------------------------------------------------------

func escapeJSON(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				continue
			}
			b.WriteRune(r)
		}
	}
	return b.String()
}

// ExportDealsJSON returns protocol stats and paginated deals (newest first) as JSON.
func ExportDealsJSON(offset int, limit int) string {
	if offset < 0 {
		offset = 0
	}
	if limit < 1 {
		limit = 20
	}
	if limit > 50 {
		limit = 50
	}
	var b strings.Builder
	b.WriteString(`{"stats":{`)
	b.WriteString(`"totalDeals":` + strconv.Itoa(stats.TotalDeals))
	b.WriteString(`,"openDeals":` + strconv.Itoa(stats.OpenDeals))
	b.WriteString(`,"activeDeals":` + strconv.Itoa(stats.ActiveDeals))
	b.WriteString(`,"disputedDeals":` + strconv.Itoa(stats.DisputedDeals))
	b.WriteString(`,"completedDeals":` + strconv.Itoa(stats.CompletedDeals))
	b.WriteString(`,"cancelledDeals":` + strconv.Itoa(stats.CancelledDeals))
	b.WriteString(`,"totalDeposited":` + strconv.FormatInt(stats.TotalDeposited, 10))
	b.WriteString(`,"totalReleased":` + strconv.FormatInt(stats.TotalReleased, 10))
	b.WriteString(`,"totalRefunded":` + strconv.FormatInt(stats.TotalRefunded, 10))
	b.WriteString(`},"total":` + strconv.Itoa(len(deals)) + `,"deals":[`)

	total := len(deals)
	emitted := 0
	for i := total - 1 - offset; i >= 0 && emitted < limit; i-- {
		d := deals[i]
		if emitted > 0 {
			b.WriteByte(',')
		}
		emitted++
		b.WriteString(`{"id":` + strconv.Itoa(d.ID))
		b.WriteString(`,"title":"` + escapeJSON(d.Title) + `"`)
		b.WriteString(`,"client":"` + string(d.Client) + `"`)
		b.WriteString(`,"worker":"` + string(d.Worker) + `"`)
		b.WriteString(`,"arbiter":"` + string(d.Arbiter) + `"`)
		if d.WasOpenBounty {
			b.WriteString(`,"wasOpenBounty":true`)
		} else {
			b.WriteString(`,"wasOpenBounty":false`)
		}
		b.WriteString(`,"totalDeposited":` + strconv.FormatInt(d.TotalDeposited, 10))
		b.WriteString(`,"remaining":` + strconv.FormatInt(d.Remaining, 10))
		b.WriteString(`,"createdAt":` + strconv.FormatInt(d.CreatedAt, 10))
		b.WriteString(`,"claimedAt":` + strconv.FormatInt(d.ClaimedAt, 10))
		b.WriteString(`,"deadline":` + strconv.FormatInt(d.Deadline, 10))
		b.WriteString(`,"disputeDeadline":` + strconv.FormatInt(d.DisputeDeadline, 10))
		b.WriteString(`,"status":"` + string(d.Status) + `"`)
		b.WriteString(`,"milestones":[`)
		for j, m := range d.Milestones {
			if j > 0 {
				b.WriteByte(',')
			}
			b.WriteString(`{"index":` + strconv.Itoa(m.Index))
			b.WriteString(`,"title":"` + escapeJSON(m.Title) + `"`)
			b.WriteString(`,"amount":` + strconv.FormatInt(m.Amount, 10))
			b.WriteString(`,"status":"` + string(m.Status) + `"`)
			b.WriteString(`,"deliverableRef":"` + escapeJSON(m.DeliverableRef) + `"}`)
		}
		b.WriteString(`]}`)
	}
	b.WriteString(`]}`)
	return b.String()
}
