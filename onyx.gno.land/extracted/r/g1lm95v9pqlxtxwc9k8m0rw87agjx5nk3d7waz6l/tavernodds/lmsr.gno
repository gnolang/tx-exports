package tavernodds

// LMSR pricing for Tavern Odds — binary prediction market (Gno.land).
//
// Port of the Prophet LMSR math (Solana, f64) to int64 fixed point.
// Gno has no floats, so every real number x is carried as a scaled
// integer: xScaled = round(x * scale).
//
// Formulas (qYes/qNo = outstanding YES/NO shares, b = liquidity):
//
//	C(qy, qn) = b * ln(exp(qy/b) + exp(qn/b))
//	price(YES) = exp(qy/b) / (exp(qy/b) + exp(qn/b)) = sigmoid((qy-qn)/b)
//
// Cost uses the numerically stable log-sum-exp form with
// m = max(qy, qn)/b:
//
//	C = b * (m + ln(exp(qy/b - m) + exp(qn/b - m)))
//
// so exp is only ever evaluated on (-inf, 0] and ln only on [1, 2].
//
// # Scales
//
// LMSRScale (1e6) is the fixed-point scale of this package's public
// interface: one LMSRScale unit = 1e-6 of a unit. Amounts themselves
// (q, b, costs) are plain ugnot integers (1 GNOT = 1e6 ugnot); the
// scale only quantises the fractional math inside.
//
// Internally exp/ln run at 1e9 (lmsrInternalScale), NOT 1e6. Reason:
// a 1e6-scale exp has rounding ~1e-6, which becomes a cost error of
// ~b*1e-6 ugnot (100 ugnot at b=1e8) — enough to swamp sub-100-ugnot
// trade deltas and even flip the sign of a 1-share buy. At 1e9 the
// measured cost error is ~b*1e-8 (see VERIFICATION below).
//
// # Primitives (all int64, deterministic, no floats)
//
//   - expNeg(x): exp(x) for x <= 0. Range reduction by ln(2):
//     x = -n*ln2 + r with r in (-ln2, 0], exp(x) = exp(r)/2^n.
//     exp(r) is a Taylor series (16 terms, |r| <= 0.694, truncation
//     < 1e-12); division by 2^n is exact repeated halving. No
//     error amplification: unlike exp(x/1024)^1024 squaring, which
//     multiplies the base rounding error by 1024, halving only ever
//     loses < 1 unit of absolute error per step.
//   - ln1to2(y): ln(y) for y in [1, 2] via the atanh series
//     ln(y) = 2*atanh(z), z = (y-1)/(y+1) in [0, 1/3],
//     9 odd terms through z^17 (truncation < 1e-10).
//   - mulDiv(a, b, d) = a*b/d computed limb-wise (a split into
//     1e6 high/low limbs) so no intermediate exceeds ~1e18.
//     Valid for 0 <= a <= 1e15, 0 <= b <= 1e10, 1 <= d <= 1e10,
//     b <= 1000*d, and (a/1e6)*d < 9e18. Every call site below
//     satisfies this (verified in lmsr_test.go's bound checks);
//     it truncates, underestimating the exact quotient by < 3 units.
//
// # Valid input ranges (correctness domain)
//
//   - b in [LMSRMinB, LMSRMaxB] = [1e6, 1e10] ugnot (1..10,000 GNOT),
//     same numerics as Prophet's MIN_B/MAX_B (0.001..10 SOL there).
//   - qYes, qNo in [0, LMSRMaxQ] = [0, 1e12] ugnot (1e6 GNOT of
//     outstanding shares — far above any realistic market).
//   - |dYes|, |dNo| <= LMSRMaxQ in lmsrCostDelta.
//   Outside this domain the public functions return 0 (invalid
//   input) instead of overflowing or panicking on division by zero.
//   lmsrCostDelta clamps a negative resulting q to 0 (selling more
//   than held is a caller bug; the realm must check balances first).
//
// # Rounding / solvency notes
//
//   - lmsrCost truncates (each mulDiv truncates); the error is
//     bounded by the tolerance below, not by a fixed direction.
//     Like the Rust code (buys ceil, sells floor), the realm should
//     charge cost+1 on buys and pay out cost on sells if it wants
//     the strict solvency direction; the raw delta here is the
//     unbiased fixed-point value.
//   - lmsrPriceBps returns YES and 10000-YES for NO, so the two
//     prices always sum to exactly 10000 bps.
//   - Seed/solvency: creator must seed at least b*ln(2); see
//     lmsrMinSeed. Since C(q) >= max(qYes, qNo) always, the vault
//     covers every outstanding winning share (1 share = 1 ugnot).
//
// # VERIFICATION (measured 2026-11-28, see lmsr_reference.py;
// sweep harness output compared by compare_sweep.py)
//
//   - Cost: max |C_gno - C_f64| = 49.3 ugnot over 716 cases (16-case
//     grid + 500-case random sweep + 200-case large-q sweep to
//     LMSRMaxQ), worst at b=1e10; tolerance max(10 ugnot, b*2e-8).
//   - Cost delta: max error 46.9 ugnot over 860 cases (incl. sells),
//     same tolerance. 1-share buy from zero: Gno 1 vs f64 0.5.
//   - Price: max |p_gno - p_f64| = 0 bps over 716 cases (tolerance
//     1 bp; differences would only be f64-vs-int rounding at .5 bp).
//   - Min seed: Gno exceeds the true ceil(b*ln2) by at most +5 ugnot
//     (b=1e10), within the documented +0..6.
//   - Primitives: exp(-ln2) exact 5e8; exp(-10 ln2) 976563 vs
//     976562.5; ln(2) 693147178 vs 693147180.6 (all at 1e9 scale).
//   - gno test: 8 tests PASS (cost, delta, price, monotone+solvent,
//     min seed, invalid inputs, exp/ln primitives, mulDiv sanity).

