package townmath

// Farm, Town Farm and ad constants.
const (
	CropGrain           = 0
	CropHops            = 1
	GrainPerPlotHour    = 3
	HopsPerPlotHour     = 2
	MaxFarmCatchUpHours = 24
	MaxFarmPlots        = 50
	MaxAdLevel          = 5
	MaxAdHours          = 24
	AdLevelBps          = 500
	AdUnitCostCg        = 100
)

// Harvest returns the crop made by a farm and the stock after storing it.
// Hours are clamped to 0..MaxFarmCatchUpHours and plots to 0..MaxFarmPlots
// before multiplying, so nothing overflows. An unknown crop makes nothing.
// yieldBps is clamped to 0..20000. A negative stock counts as 0 and a
// negative storageCap means no room. Made is limited to the room left.
func Harvest(plots int64, crop int, hours, stock, storageCap, yieldBps int64) (made, stockAfter int64) {
	plots = clamp(plots, 0, MaxFarmPlots)
	hours = clamp(hours, 0, MaxFarmCatchUpHours)
	if stock < 0 {
		stock = 0
	}
	rate := int64(0)
	if crop == CropGrain {
		rate = GrainPerPlotHour
	} else if crop == CropHops {
		rate = HopsPerPlotHour
	}
	gross := plots * rate * hours
	made = MulBps(gross, clamp(yieldBps, 0, 2*BpsOne))
	if storageCap < 0 {
		storageCap = 0
	}
	room := storageCap - stock // both >= 0, cannot wrap
	if room < 0 {
		room = 0
	}
	made = min64(made, room)
	return made, stock + made
}

// HarvestCarry is Harvest with the fraction of a unit carried between calls,
// so settling often makes the same crop as settling once. Carry is in
// 1/10000 units, clamped to 0..9999 on input. total = plots*rate*hours *
// yieldBps + carry (the same clamps as Harvest: at most 3600 * 20000 + 9999,
// no overflow); made = total / 10000, newCarry = total % 10000 (always
// 0..9999, also when full storage limits made). Made is limited to the room
// left, as in Harvest.
func HarvestCarry(plots int64, crop int, hours, stock, storageCap, yieldBps, carry int64) (made, stockAfter, newCarry int64) {
	plots = clamp(plots, 0, MaxFarmPlots)
	hours = clamp(hours, 0, MaxFarmCatchUpHours)
	if stock < 0 {
		stock = 0
	}
	rate := int64(0)
	if crop == CropGrain {
		rate = GrainPerPlotHour
	} else if crop == CropHops {
		rate = HopsPerPlotHour
	}
	total := plots*rate*hours*clamp(yieldBps, 0, 2*BpsOne) + clamp(carry, 0, BpsOne-1)
	made = total / BpsOne
	newCarry = total % BpsOne
	if storageCap < 0 {
		storageCap = 0
	}
	room := storageCap - stock // both >= 0, cannot wrap
	if room < 0 {
		room = 0
	}
	made = min64(made, room)
	return made, stock + made, newCarry
}

// TownFarmSellCg is the price a player PAYS the Town Farm for one unit of a
// good. The Town Farm sells above market: marketCg * sellBps, with sellBps
// clamped to 10000..30000 (default 13000, so 130% of market). Never below 1,
// and a market price <= 0 gives 1. The realm must pass a fixed constant such
// as 13000, never a caller-supplied value.
func TownFarmSellCg(marketCg, sellBps int64) int64 {
	v := MulBps(marketCg, clamp(sellBps, BpsOne, 3*BpsOne))
	if v < 1 {
		return 1
	}
	return v
}

// TownFarmBuyCg is the price the Town Farm PAYS a player for one unit of a
// good. The Town Farm buys below market: marketCg * buyBps, with buyBps
// clamped to 1000..10000 (default 7000, so 70% of market). Never below 1,
// and a market price <= 0 gives 1. The realm must pass a fixed constant such
// as 7000, never a caller-supplied value. Because the farm pays less than it
// charges, buying and reselling to the farm always loses gold.
func TownFarmBuyCg(marketCg, buyBps int64) int64 {
	v := MulBps(marketCg, clamp(buyBps, BpsOne/10, BpsOne))
	if v < 1 {
		return 1
	}
	return v
}

// Capped returns how much of amount still fits under limit given used so far.
// Never negative and never more than amount. Negative limit or used count as
// 0, so extreme inputs cannot wrap.
func Capped(amount, limit, used int64) int64 {
	if amount <= 0 {
		return 0
	}
	if limit < 0 {
		limit = 0
	}
	if used < 0 {
		used = 0
	}
	room := limit - used // both >= 0, cannot wrap
	if room <= 0 {
		return 0
	}
	return min64(amount, room)
}

// AdWeightBps is the customer-draw weight of a tavern ad level, in bps.
func AdWeightBps(level int64) int64 {
	return BpsOne + clamp(level, 0, MaxAdLevel)*AdLevelBps
}

// AdCostCg is the gold cost of running an ad level for the given hours.
func AdCostCg(level, hours int64) int64 {
	return clamp(level, 0, MaxAdLevel) * clamp(hours, 0, MaxAdHours) * AdUnitCostCg
}
