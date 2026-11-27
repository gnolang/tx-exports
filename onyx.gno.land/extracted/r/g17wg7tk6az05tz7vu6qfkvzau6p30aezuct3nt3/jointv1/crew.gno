package jointv1

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
	villagers "gno.land/r/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/villagersv1"
)

// Villager crews. A pub has up to MaxCrew villagers from the villagers realm
// in its crew (Tavern.Crew, "" = empty slot). The owner can buy a crew
// villager a round (RoundCostCg of the pub's gold, destroyed) or give it a
// day off (RestHours without a bonus). A happy or okay villager with
// loyalty of at least 5 brings extra customers in the evening (see
// crewBonus). A villager works for one pub at a time: crewHome maps it to the
// pub owner's address. A villager transferred to another wallet stays in the
// old crew but brings nothing (stale) until its old pub unassigns it or the
// new owner assigns it to their own pub, which clears the old slot.

const (
	// MaxCrew is the most villagers one pub can have in its crew.
	MaxCrew = 3
	// RestHours is how long a day off lasts: no bonus until then.
	RestHours int64 = 12
	// BonusSampleHour is the hour of day whose mood a settle uses for every
	// hour of that game day (clamped into the hours the settle credits).
	BonusSampleHour int64 = 20
)

// crewKeyWidth is the zero-padded width of crewHome keys (as in the
// villagers realm, so the tree orders villagers by id).
const crewKeyWidth = 12

var (
	// crewHome: zero-padded villager id -> the address string of the pub
	// owner whose crew it is in. About 2 KB of deposit per entry, paid by
	// the assigner and refunded when the entry is removed on unassign.
	crewHome avl.Tree
	// Cross-realm reads made by settlements (read-only counters for tests
	// and audits): villagers.GetVillager and villagers.OwnerOf calls.
	crewVillagerReads int64
	crewOwnerReads    int64
)

// AssignVillager puts one of the caller's villagers in the caller's pub
// crew. Pubs only. The caller must own the villager, the crew must have a
// free slot and the villager must not be in it already. A villager
// registered to another pub whose owner no longer owns it (it was
// transferred) is taken over: the old pub's slot is cleared. The pub is
// settled first, so the villager brings nothing for earlier hours. An own
// action (a dormant pub rejoins).
func AssignVillager(cur realm, id string) {
	actor := userActor(cur)
	assertNotPaused()
	t := mustTavern(actor.String())
	assertPub(t)
	owner := villagers.OwnerOf(id) // aborts for an unknown id
	if owner != actor {
		panic("town: not your villager")
	}
	if crewSlot(t, id) >= 0 {
		panic("town: already in the crew")
	}
	slot := freeSlot(t)
	if slot < 0 {
		panic("town: crew is full")
	}
	key := crewKey(id)
	var old *Tavern
	oldSlot := -1
	if v := crewHome.Get(key); v != nil {
		home := v.(string)
		if home != actor.String() {
			// The registered pub's owner keeps the villager only while it
			// owns it. The caller owns it now, so the registration is stale.
			if address(home) == owner {
				panic("town: villager works elsewhere")
			}
			if ov := taverns.Get(home); ov != nil {
				old = ov.(*Tavern)
				oldSlot = crewSlot(old, id)
			}
		}
	}
	settleTavern(t)
	ownerActs(t)
	if old != nil && oldSlot >= 0 {
		// The old pub gets no bonus from it anyway (not owned), so its
		// earnings do not change and it needs no settle.
		old.Crew[oldSlot] = ""
		old.CrewRestUntil[oldSlot] = 0
	}
	t.Crew[slot] = id
	t.CrewRestUntil[slot] = 0
	crewHome.Set(key, actor.String())
}

// UnassignVillager removes a villager from the caller's pub crew and drops
// its registration (the storage deposit is refunded). The villager need not
// be owned by the caller any more. Pubs only; an own action.
func UnassignVillager(cur realm, id string) {
	actor := userActor(cur)
	assertNotPaused()
	t := mustTavern(actor.String())
	assertPub(t)
	slot := crewSlot(t, id)
	if slot < 0 {
		panic("town: not in the crew")
	}
	settleTavern(t)
	ownerActs(t)
	t.Crew[slot] = ""
	t.CrewRestUntil[slot] = 0
	key := crewKey(id)
	if v := crewHome.Get(key); v != nil && v.(string) == actor.String() {
		crewHome.Remove(key)
	}
}

// BuyRound buys a crew villager a round: the pub pays RoundCostCg (the gold
// is destroyed) and the villager gets +4000 thirst and +1 loyalty (see the
// villagers realm). The villager must be in the caller's crew and still
// owned by the caller. Pubs only; an own action.
func BuyRound(cur realm, id string) {
	actor := userActor(cur)
	assertNotPaused()
	t := mustTavern(actor.String())
	assertPub(t)
	assertOwnCrew(t, actor, id)
	settleTavern(t)
	if t.GoldCg < townmath.RoundCostCg {
		panic("town: not enough gold")
	}
	ownerActs(t)
	cost := int64(townmath.RoundCostCg)
	t.GoldCg -= cost
	goldDestroyedCg += cost
	t.ProfitTodayCg -= cost
	t.SeasonProfitCg -= cost
	villagers.ApplyRound(cross(cur), id, CurrentGameHour())
}

