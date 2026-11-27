package villagersv1

import (
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
)

// Restricted functions: only the realm whose package path is the stored
// town path may call them. A user call (PkgPath "") and any other realm
// abort, and so does everyone before SetTown.
//
// Coins: these functions do not check unsafe.OriginSend. The only allowed
// caller is the town realm, and the town's GNOT shop mints in the same
// transaction as the player's payment, so OriginSend is non-empty there. The
// payment goes to the realm the player called (the town), never to this
// realm, so no coins can be stuck here.

// MintFor mints a new villager to `to` from seed at game hour hoursNow and
// returns its token id (the next sequential decimal id).
func MintFor(cur realm, to address, seed uint64, hoursNow int64) string {
	assertTown(cur)
	assertHour(hoursNow)
	if !to.IsValid() {
		panic("villagers: invalid address")
	}
	n := lastID + 1
	id := idOf(n)
	key, ok := keyOf(id)
	if !ok {
		panic("villagers: id space exhausted")
	}
	// The ledger mint is the first write and fails without writing.
	if err := ledger.Mint(to, grc721.TokenID(id)); err != nil {
		panic("villagers: " + err.Error())
	}
	lastID = n
	records.Set(key, &Villager{
		ID:      id,
		Seed:    seed,
		Job:     RollJob(seed),
		Loyalty: StartLoyalty,
		Traits:  RollTraits(seed),
		Needs:   townmath.Needs{Thirst: StartNeed, Fun: StartNeed, Energy: StartNeed},
		NeedsAt: hoursNow,
	})
	return id
}

// ApplyRound settles the villager's needs to hoursNow, then a bought round:
// +4000 thirst (capped) and loyalty +1 up to MaxLoyalty.
func ApplyRound(cur realm, id string, hoursNow int64) {
	assertTown(cur)
	assertHour(hoursNow)
	v := mustGet(id)
	n := townmath.BuyRound(needsAt(v, hoursNow))
	settle(v, n, hoursNow)
	if v.Loyalty < MaxLoyalty {
		v.Loyalty++
	}
}

// ApplyDayOff settles the villager's needs to hoursNow, then a day off:
// +5000 energy (capped).
func ApplyDayOff(cur realm, id string, hoursNow int64) {
	assertTown(cur)
	assertHour(hoursNow)
	v := mustGet(id)
	settle(v, townmath.DayOff(needsAt(v, hoursNow)), hoursNow)
}

// settle stores needs n as of hoursNow. NeedsAt never moves back, so an
// earlier hour (which decayed 0 hours) cannot make a later call decay the
// same hours twice.
func settle(v *Villager, n townmath.Needs, hoursNow int64) {
	v.Needs = n
	if hoursNow > v.NeedsAt {
		v.NeedsAt = hoursNow
	}
}

// assertHour aborts unless 0 <= hoursNow <= MaxHour. Every stored NeedsAt
// passed this check, so hoursNow - NeedsAt cannot overflow.
func assertHour(hoursNow int64) {
	if hoursNow < 0 || hoursNow > MaxHour {
		panic("villagers: bad hour")
	}
}

// assertTown aborts unless the caller is the town realm.
func assertTown(cur realm) {
	prev := cur.Previous()
	if townPath == "" || prev.IsUserCall() || prev.PkgPath() != townPath {
		panic("villagers: town only")
	}
}
