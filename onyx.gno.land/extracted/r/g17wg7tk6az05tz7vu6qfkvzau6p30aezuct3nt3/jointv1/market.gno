package jointv1

import "gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"

// Town market: one supply counter per good. Prices come from the supply
// level (townmath.PriceFromSupply). Buying from the town draws its supply
// down, which raises the price; harvests and sales to the town raise it;
// every touch drifts supply back toward half the target
// (townmath.DriftSupply, at most 48 hours per touch).
//
// The Town Farm is the realm's own trader. Pubs buy from it at a price that
// starts at TownFarmSellBps of the market price and ramps up to
// TownFarmSellMaxBps as that pub itself buys more that day (no global cap
// and no shared ramp: nobody can lock others out or make them pay more). Farms
// sell grain and hops to it at TownFarmBuyBps within a hard daily town
// limit. Both directions have a daily limit per business. A trade over a
// limit is refused whole (all or nothing).

// Bounds for town purchases and inventory.
const (
	MinBuyQty int64 = 1
	MaxBuyQty int64 = 100
	MaxInv    int64 = 1000 // per good, per tavern
	numGoods        = 4
)

// Town Farm prices and daily limits (placeholders, tunable before the final
// deploy). The bps are fixed here and never taken from a caller.
const (
	// pubs pay 130% of the market price before the town bought anything today
	TownFarmSellBps int64 = 13000
	// the most pubs pay: 200% of the market price
	TownFarmSellMaxBps int64 = 20000
	// units a pub buys in a game day before its own price reaches
	// TownFarmSellMaxBps (half of it on a shortage day: the price climbs
	// faster); the same as the pub's daily allowance
	TownFarmSellRampUnits int64 = 120
	// farms get 70% of the market price
	TownFarmBuyBps int64 = 7000
	// units the Town Farm buys from farms per game day (a hard town limit)
	TownFarmDailyBuyGlobal int64 = 600
	// units one farm may sell to the Town Farm per game day
	TownFarmDailyPerPlayer int64 = 60
	// units one pub may buy from the Town Farm per game day (grain and hops
	// together; a pub needs about 70 to 110 grain a day)
	TownFarmDailyBuyPerPlayer int64 = 120
)

var (
	goodBaseCg = [numGoods]int64{600, 200, 350, 1100}   // ale, grain, hops, mead
	goodTarget = [numGoods]int64{2000, 3000, 1500, 800} // supply target
	townSupply = [numGoods]int64{1000, 1500, 750, 400}  // starts at target/2 (neutral)
	marketHour int64                                    // game hour of the last stored drift
)

// GoodBaseCg returns the base centigold price of good, the price at a
// neutral supply (goodBaseCg). Read-only. Aborts for an unknown good.
func GoodBaseCg(good int) int64 {
	assertGood(good)
	return goodBaseCg[good]
}

// GoodPriceCg returns the current town market price of one unit of good in
// centigold, from the supply alone (a shortage cuts farm yield and the Town
// Farm's sales instead; the price rises because supply falls). Read-only.
func GoodPriceCg(good int) int64 {
	assertGood(good)
	return townmath.PriceFromSupply(goodBaseCg[good], townmath.SupplyBps(supplyNow(good), goodTarget[good]))
}

// MarketSupply returns the current town supply counter of good, including
// drift since the last touch. Read-only.
func MarketSupply(good int) int64 {
	assertGood(good)
	return supplyNow(good)
}

// BuyGood buys qty (1 to 100) units of good from the Town Farm for
// qty * townmath.TownFarmSellCg(GoodPriceCg(good), bps) gold, where bps is
// TownFarmSellBpsAt of the units this pub bought today before the order (the
// whole order pays the price at the start of the order). Pubs only, at most
// TownFarmDailyBuyPerPlayer units a day per pub. Grain and hops only (ale is brewed, mead is not sold).
// Direct user call only.
func BuyGood(cur realm, good int, qty int64) {
	buyGood(userActor(cur), good, qty)
}

// buyGood is the game rule behind BuyGood, for the caller actor.
func buyGood(actor address, good int, qty int64) {
	assertNotPaused()
	assertGood(good)
	if good != GoodGrain && good != GoodHops {
		panic("town: grain and hops only")
	}
	assertQty(qty)
	t := mustTavern(actor.String())
	assertPub(t)
	settleTavern(t)
	if t.Inv[good]+qty > MaxInv {
		panic("town: inventory full (max 1000 per good)")
	}
	day := CurrentGameHour() / 24
	used := playerTFUsed(t, day, t.TFBought)
	assertPlayerRoom(qty, used, TownFarmDailyBuyPerPlayer)
	// the whole order pays one unit price, from what this pub bought before
	// it today (all or nothing); the order itself then moves its ramp
	bps := TownFarmSellBpsAt(used, EventOnDay(day).Kind == townmath.EventShortage)
	cost := qty * townmath.TownFarmSellCg(GoodPriceCg(good), bps)
	if cost > t.GoldCg {
		panic("town: not enough gold")
	}
	ownerActs(t)
	rollTownFarmDay(t, day)
	t.GoldCg -= cost
	goldDestroyedCg += cost
	t.ProfitTodayCg -= cost
	t.SeasonProfitCg -= cost
	t.Inv[good] += qty
	t.TFBought += qty
	tfSoldGlobal += qty
	townSupply[good] -= qty
	if townSupply[good] < 0 {
		townSupply[good] = 0
	}
}

