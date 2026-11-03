package arena

import (
	"strconv"
	"testing"

	"gno.land/p/nym-gfanton001/gnomepit/engine/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func openRecord(who address, deadline int64) record {
	return record{phase: phaseOpen, challenger: who, deadline: deadline}
}

func showIDs(ids []int) string {
	s := "["
	for i, id := range ids {
		if i > 0 {
			s += " "
		}
		s += strconv.Itoa(id)
	}
	return s + "]"
}

func TestMatchesAcrossChunks(cur realm, t *testing.T) {
	reset()
	rules := engine.ProofOfConcept()
	lastID = 130
	for _, id := range []int{1, 64, 65, 130} {
		saveMatch(rules, id, openRecord(alice, int64(id)))
	}
	for _, id := range []int{1, 64, 65, 130} {
		m, ok := loadMatch(rules, id)
		urequire.True(t, ok, "match missing")
		uassert.Equal(t, int64(id), m.deadline)
		uassert.Equal(t, alice, m.challenger)
	}
	for _, id := range []int{66, 0, 131} {
		_, ok := loadMatch(rules, id)
		uassert.False(t, ok)
	}
	uassert.Equal(t, 3, chunks.Size())
}

func TestDropMatch(cur realm, t *testing.T) {
	reset()
	rules := engine.ProofOfConcept()
	lastID = 64
	saveMatch(rules, 1, openRecord(alice, 1))
	saveMatch(rules, 64, openRecord(bob, 64))
	dropMatch(64)
	_, ok := loadMatch(rules, 64)
	uassert.False(t, ok)
	_, ok = loadMatch(rules, 1)
	uassert.True(t, ok)
	dropMatch(64)
	dropMatch(500)
}

func TestPlayerIDs(cur realm, t *testing.T) {
	reset()
	uassert.Equal(t, 0, len(loadPlayer(alice).ids))
	p := loadPlayer(alice)
	p.add(1)
	p.add(5)
	p.add(9)
	p.add(5)
	savePlayer(alice, p)

	p = loadPlayer(alice)
	uassert.Equal(t, "[9 5]", showIDs(p.newest(0, 2)))
	uassert.Equal(t, "[1]", showIDs(p.newest(2, 2)))
	uassert.Equal(t, "[]", showIDs(p.newest(5, 2)))
	p.remove(5)
	p.remove(77)
	uassert.Equal(t, "[9 1]", showIDs(p.newest(0, 50)))
}

func TestPlayerKeepsLocks(cur realm, t *testing.T) {
	reset()
	p := loadPlayer(alice)
	p.add(1)
	p.locks = []sessionLock{{session: bob, id: 1, expires: 99}}
	savePlayer(alice, p)
	got := loadPlayer(alice)
	uassert.Equal(t, 1, len(got.locks))
	uassert.Equal(t, bob, got.locks[0].session)
	uassert.Equal(t, 1, len(got.ids))
}

func TestOpenList(cur realm, t *testing.T) {
	reset()
	const now = int64(1000)
	openAdd(1, now+10)
	openAdd(2, now+20)
	openAdd(3, now+30)
	uassert.Equal(t, "[3 2]", showIDs(openNewest(now+15, 0, 50)))
	uassert.Equal(t, "[2]", showIDs(openNewest(now+15, 1, 1)))
	uassert.Equal(t, "[1 2]", showIDs(openClear(now+25, 8)))
	uassert.Equal(t, "[3]", showIDs(openNewest(now, 0, 50)))
	openRemove(9)
	openRemove(3)
	uassert.Equal(t, "", openList)
}

func TestOpenClearStopsAtMax(cur realm, t *testing.T) {
	reset()
	openAdd(1, 10)
	openAdd(2, 20)
	openAdd(3, 30)
	uassert.Equal(t, "[1]", showIDs(openClear(100, 1)))
	uassert.Equal(t, 2, len(openEntries(openList)))
}

func TestDropAbsentMatchLeavesChunk(cur realm, t *testing.T) {
	reset()
	rules := engine.ProofOfConcept()
	lastID = 66
	saveMatch(rules, 65, openRecord(alice, 65))
	before := stringAt(&chunks, chunkKey(65))

	dropMatch(66)
	uassert.Equal(t, before, stringAt(&chunks, chunkKey(65)))

	dropMatch(65)
	dropped := stringAt(&chunks, chunkKey(65))
	dropMatch(65)
	uassert.Equal(t, dropped, stringAt(&chunks, chunkKey(65)))
}

func TestOpenExpiryBoundary(cur realm, t *testing.T) {
	reset()
	openAdd(1, 50)
	uassert.Equal(t, "[1]", showIDs(openNewest(50, 0, 50)))
	uassert.Equal(t, "[]", showIDs(openClear(50, 8)))
	uassert.Equal(t, "[1]", showIDs(openClear(51, 8)))
}
