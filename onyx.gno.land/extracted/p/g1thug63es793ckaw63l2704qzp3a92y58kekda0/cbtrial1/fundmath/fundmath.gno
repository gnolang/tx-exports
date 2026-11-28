// Package fundmath holds Charterbook's fund arithmetic as pure functions:
// exact integer money (6 decimals), share issue and cancellation at an
// approved NAV, the management fee, and the redemption-gate allocation.
//
// Rounding always favours the fund's remaining investors:
//   - shares issued for a subscription: rounded down;
//   - shares cancelled for a lot redemption: rounded up (the lot is paid exactly);
//   - value paid on a full exit: rounded down;
//   - management fee: rounded down.
//
// The worked example approved on 27 Nov 2026 (three periods, two investors)
// is reproduced to the micro-unit in fundmath_test.gno.
package fundmath

import "math/bits"

const (
	// Unit is one whole tUSD or one whole share in micro-units.
	Unit int64 = 1_000_000
	// BpsDenominator: 10,000 basis points = 100%.
	BpsDenominator int64 = 10_000
	// SecondsPerYear for fee accrual (365 days).
	SecondsPerYear int64 = 365 * 24 * 60 * 60
)

// MulDivDown returns floor(a*b/c) for non-negative a, b and positive c,
// using a 128-bit intermediate. It panics if the result does not fit int64.
func MulDivDown(a, b, c int64) int64 {
	q, _ := mulDiv(a, b, c)
	return q
}

// MulDivUp returns ceil(a*b/c) for non-negative a, b and positive c.
func MulDivUp(a, b, c int64) int64 {
	q, rem := mulDiv(a, b, c)
	if rem != 0 {
		if q == maxInt64 {
			panic("fundmath: overflow")
		}
		q++
	}
	return q
}

const maxInt64 int64 = 1<<63 - 1

