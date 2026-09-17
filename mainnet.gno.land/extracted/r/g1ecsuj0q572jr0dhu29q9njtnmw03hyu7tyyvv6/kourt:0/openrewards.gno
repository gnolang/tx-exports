package kourt
import (
	"math/bits"
)
func OpenRewards(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.rewardsOpened {
		panic("kourtv2: already rewardsOpened")
	}
	if cs.verdictAt == 0 {
		panic("kourtv2: no final verdict yet")
	}
	if cs.closed {
		panic("kourtv2: dead claims have no draw")
	}
	now := heightNow()
	if passed, known := pastDeadline(cs.verdictAtTime, finalizeGraceSecs); ((known && !passed) ||
		(!known && now < cs.verdictAt+finalizeGraceBlocks)) && !isParticipant(cs, who) {
		panic("kourtv2: OpenRewards is participant-only for its first week")
	}
	touch(c)
	advancePools(c, cs)
	cs.rewardsOpened = true
	stripExit(c, cs)
	releaseMetaLatchIfMeta(c, cs)
	cs.openBlocks = cs.frozenAt - (cs.openedAt + c.params.stakeOpenDelayBlocks)
	if cs.openBlocks < 1 {
		cs.openBlocks = 1
	}
	var midGross int64
	if int(cs.provisional) == sideYES {
		midGross = convToCC(cs.yesConvHi, cs.yesConvLo)
	} else {
		midGross = convToCC(cs.noConvHi, cs.noConvLo)
	}
	cs.winPoolConvCC = midGross
	want := drawWant(c, cs, midGross)
	d := reserveJunior(c, want)
	cs.drawWinners, cs.drawAuthor, cs.drawAnswerer = drawSplit(cs, d)
	cs.carrotTotal = mulDiv128(midGross, splitCarrot, 100)
	cs.carrotPool = cs.carrotTotal
	if cs.deposit > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.deposit)
		c.deposit -= cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.fee)
		c.deposit -= cs.fee
		cs.fee = 0
	}
	if cs.answerBond > 0 {
		settleAnswerBond(c, cs)
	}
}
func WithdrawBonus(cur realm, courtSlug string, claimID uint64, side int) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	if !cs.rewardsOpened {
		panic("kourtv2: the draw has not rewardsOpened")
	}
	if side != int(cs.provisional) {
		panic("kourtv2: only the winning side draws (principal came back either way)")
	}
	v := cs.stakers.Get(posKey(who, side))
	if v == nil {
		panic("kourtv2: no position on that side")
	}
	p := v.(*stakePos)
	if p.bonusPaid {
		panic("kourtv2: this position's bonus was already drawn")
	}
	touch(c)
	accrue(c, cs, p, side)
	p.bonusPaid = true
	convCC := convToCC(p.convHi, p.convLo)
	creditWinConviction(c, cs, who, p)
	if convCC <= 0 || cs.winPoolConvCC <= 0 {
		return 0
	}
	gross := mulDiv128(cs.drawWinners, convCC, cs.winPoolConvCC)
	pay := capBonus(cs, gross, p.rawHi, p.rawLo)
	mintEmission(c, who, pay)
	return pay
}
func AuthorBonus(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.rewardsOpened {
		panic("kourtv2: the draw has not rewardsOpened")
	}
	if who != cs.author {
		panic("kourtv2: only the author draws this slice")
	}
	if cs.authorPaid {
		panic("kourtv2: the author slice was already drawn")
	}
	touch(c)
	cs.authorPaid = true
	var pay int64
	if cs.seeded {
		mintEmission(c, who, 0)
		return 0
	}
	if v := cs.stakers.Get(posKey(who, int(cs.provisional))); v != nil {
		p := v.(*stakePos)
		accrue(c, cs, p, int(cs.provisional))
		pay = capBonus(cs, cs.drawAuthor, p.rawHi, p.rawLo)
	}
	mintEmission(c, who, pay)
	return pay
}
func AnswererBonus(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.rewardsOpened {
		panic("kourtv2: the draw has not rewardsOpened")
	}
	if who != cs.answerer {
		panic("kourtv2: only the answerer draws this slice")
	}
	if cs.answererPaid {
		panic("kourtv2: the answerer slice was already drawn")
	}
	touch(c)
	cs.answererPaid = true
	pay := cs.drawAnswerer
	if bound := mulDiv128(cs.answerBond0, tierBpsFor(cs), 2*tierParBps); pay > bound {
		pay = bound
	}
	mintEmission(c, who, pay)
	return pay
}
func timeAvgStake(cs *claimState, rawHi, rawLo uint64) int64 {
	if cs.openBlocks <= 0 || rawHi >= uint64(cs.openBlocks) {
		return 0
	}
	return div128(rawHi, rawLo, cs.openBlocks)
}
func capBonus(cs *claimState, gross int64, rawHi, rawLo uint64) int64 {
	rawAvg := timeAvgStake(cs, rawHi, rawLo)
	bound := mulDiv128(rawAvg, tierBpsFor(cs), 2*tierParBps)
	if gross > bound {
		gross = bound
	}
	if gross < 0 {
		gross = 0
	}
	return gross
}
func PullCarrot(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.rewardsOpened {
		panic("kourtv2: the draw has not rewardsOpened")
	}
	if isParticipant(cs, who) {
		panic("kourtv2: participants take their own slices, never the carrot")
	}
	if cs.voted == nil {
		panic("kourtv2: nobody voted on this claim")
	}
	if cs.decidedPID == 0 {
		panic("kourtv2: no vote resolved this claim; there is no carrot")
	}
	v := cs.voted.Get("d" + beClaimKey(uint64(cs.decidedPID)) + string(who))
	if v == nil || v.(string) != cs.carrotChoice {
		panic("kourtv2: the carrot pays with-verdict voters of the deciding round")
	}
	vw := cs.voted.Get("dw" + beClaimKey(uint64(cs.decidedPID)) + string(who))
	if vw == nil {
		panic("kourtv2: no recorded weight for that voter on the deciding round")
	}
	w, denom := vw.(int64), cs.carrotDenom
	claimedKey := "c" + beClaimKey(uint64(cs.decidedPID)) + string(who)
	if cs.voted.Has(claimedKey) {
		panic("kourtv2: carrot already claimed")
	}
	cs.voted.Set(claimedKey, true)
	if w <= 0 || denom <= 0 {
		return 0
	}
	touch(c)
	share := mulDiv128(cs.carrotTotal, w, denom)
	b0 := cs.xBarFrozen * carrotClampXBps / 10000
	if b0 < carrotClampMinCC {
		b0 = carrotClampMinCC
	}
	if clamp := b0/2 - 1; share > clamp {
		share = clamp
	}
	if share > cs.carrotPool {
		share = cs.carrotPool
	}
	if share <= 0 {
		return 0
	}
	cs.carrotPool -= share
	enqueueSenior(c, who, share, "carrot")
	return share
}
func div128(hi, lo uint64, den int64) int64 {
	if den <= 0 {
		panic("kourtv2: div128 domain")
	}
	if hi >= uint64(den) {
		panic("kourtv2: div128 quotient overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(den))
	return int64(q)
}
func RewardsOpened(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).rewardsOpened
}
func drawEntitlement(c *Court, cs *claimState, midGross int64) int64 {
	tierBps := tierBpsFor(cs)
	want := mulDiv128(midGross, tierBps, tierParBps)
	want = mulDiv128(want, spamNetBps(cs), tierParBps)
	if int(cs.provisional) == int(cs.answer) {
		if capd := cs.answerBond0 - mulDiv128(midGross, splitCarrot, 100); want > capd {
			want = capd
			if want < 0 {
				want = 0
			}
		}
	}
	return want
}
func drawWant(c *Court, cs *claimState, midGross int64) int64 {
	want := drawEntitlement(c, cs, midGross)
	if want > c.curPeriodBudget {
		want = c.curPeriodBudget
	}
	return want
}
func drawSplit(cs *claimState, d int64) (winners, author, answerer int64) {
	winners = d * splitWinners / (splitWinners + splitAuthor + splitAnswerer)
	author = d * splitAuthor / (splitWinners + splitAuthor + splitAnswerer)
	answerer = d * splitAnswerer / (splitWinners + splitAuthor + splitAnswerer)
	if int(cs.provisional) != int(cs.answer) {
		answerer = 0
	}
	if cs.seeded {
		author = 0
	}
	if cs.noAccuracy {
		winners = 0
	}
	return winners, author, answerer
}
func DrawQuote(courtSlug string, claimID uint64) (winners, author, answerer int64) {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.verdictAt == 0 || cs.rewardsOpened || cs.provisional < 0 {
		return 0, 0, 0
	}
	var midGross int64
	if cs.provisional == sideYES {
		midGross = convToCC(cs.yesConvHi, cs.yesConvLo)
	} else {
		midGross = convToCC(cs.noConvHi, cs.noConvLo)
	}
	return drawSplit(cs, drawEntitlement(c, cs, midGross))
}
func DrawSlices(courtSlug string, claimID uint64) (winners, author, answerer, carrotLeft int64) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.drawWinners, cs.drawAuthor, cs.drawAnswerer, cs.carrotPool
}
func PullState(courtSlug string, claimID uint64, who address) (winnerPaid, authorPaid, answererPaid bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.provisional >= 0 {
		if v := cs.stakers.Get(posKey(who, int(cs.provisional))); v != nil {
			winnerPaid = v.(*stakePos).bonusPaid
		}
	}
	return winnerPaid, cs.authorPaid && who == cs.author, cs.answererPaid && who == cs.answerer
}
