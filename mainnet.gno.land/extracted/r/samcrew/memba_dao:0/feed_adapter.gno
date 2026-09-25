// Fixed feed authority and moderator appointment. Content moderation stays
// with the current owner or explicitly appointed moderators.
package memba_dao

import (
	"gno.land/p/samcrew/memba_weighted_host"
	"gno.land/r/samcrew/memba_feed_v1"
)

func feedState(a memba_weighted_host.FeedAction) memba_weighted_host.FeedState {
	owner := memba_feed_v1.GetOwner()
	subject := false
	if a.Subject() != "" { subject = memba_feed_v1.IsModerator(a.Subject()) }
	return memba_weighted_host.FeedState{
		Owner: owner, PendingOwner: memba_feed_v1.GetPendingOwner(),
		Paused: memba_feed_v1.IsPaused(), ModeratorCount: memba_feed_v1.GetModeratorCount(),
		OwnerModerator: memba_feed_v1.IsModerator(owner), DAOModerator: memba_feed_v1.IsModerator(feedPolicy.DAO()),
		SuccessorModerator: memba_feed_v1.IsModerator(feedPolicy.Successor()), SubjectModerator: subject,
	}
}
func proposeFeed(cur realm, a memba_weighted_host.FeedAction) uint64 { return host.ProposeFeed(a, feedState(a), cur) }
func ProposeFeedAccept(cur realm) uint64 { return proposeFeed(cur, feedPolicy.Accept()) }
func ProposeFeedReturn(cur realm) uint64 { return proposeFeed(cur, feedPolicy.Return()) }
func ProposeFeedAbortReturn(cur realm) uint64 { return proposeFeed(cur, feedPolicy.AbortReturn()) }
func ProposeFeedAddModerator(cur realm, who address) uint64 { return proposeFeed(cur, feedPolicy.AddModerator(who)) }
func ProposeFeedRemoveModerator(cur realm, who address) uint64 { return proposeFeed(cur, memba_weighted_host.FeedRevokeModerator(who)) }
func ProposeFeedUnpause(cur realm) uint64 { return proposeFeed(cur, memba_weighted_host.FeedResume()) }
func EmergencyPauseFeed(cur realm) {
	a := memba_weighted_host.FeedResume()
	before := feedState(a)
	host.PrepareFeedEmergencyPause(before, cur)
	expected := before
	expected.Paused = true
	memba_feed_v1.PauseRealm(cross(cur))
	if feedState(a) != expected { panic("feed pause postcondition mismatch") }
}
func executeFeed(cur realm, id uint64) {
	proposed := host.Proposal(id).FeedAction
	before := feedState(proposed)
	a := host.ConsumeFeed(id, before, cur)
	expected := before
	switch a.Kind() {
	case memba_weighted_host.FeedAcceptOwner:
		expected.Owner = feedPolicy.DAO()
		expected.PendingOwner = ""
		expected.OwnerModerator = before.DAOModerator
		memba_feed_v1.AcceptOwnership(cross(cur))
	case memba_weighted_host.FeedReturnOwner:
		expected.PendingOwner = a.Recipient()
		memba_feed_v1.TransferOwnership(cross(cur), a.Recipient())
	case memba_weighted_host.FeedAbortReturn:
		expected.PendingOwner = ""
		memba_feed_v1.CancelOwnershipTransfer(cross(cur))
	case memba_weighted_host.FeedUnpause:
		expected.Paused = false
		memba_feed_v1.UnpauseRealm(cross(cur))
	case memba_weighted_host.FeedAddModerator, memba_weighted_host.FeedRemoveModerator:
		grant := a.Kind() == memba_weighted_host.FeedAddModerator
		expected.SubjectModerator = grant
		if grant { expected.ModeratorCount++ } else { expected.ModeratorCount-- }
		if a.Subject() == feedPolicy.Successor() { expected.SuccessorModerator = grant }
		if a.Subject() == feedPolicy.DAO() { expected.DAOModerator = grant; expected.OwnerModerator = grant }
		if grant { memba_feed_v1.AddModerator(cross(cur), a.Subject()) } else { memba_feed_v1.RemoveModerator(cross(cur), a.Subject()) }
	default:
		panic("unsupported feed action")
	}
	if feedState(a) != expected { panic("feed postcondition mismatch") }
	if a.Kind() == memba_weighted_host.FeedAcceptOwner && memba_feed_v1.IsModerator(before.Owner) { panic("feed previous owner moderator retained") }
}
