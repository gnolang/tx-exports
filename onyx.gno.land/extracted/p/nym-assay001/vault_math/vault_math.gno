// Package vault_math is pure, deterministic fixed-point math for yield
// vaults. It holds no state, imports nothing from the chain, never touches
// coins and every loop is bounded, which is what an Assay audit checks for.
//
// Rates are expressed in basis points (1 bp = 0.01%). All amounts are integer
// ugnot; division rounds down, in favour of the vault.
package vault_math

// BasisPoints is 100% expressed in basis points.
const BasisPoints int64 = 10_000

// MaxPeriods caps compounding loops so gas stays bounded.
const MaxPeriods int64 = 3_650

// maxSafe keeps intermediate products below int64 overflow.
const maxSafe int64 = 922_337_203_685_477 // math.MaxInt64 / 10_000

// SimpleYield returns principal * rate * periods with no compounding.
func SimpleYield(principal, rateBps, periods int64) int64 {
	checkInputs(principal, rateBps, periods)
	perPeriod := mulDiv(principal, rateBps, BasisPoints)
	if periods > 0 && perPeriod > maxSafe/periods {
		panic("vault_math: yield overflow")
	}
	return perPeriod * periods
}

// CompoundYield returns the interest earned when rateBps is applied once per
// period and re-invested, for at most MaxPeriods periods.
func CompoundYield(principal, rateBps, periods int64) int64 {
	checkInputs(principal, rateBps, periods)
	balance := principal
	for i := int64(0); i < periods; i++ {
		interest := mulDiv(balance, rateBps, BasisPoints)
		if balance > maxSafe-interest {
			panic("vault_math: balance overflow")
		}
		balance += interest
	}
	return balance - principal
}

// SharesFor returns the vault shares minted for a deposit. The first
// depositor receives shares 1:1.
func SharesFor(deposit, totalAssets, totalShares int64) int64 {
	if deposit < 0 || totalAssets < 0 || totalShares < 0 {
		panic("vault_math: negative input")
	}
	if totalShares == 0 || totalAssets == 0 {
		return deposit
	}
	return mulDiv(deposit, totalShares, totalAssets)
}

// AssetsFor returns the assets redeemable for a number of shares.
func AssetsFor(shares, totalAssets, totalShares int64) int64 {
	if shares < 0 || totalAssets < 0 || totalShares < 0 {
		panic("vault_math: negative input")
	}
	if shares > totalShares {
		panic("vault_math: shares exceed supply")
	}
	if totalShares == 0 {
		return 0
	}
	return mulDiv(shares, totalAssets, totalShares)
}

// APYBps returns the effective yearly yield, in basis points, of a per-period
// rate compounded periodsPerYear times.
func APYBps(rateBps, periodsPerYear int64) int64 {
	const unit int64 = 1_000_000_000 // 1e9 precision
	earned := CompoundYield(unit, rateBps, periodsPerYear)
	return mulDiv(earned, BasisPoints, unit)
}

func checkInputs(principal, rateBps, periods int64) {
	if principal < 0 || rateBps < 0 || periods < 0 {
		panic("vault_math: negative input")
	}
	if principal > maxSafe {
		panic("vault_math: principal too large")
	}
	if rateBps > BasisPoints {
		panic("vault_math: rate above 100% per period")
	}
	if periods > MaxPeriods {
		panic("vault_math: too many periods")
	}
}

// mulDiv computes a*b/c without overflowing for the ranges checked above.
func mulDiv(a, b, c int64) int64 {
	if c == 0 {
		panic("vault_math: division by zero")
	}
	if a == 0 || b == 0 {
		return 0
	}
	q, r := a/c, a%c
	return q*b + r*b/c
}
