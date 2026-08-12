// Package ammmath implements integer bonding-curve and constant-product AMM
// helpers for the gnomemepad factory (Pump-style virtual CPMM + real CPMM pool).
package ammmath

import "math/overflow"

// FeeResult is the split of a gross trade fee.
type FeeResult struct {
	Gross     int64
	Net       int64
	Fee       int64
	Creator   int64
	Protocol  int64
	Remainder int64
}

// ApplyFee takes gross quote paid by the user and feeBPS (e.g. 120 = 1.20%).
func ApplyFee(gross, feeBPS, creatorShareBPS, protocolShareBPS int64) FeeResult {
	if gross <= 0 {
		panic("ammmath: gross must be positive")
	}
	if feeBPS < 0 || feeBPS >= 10000 {
		panic("ammmath: feeBPS out of range")
	}
	if creatorShareBPS < 0 || protocolShareBPS < 0 || creatorShareBPS+protocolShareBPS > 10000 {
		panic("ammmath: fee share BPS invalid")
	}
	fee := gross * feeBPS / 10000
	net := gross - fee
	creator := fee * creatorShareBPS / 10000
	protocol := fee * protocolShareBPS / 10000
	remainder := fee - creator - protocol
	return FeeResult{
		Gross:     gross,
		Net:       net,
		Fee:       fee,
		Creator:   creator,
		Protocol:  protocol,
		Remainder: remainder,
	}
}

// ApplyFeeOnOutput charges fee on assets leaving the pool/curve.
func ApplyFeeOnOutput(grossOut, feeBPS, creatorShareBPS, protocolShareBPS int64) FeeResult {
	if grossOut <= 0 {
		panic("ammmath: grossOut must be positive")
	}
	if feeBPS < 0 || feeBPS >= 10000 {
		panic("ammmath: feeBPS out of range")
	}
	if creatorShareBPS < 0 || protocolShareBPS < 0 || creatorShareBPS+protocolShareBPS > 10000 {
		panic("ammmath: fee share BPS invalid")
	}
	fee := grossOut * feeBPS / 10000
	net := grossOut - fee
	if net <= 0 {
		panic("ammmath: fee consumes entire output")
	}
	creator := fee * creatorShareBPS / 10000
	protocol := fee * protocolShareBPS / 10000
	remainder := fee - creator - protocol
	return FeeResult{
		Gross:     grossOut,
		Net:       net,
		Fee:       fee,
		Creator:   creator,
		Protocol:  protocol,
		Remainder: remainder,
	}
}

// BuyTokens quotes a virtual constant-product buy (net ugnot in).
func BuyTokens(virtualUgnot, virtualToken, ugnotIn int64) (tokensOut, newVU, newVT int64) {
	if ugnotIn <= 0 {
		panic("ammmath: ugnotIn must be positive")
	}
	if virtualUgnot <= 0 || virtualToken <= 0 {
		panic("ammmath: invalid virtual reserves")
	}
	newVU, ok := overflow.Add64(virtualUgnot, ugnotIn)
	if !ok {
		panic("ammmath: virtual ugnot overflow")
	}
	k, ok := overflow.Mul64(virtualUgnot, virtualToken)
	if !ok {
		panic("ammmath: k overflow")
	}
	newVT = k / newVU
	if newVT <= 0 {
		panic("ammmath: empty virtual token reserve")
	}
	if newVT >= virtualToken {
		panic("ammmath: zero tokens out")
	}
	tokensOut = virtualToken - newVT
	return tokensOut, newVU, newVT
}

// SellTokens quotes a virtual constant-product sell (gross ugnot out).
func SellTokens(virtualUgnot, virtualToken, tokensIn int64) (ugnotOut, newVU, newVT int64) {
	if tokensIn <= 0 {
		panic("ammmath: tokensIn must be positive")
	}
	if virtualUgnot <= 0 || virtualToken <= 0 {
		panic("ammmath: invalid virtual reserves")
	}
	newVT, ok := overflow.Add64(virtualToken, tokensIn)
	if !ok {
		panic("ammmath: virtual token overflow")
	}
	k, ok := overflow.Mul64(virtualUgnot, virtualToken)
	if !ok {
		panic("ammmath: k overflow")
	}
	newVU = k / newVT
	if newVU <= 0 {
		panic("ammmath: empty virtual ugnot reserve")
	}
	if newVU >= virtualUgnot {
		panic("ammmath: zero ugnot out")
	}
	ugnotOut = virtualUgnot - newVU
	return ugnotOut, newVU, newVT
}

// PoolSwapUgnotForToken swaps net ugnot for tokens; remainderToPool adds to ugnot reserve.
func PoolSwapUgnotForToken(poolUgnot, poolToken, ugnotIn, remainderToPool int64) (tokensOut, newPU, newPT int64) {
	if ugnotIn <= 0 {
		panic("ammmath: ugnotIn must be positive")
	}
	if poolUgnot <= 0 || poolToken <= 0 {
		panic("ammmath: invalid pool reserves")
	}
	if remainderToPool < 0 {
		panic("ammmath: negative remainder")
	}
	addU, ok := overflow.Add64(ugnotIn, remainderToPool)
	if !ok {
		panic("ammmath: add overflow")
	}
	newPU, ok = overflow.Add64(poolUgnot, addU)
	if !ok {
		panic("ammmath: pool ugnot overflow")
	}
	tokensOut = poolToken * ugnotIn / (poolUgnot + ugnotIn)
	if tokensOut <= 0 {
		panic("ammmath: zero tokens out of pool")
	}
	if tokensOut >= poolToken {
		panic("ammmath: would drain pool tokens")
	}
	newPT = poolToken - tokensOut
	return tokensOut, newPU, newPT
}

// PoolSwapTokenForUgnot swaps tokens for gross ugnot out.
func PoolSwapTokenForUgnot(poolUgnot, poolToken, tokensIn int64) (ugnotOut, newPU, newPT int64) {
	if tokensIn <= 0 {
		panic("ammmath: tokensIn must be positive")
	}
	if poolUgnot <= 0 || poolToken <= 0 {
		panic("ammmath: invalid pool reserves")
	}
	newPT, ok := overflow.Add64(poolToken, tokensIn)
	if !ok {
		panic("ammmath: pool token overflow")
	}
	ugnotOut = poolUgnot * tokensIn / (poolToken + tokensIn)
	if ugnotOut <= 0 {
		panic("ammmath: zero ugnot out of pool")
	}
	if ugnotOut >= poolUgnot {
		panic("ammmath: would drain pool ugnot")
	}
	newPU = poolUgnot - ugnotOut
	return ugnotOut, newPU, newPT
}

// CanGraduate reports whether raised net ugnot meets the threshold.
func CanGraduate(raisedUgnot, threshold int64) bool {
	return raisedUgnot >= threshold && threshold > 0
}

// SpotPriceUgnotPerToken returns ugnot per token scaled by 1e6 (display only).
func SpotPriceUgnotPerToken(ugnotReserve, tokenReserve int64) int64 {
	if tokenReserve <= 0 {
		return 0
	}
	return ugnotReserve * 1000000 / tokenReserve
}
