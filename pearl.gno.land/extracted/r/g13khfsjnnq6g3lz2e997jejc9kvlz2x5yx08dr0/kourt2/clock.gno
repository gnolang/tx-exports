package kourt2
import (
	"chain/runtime"
	"strconv"
)
const (
	settleSecs    = int64(72 * 3600)
	deadClaimSecs = int64(12 * 7 * 86400)
	finalizeGraceSecs = int64(7 * 86400)
	priorityWindowSecs = int64(24 * 3600)
)
func nowTime() int64 { return tcNow() }
func deadlineTime(stamp, secs int64) int64 {
	if stamp == 0 {
		return 0
	}
	return stamp + secs
}
func pastDeadline(stamp, secs int64) (passed, known bool) {
	if stamp == 0 {
		return false, false
	}
	return nowTime() >= stamp+secs, true
}
func blocksToSecs(b int64) int64 { return b * 5 }
func heightNow() int64 {
	var h int64
	if tcArmed {
		h = tcHeightBase + tcHeightSkew
	} else {
		h = runtime.ChainHeight()
		if h < tcHeightFloor {
			h = tcHeightFloor
		}
	}
	return h
}
func itoa(v int64) string { return strconv.FormatInt(v, 10) }
func ClaimTimeline(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	out := "opened:" + itoa(cs.openedAtTime) + ":" + itoa(cs.openedAt)
	if cs.answerHeight != 0 {
		out += ";answered:" + itoa(cs.answeredAtTime) + ":" + itoa(cs.answerHeight)
		if cs.verdictAt == 0 && !cs.closed {
			out += ";settle:" + itoa(deadlineTime(cs.answeredAtTime, settleSecs)) +
				":" + itoa(cs.answerHeight+settleDelay)
		}
	}
	if cs.verdictAt != 0 {
		out += ";verdict:" + itoa(cs.verdictAtTime) + ":" + itoa(cs.verdictAt)
	}
	if cs.escrowUntil != 0 {
		out += ";reopen:" + itoa(cs.escrowUntilAt) + ":" + itoa(cs.escrowUntil)
	}
	if cs.disputeOpen && cs.proposalID != 0 {
		opened, closes, _, _ := c.gov.Timings(cs.proposalID)
		out += ";dispute:" + itoa(cs.disputeOpenedTime) + ":" + itoa(opened)
		_, closesTime := c.gov.TimingsAt(cs.proposalID)
		out += ";voteclose:" + itoa(closesTime) + ":" + itoa(closes)
	}
	out += ";now:" + itoa(nowTime()) + ":" + itoa(heightNow())
	if TestClockFabricated() {
		out += ";testclock:" + itoa(TestClockPeakSkew()) + ":" + itoa(TestHeightPeakSkew())
	}
	return out
}
type realmClock struct{}
func (realmClock) Height() int64 { return heightNow() }
func (realmClock) Now() int64 { return nowTime() }
func eventHeight() string {
	h := strconv.FormatInt(heightNow(), 10)
	if TestClockFabricated() {
		return h + "~test"
	}
	return h
}