// LMSRScale is the fixed-point scale of this package: 1 unit = 1e-6.
const LMSRScale int64 = 1000000

// lmsrInternalScale is the scale used inside exp/ln (see header).
const lmsrInternalScale int64 = 1000000000

// LMSRMinB / LMSRMaxB bound the liquidity parameter b (ugnot).
// Same numerics as Prophet MIN_B/MAX_B; units here are ugnot
// (1e-6 GNOT) instead of lamports.
const LMSRMinB int64 = 1000000
const LMSRMaxB int64 = 10000000000

// LMSRMaxQ bounds outstanding shares per outcome (ugnot).
const LMSRMaxQ int64 = 1000000000000

// lmsrLn2Scaled is ln(2)*1e9 rounded UP (true value 693147180.56).
const lmsrLn2Scaled int64 = 693147181

// mulDiv returns a*b/d for non-negative a, b and d > 0, computed so no
// intermediate product overflows int64. See the header for the valid
// domain; all call sites in this file satisfy it. The result is the
// exact quotient truncated down, underestimating it by < 3 units.
func mulDiv(a, b, d int64) int64 {
	if a <= 0 || b <= 0 {
		return 0
	}
	ah := a / 1000000
	al := a % 1000000
	// b*1e6/d split into quotient + remainder so ah*(b*1e6)/d stays
	// exact: ah*q1 + (ah*r1)/d.
	q1 := (b * 1000000) / d
	r1 := (b * 1000000) % d
	return ah*q1 + (ah*r1)/d + (al*b)/d
}

// expNeg returns exp(x)*1e9 for x <= 0, where x is given scaled by 1e9
// (xK = x * 1e9). Returns 1e9 for x = 0 and 0 for x <= -50
// (exp(-50) ~= 1.9e-22, far below half a unit at 1e9 scale).
// Method: x = -n*ln2 + r, exp(x) = exp(r)/2^n; exp(r) by Taylor
// (|r| < ln2, 16 terms), /2^n by repeated halving.
func expNeg(xK int64) int64 {
	if xK >= 0 {
		return lmsrInternalScale
	}
	if xK <= -50*lmsrInternalScale {
		return 0
	}
	// n = floor(-x/ln2), r = x + n*ln2 in (-ln2, 0].
	n := (-xK) / lmsrLn2Scaled
	rK := xK + n*lmsrLn2Scaled
	// Taylor: exp(r) = sum r^k/k!, k = 0..15. |r| <= 0.694 (1.387 in
	// the measure-zero edge case where n is one short); term 15 is
	// < 1e-10, so the truncation error is < 1 unit at 1e9 scale.
	// |term*rK| <= 1.4e9*1.4e9 = 2e18 < 2^63, so no overflow.
	sum := lmsrInternalScale
	term := lmsrInternalScale
	for k := int64(1); k <= 15; k++ {
		num := term * rK
		if num >= 0 {
			num += lmsrInternalScale / 2
		} else {
			num -= lmsrInternalScale / 2
		}
		term = (num / lmsrInternalScale) / k
		sum += term
	}
	// Divide by 2^n by repeated halving (exact, < 1 unit lost total).
	v := sum
	for i := int64(0); i < n; i++ {
		v = (v + 1) / 2
	}
	return v
}

// ln1to2 returns ln(y)*1e9 for y in [1, 2], where y is given scaled by
// 1e9 (yK in [1e9, 2e9]). Method: z = (y-1)/(y+1) in [0, 1/3],
// ln(y) = 2*atanh(z) = 2*sum_{k>=0} z^(2k+1)/(2k+1), 9 terms through
// z^17 (series remainder < 1e-10).
func ln1to2(yK int64) int64 {
	num := yK - lmsrInternalScale
	den := yK + lmsrInternalScale
	// z = (y-1)/(y+1), scaled by 1e9, rounded to nearest.
	zK := (num*lmsrInternalScale + den/2) / den
	// z^2, scaled by 1e9.
	z2K := (zK*zK + lmsrInternalScale/2) / lmsrInternalScale
	sum := int64(0)
	pow := zK // z^(2k+1), scaled by 1e9
	for k := int64(0); k <= 8; k++ {
		div := 2*k + 1
		sum += (pow + div/2) / div
		pow = (pow*z2K + lmsrInternalScale/2) / lmsrInternalScale
	}
	return 2 * sum
}

