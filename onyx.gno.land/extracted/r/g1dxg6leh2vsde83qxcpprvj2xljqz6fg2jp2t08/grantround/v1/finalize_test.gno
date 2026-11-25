package grantround

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

type ledger struct {
	addrs  []address
	before []int64
}

func snapshot(addrs ...address) ledger {
	l := ledger{addrs: addrs}
	for _, a := range addrs {
		l.before = append(l.before, bal(a))
	}
	return l
}

// delta returns the balance change of a since the snapshot.
func (l ledger) delta(a address) int64 {
	for i, x := range l.addrs {
		if x == a {
			return bal(a) - l.before[i]
		}
	}
	panic("address not in snapshot")
}

func everyone() ledger { return snapshot(customer, s1, s2, s3, p0, p1, pkgAddr) }

func finalizeAs(cur realm, a address, id int) {
	testing.SetRealm(user(a))
	Finalize(cross(cur), id)
}

// sheets commits each ev,scores pair, then opens them all in the sheet reveal
// phase and moves past HSheetReveal (round heights h0+11 -> h0+51).
func sheets(cur realm, id int, pairs ...string) {
	for i := 0; i+1 < len(pairs); i += 2 {
		commit(cur, id, address(pairs[i]), pairs[i+1])
	}
	testing.SkipHeights(30)
	for i := 0; i+1 < len(pairs); i += 2 {
		openSheet(cur, id, address(pairs[i]), pairs[i+1])
	}
	testing.SkipHeights(10)
}

func TestFinalizePaid(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	sheets(cur, id, e1.String(), "5,5;6,0", e2.String(), "4,0;6,2", e3.String(), "1,0;9,0")
	l := everyone()
	finalizeAs(cur, outsider, id)

	r := mustGet(id)
	uassert.True(t, r.Paid && r.Winner == 1 && !r.Cancelled, "paid to app 1")
	uassert.Equal(t, tGrant, l.delta(p1))
	uassert.Equal(t, int64(0), l.delta(p0))
	uassert.Equal(t, tBond, l.delta(s1))
	uassert.Equal(t, tBond, l.delta(s2))
	uassert.Equal(t, tBond, l.delta(s3))
	uassert.Equal(t, int64(0), l.delta(customer))
	uassert.Equal(t, -(tGrant + 3*tBond), l.delta(pkgAddr))
}

func TestFinalizeSlashesMissingEvaluator(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	sheets(cur, id, e1.String(), "5,5;6,0", e2.String(), "4,0;6,2")
	l := everyone()
	finalizeAs(cur, outsider, id)

	uassert.True(t, mustGet(id).Paid, "quorum of 2 met")
	uassert.Equal(t, tGrant, l.delta(p1))
	uassert.Equal(t, tBond, l.delta(s1))
	uassert.Equal(t, tBond, l.delta(s2))
	uassert.Equal(t, tBond-tSlash, l.delta(s3))
	uassert.Equal(t, tSlash, l.delta(customer))
	uassert.Equal(t, -(tGrant + 3*tBond), l.delta(pkgAddr))
}

func TestFinalizeCancelNoRule(cur realm, t *testing.T) {
	id := ruleRound(cur) // e1, e2 joined; e3 listed only
	l := everyone()
	testing.SkipHeights(10) // past HRule
	finalizeAs(cur, outsider, id)

	r := mustGet(id)
	uassert.True(t, r.Cancelled && r.Finalized, "cancelled")
	uassert.Equal(t, tGrant, l.delta(customer))
	uassert.Equal(t, tBond, l.delta(s1))
	uassert.Equal(t, tBond, l.delta(s2))
	uassert.Equal(t, int64(0), l.delta(s3))
	uassert.Equal(t, -(tGrant + 2*tBond), l.delta(pkgAddr))
}

func TestFinalizeCancelNoReveal(cur realm, t *testing.T) {
	id := adoptedRound(cur, 2, "lowest")
	l := everyone()
	testing.SkipHeights(20) // past HReveal
	finalizeAs(cur, outsider, id)

	uassert.True(t, mustGet(id).Cancelled, "cancelled")
	uassert.Equal(t, tGrant, l.delta(customer))
	uassert.Equal(t, tBond, l.delta(s3))
	uassert.Equal(t, -(tGrant + 3*tBond), l.delta(pkgAddr))
}

