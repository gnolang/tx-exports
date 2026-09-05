package nsvote

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// A name is the ballot. Not a token balance and not a GNOT balance:
// holding a name is the one thing that cannot be borrowed for an
// afternoon, and it is the population this actually concerns.
func assertHolder(caller address) {
	if nsdata.BalanceOf(caller) <= 0 {
		panic("nsvote: only a name holder may take part")
	}
}

/*
assertNoSend refuses coins, on every entry point.

types.gno states "It holds no funds, at any point, for anybody" — and
until now nothing enforced it. This package contained no banker, no
OriginSend and no withdrawal path of any kind, so ugnot attached to a
Propose or a Vote landed at the realm's address and stayed there
forever, unreachable even by a successor realm. Nobody would do it on
purpose; a fat-fingered wallet or a script reusing a payment helper
would.

The early return matters: a call arriving from another realm carries no
OriginSend of its own to inspect, and treating that as an error would
break composition for a check that has nothing to look at.
*/
func assertNoSend(cur realm) {
	if !cur.Previous().IsUserCall() {
		return
	}
	if len(unsafe.OriginSend()) > 0 {
		panic("nsvote: this call takes no payment")
	}
}

// The admin is READ FROM THE VAULT rather than stored here. Two copies
// of "who is in charge" is how a revoked admin keeps power somewhere
// nobody remembered to look.
func assertIsAdmin(caller address) {
	if caller != nsdata.GetAdmin() {
		panic("nsvote: admin only")
	}
}

// Sortable keys, so paging is in creation order rather than the order
// the strings happen to compare in. 000000001 sorts before 000000010.
func key(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 9 {
		s = "0" + s
	}
	return s
}

func voteKey(id int64, voter address) string { return key(id) + "/" + voter.String() }

// The same shape a domain must have. A chain is asked for by its ticker,
// which fits the same rule, so one check covers both — and it keeps a
// proposal from asking for something that could never be created.
func assertLabel(label string) {
	if len(label) < 1 || len(label) > 63 {
		panic("nsvote: a domain is 1 to 63 characters")
	}
	for i := 0; i < len(label); i++ {
		c := label[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
		if !ok {
			panic("nsvote: lowercase letters, digits and hyphens only")
		}
	}
	if label[0] == '-' || label[len(label)-1] == '-' {
		panic("nsvote: a domain cannot start or end with a hyphen")
	}
}

// Propose asks for a domain or for a chain. Anyone holding a name may ask.
//
// The proposer pays the storage for their own proposal, and nothing
// else. That cost is the whole of the spam control: it is small enough
// that a real request is nothing to think about and large enough that
// filling the tree with rubbish is not free.
func Propose(cur realm, kind, label, reason string) int64 {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	assertHolder(caller)
	if kind != "domain" && kind != "chain" {
		panic("nsvote: kind is domain or chain")
	}
	assertLabel(label)

	if len(reason) > maxReason {
		panic(ufmt.Sprintf("nsvote: a reason is at most %d characters", maxReason))
	}
	/* NEITHER A NEWLINE NOR A PIPE. read.gno joins a proposal's fields
	   with "|" and its comment claimed Propose enforced this; it did
	   not. A reason carrying pipes arrived at the site as extra fields,
	   and the site's parser accepted any row with AT LEAST ten — so the
	   reason's own pipes became the created/yes/no/status/decided
	   columns. One cheap name bought a permanent card reading
	   "9412 for / 3 against · accepted" on a proposal with no votes.
	   The chain state was always correct; the forgery lived entirely in
	   the rendering, which is what makes an unchecked separator in a
	   packed row worth a panic rather than an escape. */
	if strings.ContainsAny(reason, "|\n\r") {
		panic("nsvote: a reason may not contain '|' or a newline")
	}
	// Only a DOMAIN request can be checked against the registry. Whether
	// a chain is already supported on profiles is a fact about the
	// website, which this realm has no way to know and should not
	// pretend to.
	if kind == "domain" && nsdata.DomainExists(label) {
		panic("nsvote: that domain already exists")
	}

	// One open request per label PER KIND. Two identical proposals split
	// the vote and neither ever looks convincing — but a domain called
	// solana and a chain called solana are different questions and must
	// not block each other.
	dup := false
	proposals.Iterate("", "", func(k string, v any) bool {
		p := v.(*Proposal)
		if p.status == "open" && p.kind == kind && p.label == label {
			dup = true
			return true
		}
		return false
	})
	if dup {
		panic("nsvote: there is already an open request for that")
	}

	id := nextID
	nextID++
	proposals.Set(key(id), &Proposal{
		kind: kind, label: label, reason: reason, proposer: caller,
		created: time.Now().Unix(), status: "open",
	})
	return id
}

// Vote records a yes or no. One per address per proposal, and it cannot
// be changed: a vote that can be switched turns the count into a race
// against whoever is watching, and there is no deadline here to make
// that fair.
func Vote(cur realm, id int64, yes bool) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	assertHolder(caller)

	v := proposals.Get(key(id))
	if v == nil {
		panic("nsvote: no such request")
	}
	p := v.(*Proposal)
	if p.status != "open" {
		panic("nsvote: that request is closed")
	}
	if votes.Get(voteKey(id, caller)) != nil {
		panic("nsvote: you have already voted on this one")
	}

	mark := "n"
	if yes {
		mark = "y"
		p.yes++
	} else {
		p.no++
	}
	votes.Set(voteKey(id, caller), mark)
}

