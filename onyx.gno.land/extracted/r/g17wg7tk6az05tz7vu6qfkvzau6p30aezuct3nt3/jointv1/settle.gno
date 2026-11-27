package jointv1

import (
	"chain/runtime"

	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
)

// Settlement, daily events and the live leaderboard.
//
// Settling a tavern applies the game hours LastHour+1..now, at most the last
// townmath.MaxCatchUpHours (24) of them, split at game-day boundaries so each
// day uses its own event. A day's event comes from a per-day seed stored by
// the first mutating call of that day, in a fixed ring of the last SeedRing
// days (settlement reads at most the current and the previous day), so seed
// storage stays constant.

const (
	// DailyScoreCap is the most a tavern's season score can grow in one game day.
	DailyScoreCap int64 = 5000
	// TopN is the leaderboard length.
	TopN = 10
	// BarmaidStaffBps is the weight multiplier with a barmaid (10000 without).
	BarmaidStaffBps int64 = 12500
	// MaxSeats bounds the seats used in settlement.
	MaxSeats int64 = 50
	maxRep   int64 = 500
	// SeedRing is how many recent game days keep their seed.
	SeedRing = 4
)

// seedSlot holds one day's seed; Set tells an empty slot from day 0.
type seedSlot struct {
	Day  int64
	Seed uint64
	Set  bool
}

var (
	seeds    [SeedRing]seedSlot // slot day % SeedRing
	seeded   bool               // any seed stored yet
	lastSeed uint64             // most recently stored seed (valid when seeded)
	// The leaderboard lives in a fixed array updated in place (element
	// writes), so a settle never stores a new slice: assigning a fresh slice
	// every settle grew storage by about 465 bytes each time.
	top    [TopN]townmath.Entry
	topLen int // entries in use, 0..TopN
	// farmTop is the production board. Pubs never go on it and farms never
	// go on top. Same fixed-array rules as the pub board.
	farmTop    [TopN]townmath.Entry
	farmTopLen int
)

// Settle settles owner's pub or farm up to the current game hour (a farm
// harvests its crop; a dormant pub earns nothing and only its LastHour
// moves). Anyone may call it, including other realms; it only credits what
// the rules already owe. The owner's own direct call on a pub is an own
// action: it moves LastActionHour and rejoins a dormant pub.
func Settle(cur realm, owner string) {
	assertNoSend()
	assertNotPaused()
	t := mustTavern(owner)
	if t.Role == RoleFarm {
		settleFarm(t)
		return
	}
	settleTavern(t)
	if prev := cur.Previous(); prev.IsUserCall() && prev.Address() == t.Owner {
		ownerActs(t) // the owner's own settle is an own action: it rejoins
		return
	}
	if t.Dormant != 0 {
		settleDormant(t, CurrentGameHour())
	}
}

// EventToday returns the event of the current game day, or the no-event
// value if no call has stored the day's seed yet. Read-only.
func EventToday() townmath.Event {
	return EventOnDay(CurrentGameHour() / 24)
}

// EventOnDay returns the event of a game day from its stored seed, or the
// no-event value if that day has no seed. Read-only.
func EventOnDay(day int64) townmath.Event {
	s, ok := DaySeed(day)
	if !ok {
		return noEvent()
	}
	return townmath.EventForDay(s, day)
}

// DaySeed returns the stored seed of a game day. Only the last SeedRing
// days that were touched keep a seed.
func DaySeed(day int64) (uint64, bool) {
	if day < 0 {
		return 0, false
	}
	sl := seeds[day%SeedRing]
	if !sl.Set || sl.Day != day {
		return 0, false
	}
	return sl.Seed, true
}

// LastSeed returns the seed the next new day seed chains from: the most
// recently stored day seed, or the deploy time before any day was seeded.
func LastSeed() uint64 {
	if !seeded {
		return uint64(genesisUnix)
	}
	return lastSeed
}

// Top returns a copy of the live pub leaderboard (at most TopN entries).
func Top() []townmath.Entry {
	out := make([]townmath.Entry, topLen)
	for i := 0; i < topLen; i++ { // topLen <= TopN
		out[i] = top[i]
	}
	return out
}

// TopFarms returns a copy of the live farm production board.
func TopFarms() []townmath.Entry {
	out := make([]townmath.Entry, farmTopLen)
	for i := 0; i < farmTopLen; i++ { // farmTopLen <= TopN
		out[i] = farmTop[i]
	}
	return out
}