func TestFinalizeQuorumNotMet(cur realm, t *testing.T) {
	id := revealedRound(cur, 3, "lowest")
	sheets(cur, id, e1.String(), "5,5;6,0")
	l := everyone()
	finalizeAs(cur, outsider, id)

	uassert.False(t, mustGet(id).Paid, "not paid")
	uassert.Equal(t, int64(0), l.delta(p0)+l.delta(p1))
	uassert.Equal(t, tGrant+2*tSlash, l.delta(customer))
	uassert.Equal(t, tBond, l.delta(s1))
	uassert.Equal(t, tBond-tSlash, l.delta(s2))
	uassert.Equal(t, -(tGrant + 3*tBond), l.delta(pkgAddr))
}

func TestFinalizeTieRefund(cur realm, t *testing.T) {
	id := revealedRound(cur, 1, "refund")
	sheets(cur, id, e1.String(), "2,0;1,3")
	l := everyone()
	finalizeAs(cur, outsider, id)

	uassert.False(t, mustGet(id).Paid, "tie refunded")
	uassert.Equal(t, tGrant+2*tSlash, l.delta(customer))
	uassert.Equal(t, int64(0), l.delta(p0)+l.delta(p1))
}

func TestFinalizeOnceAndNotEarly(cur realm, t *testing.T) {
	id := revealedRound(cur, 1, "lowest")
	commit(cur, id, e1, "5,5;6,0")
	testing.SetRealm(user(outsider))
	uassert.AbortsContains(t, cur, "cannot be finalized yet", func() { Finalize(cross(cur), id) }, "score phase")
	testing.SkipHeights(30)
	openSheet(cur, id, e1, "5,5;6,0")
	testing.SetRealm(user(outsider))
	uassert.AbortsContains(t, cur, "cannot be finalized yet", func() { Finalize(cross(cur), id) }, "sheet reveal phase")

	testing.SkipHeights(10)
	testing.SetRealm(user(outsider))
	Finalize(cross(cur), id)
	l := everyone()
	uassert.AbortsContains(t, cur, "already finalized", func() { Finalize(cross(cur), id) })
	uassert.Equal(t, int64(0), l.delta(customer))
	uassert.Equal(t, int64(0), l.delta(p0))
	uassert.Equal(t, int64(0), l.delta(s1))
	uassert.Equal(t, int64(0), l.delta(pkgAddr))
}

// A commitment that is never opened is a missed mandate: the bond is slashed and
// the hidden sheet (which would flip the winner) is not counted.
func TestFinalizeSlashesUnopenedCommitment(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	commit(cur, id, e1, "5,5;6,0")
	commit(cur, id, e2, "4,0;6,2")
	commit(cur, id, e3, "10,10;0,0")
	testing.SkipHeights(30)
	openSheet(cur, id, e1, "5,5;6,0")
	openSheet(cur, id, e2, "4,0;6,2")
	testing.SkipHeights(10)
	l := everyone()
	before := TrackOf(e3)
	finalizeAs(cur, outsider, id)

	r := mustGet(id)
	uassert.True(t, r.Paid && r.Winner == 1, "only opened sheets count")
	uassert.Equal(t, tBond, l.delta(s1))
	uassert.Equal(t, tBond, l.delta(s2))
	uassert.Equal(t, tBond-tSlash, l.delta(s3))
	uassert.Equal(t, tSlash, l.delta(customer))
	uassert.Equal(t, -(tGrant + 3*tBond), l.delta(pkgAddr))
	after := TrackOf(e3)
	uassert.Equal(t, before.Accepted+1, after.Accepted)
	uassert.Equal(t, before.Fulfilled, after.Fulfilled)
	uassert.Equal(t, before.Missed+1, after.Missed)
}

func TestFinalizeQuorumCountsOpenedSheets(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	commit(cur, id, e1, "5,5;6,0")
	commit(cur, id, e2, "4,0;6,2")
	testing.SkipHeights(30)
	openSheet(cur, id, e1, "5,5;6,0")
	testing.SkipHeights(10)
	l := everyone()
	finalizeAs(cur, outsider, id)
	uassert.False(t, mustGet(id).Paid, "one opened sheet of quorum 2")
	uassert.Equal(t, tGrant+2*tSlash, l.delta(customer))
}

// A round nobody scores settles only after HSheetReveal: refund and full slashing.
func TestFinalizeNoSheets(cur realm, t *testing.T) {
	id := revealedRound(cur, 1, "lowest")
	testing.SkipHeights(39) // h0+50 == HSheetReveal
	testing.SetRealm(user(outsider))
	uassert.AbortsContains(t, cur, "cannot be finalized yet", func() { Finalize(cross(cur), id) }, "at HSheetReveal")
	testing.SkipHeights(1)
	l := everyone()
	finalizeAs(cur, outsider, id)
	uassert.Equal(t, tGrant+3*tSlash, l.delta(customer))
	uassert.Equal(t, 3*(tBond-tSlash), l.delta(s1)+l.delta(s2)+l.delta(s3))
}
