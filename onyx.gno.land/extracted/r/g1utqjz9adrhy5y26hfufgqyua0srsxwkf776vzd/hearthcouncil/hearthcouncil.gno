package hearthcouncil

// HearthCouncil is a DAO voting realm on Gno.land.
//
// Voting model (the core design decision — see DESIGN.md §4–5):
//   - Voting power is ESCROWED HEARTH, not a plain balance read. A voter
//     first Approves this realm on the HEARTH token, then Deposits.
//     Weight = own deposit + deposits of everyone delegating directly
//     to the voter (one level only; chains do not propagate).
//   - Why escrow: a plain balance read lets a voter vote, transfer the
//     tokens to a second address, and vote again with the same tokens.
//     Escrowed tokens sit in this realm, so they cannot move while a
//     vote is active: every vote locks each contributor's deposit until
//     the proposal is finalized, and Withdraw refuses locked funds.
//   - Delegation changes are refused while the delegator's tokens are
//     locked in an active vote, so a delegate can never double-count
//     the same deposit on one proposal via a mid-vote re-delegation.
//
// Lifecycle: Active → (Finalize, after EndHeight) → Succeeded/Defeated
// → (Queue) → Queued → (Execute, after ETA) → Executed.
// Anyone may call Finalize/Queue/Execute: they are permissionless state
// transitions. All failures panic (state reverts, per Gno semantics).
//
// Whitelisted actions (executed cross-realm from Execute):
//   - "set_param" on the hearthregistry realm, args "key=value".
//   - "release" from the DAO treasury, args "recipient:amount".
//     The treasury is the DAO's HEARTH balance minus total deposits:
//     only donated/seeded funds can be released, never deposits.

import (
	"strconv"
	"strings"

	"chain"
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1utqjz9adrhy5y26hfufgqyua0srsxwkf776vzd/hearth"
	"gno.land/r/g1utqjz9adrhy5y26hfufgqyua0srsxwkf776vzd/hearthregistry"
)

const (
	// MinProposalBalance is the HEARTH balance a proposer must hold.
	MinProposalBalance = 100
	// VotingPeriod is how long a proposal stays open (blocks).
	// Demo-tuned (~10 min at ~6s/block) so judges can see the full
	// flow in one session; a production deployment would use days.
	VotingPeriod = 100
	// TimelockDelay is the wait between Queue and Execute (blocks).
	// Demo-tuned (~5 min); production would use ~2 days.
	TimelockDelay = 50
	// QuorumBps is the required participation, in basis points of the
	// total supply snapshotted when the proposal is created (400 = 4%).
	QuorumBps = 400
	// RegistryPkgPath is the only allowed target for "set_param".
	RegistryPkgPath = "gno.land/r/g1utqjz9adrhy5y26hfufgqyua0srsxwkf776vzd/hearthregistry"
)

// ProposalStatus tracks a proposal through its lifecycle.
type ProposalStatus int

const (
	StatusActive ProposalStatus = iota
	StatusSucceeded
	StatusDefeated
	StatusQueued
	StatusExecuted
)

func (s ProposalStatus) String() string {
	switch s {
	case StatusActive:
		return "Active"
	case StatusSucceeded:
		return "Succeeded"
	case StatusDefeated:
		return "Defeated"
	case StatusQueued:
		return "Queued"
	case StatusExecuted:
		return "Executed"
	default:
		return "Unknown"
	}
}

// Proposal is one governance proposal. It is stored by value copy in the
// proposals tree; GetProposal returns a copy, never a pointer to state.
type Proposal struct {
	ID           uint64
	Proposer     address
	Title        string
	Description  string
	Target       string // realm path, or "" for treasury actions
	Action       string // "set_param" | "release"
	Args         string // raw args as submitted ("key=value" | "recipient:amount")
	ParamKey     string // parsed from Args for set_param
	ParamValue   string // parsed from Args for set_param
	ReleaseTo    address // parsed from Args for release
	ReleaseAmt   int64   // parsed from Args for release
	StartHeight  int64
	EndHeight    int64
	ForVotes     int64
	AgainstVotes int64
	Status       ProposalStatus
	Quorum       int64 // required participation, snapshotted at creation
	TotalSupply  int64 // snapshotted at creation
	ETA          int64 // first height Execute is allowed (0 until queued)
	ExecutedAt   int64
}

var (
	proposals      avl.Tree // padded ID string -> *Proposal
	nextID         uint64
	deposited      avl.Tree // address string -> int64 escrowed HEARTH
	locked         avl.Tree // address string -> int64 locked in active votes
	delegatedTo    avl.Tree // delegator address string -> delegate address string
	delegatedPower avl.Tree // delegate address string -> int64 (direct delegators' deposits)
	delegators     avl.Tree // "delegate:delegator" -> true (reverse index)
	voteLocks      avl.Tree // "paddedID:address" -> int64 locked by that vote
	voted          avl.Tree // "paddedID:address" -> true
	totalDeposited int64
	daoAddr        address
)

