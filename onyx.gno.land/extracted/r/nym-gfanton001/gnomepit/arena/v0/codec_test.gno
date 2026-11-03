package arena

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nym-gfanton001/gnomepit/engine/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

// panicsWith fails unless f panics with exactly want.
func panicsWith(t *testing.T, want string, f func()) {
	t.Helper()
	got := "no panic"
	func() {
		defer func() {
			if r := recover(); r != nil {
				got, _ = r.(string)
			}
		}()
		f()
	}()
	uassert.Equal(t, want, got)
}

func TestBits(cur realm, t *testing.T) {
	uassert.Equal(t, uint64(0xB), bitsAt(0xAB, 0, 4))
	uassert.Equal(t, uint64(0xA), bitsAt(0xAB, 4, 4))
	uassert.Equal(t, uint64(0xA5), withBits(0xA0, 0, 4, 5))
	uassert.Equal(t, uint64(1)<<63, withBits(0, 63, 1, 1))
	uassert.Equal(t, uint64(0), withBits(^uint64(0), 0, 64, 0))
	panicsWith(t, "value does not fit", func() {
		withBits(0, 0, 4, 16)
	})
}

func TestWorkedExamplePlans(cur realm, t *testing.T) {
	uassert.Equal(t, uint64(0x71A), withPlan(0, 1, engine.Plan{6, 7}))
	uassert.Equal(t, uint64(0x4107)<<20, withPlan(0, 2, engine.Plan{1, 1, 1}))
	uassert.Equal(t, uint64(0x103A), withPlan(0, 1, engine.Plan{14, 16}))
}

func TestPlansRoundTrip(cur realm, t *testing.T) {
	rules := engine.ProofOfConcept()
	for _, clan := range rules.Clans {
		for _, p := range rules.LegalPlans(rules.Start(), engine.SideA, clan.Pool) {
			for round := 1; round <= 3; round++ {
				got := planAt(withPlan(0, round, p), round)
				urequire.True(t, samePlan(p, got), "plan lost in round "+string(rune('0'+round)))
			}
		}
	}
}

func TestPlanSlotsDoNotOverlap(cur realm, t *testing.T) {
	var plans uint64
	for round := 1; round <= 3; round++ {
		plans = withPlan(plans, round, engine.Plan{63, 63, 63})
	}
	uassert.Equal(t, 3, plansMade(plans))
	plans = withPlan(plans, 2, engine.Plan{1})
	uassert.True(t, samePlan(engine.Plan{1}, planAt(plans, 2)))
	uassert.True(t, samePlan(engine.Plan{63, 63, 63}, planAt(plans, 1)))
	uassert.True(t, samePlan(engine.Plan{63, 63, 63}, planAt(plans, 3)))

	plans = withPlan(0, 1, engine.Plan{63, 63, 63})
	uassert.Equal(t, 1, plansMade(plans))
	uassert.Equal(t, 0, plansMade(0))
	uassert.True(t, planAt(plans, 2) == nil)
}

func TestPlanLimits(cur realm, t *testing.T) {
	for _, c := range []struct {
		round int
		plan  engine.Plan
	}{
		{0, engine.Plan{1}},
		{4, engine.Plan{1}},
		{1, nil},
		{1, engine.Plan{1, 1, 1, 1}},
		{1, engine.Plan{64}},
	} {
		panicsWith(t, "invalid plan", func() {
			withPlan(0, c.round, c.plan)
		})
	}
}

func TestDeckOnPool(cur realm, t *testing.T) {
	rules := engine.ProofOfConcept()
	for _, clan := range rules.Clans {
		n := 0
		for i := 0; i < 64; i++ {
			if clan.Pool&(1<<uint(i)) != 0 {
				n++
			}
		}
		uassert.True(t, n <= 16, clan.Name+" pool holds more than 16 cards")
	}

	for i, deck := range []string{deckA, deckB} {
		pool := rules.Clans[i].Pool
		bits := deckBits(rules, rules.Clans[i], deck)
		uassert.Equal(t, bits, deckFromPool(pool, deckOnPool(pool, bits)))
	}

	panicsWith(t, "deck outside the pool", func() {
		deckOnPool(rules.Clans[1].Pool, deckBits(rules, rules.Clans[0], deckA))
	})
	panicsWith(t, "pool holds more than 16 cards", func() {
		deckOnPool(^uint64(0), 1)
	})
}

func TestMatchRecordRoundTrip(cur realm, t *testing.T) {
	rules := engine.ProofOfConcept()
	deckBitsA := deckBits(rules, rules.Clans[0], deckA)
	deckBitsB := deckBits(rules, rules.Clans[1], deckB)

	box := make([]byte, 104)
	for i := range box {
		box[i] = byte(i * 3)
	}

	open := record{
		phase:      phaseOpen,
		clans:      [2]int{1, 0},
		deadline:   1_790_000_000,
		challenger: alice,
		opponent:   bob,
		deckSeal:   sealOf(saltA, deckA),
		seal:       sealOf(salt1, "Chalk Dust,Double Tap"),
		box:        "box1",
	}
	running := record{
		phase:      phasePlay,
		clans:      [2]int{1, 2},
		deadline:   1_790_086_400,
		decks:      [2]uint64{deckBitsA, deckBitsB},
		plans:      [2]uint64{withPlan(0, 1, engine.Plan{6, 7}), withPlan(0, 1, engine.Plan{14, 16})},
		hp:         [3][2]int{{10, 7}},
		carried:    [2]engine.Vitals{{Vulnerable: 1}, {Strength: 2}},
		challenger: alice,
		acceptor:   bob,
		seal:       sealOf(salt2, picks),
		box:        string(box),
	}
	finished := record{
		phase:      phaseEnded,
		result:     "b",
		reason:     "knockout",
		clans:      [2]int{2, 1},
		deadline:   1_790_172_800,
		decks:      [2]uint64{deckBitsB, deckBitsA},
		plans:      [2]uint64{withPlan(withPlan(0, 1, engine.Plan{1}), 2, engine.Plan{0, 0, 0}), withPlan(0, 3, engine.Plan{63, 63, 63})},
		hp:         [3][2]int{{10, 7}, {4, 0}, {-3, 0}},
		carried:    [2]engine.Vitals{{Vulnerable: 3, Strength: 8}, {Vulnerable: 3, Strength: 8}},
		challenger: alice,
		acceptor:   bob,
	}

	for name, want := range map[string]record{"open": open, "running": running, "finished": finished} {
		b := encodeMatch(rules, want)
		got := decodeMatch(rules, b)
		uassert.True(t, want == got, name+" record changed in a round trip")
	}
	uassert.Equal(t, 115, len(encodeMatch(rules, finished)))
}

