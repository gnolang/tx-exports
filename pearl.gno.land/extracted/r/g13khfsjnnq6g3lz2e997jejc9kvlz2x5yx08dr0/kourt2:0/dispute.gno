package kourt2
import (
	"strconv"
	governor "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/governor/v0"
	grc20votes "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)
const disputeKindName = "dispute"
const quorumSupplyBps = int64(500)
const finalizeGraceBlocks = int64(120_960)
type disputeKind struct{}
func (disputeKind) Name() string { return disputeKindName }
func (disputeKind) Describe(payload string) string {
	return "resolve a disputed claim by a token vote (see the court page for the claim)"
}
func (disputeKind) Check(payload string) error { return nil }
func (disputeKind) Do(_ int, rlm realm, payload string) error { return nil }
func disputeRules(p Params) governor.Rules {
	return governor.NewRules(5000, p.disputeThresholdBps, p.votingBlocks, 1, p.graceBlocks, 0)
}
func OpenDispute(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.frozenAt == 0 {
		panic("kourtv2: there is no answer to dispute")
	}
	if who == cs.answerer {
		panic("kourtv2: the answerer cannot dispute their own answer")
	}
	if cs.disputeOpen {
		panic("kourtv2: a dispute is already open on this claim")
	}
	if cs.verdictAt != 0 {
		panic("kourtv2: the verdict is final")
	}
	now := heightNow()
	if cs.provisional < 0 {
		if passed, known := pastDeadline(cs.answeredAtTime, settleSecs); (known && passed) ||
			(!known && now >= cs.answerHeight+settleDelay) {
			panic("kourtv2: the dispute window has passed; the answer settles undisputed")
		}
	} else if escrowPassed(cs) {
		panic("kourtv2: the escrow window has passed; Finalize the verdict")
	}
	touch(c)
	bond := cs.disputeBond0()
	mustSpendable(c, who, bond)
	c.coin.Transfer(who, c.escrow, bond)
	floor := quorumFloor(c, cs.xBarFrozen)
	cs.round++
	payload := strconv.FormatUint(claimID, 10) + "|" + strconv.FormatInt(cs.round, 10)
	pid := c.gov.ProposeWithQuorum(c.escrow, disputeKindName, payload, "dispute", floor)
	cs.proposalID = pid
	cs.disputeOpen = true
	cs.disputeOpenedTime = nowTime()
	cs.disputeBond = bond
	cs.disputer = who
	return pid
}
func VoteDispute(cur realm, courtSlug string, claimID uint64, choice string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.disputeOpen {
		panic("kourtv2: no open dispute on this claim")
	}
	if isParticipant(cs, who) {
		panic("kourtv2: a participant may not vote on their own claim's verdict")
	}
	held := voteCap(c, who)
	if held <= 0 {
		panic("kourtv2: you hold none of this court's coin, and voting weight is " +
			"the lesser of what you held when the round opened and what you hold now")
	}
	govChoice := choice
	switch choice {
	case voteYes, voteNo:
	case voteSpam:
		govChoice = govAbstain
	default:
		panic("kourtv2: a dispute vote is \"yes\" to overturn, \"no\" to uphold, " +
			"or \"spam\" to say the claim was not worth judging")
	}
	c.gov.VoteWithCap(who, cs.proposalID, govChoice, held)
	if cs.voted == nil {
		cs.voted = bptree.NewBPTree32()
	}
	cs.voted.Set("d"+beClaimKey(uint64(cs.proposalID))+string(who), choice)
	_, dw, ok := c.gov.VoteOf(cs.proposalID, who)
	if !ok {
		panic("kourtv2: the governor did not record the vote it just accepted")
	}
	cs.voted.Set("dw"+beClaimKey(uint64(cs.proposalID))+string(who), dw)
	lockVote(c, who, voteLockDispute, int64(claimID), cs.proposalID, dw)
}
func ResolveDispute(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.disputeOpen {
		panic("kourtv2: no dispute to resolve")
	}
	if c.gov.State(cs.proposalID) == "active" {
		panic("kourtv2: the dispute vote is still open")
	}
	touch(c)
	yes, no, spamW, _ := c.gov.Tally(cs.proposalID)
	cast := yes + no + spamW
	floor := c.gov.QuorumFloor(cs.proposalID)
	firstResolution := cs.provisional < 0
	switch {
	case cast < floor:
		half := cs.disputeBond / 2
		if half > 0 {
			c.coin.Transfer(c.escrow, cs.disputer, half)
		}
		if rest := cs.disputeBond - half; rest > 0 {
			c.coin.Burn(c.escrow, rest)
		}
		cs.disputeBond = 0
		if firstResolution {
			cs.provisional = cs.answer
		}
		cs.failedRounds++
		if cs.failedRounds >= maxFailedRounds {
			provCloseClaim(c, cs)
		}
	case spamDiscards(spamW, cast):
		spamDiscardClaim(c, cs, spamW, cast)
	case yes > 0 && yes*grc20votes.Bps >= (yes+no)*c.params.disputeThresholdBps:
		posted := cs.disputeBond
		burned := cs.answerBond
		if burned > 0 {
			c.coin.Burn(c.escrow, burned)
			cs.answerBond = 0
			cs.overturnBy = cs.disputer
			cs.overturnBond = posted
		}
		if posted > 0 {
			c.coin.Transfer(c.escrow, cs.disputer, posted)
			cs.disputeBond = 0
		}
		if comp := compAmount(posted, burned); comp > 0 {
			enqueueSenior(c, cs.disputer, comp, "comp")
		}
		cs.provisional = int8(oppositeSide(int(cs.answer)))
		cs.failedRounds = 0
		cs.decidedRounds++
		cs.decidedPID, cs.carrotChoice, cs.carrotDenom = cs.proposalID, "yes", yes
		cs.spamW, cs.spamTotalW = spamW, cast
	default:
		burned := cs.disputeBond
		if burned > 0 {
			c.coin.Burn(c.escrow, burned)
			cs.disputeBond = 0
		}
		if comp := compAmount(cs.answerBond0, burned); comp > 0 {
			enqueueSenior(c, cs.answerer, comp, "comp")
		}
		if yes >= credWeightFloor(c, cs.proposalID)/4 {
			cs.credEligible = true
		}
		cs.provisional = cs.answer
		cs.failedRounds = 0
		cs.decidedRounds++
		cs.decidedPID, cs.carrotChoice, cs.carrotDenom = cs.proposalID, "no", no
		cs.spamW, cs.spamTotalW = spamW, cast
	}
	if firstResolution && !cs.provClose {
		w := escrowWindow(c, cs)
		if cs.failedRounds > 0 {
			if lw := ladderWindow(c.params); lw > w {
				w = lw
			}
		}
		cs.escrowUntil = heightNow() + w
		cs.escrowUntilAt = nowTime() + blocksToSecs(w)
	}
	cs.disputeOpen = false
}
func (cs *claimState) disputeBond0() int64 {
	base := cs.xBarFrozen * disputeBondXBps / 10000
	if arm := cs.answerBond0 * disputeBondOfAnswerBps / 10000; arm < base {
		base = arm
	}
	if base < 1 {
		base = 1
	}
	shift := cs.failedRounds
	if shift > maxFailedRounds-1 {
		shift = maxFailedRounds - 1
	}
	return mustMul(base, int64(1)<<uint(shift))
}
func compAmount(ownBond, burned int64) int64 {
	comp := mustMul(compOwnX, ownBond)
	if arm := burned * compOfBurnBps / 10000; arm < comp {
		comp = arm
	}
	if comp < 0 {
		comp = 0
	}
	return comp
}
func spamDiscards(spamW, cast int64) bool { return spamW*2 > cast }
func spamBurnsDeposit(spamW, cast int64) bool { return spamW*3 >= cast*2 }
func spamDiscardClaim(c *Court, cs *claimState, spamW, cast int64) {
	cs.spamClosed = true
	cs.provClose = true
	cs.verdictAt = heightNow()
	cs.verdictAtTime = nowTime()
	cs.route = "spam"
	cs.spamW, cs.spamTotalW = spamW, cast
	cs.decidedPID, cs.carrotChoice, cs.carrotDenom = cs.proposalID, voteSpam, spamW
	if cs.answerBond > 0 {
		settleAnswerBond(c, cs)
	}
	if cs.disputeBond > 0 {
		c.coin.Transfer(c.escrow, cs.disputer, cs.disputeBond)
		cs.disputeBond = 0
	}
	burnDeposit := spamBurnsDeposit(spamW, cast)
	if cs.deposit > 0 {
		if burnDeposit {
			c.coin.Burn(c.escrow, cs.deposit)
		} else {
			c.coin.Transfer(c.escrow, cs.author, cs.deposit)
		}
		c.deposit -= cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Burn(c.escrow, cs.fee)
		c.deposit -= cs.fee
		cs.fee = 0
	}
	releasePriority(c, cs.answerer, cs.id)
	stripExit(c, cs)
	releaseMetaLatchIfMeta(c, cs)
}
func provCloseClaim(c *Court, cs *claimState) {
	cs.provClose = true
	cs.verdictAt = heightNow()
	cs.verdictAtTime = nowTime()
	cs.route = "closed"
	if cs.answerBond > 0 {
		settleAnswerBond(c, cs)
	}
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
	releasePriority(c, cs.answerer, cs.id)
	stripExit(c, cs)
	releaseMetaLatchIfMeta(c, cs)
}
func Finalize(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.verdictAt != 0 {
		panic("kourtv2: already final")
	}
	if cs.disputeOpen {
		panic("kourtv2: a dispute is active; cannot finalize")
	}
	if cs.provisional < 0 {
		panic("kourtv2: no provisional verdict to finalize")
	}
	now := heightNow()
	if !escrowPassed(cs) {
		panic("kourtv2: the escrow window has not passed")
	}
	if passed, known := pastDeadline(cs.escrowUntilAt, finalizeGraceSecs); ((known && !passed) ||
		(!known && now < cs.escrowUntil+finalizeGraceBlocks)) && !isParticipant(cs, who) {
		panic("kourtv2: Finalize is participant-only for its first week")
	}
	touch(c)
	cs.verdictAt = now
	cs.verdictAtTime = nowTime()
	cs.route = "vote"
	trimClaimHistory(c, cs, uint32(cs.frozenAt/epochBlocks)+1)
	if cs.answerBond > 0 {
		settleAnswerBond(c, cs)
	}
	if cs.provisional != cs.answer {
		resetOverturned(c, cs.answerer)
	} else if cs.decidedRounds > 0 && cs.credEligible {
		creditUpheld(c, cs.answerer)
	}
	creditDisputeResolved(c, cs)
	releasePriority(c, cs.answerer, claimID)
}
func VotableSupply(courtSlug string) (raw, escrowed, votable int64) {
	c := mustCourt(courtSlug)
	at := c.coin.Epoch()
	if at <= 1 {
		return 0, 0, 0
	}
	at--
	raw = c.coin.PastTotal(at)
	escrowed = c.coin.PastVotes(c.escrow, at)
	votable = raw - escrowed
	if votable < 0 {
		votable = 0
	}
	return raw, escrowed, votable
}
func QuorumFloorOf(courtSlug string, claimID uint64) int64 {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.disputeOpen {
		return c.gov.QuorumFloor(cs.proposalID)
	}
	return quorumFloor(c, cs.xBarFrozen)
}
func isParticipant(cs *claimState, who address) bool {
	if who == cs.author || who == cs.answerer {
		return true
	}
	return cs.stakers.Get(posKey(who, sideYES)) != nil ||
		cs.stakers.Get(posKey(who, sideNO)) != nil
}
func quorumFloor(c *Court, xbar int64) int64 {
	at := c.coin.Epoch() - 1
	supply := c.coin.PastTotal(at)
	votable := supply - c.coin.PastVotes(c.escrow, at)
	if votable < 0 {
		votable = 0
	}
	floor := xbar
	if third := votable / 3; third < floor {
		floor = third
	}
	if floor < 1 {
		floor = 1
	}
	return floor
}
func oppositeSide(side int) int {
	if side == sideYES {
		return sideNO
	}
	return sideYES
}
func escrowWindow(c *Court, cs *claimState) int64 {
	extraDays := mulDiv128(cs.xBarFrozen, c.crv.Price(c.minted), 500_000_000)
	room := (c.params.escrowMaxBlocks - c.params.escrowMinBlocks) / oneDayBlocks
	if extraDays >= room {
		return c.params.escrowMaxBlocks
	}
	return c.params.escrowMinBlocks + extraDays*oneDayBlocks
}
const (
	voteYes  = "yes"
	voteNo   = "no"
	voteSpam = "spam"
	govAbstain = "abstain"
)
const oneDayBlocks = int64(24) * epochBlocks
func DisputeOpen(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).disputeOpen
}
func DisputeProposal(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).proposalID
}
func Provisional(courtSlug string, claimID uint64) int {
	return int(mustClaim(mustCourt(courtSlug), claimID).provisional)
}
func FailedRounds(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).failedRounds
}
func ProvClose(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).provClose
}
func EscrowUntil(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).escrowUntil
}
func DisputeVoteCloses(courtSlug string, claimID uint64) int64 {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.disputeOpen || cs.proposalID == 0 {
		return 0
	}
	_, closes, _, _ := c.gov.Timings(cs.proposalID)
	return closes
}
func DisputeBondNext(courtSlug string, claimID uint64) int64 {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.frozenAt == 0 {
		return 0
	}
	return cs.disputeBond0()
}
func escrowPassed(cs *claimState) bool {
	passed, known := pastDeadline(cs.escrowUntilAt, 0)
	return (known && passed) || (!known && heightNow() >= cs.escrowUntil)
}
func Reopenable(courtSlug string, claimID uint64) bool {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.provisional >= 0 && cs.verdictAt == 0 && !cs.disputeOpen &&
		!escrowPassed(cs)
}
func ladderWindow(p Params) int64 {
	return (maxFailedRounds-2)*p.votingBlocks + (maxFailedRounds-1)*p.graceBlocks + 1
}
func credWeightFloor(c *Court, pid int64) int64 {
	engaged, _ := c.gov.Snapshot(pid)
	return mulDiv128(engaged, quorumSupplyBps, grc20votes.Bps)
}
func credWeightFloorAt(c *Court, at uint32) int64 {
	return mulDiv128(c.coin.EngagedTotal(at), quorumSupplyBps, grc20votes.Bps)
}
