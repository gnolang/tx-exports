package sugarproxy

import (
	"strconv"
	"strings"

	governor "gno.land/p/g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6/governor/v0"
	grc20votes "gno.land/p/g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6/grc20votes/v0"
)

// SUGAR, the governance token: kourt's grc20votes ledger (balances checkpointed per epoch of 720 blocks, about an
// hour, so a vote weighs what a holder held before the proposal) and kourt's governor over it. Both packages are
// deployed under Jae's address on gnoland-1.
//
// The governor's proposals here are of two kinds of this realm's own: add an item, remove one. Holders propose
// with Propose(cur, kind, payload, title), vote with Vote, and anyone may Execute a proposal that passed and
// whose delay is over.
var (
	ledger = grc20votes.NewLedger("sugar proxy", "SUGAR", 6, 720)
	engine = governor.New(ledger, ledger)
)

// InitialSupply is minted to the deployer at init: 1,000,000 SUGAR of 6 decimals.
const InitialSupply = int64(1_000_000_000_000)

const (
	kindAdd    = governor.Reserved + "sugar-add"
	kindRemove = governor.Reserved + "sugar-remove"
)

// rules are kourt's bootstrap rules (a fifth of the supply turns out, two thirds of the votes cast say yes, a week
// to vote, two days' delay, two weeks to execute), except that proposing takes 0.1% of the supply: kourt's lets
// anyone propose.
func rules() governor.Rules {
	r := governor.BootstrapRules()
	r.ProposeBps = 10
	return r
}

// setupGovernor adopts this realm's two kinds; init calls it.
func setupGovernor() {
	engine.InstallBuiltin(addKind{}, rules())
	engine.InstallBuiltin(removeKind{}, rules())
}

func mintInitial(to address) { ledger.Mint(to, InitialSupply) }

// KindAdd and KindRemove are the names to propose under.
func KindAdd() string    { return kindAdd }
func KindRemove() string { return kindRemove }

type addKind struct{}

func (addKind) Name() string { return kindAdd }
func (addKind) Describe(payload string) string {
	return "Add to sugar proxy's rules: `" + payload + "`. Once executed it waits out the veto window for its kind, " +
		"during which GovDAO or the guardian may veto it."
}
func (addKind) Check(payload string) error {
	_, _, err := parse(payload)
	return err
}
func (addKind) Do(_ int, _ realm, payload string) error {
	_, err := add(payload, "token")
	return err
}

type removeKind struct{}

func (removeKind) Name() string { return kindRemove }
func (removeKind) Describe(payload string) string {
	return "Remove item " + payload + " from sugar proxy's rules, at once."
}
func (removeKind) Check(payload string) error {
	id, err := strconv.Atoi(strings.TrimSpace(payload))
	if err != nil {
		return errorf("the payload is an item's number")
	}
	if it := find(id); it == nil || it.State != StateApproved {
		return errorf("item %d isn't approved", id)
	}
	return nil
}
func (removeKind) Do(_ int, _ realm, payload string) error {
	id, _ := strconv.Atoi(strings.TrimSpace(payload))
	return end(id, false, "token")
}

const errStaleRealm = "sugarproxy: that realm value is not live; pass your own cur"

func live(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
}

// Propose opens a proposal: kind is KindAdd() with a payload "kind|field|...", or KindRemove() with an item's
// number. It needs the governor's share of the supply to propose.
func Propose(cur realm, kind, payload, title string) int64 {
	live(cur)
	return engine.Propose(cur.Previous().Address(), kind, payload, title)
}

// Vote casts the caller's weight: "yes", "no" or "abstain".
func Vote(cur realm, id int64, choice string) {
	live(cur)
	engine.Vote(cur.Previous().Address(), id, choice)
}

// Execute carries out a proposal that passed, once its delay is over.
func Execute(cur realm, id int64) {
	live(cur)
	engine.Execute(cur.Previous().Address(), id, func(k governor.Kind, sub, payload string) error {
		return k.Do(0, cur.Sub(sub), payload)
	})
}

// Cancel withdraws the caller's own open proposal.
func Cancel(cur realm, id int64) {
	live(cur)
	engine.Cancel(cur.Previous().Address(), id)
}

// Settle closes a proposal whose voting is over.
func Settle(cur realm, id int64) {
	live(cur)
	engine.Settle(cur.Previous().Address(), id)
}

// State, Describe and Tally read a proposal.
func State(id int64) string                           { return engine.State(id) }
func DescribeProposal(id int64) string                { return engine.Describe(id) }
func Tally(id int64) (yes, no, abstain, total int64) { return engine.Tally(id) }

// --- the token ---

func TotalSupply() int64              { return ledger.TotalSupply() }
func BalanceOf(who address) int64     { return ledger.BalanceOf(who) }
func VotesOf(who address) int64       { return ledger.VotesOf(who) }
func DelegateOf(who address) address  { return ledger.DelegateOf(who) }
func Allowance(o, s address) int64    { return ledger.Allowance(o, s) }

// Transfer sends SUGAR from the caller.
func Transfer(cur realm, to address, amount int64) {
	live(cur)
	ledger.Transfer(cur.Previous().Address(), to, amount)
}

// Approve lets spender move up to amount of the caller's SUGAR.
func Approve(cur realm, spender address, amount int64) {
	live(cur)
	ledger.Approve(cur.Previous().Address(), spender, amount)
}

// TransferFrom moves SUGAR the owner approved the caller to move.
func TransferFrom(cur realm, from, to address, amount int64) {
	live(cur)
	ledger.TransferFrom(cur.Previous().Address(), from, to, amount)
}

// DelegateVotes gives the caller's voting weight to another address (its own, to take it back).
func DelegateVotes(cur realm, to address) {
	live(cur)
	ledger.Delegate(cur.Previous().Address(), to)
}