func init(cur realm) {
	daoAddr = cur.Address()
}

// ---- read-only ----

// DAOAddress returns this realm's own address (the deposit + treasury holder).
func DAOAddress() address {
	return daoAddr
}

// ProposalCount returns the number of proposals ever created.
func ProposalCount() int {
	return int(nextID)
}

// GetProposal returns a copy of the proposal, or panics if it does not exist.
func GetProposal(id uint64) Proposal {
	p := mustProposal(id)
	return *p
}

// Deposited returns how much HEARTH addr has escrowed in the DAO.
func Deposited(addr address) int64 {
	return getInt(&deposited, addr.String())
}

// Locked returns how much of addr's deposit is locked in active votes.
func Locked(addr address) int64 {
	return getInt(&locked, addr.String())
}

// Unlocked returns the withdrawable part of addr's deposit.
func Unlocked(addr address) int64 {
	return Deposited(addr) - Locked(addr)
}

// DelegatedTo returns the address addr delegated to, or "" if none.
func DelegatedTo(addr address) address {
	v := delegatedTo.Get(addr.String())
	if v == nil {
		return address("")
	}
	return address(v.(string))
}

// DelegatedPower returns the voting power delegated directly to addr
// (the sum of its direct delegators' deposits).
func DelegatedPower(addr address) int64 {
	return getInt(&delegatedPower, addr.String())
}

// VotingPower returns addr's current voting weight: own deposit (only if
// addr has not delegated it away) plus power delegated directly to addr.
func VotingPower(addr address) int64 {
	power := DelegatedPower(addr)
	if !delegatedTo.Has(addr.String()) {
		power += Deposited(addr)
	}
	return power
}

// HasVoted reports whether addr already voted on proposal id.
func HasVoted(id uint64, addr address) bool {
	return voted.Has(voteKey(id, addr))
}

// TotalDeposited returns all HEARTH currently escrowed by voters.
func TotalDeposited() int64 {
	return totalDeposited
}

// Treasury returns the DAO's spendable HEARTH: its token balance minus
// all deposits (deposits are never spendable by proposals).
func Treasury() int64 {
	return hearth.BalanceOf(daoAddr) - totalDeposited
}

// DelegatorsOf returns the addresses delegating directly to addr.
func DelegatorsOf(addr address) []address {
	prefix := addr.String() + ":"
	out := []address{}
	delegators.Iterate(prefix, prefixEnd(prefix), func(key string, value any) bool {
		parts := strings.SplitN(key, ":", 2)
		if len(parts) == 2 {
			out = append(out, address(parts[1]))
		}
		return false
	})
	return out
}

// ---- deposits ----

// Deposit escrows amount HEARTH into the DAO. The caller must first
// Approve this realm on the HEARTH token for at least amount.
func Deposit(cur realm, amount int64) {
	caller := cur.Previous().Address()
	if amount <= 0 {
		panic("deposit amount must be positive")
	}
	hearth.TransferFrom(cross(cur), caller, daoAddr, amount)
	addInt(&deposited, caller.String(), amount)
	totalDeposited += amount
	if to, ok := delegateOf(caller); ok {
		addInt(&delegatedPower, to, amount)
	}
	chain.Emit("Deposit", "from", caller.String(), "amount", strconv.FormatInt(amount, 10))
}

// Withdraw returns amount of the caller's unlocked deposit.
func Withdraw(cur realm, amount int64) {
	caller := cur.Previous().Address()
	if amount <= 0 {
		panic("withdraw amount must be positive")
	}
	if amount > Unlocked(caller) {
		panic("amount exceeds unlocked deposit")
	}
	addInt(&deposited, caller.String(), -amount)
	totalDeposited -= amount
	if to, ok := delegateOf(caller); ok {
		addInt(&delegatedPower, to, -amount)
	}
	hearth.Transfer(cross(cur), caller, amount)
	chain.Emit("Withdraw", "to", caller.String(), "amount", strconv.FormatInt(amount, 10))
}

// ---- delegation ----

// Delegate moves the caller's voting power to `to` (one level only).
// It is refused while the caller's tokens are locked in an active vote.
func Delegate(cur realm, to address) {
	caller := cur.Previous().Address()
	if to == caller {
		panic("cannot delegate to yourself")
	}
	if delegatedTo.Has(caller.String()) {
		panic("already delegating; undelegate first")
	}
	if Locked(caller) > 0 {
		panic("cannot change delegation while your tokens are locked in an active vote")
	}
	delegatedTo.Set(caller.String(), to.String())
	delegators.Set(to.String()+":"+caller.String(), true)
	addInt(&delegatedPower, to.String(), Deposited(caller))
	chain.Emit("Delegate", "from", caller.String(), "to", to.String())
}

