package jointv1

import "gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"

// Roles, farms and town stats.
//
// Pubs and farms share the taverns tree (one business per address). The
// town keeps pubCount, farmCount, totalWeight, totalPriceCg and
// totalPriceWeight up to date incrementally: every change to a pub's price,
// reputation, seats or barmaid calls reweigh, which applies only the deltas,
// and a pub enters or leaves the totals only through joinTotals and
// leaveTotals (idle.gno). RecountStats recomputes them from scratch so tests
// can prove they never drift.

// maxRecount bounds the businesses one RecountStats call visits.
const maxRecount = 2000

// Farm harvest constants (placeholders, tunable before the final deploy).
const (
	// FarmStorageCap is the most a farm stores of each good; harvest stops there.
	FarmStorageCap int64 = 120
	// FarmShortageYieldBps is a farm's yield on a shortage day (10000 otherwise).
	FarmShortageYieldBps int64 = 5000
	// DailyFarmScoreCap is the most a farm's season score can grow in one
	// game day. A tuned farm harvests more than this, so the cap bites.
	DailyFarmScoreCap int64 = 200
)

// CreateFarm opens a farm for the calling user. It uses the same checks, in
// the same order, as CreateTavern: one business (pub or farm) per address.
func CreateFarm(cur realm, name string) {
	prev := cur.Previous()
	// validate everything first; mutate only after
	if !prev.IsUserCall() {
		panic("town: CreateFarm must be a direct user call")
	}
	assertNotPaused()
	assertNoSend()
	validateName(name)
	owner := prev.Address()
	key := owner.String()
	assertNoBusiness(key)

	t := &Tavern{
		Owner:    owner,
		Name:     name,
		GoldCg:   params.StartGoldCg,
		Rep:      StartRep,
		LastHour: CurrentGameHour(),
		Role:     RoleFarm,
		Plots:    FarmStartPlots,
		ScoreGen: seasonGen,
	}
	t.Inv[GoodGrain] = FarmStartGrain
	taverns.Set(key, t)
	farmCount++
}

// TownStats returns the pub count, farm count, the sum of pub weights and
// the sum of pub prices (centigold). Dormant pubs are not counted. Read-only.
func TownStats() (pubs, farms, totalW, totalPrice int64) {
	return pubCount, farmCount, totalWeight, totalPriceCg
}

// RecountStats recomputes TownStats from the stored businesses, visiting at
// most limit of them (limit is clamped to 1..2000). Dormant pubs are not in
// the totals and are skipped. Read-only; with limit at or above the business
// count it must equal TownStats.
func RecountStats(limit int) (pubs, farms, totalW, totalPrice int64) {
	if limit < 1 {
		limit = 1
	}
	if limit > maxRecount {
		limit = maxRecount
	}
	taverns.IterateByOffset(0, limit, func(_ string, v any) bool {
		t := v.(*Tavern)
		if t.Role == RoleFarm {
			farms++
			return false
		}
		if t.Dormant != 0 {
			return false // not in the totals
		}
		pubs++
		totalW += pubWeight(t)
		totalPrice += t.PriceCg
		return false
	})
	return pubs, farms, totalW, totalPrice
}

// TownPriceWeight returns the sum of PriceCg * Weight over all pubs. The
// pool elasticity uses TownPriceWeight / total weight as the town's average
// price, so pubs with almost no weight barely move it. Read-only.
func TownPriceWeight() int64 {
	return totalPriceWeight
}

// RecountPriceWeight recomputes TownPriceWeight from the stored pubs that
// are not dormant, with weights recomputed from scratch, visiting at most limit businesses (clamped
// to 1..2000). Read-only; with limit at or above the business count it must
// equal TownPriceWeight.
func RecountPriceWeight(limit int) int64 {
	if limit < 1 {
		limit = 1
	}
	if limit > maxRecount {
		limit = maxRecount
	}
	sum := int64(0)
	taverns.IterateByOffset(0, limit, func(_ string, v any) bool {
		t := v.(*Tavern)
		if t.Role == RolePub && t.Dormant == 0 {
			sum += t.PriceCg * pubWeight(t)
		}
		return false
	})
	return sum
}

// GoldFlow returns all gold (centigold) the game has created (customer
// revenue, Town Farm purchases from farms) and destroyed (tax, hires, Town
// Farm sales to pubs). Start capital is not counted: the gold of all
// businesses is businesses * StartGoldCg + created - destroyed. Read-only.
func GoldFlow() (created, destroyed int64) {
	return goldCreatedCg, goldDestroyedCg
}

// BusinessCount returns the number of stored businesses: pubs (dormant or
// not) and farms. Read-only.
func BusinessCount() int {
	return taverns.Size()
}

