package kourt2
import (
	"strconv"
	"strings"
)
func ClaimHead(courtSlug string, claimID uint64, window int64) string {
	c := mustCourt(courtSlug)
	mustClaim(c, claimID)
	b := strings.Builder{}
	n := func(v int64) { b.WriteString(strconv.FormatInt(v, 10) + "\t") }
	i := func(v int) { b.WriteString(strconv.Itoa(v) + "\t") }
	f := func(v bool) { b.WriteString(boolDigit(v) + "\t") }
	t := func(v string) { b.WriteString(v + "\t") }
	yes, no := StakePools(courtSlug, claimID)
	cy, cn := PoolConviction(courtSlug, claimID)
	oi, oiM := TrailingOI(courtSlug, claimID, window)
	ty, tyM := TrailingYes(courtSlug, claimID, window)
	n(yes)
	n(no)
	n(cy)
	n(cn)
	n(oi)
	f(oiM)
	n(ty)
	f(tyM)
	answered := HasAnswer(courtSlug, claimID)
	settled := Settled(courtSlug, claimID)
	disputeOpen := DisputeOpen(courtSlug, claimID)
	provClose := ProvClose(courtSlug, claimID)
	f(answered)
	f(disputeOpen)
	f(settled)
	f(provClose)
	i(Provisional(courtSlug, claimID))
	f(ClaimClosed(courtSlug, claimID))
	if answered {
		who := Answerer(courtSlug, claimID)
		i(AnswerVerdict(courtSlug, claimID))
		n(AnswerBond(courtSlug, claimID))
		n(SettleDeadline(courtSlug, claimID))
		t(who.String())
		i(AnswerRecord(courtSlug, who))
	} else {
		i(-1)
		n(0)
		n(0)
		t("")
		i(0)
	}
	if answered && !settled {
		n(FailedRounds(courtSlug, claimID))
		n(DisputeBondNext(courtSlug, claimID))
		n(EscrowUntil(courtSlug, claimID))
		if disputeOpen {
			n(QuorumFloorOf(courtSlug, claimID))
			n(DisputeVoteCloses(courtSlug, claimID))
		} else {
			n(0)
			n(0)
		}
	} else {
		n(0)
		n(0)
		n(0)
		n(0)
		n(0)
	}
	if settled && !provClose {
		i(Verdict(courtSlug, claimID))
		t(VerdictRoute(courtSlug, claimID))
	} else {
		i(-1)
		t("")
	}
	cryst := RewardsOpened(courtSlug, claimID)
	f(cryst)
	if cryst {
		w, au, an, ca := DrawSlices(courtSlug, claimID)
		n(w)
		n(au)
		n(an)
		n(ca)
	} else {
		n(0)
		n(0)
		n(0)
		n(0)
	}
	t(ClaimAuthor(courtSlug, claimID).String())
	f(HiddenFromListing(courtSlug, claimID))
	f(TextRedacted(courtSlug, claimID))
	f(ClaimPurged(courtSlug, claimID))
	f(ClaimSeeded(courtSlug, claimID))
	n(CourtStakeOpenDelay(courtSlug))
	i(BoardSize(courtSlug, claimID))
	f(BoardOpen(courtSlug, claimID))
	return strings.TrimSuffix(b.String(), "\t")
}
const claimHeadFields = 39
