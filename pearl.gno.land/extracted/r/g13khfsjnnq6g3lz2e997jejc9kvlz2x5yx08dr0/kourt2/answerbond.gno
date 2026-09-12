package kourt2
func settleAnswerBond(c *Court, cs *claimState) {
	c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
	cs.answerBond = 0
}
func (cs *claimState) sideConv(side int) (hi, lo uint64) {
	if side == sideYES {
		return cs.yesConvHi, cs.yesConvLo
	}
	return cs.noConvHi, cs.noConvLo
}
func bondFloorAt(xbar int64, convHi, convLo uint64) int64 {
	flat := xbar * bondFloorFlatBps / 10000
	if draw := mulDiv128(convToCC(convHi, convLo), bondFloorConvBps, 10000); draw > flat {
		return draw
	}
	return flat
}
func bondFloorFor(cs *claimState) int64 {
	hi, lo := cs.sideConv(int(cs.answer))
	return bondFloorAt(cs.xBarFrozen, hi, lo)
}