// DayOff gives a crew villager a day off (free, DayOffCostCg): +5000 energy
// now, and no bonus for the next RestHours game hours. The villager must be
// in the caller's crew, owned by the caller and not resting. Pubs only; an
// own action.
func DayOff(cur realm, id string) {
	actor := userActor(cur)
	assertNotPaused()
	t := mustTavern(actor.String())
	assertPub(t)
	slot := assertOwnCrew(t, actor, id)
	now := CurrentGameHour()
	if now < t.CrewRestUntil[slot] {
		panic("town: already resting")
	}
	settleTavern(t)
	ownerActs(t)
	t.CrewRestUntil[slot] = now + RestHours
	villagers.ApplyDayOff(cross(cur), id, now)
}

// MintVillager mints a villager to `to` from seed at the current game hour.
// Admin only, for demos and tests; its id is villagers.Count() after the
// mint. The storage deposit of the new villager is paid by the signer.
func MintVillager(cur realm, to address, seed uint64) {
	assertAdmin(cur)
	if !cur.Previous().IsUserCall() {
		panic("town: must be a direct user call")
	}
	assertNoSend()
	assertNotPaused()
	villagers.MintFor(cross(cur), to, seed, CurrentGameHour())
}

// CrewOf returns a copy of the crew of owner's pub ("" = empty slot, all
// empty when owner has no business). Read-only.
func CrewOf(owner string) [MaxCrew]string {
	v := taverns.Get(owner)
	if v == nil {
		return [MaxCrew]string{}
	}
	return v.(*Tavern).Crew
}

// VillagerHome returns the address string of the pub owner whose crew the
// villager is registered to, or "". Read-only.
func VillagerHome(id string) string {
	if !canonicalID(id) {
		return ""
	}
	v := crewHome.Get(crewKey(id))
	if v == nil {
		return ""
	}
	return v.(string)
}

// CrewReads returns how many villagers.GetVillager and villagers.OwnerOf
// calls settlements have made in total. Read-only.
func CrewReads() (villagerReads, ownerReads int64) {
	return crewVillagerReads, crewOwnerReads
}

// assertOwnCrew aborts unless id is in t's crew and actor owns it; it
// returns the slot.
func assertOwnCrew(t *Tavern, actor address, id string) int {
	slot := crewSlot(t, id)
	if slot < 0 {
		panic("town: not in the crew")
	}
	if villagers.OwnerOf(id) != actor {
		panic("town: not your villager")
	}
	return slot
}

// crewSlot returns the slot of t's crew holding id, or -1 (always -1 for
// the empty id, which marks a free slot).
func crewSlot(t *Tavern, id string) int {
	if id == "" {
		return -1
	}
	for i := 0; i < MaxCrew; i++ {
		if t.Crew[i] == id {
			return i
		}
	}
	return -1
}

// freeSlot returns the first free slot of t's crew, or -1.
func freeSlot(t *Tavern) int {
	for i := 0; i < MaxCrew; i++ {
		if t.Crew[i] == "" {
			return i
		}
	}
	return -1
}

// canonicalID reports whether id is a villager id as the villagers realm
// writes them: 1..12 decimal digits, no leading zero.
func canonicalID(id string) bool {
	if len(id) == 0 || len(id) > crewKeyWidth || id[0] == '0' {
		return false
	}
	for i := 0; i < len(id); i++ {
		if id[i] < '0' || id[i] > '9' {
			return false
		}
	}
	return true
}

// crewKey is the crewHome key of a canonical id.
func crewKey(id string) string {
	return "000000000000"[len(id):] + id
}

// crewMember is what a settle reads once about one crew slot.
type crewMember struct {
	active  bool // in the crew and still owned by the pub owner
	restTo  int64
	loyalty int64
	needs   townmath.Needs
	mods    townmath.TraitMods
	needsAt int64
}

// loadCrew reads t's crew once for a settle: one villagers.OwnerOf per
// filled slot, and one villagers.GetVillager per villager the pub owner
// still owns (at most MaxCrew of each, none for an empty crew). It reports
// whether any member is active.
func loadCrew(t *Tavern, crew *[MaxCrew]crewMember) bool {
	found := false
	for i := 0; i < MaxCrew; i++ {
		id := t.Crew[i]
		if id == "" {
			continue
		}
		crewOwnerReads++
		if villagers.OwnerOf(id) != t.Owner {
			continue // transferred: stale, brings nothing
		}
		crewVillagerReads++
		v := villagers.GetVillager(id)
		crew[i] = crewMember{
			active:  true,
			restTo:  t.CrewRestUntil[i],
			loyalty: v.Loyalty,
			needs:   v.Needs,
			mods:    villagers.CombinedMods(v.Traits),
			needsAt: v.NeedsAt,
		}
		found = true
	}
	return found
}

// dayMoods sets each active member's mood for the game day whose credited
// hours are from..to: the mood at hour BonusSampleHour of that day, clamped
// into from..to.
func dayMoods(crew *[MaxCrew]crewMember, moods *[MaxCrew]int, day, from, to int64) {
	sample := day*24 + BonusSampleHour
	if sample < from {
		sample = from
	}
	if sample > to {
		sample = to
	}
	for i := 0; i < MaxCrew; i++ {
		m := crew[i]
		if !m.active {
			continue
		}
		moods[i] = townmath.Mood(townmath.Decay(m.needs, m.mods, sample-m.needsAt))
	}
}

// crewBonus is the extra customers t's active crew brings in game hour h:
// the sum of townmath.RegularBonus over members not resting at h.
func crewBonus(crew *[MaxCrew]crewMember, moods *[MaxCrew]int, h int64) int64 {
	hod := int(h % 24)
	sum := int64(0)
	for i := 0; i < MaxCrew; i++ {
		m := crew[i]
		if !m.active || h < m.restTo {
			continue
		}
		sum += townmath.RegularBonus(moods[i], m.loyalty, hod)
	}
	return sum
}
