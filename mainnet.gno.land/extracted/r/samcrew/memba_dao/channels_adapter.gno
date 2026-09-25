// Fixed channels authority and membership. Content moderation remains with the
// current owner and appointed target admins; votes cannot call arbitrary code.
package memba_dao

import (
	"gno.land/p/samcrew/memba_weighted_host"
	channels "gno.land/r/samcrew/memba_dao_channels_v2"
)

func channelsState(a memba_weighted_host.ChannelsAction) memba_weighted_host.ChannelsState {
	owner:=channels.GetOwner()
	subjectRoles:=""
	if a.Subject()!="" { subjectRoles=channels.GetMemberRoles(a.Subject()) }
	s:=memba_weighted_host.ChannelsState{
		Owner:owner, PendingOwner:channels.GetPendingOwner(), Paused:channels.IsPaused(),
		MemberCount:channels.GetMemberCount(), MembershipRevision:channels.GetMembershipRevision(), OwnerRoles:channels.GetMemberRoles(owner),
		OwnerMember:channels.IsMember(owner), DAOMember:channels.IsMember(channelsPolicy.DAO()),
		SuccessorMember:channels.IsMember(channelsPolicy.Successor()),
		SubjectMember:a.Subject()!="" && channels.IsMember(a.Subject()),
		DAORoles:channels.GetMemberRoles(channelsPolicy.DAO()),
		SuccessorRoles:channels.GetMemberRoles(channelsPolicy.Successor()), SubjectRoles:subjectRoles,
	}
	s.ChannelCount,s.ChannelExists,s.ChannelDescription,s.ChannelType,s.ChannelReadRoles,s.ChannelWriteRoles=channels.GetChannelState(a.Name())
	return s
}
func proposeChannels(cur realm,a memba_weighted_host.ChannelsAction) uint64 { return host.ProposeChannels(a,channelsState(a),cur) }
func ProposeChannelsAccept(cur realm) uint64 { return proposeChannels(cur,channelsPolicy.Accept()) }
func ProposeChannelsReturn(cur realm) uint64 { return proposeChannels(cur,channelsPolicy.Return()) }
func ProposeChannelsAbortReturn(cur realm) uint64 { return proposeChannels(cur,channelsPolicy.AbortReturn()) }
func ProposeChannelsAddMember(cur realm,who address,roles string) uint64 { return proposeChannels(cur,channelsPolicy.AddMember(who,roles)) }
func ProposeChannelsRemoveMember(cur realm,who address) uint64 { return proposeChannels(cur,channelsPolicy.RemoveMember(who)) }
func ProposeChannelsSetRoles(cur realm,who address,roles string) uint64 { return proposeChannels(cur,channelsPolicy.SetRoles(who,roles)) }
func ProposeChannelsCreateText(cur realm,name,description string) uint64 { return proposeChannels(cur,channelsPolicy.CreateText(name,description)) }
func ProposeChannelsUnpause(cur realm) uint64 { return proposeChannels(cur,memba_weighted_host.ChannelsResume()) }
func EmergencyPauseChannels(cur realm) {
	a:=memba_weighted_host.ChannelsResume()
	before:=channelsState(a)
	host.PrepareChannelsEmergencyPause(before,cur)
	expected:=before; expected.Paused=true
	channels.PauseRealm(cross(cur))
	if channelsState(a)!=expected { panic("channels pause postcondition mismatch") }
}
func executeChannels(cur realm,id uint64) {
	proposed:=host.Proposal(id).ChannelsAction
	before:=channelsState(proposed)
	a:=host.ConsumeChannels(id,before,cur)
	expected:=before
	switch a.Kind() {
	case memba_weighted_host.ChannelsAcceptOwner:
		expected.Owner=channelsPolicy.DAO();expected.PendingOwner=""
		expected.OwnerRoles="admin";expected.DAORoles="admin";expected.OwnerMember=true;expected.DAOMember=true
		expected.MembershipRevision++
		if before.Owner==channelsPolicy.Successor() { expected.SuccessorRoles="";expected.SuccessorMember=false }
		channels.AcceptOwnership(cross(cur))
	case memba_weighted_host.ChannelsReturnOwner:
		expected.PendingOwner=a.Recipient()
		channels.ProposeOwner(cross(cur),a.Recipient())
	case memba_weighted_host.ChannelsAbortReturn:
		expected.PendingOwner=""
		channels.CancelPendingOwner(cross(cur))
	case memba_weighted_host.ChannelsAddMember:
		expected.MemberCount++;expected.MembershipRevision++;expected.SubjectRoles=a.Roles();expected.SubjectMember=true
		channels.AddMember(cross(cur),a.Subject(),a.Roles())
	case memba_weighted_host.ChannelsRemoveMember:
		expected.MemberCount--;expected.MembershipRevision++;expected.SubjectRoles="";expected.SubjectMember=false
		if a.Subject()==channelsPolicy.Successor() { expected.SuccessorRoles="";expected.SuccessorMember=false }
		channels.RemoveMember(cross(cur),a.Subject())
	case memba_weighted_host.ChannelsSetRoles:
		expected.MembershipRevision++;expected.SubjectRoles=a.Roles()
		channels.UpdateMemberRoles(cross(cur),a.Subject(),a.Roles())
	case memba_weighted_host.ChannelsCreateText:
		expected.ChannelCount++;expected.ChannelExists=true
		expected.ChannelDescription=a.Description();expected.ChannelType="text"
		expected.ChannelReadRoles="admin,dev,ops,member";expected.ChannelWriteRoles="admin,dev,ops,member"
		channels.CreateChannel(cross(cur),a.Name(),a.Description(),"text")
	case memba_weighted_host.ChannelsUnpause:
		expected.Paused=false
		channels.UnpauseRealm(cross(cur))
	default: panic("unsupported channels action")
	}
	if channelsState(a)!=expected { panic("channels postcondition mismatch") }
	if a.Kind()==memba_weighted_host.ChannelsAcceptOwner && channels.IsMember(before.Owner) { panic("channels previous owner membership retained") }
}
