// Fixed feedback authority and membership. Content moderation remains with the
// current owner and appointed target admins; votes cannot call arbitrary code.
package memba_dao

import (
	"gno.land/p/samcrew/memba_weighted_host"
	feedback "gno.land/r/samcrew/memba_feedback_v2"
)

func feedbackState(a memba_weighted_host.FeedbackAction) memba_weighted_host.FeedbackState {
	owner:=feedback.GetOwner()
	subjectRoles:=""
	if a.Subject()!="" { subjectRoles=feedback.GetMemberRoles(a.Subject()) }
	s:=memba_weighted_host.FeedbackState{
		Owner:owner, PendingOwner:feedback.GetPendingOwner(), Paused:feedback.IsPaused(),
		MemberCount:feedback.GetMemberCount(), MembershipRevision:feedback.GetMembershipRevision(), OwnerRoles:feedback.GetMemberRoles(owner),
		OwnerMember:feedback.IsMember(owner), DAOMember:feedback.IsMember(feedbackPolicy.DAO()),
		SuccessorMember:feedback.IsMember(feedbackPolicy.Successor()),
		SubjectMember:a.Subject()!="" && feedback.IsMember(a.Subject()),
		DAORoles:feedback.GetMemberRoles(feedbackPolicy.DAO()),
		SuccessorRoles:feedback.GetMemberRoles(feedbackPolicy.Successor()), SubjectRoles:subjectRoles,
	}
	s.ChannelCount,s.ChannelExists,s.ChannelDescription,s.ChannelType,s.ChannelReadRoles,s.ChannelWriteRoles=feedback.GetChannelState(a.Name())
	return s
}
func proposeFeedback(cur realm,a memba_weighted_host.FeedbackAction) uint64 { return host.ProposeFeedback(a,feedbackState(a),cur) }
func ProposeFeedbackAccept(cur realm) uint64 { return proposeFeedback(cur,feedbackPolicy.Accept()) }
func ProposeFeedbackReturn(cur realm) uint64 { return proposeFeedback(cur,feedbackPolicy.Return()) }
func ProposeFeedbackAbortReturn(cur realm) uint64 { return proposeFeedback(cur,feedbackPolicy.AbortReturn()) }
func ProposeFeedbackAddMember(cur realm,who address,roles string) uint64 { return proposeFeedback(cur,feedbackPolicy.AddMember(who,roles)) }
func ProposeFeedbackRemoveMember(cur realm,who address) uint64 { return proposeFeedback(cur,feedbackPolicy.RemoveMember(who)) }
func ProposeFeedbackSetRoles(cur realm,who address,roles string) uint64 { return proposeFeedback(cur,feedbackPolicy.SetRoles(who,roles)) }
func ProposeFeedbackCreateText(cur realm,name,description string) uint64 { return proposeFeedback(cur,feedbackPolicy.CreateText(name,description)) }
func ProposeFeedbackUnpause(cur realm) uint64 { return proposeFeedback(cur,memba_weighted_host.FeedbackResume()) }
func EmergencyPauseFeedback(cur realm) {
	a:=memba_weighted_host.FeedbackResume()
	before:=feedbackState(a)
	host.PrepareFeedbackEmergencyPause(before,cur)
	expected:=before; expected.Paused=true
	feedback.PauseRealm(cross(cur))
	if feedbackState(a)!=expected { panic("feedback pause postcondition mismatch") }
}
func executeFeedback(cur realm,id uint64) {
	proposed:=host.Proposal(id).FeedbackAction
	before:=feedbackState(proposed)
	a:=host.ConsumeFeedback(id,before,cur)
	expected:=before
	switch a.Kind() {
	case memba_weighted_host.FeedbackAcceptOwner:
		expected.Owner=feedbackPolicy.DAO();expected.PendingOwner=""
		expected.OwnerRoles="admin";expected.DAORoles="admin";expected.OwnerMember=true;expected.DAOMember=true
		expected.MemberCount++;expected.MembershipRevision++
		expected.SuccessorRoles="member";expected.SuccessorMember=true
		feedback.AcceptOwnership(cross(cur))
	case memba_weighted_host.FeedbackReturnOwner:
		expected.PendingOwner=a.Recipient()
		feedback.TransferOwnership(cross(cur),a.Recipient())
	case memba_weighted_host.FeedbackAbortReturn:
		expected.PendingOwner=""
		feedback.CancelOwnershipTransfer(cross(cur))
	case memba_weighted_host.FeedbackAddMember:
		expected.MemberCount++;expected.MembershipRevision++;expected.SubjectRoles=a.Roles();expected.SubjectMember=true
		feedback.AddMember(cross(cur),a.Subject(),a.Roles())
	case memba_weighted_host.FeedbackRemoveMember:
		expected.MemberCount--;expected.MembershipRevision++;expected.SubjectRoles="";expected.SubjectMember=false
		if a.Subject()==feedbackPolicy.Successor() { expected.SuccessorRoles="";expected.SuccessorMember=false }
		feedback.RemoveMember(cross(cur),a.Subject())
	case memba_weighted_host.FeedbackSetRoles:
		expected.MembershipRevision++;expected.SubjectRoles=a.Roles()
		feedback.UpdateMemberRoles(cross(cur),a.Subject(),a.Roles())
	case memba_weighted_host.FeedbackCreateText:
		expected.ChannelCount++;expected.ChannelExists=true
		expected.ChannelDescription=a.Description();expected.ChannelType="text"
		expected.ChannelReadRoles="admin,dev,ops,member";expected.ChannelWriteRoles="admin,dev,ops,member"
		feedback.CreateChannel(cross(cur),a.Name(),a.Description(),"text")
	case memba_weighted_host.FeedbackUnpause:
		expected.Paused=false
		feedback.UnpauseRealm(cross(cur))
	default: panic("unsupported feedback action")
	}
	if feedbackState(a)!=expected { panic("feedback postcondition mismatch") }
	if a.Kind()==memba_weighted_host.FeedbackAcceptOwner && feedback.GetMemberRoles(before.Owner)!="member" { panic("feedback previous owner admin retained") }
}