// SellGood sells qty (1 to 100) units of grain or hops from the caller's
// farm to the Town Farm for qty * townmath.TownFarmBuyCg(GoodPriceCg(good),
// TownFarmBuyBps) gold. Farms only, within the daily limits
// (TownFarmDailyPerPlayer for the farm, TownFarmDailyBuyGlobal for the
// town). The farm is settled first, so the stock includes the harvest so
// far. Direct user call only.
func SellGood(cur realm, good int, qty int64) {
	sellGood(userActor(cur), good, qty)
}

// sellGood is the game rule behind SellGood, for the caller actor.
func sellGood(actor address, good int, qty int64) {
	assertNotPaused()
	assertGood(good)
	if good != GoodGrain && good != GoodHops {
		panic("town: the town farm buys only grain and hops")
	}
	assertQty(qty)
	t := mustTavern(actor.String())
	assertFarm(t)
	settleFarm(t)
	if t.Inv[good] < qty {
		panic("town: not enough stock")
	}
	day := CurrentGameHour() / 24
	_, _, boughtToday := TownFarmToday()
	assertPlayerRoom(qty, playerTFUsed(t, day, t.TFSold), TownFarmDailyPerPlayer)
	if townmath.Capped(qty, TownFarmDailyBuyGlobal, boughtToday) < qty {
		panic("town: town farm limit reached")
	}
	pay := qty * townmath.TownFarmBuyCg(GoodPriceCg(good), TownFarmBuyBps)
	rollTownFarmDay(t, day)
	t.GoldCg += pay
	goldCreatedCg += pay
	t.Inv[good] -= qty
	t.TFSold += qty
	tfBoughtGlobal += qty
	raiseSupply(good, qty)
}

// TownFarmToday returns the current game day and the units the Town Farm
// sold to pubs and bought from farms on it (0 and 0 before the day's first
// trade). Read-only.
func TownFarmToday() (day, soldGlobal, boughtGlobal int64) {
	day = CurrentGameHour() / 24
	if tfDay != day {
		return day, 0, 0
	}
	return day, tfSoldGlobal, tfBoughtGlobal
}

// playerTFUsed is used (TFSold or TFBought of t) if t's counters are of day,
// else 0.
func playerTFUsed(t *Tavern, day, used int64) int64 {
	if t.TFDay != day {
		return 0
	}
	return used
}

// assertPlayerRoom aborts unless all of qty fits the player's daily limit
// (used so far today).
func assertPlayerRoom(qty, used, limit int64) {
	if townmath.Capped(qty, limit, used) < qty {
		panic("town: town farm limit reached")
	}
}

// TownFarmSellBpsAt is the Town Farm's sell price in bps of the market price
// for a pub that bought used units from it today: TownFarmSellBps +
// (TownFarmSellMaxBps - TownFarmSellBps) * min(used, ramp) / ramp, where ramp
// is TownFarmSellRampUnits, halved on a shortage day. Never above
// TownFarmSellMaxBps; a negative used counts as 0. Pure.
func TownFarmSellBpsAt(used int64, shortage bool) int64 {
	ramp := TownFarmSellRampUnits
	if shortage {
		ramp /= 2
	}
	if used < 0 {
		used = 0
	}
	if used > ramp {
		used = ramp
	}
	return TownFarmSellBps + (TownFarmSellMaxBps-TownFarmSellBps)*used/ramp
}

// TownFarmSellBpsFor is the sell price (bps of the market price) the pub of
// owner would pay for its next order now: TownFarmSellBpsAt of its own units
// bought today and today's event. 13000 for an owner with no business or no
// buys today. It uses the last stored event of today (a settle stores it).
// Read-only.
func TownFarmSellBpsFor(owner string) int64 {
	day := CurrentGameHour() / 24
	used := int64(0)
	if t := GetTavern(owner); t != nil {
		used = playerTFUsed(t, day, t.TFBought)
	}
	return TownFarmSellBpsAt(used, EventOnDay(day).Kind == townmath.EventShortage)
}

// rollTownFarmDay resets the player's and the town's Town Farm counters if
// they are of another day than day. Call it only after every check passed.
func rollTownFarmDay(t *Tavern, day int64) {
	if t.TFDay != day {
		t.TFDay = day
		t.TFSold = 0
		t.TFBought = 0
	}
	if tfDay != day {
		tfDay = day
		tfSoldGlobal = 0
		tfBoughtGlobal = 0
	}
}

func assertQty(qty int64) {
	if qty < MinBuyQty || qty > MaxBuyQty {
		panic("town: quantity must be 1 to 100")
	}
}

// raiseSupply adds n units to the town supply of good, never above the
// good's target. Call it after touchMarket so the drift is stored first.
func raiseSupply(good int, n int64) {
	if n <= 0 {
		return
	}
	s := townSupply[good] + n // both bounded (n <= 100 or a harvest), no wrap
	if s > goodTarget[good] {
		s = goodTarget[good]
	}
	townSupply[good] = s
}

func assertGood(good int) {
	if good < 0 || good >= numGoods {
		panic("town: unknown good")
	}
}

// supplyNow is the stored supply drifted to the current hour (not stored).
func supplyNow(good int) int64 {
	d := CurrentGameHour() - marketHour
	if d <= 0 {
		return townSupply[good]
	}
	return townmath.DriftSupply(townSupply[good], goodTarget[good], d)
}

// touchMarket stores the drift up to the current hour. A clock behind the
// last touch changes nothing.
func touchMarket() {
	now := CurrentGameHour()
	d := now - marketHour
	if d <= 0 {
		return
	}
	for g := 0; g < numGoods; g++ {
		townSupply[g] = townmath.DriftSupply(townSupply[g], goodTarget[g], d)
	}
	marketHour = now
}