// BusinessOwners returns up to count (clamped to 1..50) owner addresses of
// stored businesses from offset (at least 0), in the order the recounts
// visit them. Read-only.
func BusinessOwners(offset, count int) []string {
	if offset < 0 {
		offset = 0
	}
	if count < 1 {
		count = 1
	}
	if count > 50 {
		count = 50
	}
	out := make([]string, 0, count)
	taverns.IterateByOffset(offset, count, func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

// RecountGold sums GoldCg over the stored businesses (pubs and farms),
// visiting at most limit of them (clamped to 1..2000). Read-only.
func RecountGold(limit int) int64 {
	if limit < 1 {
		limit = 1
	}
	if limit > maxRecount {
		limit = maxRecount
	}
	sum := int64(0)
	taverns.IterateByOffset(0, limit, func(_ string, v any) bool {
		sum += v.(*Tavern).GoldCg
		return false
	})
	return sum
}

// pubWeight is a pub's pull on the customer pool, measured against the fixed
// ReferencePriceCg. Ads are not counted yet (level 0).
func pubWeight(t *Tavern) int64 {
	staff := townmath.BpsOne
	if t.HasBarmaid {
		staff = BarmaidStaffBps
	}
	return townmath.PubWeight(townmath.WeightIn{
		PriceCg:  t.PriceCg,
		MarketCg: ReferencePriceCg,
		Rep:      t.Rep,
		Seats:    t.Seats,
		StaffBps: staff,
		AdBps:    townmath.AdWeightBps(0),
	})
}

// reweigh recomputes a pub's Weight and applies the deltas of weight, price
// and price x weight to the town totals. oldPriceCg is the price counted in totalPriceCg
// before the change (pass t.PriceCg when the price did not change). Call it
// after every change to price, reputation, seats or barmaid. It then records
// the totals in the snapshot ring for the current hour. A farm keeps Weight
// 0 and never touches the totals or the ring, and so does a dormant pub
// (it is not in the totals).
func reweigh(t *Tavern, oldPriceCg int64) {
	if t.Role != RolePub || t.Dormant != 0 {
		return
	}
	w := pubWeight(t)
	totalWeight += w - t.Weight
	totalPriceCg += t.PriceCg - oldPriceCg
	totalPriceWeight += t.PriceCg*w - oldPriceCg*t.Weight
	t.Weight = w
	writeSnapshot(CurrentGameHour()) // skipped when nothing changed
}

// SetCrop sets what the caller's farm grows: townmath.CropGrain (0) or
// townmath.CropHops (1). The farm is settled first, so the hours before the
// change harvest the old crop. Farms only.
func SetCrop(cur realm, crop int) {
	setCrop(userActor(cur), crop)
}

func setCrop(actor address, crop int) {
	assertNotPaused()
	if crop != townmath.CropGrain && crop != townmath.CropHops {
		panic("town: crop must be 0 (grain) or 1 (hops)")
	}
	t := mustTavern(actor.String())
	assertFarm(t)
	settleFarm(t)
	if t.Crop != int64(crop) {
		t.Carry = 0 // a fraction of the old crop is not the new crop
	}
	t.Crop = int64(crop)
}

// settleFarm applies the elapsed game hours to a farm, like settleTavern for
// a pub: a LastHour at or ahead of the clock credits nothing; otherwise the
// last at most 24 hours are split at day boundaries (at most 3 segments) and
// each segment harvests t.Crop with that day's yield (FarmShortageYieldBps on
// a shortage day), up to FarmStorageCap. The fraction of a unit carries in
// t.Carry (1/10000 units, 0..9999), so settling every hour makes the same
// crop as settling once a day. The harvest raises the town supply
// of the good. Harvested units (not gold) add to SeasonProd. At each day
// boundary ScoreDayStart becomes the score so far, and the score is
// CapGain of SeasonProd from that start, at most DailyFarmScoreCap, and
// never below the previous score. The result is submitted to the farm
// board only. LastHour moves to the current hour. Farms are not taxed and
// never touch the pub totals.
func settleFarm(t *Tavern) {
	ensureSeasonScore(t)
	ensureDaySeed()
	touchMarket()
	now := CurrentGameHour()
	last := t.LastHour
	if last >= now {
		return
	}
	hours := now - last
	if hours > townmath.MaxFarmCatchUpHours {
		hours = townmath.MaxFarmCatchUpHours
	}
	good := cropGood(t.Crop)
	h := now - hours + 1
	profitDay := last / 24
	// 24 hours span at most 2 game days; the bound is a safety net
	for i := 0; i < 3 && h <= now; i++ {
		day := h / 24
		end := day*24 + 23
		if end > now {
			end = now
		}
		if day != profitDay {
			t.ScoreDayStart = t.SeasonScore
			profitDay = day
		}
		yield := townmath.BpsOne
		if EventOnDay(day).Kind == townmath.EventShortage {
			yield = FarmShortageYieldBps
		}
		made, after, carry := townmath.HarvestCarry(t.Plots, int(t.Crop), end-h+1, t.Inv[good], FarmStorageCap, yield, t.Carry)
		t.Inv[good] = after
		t.Carry = carry
		raiseSupply(good, made)
		if made > 0 {
			t.SeasonProd += made
		}
		t.SeasonScore = NextFarmScore(t.SeasonScore, t.ScoreDayStart, t.SeasonProd)
		h = end + 1
	}
	t.LastHour = now
	submitFarmScore(t)
}

// NextFarmScore is a farm's season score from units harvested: CapGain of
// seasonProd above the score the day started with, at most DailyFarmScoreCap,
// and never below the previous score or 0.
func NextFarmScore(oldScore, dayStartScore, seasonProd int64) int64 {
	if oldScore < 0 {
		oldScore = 0
	}
	if dayStartScore < 0 {
		dayStartScore = 0
	}
	if dayStartScore > oldScore {
		dayStartScore = oldScore
	}
	if seasonProd < 0 {
		seasonProd = 0
	}
	s := townmath.CapGain(dayStartScore, seasonProd, DailyFarmScoreCap)
	if s < oldScore {
		return oldScore
	}
	return s
}

// cropGood is the inventory slot (and market good) a crop fills.
func cropGood(crop int64) int {
	if crop == townmath.CropHops {
		return GoodHops
	}
	return GoodGrain
}

// assertFarm aborts unless t is a farm.
func assertFarm(t *Tavern) {
	if t.Role != RoleFarm {
		panic("town: farms only")
	}
}

// assertPub aborts unless t is a pub.
func assertPub(t *Tavern) {
	if t.Role != RolePub {
		panic("town: joints only")
	}
}

// assertNoBusiness aborts if the address already has a pub or a farm.
func assertNoBusiness(key string) {
	if taverns.Has(key) {
		panic("town: address already has a joint or farm")
	}
}
