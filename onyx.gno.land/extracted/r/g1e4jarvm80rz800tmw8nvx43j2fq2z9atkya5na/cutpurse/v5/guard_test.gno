package cutpurse

import (
	"chain"
	"strings"
	"testing"
)

// Guard coverage note (§10 R3).
//
// A crossing call must be written `f(cur)` or `f(cross(rlm))`, and cross()
// validates the realm pointer before the body runs — so an outside caller can
// never hand a mutator a bad realm. The `if !cur.IsCurrent()` guard therefore
// protects against *stale captures* inside the realm (the case the banker
// stdlib docs warn about). What is assertable here is the predicate plus the
// fact that the live-cur path clears every mutator.

func TestStaleRealmIsNotCurrent(cur realm, t *testing.T) {
	if !cur.IsCurrent() {
		t.Fatal("the injected cur must be current")
	}
	if cur.Previous().IsCurrent() {
		t.Fatal("a previous realm must not report IsCurrent")
	}
}

func TestMutatorsRunOnLiveCur(cur realm, t *testing.T) {
	testing.SetHeight(700)
	actor := address("g1guard")
	testing.SetOriginCaller(actor)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(Denom, MinFee)))

	id := CreateJob(cur, "guard", MinFee)
	if _, ok := jobView(id); !ok {
		t.Fatal("CreateJob must work on the live cur")
	}

	testing.SetOriginCaller(address("g1guard2"))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(Denom, MinFee)))
	JoinJob(cur, id)

	testing.SetOriginCaller(actor)
	testing.SetOriginSend(chain.NewCoins())
	Start(cur, id)
	Tick(cur, id) // inside the commit deadline: no-op, must not panic

	jv, _ := jobView(id)
	if jv.Phase != uint8(PhaseCommit) || jv.NSeats != 2 {
		t.Fatalf("expected an open commit round with 2 seats, got phase %d nseats %d", jv.Phase, jv.NSeats)
	}
}

// seed() fills the globals directly (no caller realm needed) so render probes
// can address a realistic board. Idempotent.
func seed() {
	if len(jobs) > 0 {
		return
	}
	hostile := "a|b *c* _d_ `e` <gno-x> [f](g) " + strings.Repeat("z", 30)
	who0 := address("g1qrmldr7hh985wngaklzfkzlt588z4gewtlgwg0")
	other := address("g1seedother")

	for i := int64(0); i < 9; i++ {
		j := &Job{
			ID:       i,
			Name:     hostile,
			Creator:  who0,
			Fee:      MinFee,
			Pot:      MinFee * 4,
			Phase:    PhaseCommit,
			Round:    2,
			Deadline: 900,
			Alarm:    i % 4,
			Loot:     12,
			Secured:  4,
			Traitor:  1,
			OpenedAt: 100,
		}
		j.NSeats = 4
		for s := 0; s < 4; s++ {
			j.Seats[s] = Seat{Addr: who0, Committed: true, CommitHash: hostile}
			if s%2 == 1 {
				j.Seats[s].Addr = other
				j.Seats[s].Action = Action(1 + s%4)
				j.Seats[s].Contribution = 3
			}
		}
		jobs[i] = j
		active[j.Seats[0].Addr] = i
	}
	nextID = 9
	liveCount = 9
}
