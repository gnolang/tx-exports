package escrow_v3

// basisPointsFee computes floor(amount*bps/10000) without overflowing the
// intermediate product. For nonnegative amount and bps <= 10000, the quotient
// product and final sum are <= amount; the remainder product is < 100000000.
// Callers retain their existing configured rates, recipients and rounding.
func basisPointsFee(amount, bps int64) int64 {
	if amount < 0 || bps < 0 || bps > 10000 {
		panic("invalid fee inputs")
	}
	return (amount/10000)*bps + ((amount%10000)*bps)/10000
}