// ensureSeasonScore clears a tavern's season fields when a new season has
// started since they were last scored. Called from settle, before any
// early return, so a same-hour settle still drops the previous season's
// score and does not submit it again. A field that is already zero is left
// untouched. ScoreGen is still set to the live generation.
func ensureSeasonScore(t *Tavern) {
	if t.ScoreGen == seasonGen {
		return
	}
	if t.SeasonScore != 0 {
		t.SeasonScore = 0
	}
	if t.SeasonProfitCg != 0 {
		t.SeasonProfitCg = 0
	}
	if t.SeasonProd != 0 {
		t.SeasonProd = 0
	}
	if t.ScoreDayStart != 0 {
		t.ScoreDayStart = 0
	}
	if t.ProfitTodayCg != 0 {
		t.ProfitTodayCg = 0
	}
	t.ScoreGen = seasonGen
}

// NextSeasonScore returns the new season score for a tavern: the score from
// profit and reputation (negative profit counts as 0, reputation is clamped
// to 0..500), grown at most DailyScoreCap above the score the day started
// with, and never below the old score or 0.
func NextSeasonScore(oldScore, dayStartScore, seasonProfitCg, rep int64) int64 {
	if oldScore < 0 {
		oldScore = 0
	}
	if dayStartScore < 0 {
		dayStartScore = 0
	}
	if dayStartScore > oldScore {
		dayStartScore = oldScore
	}
	if seasonProfitCg < 0 {
		seasonProfitCg = 0
	}
	if rep < 0 {
		rep = 0
	}
	if rep > maxRep {
		rep = maxRep
	}
	raw := townmath.SeasonScore(seasonProfitCg, rep)
	if raw < 0 {
		raw = 0
	}
	s := townmath.CapGain(dayStartScore, raw, DailyScoreCap)
	if s < oldScore {
		return oldScore
	}
	return s
}

// settleTavern applies the elapsed game hours to t. Hours already settled,
// or a LastHour ahead of the clock, credit nothing. Each missed hour's
// customers are t's share of that hour's town pool (see ring.gno), from the
// ring snapshot of that hour or the last known one before it; fractions of a
// customer carry over in t.Carry. The crew's regulars (crewBonus) are added
// to each hour's whole customers after the carry step. Staff is part of the weight, so the
// demand is not scaled again here. A dormant pub earns nothing and is left
// unchanged, so an own action can still be refused after the settle without
// having changed it (see settleDormant).
func settleTavern(t *Tavern) {
	ensureSeasonScore(t)
	ensureDaySeed()
	touchMarket()
	now := CurrentGameHour()
	last := t.LastHour
	if t.Dormant != 0 {
		return // earns nothing; Settle and ownerActs move its LastHour
	}
	if last >= now {
		writeSnapshot(now)
		return
	}
	hours := now - last
	if hours > townmath.MaxCatchUpHours {
		hours = townmath.MaxCatchUpHours
	}
	seats := t.Seats
	if seats < 0 {
		seats = 0
	}
	if seats > MaxSeats {
		seats = MaxSeats
	}
	profitDay := last / 24
	h := now - hours + 1
	// Read the ring once, with the start-of-settle snapshot of now applied to
	// the copy only: the reweigh at the end stores the slot of now (one ring
	// write per settle instead of two; the stored result is the same).
	rg := ring
	if s := rg[now%ringSize]; !s.Set || s.Hour <= now {
		rg[now%ringSize] = currentSnapshot(now)
	}
	known := lastKnownSnapshot(&rg, h)
	var calc poolCalc
	// The crew is read once per settle (at most MaxCrew OwnerOf and
	// GetVillager reads, none for an empty crew).
	var crew [MaxCrew]crewMember
	var moods [MaxCrew]int
	hasCrew := loadCrew(t, &crew)
	// 24 hours span at most 2 game days; the bound is a safety net
	for i := 0; i < 3 && h <= now; i++ {
		day := h / 24
		end := day*24 + 23
		if end > now {
			end = now
		}
		if day != profitDay {
			t.ProfitTodayCg = 0
			t.ScoreDayStart = t.SeasonScore
			profitDay = day
		}
		ev := EventOnDay(day)
		profit := int64(0)
		if ev.TaxBps > 0 && t.LastTaxDay != day+1 && t.GoldCg > 0 {
			bps := ev.TaxBps
			if bps > townmath.BpsOne {
				bps = townmath.BpsOne
			}
			tax := townmath.MulBps(t.GoldCg, bps)
			t.GoldCg -= tax
			goldDestroyedCg += tax
			profit -= tax
			t.LastTaxDay = day + 1
		}
		n := end - h + 1 // 1..24
		if hasCrew {
			dayMoods(&crew, &moods, day, h, end)
		}
		demands := make([]int64, n)
		for j := int64(0); j < n; j++ {
			known = snapshotFor(&rg, h+j, known)
			milli := calc.shareMilli(int((h+j)%24), known, t.Weight, ev.BoostBps)
			demands[j], t.Carry = townmath.CarryDemand(milli, t.Carry)
			if hasCrew {
				// regulars come on top of the pool share, after the carry
				demands[j] += crewBonus(&crew, &moods, h+j)
			}
		}
		out := townmath.SettleRangeDemand(demands, townmath.SettleIn{
			PriceCg:  t.PriceCg,
			Rep:      t.Rep,
			Stock:    t.Stock,
			Seats:    seats,
			EventBps: townmath.BpsOne,
			StaffBps: townmath.BpsOne,
		})
		t.GoldCg += out.RevenueCg
		goldCreatedCg += out.RevenueCg
		t.Stock = out.StockLeft
		t.Rep = out.RepAfter
		profit += out.RevenueCg
		t.ProfitTodayCg += profit
		t.SeasonProfitCg += profit
		t.SeasonScore = NextSeasonScore(t.SeasonScore, t.ScoreDayStart, t.SeasonProfitCg, t.Rep)
		h = end + 1
	}
	t.LastHour = now
	reweigh(t, t.PriceCg) // settlement moves reputation
	submitScore(t)
}

