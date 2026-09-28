package otc

const bpsDenominator = 10000

// feeOf is bps of amount, rounded down (F1). Split so that a large amount
// cannot overflow on the multiplication: bps is at most feeCapBps, so both
// terms stay far below int64 max.
func feeOf(amount, bps int64) int64 {
	if amount <= 0 || bps <= 0 {
		return 0
	}
	return amount/bpsDenominator*bps + amount%bpsDenominator*bps/bpsDenominator
}

// feeFor picks the fee a new offer on tokenKey is created with (F4, F6).
func feeFor(tokenKey string) int64 {
	if gnomicFeeOn && tokenKey == gnomicKey {
		return gnomicFee
	}
	return feeBps
}

// addSat adds two non-negative totals without wrapping (S5). The totals are
// statistics, not money: one that stops at the ceiling is better than one
// that turns negative.
func addSat(a, b int64) int64 {
	if b > 0 && a > maxInt64-b {
		return maxInt64
	}
	return a + b
}

const maxInt64 = int64(9223372036854775807)