// Undelegate returns the caller's voting power to itself. Refused while
// the caller's tokens are locked in an active vote.
func Undelegate(cur realm) {
	caller := cur.Previous().Address()
	to, ok := delegateOf(caller)
	if !ok {
		panic("not delegating")
	}
	if Locked(caller) > 0 {
		panic("cannot change delegation while your tokens are locked in an active vote")
	}
	addInt(&delegatedPower, to, -Deposited(caller))
	delegatedTo.Remove(caller.String())
	delegators.Remove(to + ":" + caller.String())
	chain.Emit("Undelegate", "from", caller.String(), "to", to)
}

// ---- proposals ----

// CreateProposal opens a new proposal and returns its ID. The proposer
// must have at least MinProposalBalance HEARTH deposited in the DAO
// (escrowed stake is the anti-spam bar — a proposer who deposited
// everything can still propose). Args format depends on Action:
//   - "set_param": target must be the hearthregistry realm, args "key=value"
//   - "release":   target must be "", args "recipient:amount" (g1 address)
func CreateProposal(cur realm, title, desc, target, action, args string) uint64 {
	caller := cur.Previous().Address()
	if Deposited(caller) < MinProposalBalance {
		panic("need at least 100 HEARTH deposited to propose")
	}
	if title == "" || desc == "" {
		panic("title and description must not be empty")
	}
	p := &Proposal{
		ID:          nextID,
		Proposer:    caller,
		Title:       title,
		Description: desc,
		Target:      target,
		Action:      action,
		Args:        args,
		Status:      StatusActive,
	}
	switch action {
	case "set_param":
		if target != RegistryPkgPath {
			panic("set_param target must be the hearthregistry realm")
		}
		k, v, ok := splitKV(args)
		if !ok || k == "" || v == "" {
			panic("set_param args must be key=value")
		}
		p.ParamKey, p.ParamValue = k, v
	case "release":
		if target != "" {
			panic("release target must be empty (treasury is the DAO itself)")
		}
		to, amount, ok := splitRelease(args)
		if !ok {
			panic("release args must be recipient:amount")
		}
		if amount <= 0 {
			panic("release amount must be positive")
		}
		p.ReleaseTo, p.ReleaseAmt = to, amount
	default:
		panic("unknown action; allowed: set_param, release")
	}
	now := runtime.ChainHeight()
	totalSupply := hearth.TotalSupply()
	p.StartHeight = now
	p.EndHeight = now + VotingPeriod
	p.Quorum = totalSupply * QuorumBps / 10000
	p.TotalSupply = totalSupply
	proposals.Set(pkey(p.ID), p)
	nextID++
	chain.Emit("ProposalCreated", "id", strconv.FormatUint(p.ID, 10), "proposer", caller.String(), "action", action)
	return p.ID
}

// Vote casts the caller's full current voting weight for or against a
// proposal, and locks each contributing deposit until finalization.
func Vote(cur realm, id uint64, support bool) {
	caller := cur.Previous().Address()
	p := mustProposal(id)
	if p.Status != StatusActive {
		panic("proposal is not active")
	}
	now := runtime.ChainHeight()
	if now < p.StartHeight || now >= p.EndHeight {
		panic("voting is closed for this proposal")
	}
	if voted.Has(voteKey(id, caller)) {
		panic("already voted on this proposal")
	}
	weight := VotingPower(caller)
	if weight <= 0 {
		panic("no voting power: deposit HEARTH or receive a delegation first")
	}
	voted.Set(voteKey(id, caller), true)
	if support {
		p.ForVotes += weight
	} else {
		p.AgainstVotes += weight
	}
	proposals.Set(pkey(id), p)
	// Lock every deposit that contributed to this vote.
	if !delegatedTo.Has(caller.String()) {
		lockAmount(id, caller, Deposited(caller))
	}
	for _, d := range DelegatorsOf(caller) {
		lockAmount(id, d, Deposited(d))
	}
	chain.Emit("VoteCast", "id", strconv.FormatUint(id, 10), "voter", caller.String(), "weight", strconv.FormatInt(weight, 10))
}

// Finalize closes voting on a proposal once EndHeight has passed and
// sets Succeeded (quorum met and for > against) or Defeated, releasing
// all vote locks for the proposal.
func Finalize(cur realm, id uint64) {
	p := mustProposal(id)
	if p.Status != StatusActive {
		panic("proposal is not active")
	}
	if runtime.ChainHeight() < p.EndHeight {
		panic("voting is still open")
	}
	if p.ForVotes+p.AgainstVotes >= p.Quorum && p.ForVotes > p.AgainstVotes {
		p.Status = StatusSucceeded
	} else {
		p.Status = StatusDefeated
	}
	proposals.Set(pkey(id), p)
	releaseLocks(id)
	chain.Emit("ProposalFinalized", "id", strconv.FormatUint(id, 10), "status", p.Status.String())
}

