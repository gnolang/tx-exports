package bubble

import (
	governor "gno.land/p/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/governor/v0"
)

// The governor: kourt's engine on this ledger, with this realm's own powers installed under the reserved prefix.
// Everything about proposals — kinds, tally, rules, sweep, pages — is the engine's; what is here is what only a
// realm can do: hold a live cur, check it, read who is calling, dispatch a decided kind with a sub-realm.
//
// "Usable for governance flexibly as we build it out": a new power is a Kind any realm can Offer (published,
// immutable code plus the bar it would pass at) and the holders adopt by govern:adopt. The token is never
// redeployed to gain a power.

type (
	Kind  = governor.Kind
	Rules = governor.Rules
)

func NewRules(quorumBps, thresholdBps, votingBlocks, delayBlocks, graceBlocks, proposeBps int64) Rules {
	return governor.NewRules(quorumBps, thresholdBps, votingBlocks, delayBlocks, graceBlocks, proposeBps)
}

func TextOnly(s string) error { return governor.TextOnly(s) }

// engine is this realm's governor. Unexported: whoever holds it can adopt a kind without a vote.
var engine = governor.New(ledger, ledger)

func init() {
	installKinds()
}

// dispatch runs a decided kind with a SUB-realm, never this realm's own capability (the engine's note on
// dispatch: a kind holding the live cur could cross into anything that trusts this realm).
func dispatch(cur realm) governor.Dispatch {
	return func(k Kind, subpath, payload string) error {
		return k.Do(0, cur.Sub(subpath), payload)
	}
}

// Offer publishes a kind. It grants nothing: the holders adopt it by vote.
func Offer(cur realm, k Kind, r Rules) { engine.Offer(caller(cur), k, r) }

// Propose asks a question under an adopted kind. A money kind carries its absolute turnout floor (kinds.gno).
func Propose(cur realm, kind, payload, title string) int64 {
	who := caller(cur)
	var id int64
	if floor := quorumFloor(kind); floor > 0 {
		id = engine.ProposeWithQuorum(who, kind, payload, title, floor)
	} else {
		id = engine.Propose(who, kind, payload, title)
	}
	if len(askedKinds) > 512 { // a guard, not a record: only decided-but-unnoted money votes need it, and those are few
		askedKinds = map[int64]string{}
	}
	askedKinds[id] = kind
	return id
}

// Vote casts the caller's weight as of the proposal's sealed epoch: "yes", "no" or "abstain".
func Vote(cur realm, id int64, choice string) { engine.Vote(caller(cur), id, choice) }

func VoteWithReason(cur realm, id int64, choice, reason string) {
	engine.VoteWithReason(caller(cur), id, choice, reason)
}

// Cancel withdraws the proposer's own open proposal.
func Cancel(cur realm, id int64) { engine.Cancel(caller(cur), id) }

// Settle writes down a conclusion the rules already reached. Permissionless. A decided money vote's turnout goes
// into the bar's memory (kinds.gno).
func Settle(cur realm, id int64) {
	engine.Settle(caller(cur), id)
	if isMoneyKind(kindOf(id)) {
		noteTurnout(id)
	}
}

// Execute runs a decided proposal after its delay. Permissionless.
func Execute(cur realm, id int64) {
	engine.Execute(caller(cur), id, dispatch(cur))
	if isMoneyKind(kindOf(id)) {
		noteTurnout(id)
	}
}

// kindOf is the kind a proposal was asked under, as this realm noted it at Propose (the engine describes a
// proposal by its payload alone); an id it never saw is "".
func kindOf(id int64) string { return askedKinds[id] }

// askedKinds is id -> kind for the proposals asked here, the last few hundred.
var askedKinds = map[int64]string{}

func ReleaseRoll(cur realm, id int64) { engine.ReleaseRoll(caller(cur), id) }

func Sweep(cur realm) {
	caller(cur)
	engine.Sweep()
}

// ------------------------------------------------------------------ reads --

func State(id int64) string                         { return engine.State(id) }
func Describe(id int64) string                      { return engine.Describe(id) }
func Preview(kind, payload string) string           { return engine.Preview(kind, payload) }
func HasVoted(id int64, who address) bool           { return engine.HasVoted(id, who) }
func Tally(id int64) (yes, no, abstain, total int64) { return engine.Tally(id) }
func KindRules(name string) (Rules, bool)           { return engine.KindRules(name) }

func Timings(id int64) (opened, closes, ready, expires int64) { return engine.Timings(id) }

func VoteOf(id int64, who address) (choice string, weight int64, ok bool) {
	return engine.VoteOf(id, who)
}
