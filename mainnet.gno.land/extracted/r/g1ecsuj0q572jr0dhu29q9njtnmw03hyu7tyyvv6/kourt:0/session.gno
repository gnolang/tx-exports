package kourt
func SettleUndisputed(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.frozenAt == 0 {
		panic("kourtv2: there is no answer to settle")
	}
	if cs.disputeOpen || cs.round > 0 {
		panic("kourtv2: this claim was disputed; it settles by vote")
	}
	if cs.verdictAt != 0 {
		panic("kourtv2: already settled")
	}
	if passed, known := pastDeadline(cs.answeredAtTime, settleSecs); (known && !passed) ||
		(!known && heightNow() < cs.answerHeight+settleDelay) {
		panic("kourtv2: the answer has not aged the 72h settlement minimum")
	}
	touch(c)
	cs.verdictAt = heightNow()
	cs.verdictAtTime = nowTime()
	cs.route = "undisputed"
	trimClaimHistory(c, cs, uint32(cs.frozenAt/epochBlocks)+1)
	cs.provisional = cs.answer
	if cs.answerBond > 0 {
		settleAnswerBond(c, cs)
	}
	releasePriority(c, cs.answerer, claimID)
}
func WithdrawStake(cur realm, courtSlug string, claimID uint64, side int) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	if cs.verdictAt == 0 && !(cs.provisional >= 0 && side != int(cs.provisional)) {
		panic("kourtv2: no verdict yet — unstake freely before an answer, withdraw after the verdict")
	}
	touch(c)
	advancePools(c, cs)
	p := getPos(c, cs, who, side)
	if p.stake <= 0 {
		panic("kourtv2: nothing staked on that side")
	}
	accrue(c, cs, p, side)
	amount := p.stake
	p.stake = 0
	if side == sideYES {
		cs.yesStake -= amount
	} else {
		cs.noStake -= amount
	}
	releaseStake(c, who, amount)
	return amount
}
func Settled(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).verdictAt != 0
}
func Verdict(courtSlug string, claimID uint64) int {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.verdictAt == 0 {
		panic("kourtv2: no verdict yet")
	}
	if cs.provClose {
		panic("kourtv2: closed without a decision (three failed dispute rounds)")
	}
	return int(cs.provisional)
}
func VerdictRoute(courtSlug string, claimID uint64) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.verdictAt == 0 {
		panic("kourtv2: no verdict yet")
	}
	return cs.route
}
func SettleDeadline(courtSlug string, claimID uint64) int64 {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.frozenAt == 0 {
		return 0
	}
	return cs.answerHeight + settleDelay
}