// Queue moves a succeeded proposal into the timelock. Execute is allowed
// from ETA = current height + TimelockDelay.
func Queue(cur realm, id uint64) {
	p := mustProposal(id)
	if p.Status != StatusSucceeded {
		panic("only a succeeded proposal can be queued")
	}
	p.Status = StatusQueued
	p.ETA = runtime.ChainHeight() + TimelockDelay
	proposals.Set(pkey(id), p)
	chain.Emit("ProposalQueued", "id", strconv.FormatUint(id, 10), "eta", strconv.FormatInt(p.ETA, 10))
}

// Execute runs a queued proposal after its timelock expired. The action
// is executed cross-realm (set_param) or from the treasury (release).
func Execute(cur realm, id uint64) {
	p := mustProposal(id)
	if p.Status != StatusQueued {
		panic("only a queued proposal can be executed")
	}
	if runtime.ChainHeight() < p.ETA {
		panic("timelock has not expired")
	}
	switch p.Action {
	case "set_param":
		hearthregistry.SetParam(cross(cur), p.ParamKey, p.ParamValue)
	case "release":
		if p.ReleaseAmt > Treasury() {
			panic("treasury cannot cover this release")
		}
		hearth.Transfer(cross(cur), p.ReleaseTo, p.ReleaseAmt)
	default:
		panic("unknown action")
	}
	p.Status = StatusExecuted
	p.ExecutedAt = runtime.ChainHeight()
	proposals.Set(pkey(id), p)
	chain.Emit("ProposalExecuted", "id", strconv.FormatUint(id, 10), "action", p.Action)
}

// ---- internals ----

func mustProposal(id uint64) *Proposal {
	v := proposals.Get(pkey(id))
	if v == nil {
		panic("proposal not found")
	}
	return v.(*Proposal)
}

func getInt(tree *avl.Tree, key string) int64 {
	v := tree.Get(key)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func addInt(tree *avl.Tree, key string, delta int64) {
	tree.Set(key, getInt(tree, key)+delta)
}

func delegateOf(addr address) (string, bool) {
	v := delegatedTo.Get(addr.String())
	if v == nil {
		return "", false
	}
	return v.(string), true
}

// lockAmount records that amount of addr's deposit is committed to the
// vote on proposal id until finalization.
func lockAmount(id uint64, addr address, amount int64) {
	if amount <= 0 {
		return
	}
	voteLocks.Set(lockKey(id, addr), amount)
	addInt(&locked, addr.String(), amount)
}

// releaseLocks frees every deposit locked by votes on proposal id.
func releaseLocks(id uint64) {
	prefix := pkey(id) + ":"
	keys := []string{}
	voteLocks.Iterate(prefix, prefixEnd(prefix), func(key string, value any) bool {
		keys = append(keys, key)
		return false
	})
	for _, key := range keys {
		amount := voteLocks.Get(key).(int64)
		addr := key[len(prefix):]
		addInt(&locked, addr, -amount)
		voteLocks.Remove(key)
	}
}

// pkey pads the proposal ID so avl iteration order is numeric.
func pkey(id uint64) string {
	return ufmt.Sprintf("%020d", id)
}

// voteKey / lockKey share the "paddedID:address" scheme.
func voteKey(id uint64, addr address) string {
	return pkey(id) + ":" + addr.String()
}

func lockKey(id uint64, addr address) string {
	return pkey(id) + ":" + addr.String()
}

// prefixEnd returns the smallest string greater than every string with
// the given prefix (for avl range iteration).
func prefixEnd(prefix string) string {
	b := []byte(prefix)
	b[len(b)-1]++
	return string(b)
}

// splitKV parses "key=value".
func splitKV(args string) (string, string, bool) {
	i := strings.Index(args, "=")
	if i < 0 {
		return "", "", false
	}
	return args[:i], args[i+1:], true
}

// splitRelease parses "recipient:amount" with a g1 recipient address.
func splitRelease(args string) (address, int64, bool) {
	i := strings.Index(args, ":")
	if i < 0 {
		return address(""), 0, false
	}
	to := args[:i]
	if len(to) != 40 || !strings.HasPrefix(to, "g1") {
		return address(""), 0, false
	}
	amount, err := strconv.ParseInt(args[i+1:], 10, 64)
	if err != nil {
		return address(""), 0, false
	}
	return address(to), amount, true
}
