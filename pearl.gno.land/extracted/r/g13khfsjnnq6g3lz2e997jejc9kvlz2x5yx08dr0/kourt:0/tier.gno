package kourt
func tierBpsFor(cs *claimState) int64 {
	if cs.tierRef <= 0 {
		return tierParBps
	}
	v := mulDiv128(cs.xBarFrozen, tierParBps, cs.tierRef)
	if v < tierFloorBps {
		return tierFloorBps
	}
	if v > tierCeilBps {
		return tierCeilBps
	}
	return v
}
func tierRefAt(c *Court) int64 {
	ref := c.xBarAcc / tierEMAN
	if floor := supplyFloor(c, tierRefFloorBps, tierRefDustCC); ref < floor {
		ref = floor
	}
	return ref
}
func observeClaimSize(c *Court, xbar int64) {
	c.xBarAcc = mustAdd(c.xBarAcc, xbar-c.xBarAcc/tierEMAN)
}
func ClaimTierBps(courtSlug string, claimID uint64) int64 {
	return tierBpsFor(mustClaim(mustCourt(courtSlug), claimID))
}
func ClaimTierRef(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).tierRef
}
func spamNetBps(cs *claimState) int64 {
	if cs.spamTotalW <= 0 {
		return tierParBps
	}
	net := cs.spamTotalW - mustMul(2, cs.spamW)
	if net <= 0 {
		return 0
	}
	return mulDiv128(net, tierParBps, cs.spamTotalW)
}