// Withdraw closes a request the proposer no longer wants. The votes
// already cast stay: deleting them would refund their storage to
// whoever called this, which is not the person who paid it.
func Withdraw(cur realm, id int64) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	v := proposals.Get(key(id))
	if v == nil {
		panic("nsvote: no such request")
	}
	p := v.(*Proposal)
	if p.proposer != caller {
		panic("nsvote: only the proposer may withdraw it")
	}
	if p.status != "open" {
		panic("nsvote: that request is already closed")
	}
	p.status = "withdrawn"
	p.decided = time.Now().Unix()
}

// Resolve records what was decided. It does NOT create the domain —
// that stays a separate, deliberate call in nslogic. A vote is advice,
// and the vault has no undo.
func Resolve(cur realm, id int64, accepted bool) {
	assertNoSend(cur)
	assertIsAdmin(cur.Previous().Address())
	v := proposals.Get(key(id))
	if v == nil {
		panic("nsvote: no such request")
	}
	p := v.(*Proposal)
	if p.status != "open" {
		panic("nsvote: that request is already closed")
	}
	if accepted {
		p.status = "accepted"
	} else {
		p.status = "rejected"
	}
	p.decided = time.Now().Unix()
}

// Purge deletes a closed request and its votes, releasing the storage.
//
// The refund goes to WHOEVER SIGNS THIS, which is not the people who
// paid — so it is admin-only and it is not a tidying operation to run
// casually. It exists because a registry that can only ever grow is
// worse, not because reclaiming somebody else's deposit is free money.
func Purge(cur realm, id int64) int64 {
	assertNoSend(cur)
	assertIsAdmin(cur.Previous().Address())
	v := proposals.Get(key(id))
	if v == nil {
		panic("nsvote: no such request")
	}
	p := v.(*Proposal)
	if p.status == "open" {
		panic("nsvote: an open request cannot be purged")
	}

	// Collect first, mutate after: removing during an iteration walks a
	// tree that is changing underneath the walk.
	prefix := key(id) + "/"
	var doomed []string
	votes.Iterate(prefix, prefix+"\xff", func(k string, _ any) bool {
		doomed = append(doomed, k)
		return false
	})
	for _, k := range doomed {
		votes.Remove(k)
	}
	proposals.Remove(key(id))
	return int64(len(doomed))
}