func TestMatchRecordLimits(cur realm, t *testing.T) {
	rules := engine.ProofOfConcept()
	base := record{phase: phaseEnded, result: "a", reason: "hp", clans: [2]int{1, 2}, challenger: alice, acceptor: bob}

	hp := base
	hp.hp[0][0] = 128
	panicsWith(t, "hp does not fit a byte", func() { encodeMatch(rules, hp) })

	vuln := base
	vuln.carried[0].Vulnerable = 16
	panicsWith(t, "carried state does not fit", func() { encodeMatch(rules, vuln) })

	phase := base
	phase.phase = "lost"
	panicsWith(t, "unknown phase", func() { encodeMatch(rules, phase) })
}

func TestMatchRecordBox(cur realm, t *testing.T) {
	rules := engine.ProofOfConcept()
	base := record{
		phase: phasePlay, clans: [2]int{1, 2}, challenger: alice, acceptor: bob,
		seal: sealOf(salt2, picks),
	}

	for _, n := range []int{1, 64, maxBox} {
		m := base
		m.box = strings.Repeat("\x00\xff\x07", n)[:n]
		b := encodeMatch(rules, m)
		uassert.Equal(t, 115+32+2+n, len(b))
		uassert.True(t, decodeMatch(rules, b) == m, "box of "+strconv.Itoa(n)+" bytes changed")
	}

	over := base
	over.box = strings.Repeat("x", maxBox+1)
	panicsWith(t, "box too long", func() { encodeMatch(rules, over) })
}

func TestChunkSlots(cur realm, t *testing.T) {
	var chunk string
	chunk = withChunkRecord(chunk, 0, "zero")
	chunk = withChunkRecord(chunk, 5, "five")
	chunk = withChunkRecord(chunk, 63, "sixty-three")
	uassert.Equal(t, "zero", chunkRecord(chunk, 0))
	uassert.Equal(t, "five", chunkRecord(chunk, 5))
	uassert.Equal(t, "sixty-three", chunkRecord(chunk, 63))
	uassert.Equal(t, "", chunkRecord(chunk, 3))
	uassert.Equal(t, "", chunkRecord(chunk, 64))

	chunk = withChunkRecord(chunk, 5, "")
	uassert.Equal(t, "", chunkRecord(chunk, 5))
	uassert.Equal(t, "sixty-three", chunkRecord(chunk, 63))

	chunk = withChunkRecord(chunk, 0, "longer than before")
	uassert.Equal(t, "longer than before", chunkRecord(chunk, 0))
	uassert.Equal(t, "sixty-three", chunkRecord(chunk, 63))

	rec := "abc"
	uassert.Equal(t, 2+2+2+len(rec), len(withChunkRecord("", 2, rec)))
	uassert.Equal(t, "", chunkRecord("", 0))
}

func TestPlayerRecordRoundTrip(cur realm, t *testing.T) {
	locks := []sessionLock{
		{session: bob, id: 7, expires: 1_790_000_000},
		{session: carol, id: 9, expires: 1_790_086_400},
	}
	for _, p := range []playerRecord{
		{},
		{ids: []int{1, 70000, 3}},
		{locks: locks},
		{ids: []int{4, 5, 6}, locks: locks},
	} {
		s := encodePlayer(p)
		got := decodePlayer(s)
		urequire.Equal(t, len(p.ids), len(got.ids))
		urequire.Equal(t, len(p.locks), len(got.locks))
		for i := range p.ids {
			uassert.Equal(t, p.ids[i], got.ids[i])
		}
		for i := range p.locks {
			uassert.True(t, p.locks[i] == got.locks[i])
		}
		uassert.Equal(t, 2+4*len(p.ids)+48*len(p.locks), len(s))
	}
	got := decodePlayer("")
	uassert.Equal(t, 0, len(got.ids)+len(got.locks))
}

func TestOpenListRoundTrip(cur realm, t *testing.T) {
	entries := []openEntry{{1, 1_790_000_000}, {2, 1_790_000_100}, {300000, 1_790_000_200}}
	s := encodeOpen(entries)
	uassert.Equal(t, 8*len(entries), len(s))
	got := openEntries(s)
	urequire.Equal(t, len(entries), len(got))
	for i := range entries {
		uassert.True(t, entries[i] == got[i])
	}
	uassert.Equal(t, 0, len(openEntries("")))
	panicsWith(t, "malformed open list", func() {
		openEntries("short")
	})
}

func TestMalformedPlayer(cur realm, t *testing.T) {
	panicsWith(t, "malformed player", func() { decodePlayer("\x00\x00" + strings.Repeat("\x00", 10)) })
}
