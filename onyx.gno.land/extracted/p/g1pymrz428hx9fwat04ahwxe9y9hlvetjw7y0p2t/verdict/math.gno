package verdict

import "math/bits"

func CalculateOdds(yesPool, noPool int64) (yesBps, noBps int64) {
	if yesPool < 0 || noPool < 0 {
		panic("negative pool")
	}
	total := uint64(yesPool) + uint64(noPool)
	if total > uint64(1<<63-1) {
		panic("pool overflow")
	}
	if total == 0 {
		return 5000, 5000
	}
	hi, lo := bits.Mul64(uint64(yesPool), 10000)
	lo, carry := bits.Add64(lo, total>>1, 0)
	hi += carry
	yes, _ := bits.Div64(hi, lo, total)
	return int64(yes), 10000 - int64(yes)
}

func CalculatePayout(userStake, winningPool, totalPool, feeBps int64) int64 {
	if userStake < 0 || winningPool < 0 || totalPool < 0 || feeBps < 0 || feeBps > 10000 {
		panic("invalid payout input")
	}
	if userStake == 0 {
		return 0
	}
	if winningPool == 0 || totalPool < winningPool {
		panic("invalid winning pool")
	}
	hi, lo := bits.Mul64(uint64(userStake), uint64(totalPool))
	grossHi := hi / uint64(winningPool)
	remainder := hi % uint64(winningPool)
	grossLo, _ := bits.Div64(remainder, lo, uint64(winningPool))
	wholeHi := grossHi / 10000
	remainder = grossHi % 10000
	wholeLo, remainder := bits.Div64(remainder, grossLo, 10000)
	factor := uint64(10000 - feeBps)
	if wholeHi != 0 && factor != 0 {
		panic("payout overflow")
	}
	resultHi, resultLo := bits.Mul64(wholeLo, factor)
	extra := remainder * factor / 10000
	resultLo, carry := bits.Add64(resultLo, extra, 0)
	resultHi += carry
	if resultHi != 0 || resultLo > uint64(1<<63-1) {
		panic("payout overflow")
	}
	return int64(resultLo)
}
