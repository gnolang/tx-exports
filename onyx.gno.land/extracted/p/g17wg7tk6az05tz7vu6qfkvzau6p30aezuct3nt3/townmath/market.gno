package townmath

// HourCurveTable is the relative customer demand for each hour of the day
// (index 0 to 23), in arbitrary weight units.
var HourCurveTable = [24]int64{2, 1, 0, 0, 0, 0, 1, 2, 3, 3, 4, 5, 6, 6, 5, 5, 6, 8, 12, 15, 16, 14, 9, 4}

// Supply drift constants.
const (
	maxDriftHours = 48
	driftPercent  = 2
)

// PriceFactorBps returns how a tavern's menu price affects demand, in basis
// points. A price equal to the market price gives 10000. Cheaper sells more
// (up to 20000), dearer sells less (down to 800). mkt <= 0 gives 10000.
func PriceFactorBps(price, mkt int64) int64 {
	if mkt <= 0 {
		return BpsOne
	}
	return clamp(BpsOne+(mkt-price)*22000/mkt, 800, 20000)
}

// RepFactorBps returns the reputation effect on demand in basis points:
// 6000 at rep 0 up to 14000 at rep 500 and above. Negative rep counts as 0.
func RepFactorBps(rep int64) int64 {
	return 6000 + clamp(rep, 0, 500)*16
}

// HourCurve returns the demand weight for an hour of day. The hour wraps
// modulo 24, so 24 is hour 0 and -1 is hour 23.
func HourCurve(hour int) int64 {
	h := hour % 24
	if h < 0 {
		h += 24
	}
	return HourCurveTable[h]
}

// SupplyBps returns total as a share of target in basis points. A target of
// zero or less gives 5000 (the neutral midpoint).
func SupplyBps(total, target int64) int64 {
	if target <= 0 {
		return 5000
	}
	return total * BpsOne / target
}

// PriceFromSupply turns a supply level (basis points of target) into a price.
// Supply is clamped to [1500, 8800]; 5000 gives the base price, scarcer is
// dearer, plentiful is cheaper. The result is never below 1.
func PriceFromSupply(baseCg, supplyBps int64) int64 {
	s := clamp(supplyBps, 1500, 8800)
	p := MulBps(baseCg, BpsOne+(5000-s)*9/10)
	if p < 1 {
		return 1
	}
	return p
}

// DriftSupply moves supply toward half of target by 2% of the gap per hour.
// Hours are capped at 48; zero or fewer hours returns supply unchanged.
func DriftSupply(supply, target, hours int64) int64 {
	if hours > maxDriftHours {
		hours = maxDriftHours
	}
	mid := target / 2
	for i := int64(0); i < hours; i++ {
		supply += (mid - supply) * driftPercent / 100
	}
	return supply
}