func mulDiv(a, b, c int64) (int64, uint64) {
	if a < 0 || b < 0 {
		panic("fundmath: negative operand")
	}
	if c <= 0 {
		panic("fundmath: non-positive divisor")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(c) {
		panic("fundmath: overflow")
	}
	q, rem := bits.Div64(hi, lo, uint64(c))
	if q > uint64(maxInt64) {
		panic("fundmath: overflow")
	}
	return int64(q), rem
}

// ManagementFee returns the fee accrued on gross assets over elapsed seconds
// at an annual rate in basis points, rounded down. The same rule serves every
// charge expressed as a percentage a year.
func ManagementFee(gross, rateBps, elapsedSeconds int64) int64 {
	return AnnualCharge(gross, rateBps, elapsedSeconds)
}

// AnnualCharge returns base x rateBps/10,000 x elapsed/365 days, rounded down.
func AnnualCharge(gross, rateBps, elapsedSeconds int64) int64 {
	if rateBps < 0 || rateBps > BpsDenominator || elapsedSeconds < 0 || elapsedSeconds > 10*SecondsPerYear {
		panic("fundmath: fee rate or period out of range")
	}
	if gross <= 0 || rateBps == 0 || elapsedSeconds == 0 {
		return 0
	}
	return MulDivDown(gross, rateBps*elapsedSeconds, BpsDenominator*SecondsPerYear)
}

// SharesForSubscription returns the shares issued for amount at the period's
// NAV over the opening shares in issue (rounded down). With no shares in
// issue, shares are issued at the par price (tUSD micro-units per share).
func SharesForSubscription(amount, sharesInIssue, nav, par int64) int64 {
	if amount <= 0 {
		panic("fundmath: amount must be positive")
	}
	if par <= 0 || sharesInIssue < 0 {
		panic("fundmath: invalid par or shares")
	}
	if sharesInIssue == 0 {
		return MulDivDown(amount, Unit, par)
	}
	if nav <= 0 {
		panic("fundmath: dealing suspended, NAV not positive")
	}
	return MulDivDown(amount, sharesInIssue, nav)
}

// SharesToCancel returns the shares cancelled to pay exactly amount at the
// period's NAV (rounded up).
func SharesToCancel(amount, sharesInIssue, nav int64) int64 {
	if amount <= 0 || sharesInIssue <= 0 || nav <= 0 {
		panic("fundmath: invalid redemption")
	}
	return MulDivUp(amount, sharesInIssue, nav)
}

// ValueOf returns the value of shares at the period's NAV (rounded down).
func ValueOf(shares, sharesInIssue, nav int64) int64 {
	if shares == 0 {
		return 0
	}
	if sharesInIssue <= 0 || nav <= 0 {
		panic("fundmath: invalid valuation")
	}
	return MulDivDown(shares, nav, sharesInIssue)
}

// Request is one redemption request for gate allocation.
//   - Full: a full exit of the wallet, worth Value;
//   - otherwise: Lots whole lots; Value is the wallet's value (for the
//     minimum-holding check).
type Request struct {
	Full     bool
	Lots     int64
	Value    int64
	Deferred bool // carried from an earlier period: served before new requests
}

// Fill is the result for one request.
type Fill struct {
	Lots int64 // whole lots paid (partial requests, and full exits paid in lots)
	Paid int64 // amount paid
	Done bool  // request completely filled
}

// Classify turns a request for `lots` lots from a wallet worth `value` into a
// Request: a full exit if lots is 0 (meaning "all"), if the lots exceed the
// value, or if paying them would leave less than minHolding. It never
// multiplies before comparing, so no lot count can overflow.
func Classify(lots, value, lot, minHolding int64) Request {
	checkLot(lot, minHolding)
	if lots < 0 {
		panic("fundmath: negative lots")
	}
	if value < 0 {
		panic("fundmath: negative value")
	}
	if lots == 0 || lots > value/lot || value-lots*lot < minHolding {
		return Request{Full: true, Value: value}
	}
	return Request{Lots: lots, Value: value}
}

func checkLot(lot, minHolding int64) {
	if lot <= 0 || minHolding < 0 {
		panic("fundmath: invalid lot or minimum holding")
	}
}

// maxLots is how many whole lots a full exit may be paid in this period
// while at least minHolding stays invested.
func maxLots(r Request, lot, minHolding int64) int64 {
	if r.Value < minHolding {
		return 0
	}
	return (r.Value - minHolding) / lot
}

func asked(r Request, lot int64) int64 {
	if r.Full {
		return r.Value
	}
	return r.Lots * lot
}

// AllocateGate shares capacity among redemption requests. Deferred requests
// (carried from earlier periods) are served first; only what is left goes to
// new requests. Within each tier, in request order:
//  1. if the whole tier fits what is left, it is filled;
//  2. round 1: each request gets its pro-rata share in whole lots; a full
//     exit is paid in whole lots while at least minHolding stays invested;
//  3. round 2: what is left goes first to requests that received nothing in
//     round 1; then one more lot at a time, in request order, until nothing
//     more fits. Whenever the rest of a full exit fits, it is paid in full.
//
// Last exit: if, after both tiers, exactly one request is unfilled, it is a
// full exit, and its rest is below one lot plus minHolding, the rest is paid
// from cash even above the gate (at most one such payment per period).
//
// cash is the cash available (cash >= capacity). Work is linear in the
// number of requests. AllocateGate panics on inputs Classify would not
// produce.
func AllocateGate(reqs []Request, capacity, cash, lot, minHolding int64) []Fill {
	checkLot(lot, minHolding)
	if capacity < 0 || cash < capacity {
		panic("fundmath: invalid capacity or cash")
	}
	fills := make([]Fill, len(reqs))
	var deferred, fresh []int
	for i, r := range reqs {
		if r.Value < 0 {
			panic("fundmath: negative value")
		}
		if !r.Full && (r.Lots <= 0 || r.Lots > maxLots(r, lot, minHolding)) {
			panic("fundmath: invalid partial request, use Classify")
		}
		if r.Deferred {
			deferred = append(deferred, i)
		} else {
			fresh = append(fresh, i)
		}
	}
	var used int64
	allocateTier(reqs, fills, deferred, capacity, lot, minHolding, &used)
	allocateTier(reqs, fills, fresh, capacity, lot, minHolding, &used)
	// Last exit.
	open := -1
	for i := range fills {
		if !fills[i].Done {
			if open >= 0 {
				return fills
			}
			open = i
		}
	}
	if open >= 0 && reqs[open].Full {
		rest := reqs[open].Value - fills[open].Paid
		if rest < lot+minHolding && rest <= cash-used {
			fills[open].Paid += rest
			fills[open].Done = true
		}
	}
	return fills
}

func allocateTier(reqs []Request, fills []Fill, idx []int, capacity, lot, minHolding int64, used *int64) {
	if len(idx) == 0 {
		return
	}
	var total int64
	for _, i := range idx {
		total = addChecked(total, asked(reqs[i], lot))
	}
	room := capacity - *used
	if total <= room {
		for _, i := range idx {
			r := reqs[i]
			fills[i] = Fill{Paid: asked(r, lot), Done: true}
			if !r.Full {
				fills[i].Lots = r.Lots
			}
			*used += fills[i].Paid
		}
		return
	}
	if room <= 0 {
		return
	}
	// Round 1. alloc < asked, because room < total.
	for _, i := range idx {
		r := reqs[i]
		alloc := MulDivDown(asked(r, lot), room, total)
		limit := r.Lots
		if r.Full {
			limit = maxLots(r, lot, minHolding)
		}
		k := alloc / lot
		if k > limit {
			k = limit
		}
		fills[i] = Fill{Lots: k, Paid: k * lot, Done: !r.Full && k == r.Lots}
		*used += fills[i].Paid
	}
	// Round 2, first pass: only requests that got nothing in round 1. An
	// entry that cannot move now never can, since what is left only shrinks;
	// it leaves the rotation.
	active := make([]int, 0, len(idx))
	for _, i := range idx {
		if fills[i].Done {
			continue
		}
		if fills[i].Paid > 0 {
			active = append(active, i)
			continue
		}
		if step(reqs[i], &fills[i], capacity-*used, lot, minHolding, used) && !fills[i].Done {
			active = append(active, i)
		}
	}
	// Then one payment per request per sweep, in request order.
	for len(active) > 0 {
		next := active[:0]
		for _, i := range active {
			if step(reqs[i], &fills[i], capacity-*used, lot, minHolding, used) && !fills[i].Done {
				next = append(next, i)
			}
		}
		active = next
	}
}

// step gives request r one more payment if it fits: the whole rest of a full
// exit, else one lot. It reports whether anything was paid.
func step(r Request, f *Fill, left, lot, minHolding int64, used *int64) bool {
	if r.Full {
		rest := r.Value - f.Paid
		if rest <= left {
			f.Paid += rest
			f.Done = true
			*used += rest
			return true
		}
		if f.Lots < maxLots(r, lot, minHolding) && lot <= left {
			f.Lots++
			f.Paid += lot
			*used += lot
			return true
		}
		return false
	}
	if f.Lots < r.Lots && lot <= left {
		f.Lots++
		f.Paid += lot
		f.Done = f.Lots == r.Lots
		*used += lot
		return true
	}
	return false
}

func addChecked(a, b int64) int64 {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		panic("fundmath: overflow")
	}
	return c
}

// PerformanceFeePerShare is rateBps of the rise of navps above hwm, per share
// (micro-units), rounded down; zero at or below the mark.
func PerformanceFeePerShare(navps, hwm, rateBps int64) int64 {
	if rateBps < 0 || rateBps > BpsDenominator || navps < 0 || hwm < 0 {
		panic("fundmath: invalid performance fee input")
	}
	if navps <= hwm {
		return 0
	}
	return MulDivDown(navps-hwm, rateBps, BpsDenominator)
}

// BlendHWM is the high-water mark after a holder of oldShares at mark oldHWM
// receives newShares at price: the share-weighted average, rounded up (in the
// investor's favour). A holder with no shares takes the price.
func BlendHWM(oldShares, oldHWM, newShares, price int64) int64 {
	if oldShares < 0 || newShares <= 0 || oldHWM < 0 || price <= 0 {
		panic("fundmath: invalid high-water mark input")
	}
	if oldShares == 0 {
		return price
	}
	total := addChecked(oldShares, newShares)
	if price >= oldHWM {
		return oldHWM + MulDivUp(price-oldHWM, newShares, total)
	}
	return oldHWM - MulDivDown(oldHWM-price, newShares, total)
}
