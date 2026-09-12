package kourt2
const answerWindow = 3 * epochBlocks
func PostAnswer(cur realm, courtSlug string, claimID uint64, verdict int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(verdict)
	if cs.closed {
		panic("kourtv2: this claim is closed")
	}
	if cs.frozenAt != 0 {
		panic("kourtv2: this claim already has an answer")
	}
	now := heightNow()
	if passed, known := pastDeadline(cs.openedAtTime, deadClaimSecs); (known && passed) ||
		(!known && now >= cs.openedAt+deadClaimTimeout) {
		panic("kourtv2: this claim is past the dead-claim timeout; it closes, it is not answered")
	}
	xbar, mature := cs.oi.Average(now, answerWindow)
	if !mature {
		panic("kourtv2: not enough stake history to answer yet")
	}
	if xbar < effMinAnswerX(c) {
		panic("kourtv2: trailing stake is below the minimum to answer")
	}
	inPriority := false
	if passed, known := pastDeadline(cs.openedAtTime,
		blocksToSecs(c.params.stakeOpenDelayBlocks+answerWindow)+priorityWindowSecs); priorityGateActive(c) &&
		((known && !passed) ||
			(!known && now < cs.openedAt+c.params.stakeOpenDelayBlocks+answerWindow+priorityWindowBlocks)) {
		if !mayAnswerInPriority(c, who) {
			panic("kourtv2: the priority window is open — a qualified answerer may act first (wait ~24h)")
		}
		inPriority = true
	}
	touch(c)
	advancePools(c, cs)
	if life := lifeAvgStake(cs, now); life > xbar {
		xbar = life
	}
	bond := xbar * answerBondBps / 10000
	if c.params.answerBondCapCC > 0 && bond > c.params.answerBondCapCC {
		bond = c.params.answerBondCapCC
	}
	convHi, convLo := cs.sideConv(verdict)
	floor := bondFloorAt(xbar, convHi, convLo)
	oppHi, oppLo := cs.sideConv(oppositeSide(verdict))
	if opp := bondFloorAt(xbar, oppHi, oppLo); opp > floor {
		floor = opp
	}
	if floor > bond {
		bond = floor
	}
	if bond < 1 {
		bond = 1
	}
	mustSpendable(c, who, bond)
	c.coin.Transfer(who, c.escrow, bond)
	cs.frozenAt = now
	cs.rateAccAtFreeze = c.rateAccFP
	cs.xBarFrozen = xbar
	cs.tierRef = tierRefAt(c)
	observeClaimSize(c, xbar)
	cs.yesStakeAtFreeze, cs.noStakeAtFreeze = cs.yesStake, cs.noStake
	cs.answer = int8(verdict)
	cs.answerer = who
	cs.answerBond = bond
	cs.answerBond0 = bond
	cs.answerHeight = now
	cs.answeredAtTime = nowTime()
	if inPriority {
		holdPriority(c, who, claimID)
	}
	pendingExit(c, cs)
	stripEnter(c, cs)
	onClaimAnswered(c, cs)
}
func HasAnswer(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).frozenAt != 0
}
func AnswerVerdict(courtSlug string, claimID uint64) int {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.frozenAt == 0 {
		panic("kourtv2: no answer yet")
	}
	return int(cs.answer)
}
func AnswerBond(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).answerBond
}
func Answerer(courtSlug string, claimID uint64) address {
	return mustClaim(mustCourt(courtSlug), claimID).answerer
}
func XBarFrozen(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).xBarFrozen
}