// lmsrCost returns the LMSR cost C(qYes, qNo) = b*ln(exp(qy/b) +
// exp(qn/b)) in ugnot, via the stable log-sum-exp form. Returns 0 for
// out-of-domain inputs (see header).
func lmsrCost(qYes, qNo, b int64) int64 {
	if b < LMSRMinB || b > LMSRMaxB {
		return 0
	}
	if qYes < 0 || qNo < 0 || qYes > LMSRMaxQ || qNo > LMSRMaxQ {
		return 0
	}
	aK := mulDiv(qYes, lmsrInternalScale, b)
	cK := mulDiv(qNo, lmsrInternalScale, b)
	mK := aK
	if cK > mK {
		mK = cK
	}
	e1 := expNeg(aK - mK)
	e2 := expNeg(cK - mK)
	sumK := e1 + e2 // in [1e9, 2e9]
	lnK := ln1to2(sumK)
	return mulDiv(mK+lnK, b, lmsrInternalScale)
}

// lmsrCostDelta returns C(q+d) - C(q) in ugnot: the cost of buying
// dYes/dNo shares (positive), or the negative of the refund for
// selling (pass negative deltas). Returns 0 for out-of-domain inputs;
// a resulting negative q is clamped to 0. New q above LMSRMaxQ is
// rejected (returns 0).
func lmsrCostDelta(qYes, qNo, b, dYes, dNo int64) int64 {
	if b < LMSRMinB || b > LMSRMaxB {
		return 0
	}
	if qYes < 0 || qNo < 0 || qYes > LMSRMaxQ || qNo > LMSRMaxQ {
		return 0
	}
	if dYes < -LMSRMaxQ || dYes > LMSRMaxQ || dNo < -LMSRMaxQ || dNo > LMSRMaxQ {
		return 0
	}
	var nYes int64
	if dYes >= 0 {
		if dYes > LMSRMaxQ-qYes {
			return 0
		}
		nYes = qYes + dYes
	} else if -dYes > qYes {
		nYes = 0
	} else {
		nYes = qYes + dYes
	}
	var nNo int64
	if dNo >= 0 {
		if dNo > LMSRMaxQ-qNo {
			return 0
		}
		nNo = qNo + dNo
	} else if -dNo > qNo {
		nNo = 0
	} else {
		nNo = qNo + dNo
	}
	return lmsrCost(nYes, nNo, b) - lmsrCost(qYes, qNo, b)
}

// lmsrPriceBps returns the price of outcome `yes` in basis points
// (0..10000). price(YES) = sigmoid((qYes-qNo)/b); price(NO) is
// exactly 10000 - price(YES). Returns 0 for out-of-domain inputs.
func lmsrPriceBps(qYes, qNo, b int64, yes bool) int64 {
	if b < LMSRMinB || b > LMSRMaxB {
		return 0
	}
	if qYes < 0 || qNo < 0 || qYes > LMSRMaxQ || qNo > LMSRMaxQ {
		return 0
	}
	diff := qYes - qNo // in [-1e12, 1e12]
	var tK int64
	if diff >= 0 {
		tK = mulDiv(diff, lmsrInternalScale, b)
	} else {
		tK = -mulDiv(-diff, lmsrInternalScale, b)
	}
	var pYes int64
	switch {
	case tK >= 50*lmsrInternalScale:
		pYes = 10000
	case tK <= -50*lmsrInternalScale:
		pYes = 0
	case tK >= 0:
		// p = 1/(1+exp(-t)); exp(-t) in (0, 1].
		e := expNeg(-tK)
		den := lmsrInternalScale + e
		pYes = (10000*lmsrInternalScale + den/2) / den
	default:
		// p = exp(t)/(1+exp(t)); exp(t) in (0, 1).
		e := expNeg(tK)
		den := lmsrInternalScale + e
		pYes = (10000*e + den/2) / den
	}
	if yes {
		return pYes
	}
	return 10000 - pYes
}

// lmsrMinSeed returns the minimum creator seed for liquidity b:
// ceil(b*ln(2)) in ugnot. It overestimates the true ceiling by at
// most 6 ugnot (ln2 is rounded up at 1e9 scale, plus the +1 covers
// the floor truncation) — safe direction for a minimum-seed check.
// Returns 0 for out-of-domain b.
func lmsrMinSeed(b int64) int64 {
	if b < LMSRMinB || b > LMSRMaxB {
		return 0
	}
	return mulDiv(b, lmsrLn2Scaled, lmsrInternalScale) + 1
}
