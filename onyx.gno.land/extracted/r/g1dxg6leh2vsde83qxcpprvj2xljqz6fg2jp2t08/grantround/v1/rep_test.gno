package grantround

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func assertTrack(t *testing.T, a address, acc, ful, miss int, name string) {
	tr := TrackOf(a)
	uassert.True(t, tr.Accepted == acc && tr.Fulfilled == ful && tr.Missed == miss,
		name+": got "+tr.String())
}

func TestTrackAfterSettlement(cur realm, t *testing.T) {
	f1, f2, f3 := testutils.TestAddress("rep-f1"), testutils.TestAddress("rep-f2"), testutils.TestAddress("rep-f3")
	sf1, sf2 := testutils.TestAddress("rep-sf1"), testutils.TestAddress("rep-sf2")
	id, _ := newRound(cur, f1, sf1, f2, sf2, f3, f3)
	joinAll(cur, id, f1, sf1, f2, sf2, f3, f3) // f3 sponsors itself
	assertTrack(t, f1, 0, 0, 0, "f1 before finalize")

	testing.SkipHeights(11)
	testing.SetRealm(user(f1))
	seq := ProposeRule(cross(cur), id, "weighted", "a:1", 1, "lowest", "")
	testing.SetRealm(user(f2))
	ApproveRule(cross(cur), id, seq)
	testing.SetRealm(user(f3))
	ApproveRule(cross(cur), id, seq)
	testing.SetRealm(user(customer))
	Reveal(cross(cur), id, testAppsEncoded(), tSalt)
	sheets(cur, id, f1.String(), "1;2", f3.String(), "3;1")
	finalizeAs(cur, outsider, id)

	assertTrack(t, f1, 1, 1, 0, "f1")
	assertTrack(t, sf1, 1, 1, 0, "sf1")
	assertTrack(t, f2, 1, 0, 1, "f2")
	assertTrack(t, sf2, 1, 0, 1, "sf2")
	assertTrack(t, f3, 1, 1, 0, "f3 self-sponsored counts once")
}

func TestTrackUnchangedOnCancel(cur realm, t *testing.T) {
	h1, sh1 := testutils.TestAddress("rep-h1"), testutils.TestAddress("rep-sh1")
	id, _ := newRound(cur, h1, sh1)
	joinAll(cur, id, h1, sh1)
	testing.SkipHeights(21) // past HRule with no rule
	finalizeAs(cur, outsider, id)
	assertTrack(t, h1, 0, 0, 0, "h1")
	assertTrack(t, sh1, 0, 0, 0, "sh1")
}

// Join opens empty records, paid by the sponsor, so that Finalize only updates them.
func TestJoinOpensEmptyTracks(cur realm, t *testing.T) {
	j1, sj1 := testutils.TestAddress("rep-j1"), testutils.TestAddress("rep-sj1")
	j2, j3 := testutils.TestAddress("rep-j2"), testutils.TestAddress("rep-j3")
	id, _ := newRound(cur, j1, sj1, j2, j2, j3, outsider)
	n := tracks.Size()
	joinAll(cur, id, j1, sj1)
	uassert.True(t, tracks.Has(j1.String()) && tracks.Has(sj1.String()), "evaluator and sponsor have records")
	uassert.Equal(t, n+2, tracks.Size())
	joinAll(cur, id, j2, j2) // self-sponsored
	uassert.Equal(t, n+3, tracks.Size(), "one record for a self-sponsored evaluator")
	uassert.False(t, tracks.Has(j3.String()), "listed but not joined: no record")
	for _, a := range []address{j1, sj1, j2} {
		assertTrack(t, a, 0, 0, 0, a.String())
	}

	testing.SkipHeights(11)
	testing.SetRealm(user(j1))
	seq := ProposeRule(cross(cur), id, "weighted", "a:1", 1, "lowest", "")
	testing.SetRealm(user(j2))
	ApproveRule(cross(cur), id, seq)
	testing.SetRealm(user(customer))
	Reveal(cross(cur), id, testAppsEncoded(), tSalt)
	assertTrack(t, j1, 0, 0, 0, "counters move only in Finalize")
	sheets(cur, id, j1.String(), "1;2")
	finalizeAs(cur, outsider, id)
	uassert.Equal(t, n+3, tracks.Size(), "Finalize adds no records")
	assertTrack(t, j1, 1, 1, 0, "j1")
	assertTrack(t, sj1, 1, 1, 0, "sj1")
	assertTrack(t, j2, 1, 0, 1, "j2")

	// Joining another round must not reset an existing record.
	id, _ = newRound(cur, j1, sj1)
	joinAll(cur, id, j1, sj1)
	assertTrack(t, j1, 1, 1, 0, "j1 keeps its record")
	assertTrack(t, sj1, 1, 1, 0, "sj1 keeps its record")
}

func TestRejectedJoinOpensNoTrack(cur realm, t *testing.T) {
	k1, sk1 := testutils.TestAddress("rep-k1"), testutils.TestAddress("rep-sk1")
	id, _ := newRound(cur, k1, sk1)
	n := tracks.Size()
	testing.SetRealm(user(outsider))
	pay(tBond)
	uassert.AbortsContains(t, cur, "designated sponsor", func() { Join(cross(cur), id, k1) })
	noPay()
	uassert.Equal(t, n, tracks.Size())
}
