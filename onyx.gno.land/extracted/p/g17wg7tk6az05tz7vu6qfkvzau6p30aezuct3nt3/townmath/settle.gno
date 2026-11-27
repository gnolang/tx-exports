package townmath

// MaxCatchUpHours caps how many hours one settlement applies.
const MaxCatchUpHours int64 = 24

// Reputation bounds after settlement.
const (
	repMin int64 = 50
	repMax int64 = 500
)

// SettleIn is the state of one tavern entering settlement.
// PriceCg is the menu price, MarketCg the market price of the same item.
// EventBps and StaffBps are demand multipliers in basis points (10000 = 1.0).
// RegularBonus is extra customers per hour from regulars.
type SettleIn struct {
	PriceCg, MarketCg, Rep, Stock, Seats, EventBps, StaffBps, RegularBonus int64
}

// SettleOut is the result of settling one or more hours.
// RepDelta is the raw sum of the per-hour changes (before the [50,500]
// clamp); RepAfter is the clamped reputation to store.
type SettleOut struct {
	Served, UnservedStock, RevenueCg, RepDelta, StockLeft, RepAfter, HoursApplied int64
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

// SettleHour settles a single hour of day. The potential customer count comes
// from the formulas below, then SettleHourDemand applies the seat and stock
// limits. Nothing negative is ever served.
func SettleHour(hour int, in SettleIn) SettleOut {
	potential := HourCurve(hour)
	potential = potential * PriceFactorBps(in.PriceCg, in.MarketCg) / BpsOne
	potential = potential * RepFactorBps(in.Rep) / BpsOne
	potential = potential * in.EventBps / BpsOne
	potential = potential * in.StaffBps / BpsOne
	potential += in.RegularBonus
	return SettleHourDemand(in, potential)
}

// SettleHourDemand settles one hour for a given customer demand instead of
// the formula potential. A negative demand counts as zero. Seats, stock and
// price are floored at zero, and at most Seats*2 customers are served.
func SettleHourDemand(in SettleIn, demand int64) SettleOut {
	if demand < 0 {
		demand = 0
	}

	seats := in.Seats
	if seats < 0 {
		seats = 0
	}
	stock := in.Stock
	if stock < 0 {
		stock = 0
	}
	price := in.PriceCg
	if price < 0 {
		price = 0
	}

	capped := min64(demand, seats*2)
	served := min64(capped, stock)
	unserved := capped - served
	repDelta := served/5 - unserved*4/5

	return SettleOut{
		Served:        served,
		UnservedStock: unserved,
		RevenueCg:     served * price,
		RepDelta:      repDelta,
		StockLeft:     stock - served,
		RepAfter:      clamp(in.Rep+repDelta, repMin, repMax),
		HoursApplied:  1,
	}
}

// SettleRange settles hours consecutive hours starting at startHour (wrapping
// modulo 24), carrying stock and reputation from each hour to the next.
// hours is capped at MaxCatchUpHours; zero or fewer returns the input stock
// and reputation unchanged.
func SettleRange(startHour int, hours int64, in SettleIn) SettleOut {
	if hours > MaxCatchUpHours {
		hours = MaxCatchUpHours
	}
	total := SettleOut{StockLeft: in.Stock, RepAfter: in.Rep}
	cur := in
	for i := int64(0); i < hours; i++ {
		out := SettleHour(startHour+int(i), cur)
		total.Served += out.Served
		total.UnservedStock += out.UnservedStock
		total.RevenueCg += out.RevenueCg
		total.RepDelta += out.RepDelta
		total.StockLeft = out.StockLeft
		total.RepAfter = out.RepAfter
		total.HoursApplied++
		cur.Stock = out.StockLeft
		cur.Rep = out.RepAfter
	}
	return total
}

// SettleRangeDemand settles one hour per entry of demands, carrying stock and
// reputation from each hour to the next like SettleRange. At most
// MaxCatchUpHours entries are used and HoursApplied counts them. A negative
// entry counts as zero customers but still uses its hour. An empty or nil
// slice returns the input stock and reputation unchanged.
func SettleRangeDemand(demands []int64, in SettleIn) SettleOut {
	n := int64(len(demands))
	if n > MaxCatchUpHours {
		n = MaxCatchUpHours
	}
	total := SettleOut{StockLeft: in.Stock, RepAfter: in.Rep}
	cur := in
	for i := int64(0); i < n; i++ {
		out := SettleHourDemand(cur, demands[i])
		total.Served += out.Served
		total.UnservedStock += out.UnservedStock
		total.RevenueCg += out.RevenueCg
		total.RepDelta += out.RepDelta
		total.StockLeft = out.StockLeft
		total.RepAfter = out.RepAfter
		total.HoursApplied++
		cur.Stock = out.StockLeft
		cur.Rep = out.RepAfter
	}
	return total
}