// submitScore puts t's score on the leaderboard. The entry never falls
// (max of the listed and the new score) and only t's own entry changes.
// An owner already listed with the same score changes nothing (no write).
// Otherwise townmath.InsertTop updates the fixed array in place, with the
// same result as townmath.UpdateTop.
func submitScore(t *Tavern) {
	if t.Role != RolePub {
		return // farms are scored on farmTop only
	}
	owner := t.Owner.String()
	s := t.SeasonScore
	listed := false
	for i := 0; i < topLen; i++ { // topLen <= TopN
		if top[i].Owner == owner {
			listed = true
			if top[i].Score > s {
				s = top[i].Score
			}
			if top[i].Score == s {
				return // unchanged
			}
		}
	}
	if s <= 0 {
		return
	}
	if !listed && topLen == TopN && top[TopN-1].Score >= s {
		return // would rank below a full board: InsertTop would drop it
	}
	topLen = townmath.InsertTop(top[:], topLen, townmath.Entry{Owner: owner, Score: s})
}

// submitFarmScore puts a farm's production score on the farm board. Same
// high-water rule as pubs: the listed score never falls, and an unchanged
// score does not write. Pubs are ignored.
func submitFarmScore(t *Tavern) {
	if t.Role != RoleFarm {
		return
	}
	owner := t.Owner.String()
	s := t.SeasonScore
	listed := false
	for i := 0; i < farmTopLen; i++ { // farmTopLen <= TopN
		if farmTop[i].Owner == owner {
			listed = true
			if farmTop[i].Score > s {
				s = farmTop[i].Score
			}
			if farmTop[i].Score == s {
				return
			}
		}
	}
	if s <= 0 {
		return
	}
	if !listed && farmTopLen == TopN && farmTop[TopN-1].Score >= s {
		return
	}
	farmTopLen = townmath.InsertTop(farmTop[:], farmTopLen, townmath.Entry{Owner: owner, Score: s})
}

// ensureDaySeed stores the current game day's seed if no call has yet.
func ensureDaySeed() {
	day := CurrentGameHour() / 24 // never negative
	sl := seeds[day%SeedRing]
	if sl.Set && sl.Day >= day {
		// already seeded, or the slot holds a newer day (block time behind
		// it): never replace a newer seed, so a day's event cannot change
		return
	}
	s := townmath.Mix(LastSeed() ^ uint64(runtime.ChainHeight()))
	seeds[day%SeedRing] = seedSlot{Day: day, Seed: s, Set: true} // replaces an older day
	lastSeed = s
	seeded = true
}

func noEvent() townmath.Event {
	return townmath.Event{Kind: townmath.EventNone, BoostBps: townmath.BpsOne, GrainMulBps: townmath.BpsOne}
}

// mustTavern returns the stored tavern of owner (a pointer into state).
func mustTavern(owner string) *Tavern {
	v := taverns.Get(owner)
	if v == nil {
		panic("town: no joint for this address")
	}
	return v.(*Tavern)
}
