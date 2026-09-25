package memba_weighted_host

import (
	"chain"
	"gno.land/p/samcrew/memba_weighted_policy"
)

type ChannelsState struct {
	Owner, PendingOwner address
	Paused bool
	MemberCount int
	MembershipRevision uint64
	OwnerMember, DAOMember, SuccessorMember, SubjectMember bool
	OwnerRoles, DAORoles, SuccessorRoles, SubjectRoles string
	ChannelCount int
	ChannelExists bool
	ChannelDescription, ChannelType, ChannelReadRoles, ChannelWriteRoles string
}
type channelsProposal struct { action ChannelsAction; before ChannelsState }

func channelsCommitment(a ChannelsAction, s ChannelsState) string {
	return a.Bytes()+"|before|"+channelsStateJSON(s)
}
func (h *Host) validateChannels(a ChannelsAction, s ChannelsState) {
	if h.channelsPolicy==nil { panic("channels actions are not configured") }
	a.Bytes()
	p:=h.channelsPolicy
	if !s.Owner.IsValid() || (s.PendingOwner!="" && !s.PendingOwner.IsValid()) || s.MemberCount<1 || !s.OwnerMember || s.ChannelCount<0 || s.ChannelCount>20 {
		panic("invalid channels authority pre-state")
	}
	if a.Subject()=="" && (s.SubjectMember || s.SubjectRoles!="") { panic("unexpected channels subject pre-state") }
	if a.Name()=="" && (s.ChannelExists || s.ChannelDescription!="" || s.ChannelType!="" || s.ChannelReadRoles!="" || s.ChannelWriteRoles!="") { panic("unexpected channels creation pre-state") }
	if a.Kind()==ChannelsAcceptOwner {
		if s.Owner==p.DAO() || s.PendingOwner!=p.DAO() || s.DAOMember {
			panic("DAO is not pending channels owner or already has membership")
		}
		return
	}
	if s.Owner!=p.DAO() || !s.DAOMember || s.DAORoles!=s.OwnerRoles { panic("DAO is not channels owner") }
	if a.Kind()==ChannelsAbortReturn {
		if a.Recipient()!=p.Successor() || s.PendingOwner!=p.Successor() { panic("channels return does not match policy") }
		return
	}
	if s.PendingOwner!="" { panic("channels authority transfer is pending") }
	switch a.Kind() {
	case ChannelsReturnOwner:
		if a.Recipient()!=p.Successor() || s.SuccessorMember { panic("channels successor mismatch or preexisting membership") }
	case ChannelsAddMember, ChannelsRemoveMember, ChannelsSetRoles:
		if a.Subject()==p.DAO() || a.Subject()==chain.PackageAddress(ChannelsPath) || (a.Subject()==p.Successor() && a.Kind()!=ChannelsRemoveMember) {
			panic("channels member action targets protected authority")
		}
		if a.Kind()==ChannelsAddMember && s.SubjectMember { panic("channels member already exists") }
		if a.Kind()!=ChannelsAddMember && !s.SubjectMember { panic("channels member does not exist") }
		if a.Kind()==ChannelsSetRoles && s.SubjectRoles==a.Roles() { panic("channels roles are unchanged") }
	case ChannelsCreateText:
		if s.ChannelCount>=20 || s.ChannelExists { panic("channels text creation unavailable") }
	case ChannelsUnpause:
		if !s.Paused { panic("channels unpause is a no-op") }
	default: panic("unsupported channels action")
	}
}
func (h *Host) ProposeChannels(a ChannelsAction, s ChannelsState, rlm realm) uint64 {
	who:=assertCaller(h,rlm)
	h.validateChannels(a,s)
	p:=&roleProposal{proposer:who,channels:&channelsProposal{action:a,before:s}}
	p.ballot=h.policy.NewProposal(a.Category(),channelsCommitment(a,s))
	h.addProposal(p)
	return uint64(len(h.proposals))
}
func (h *Host) invalidateChannelsPeers(cause string, id uint64) {
	members:=[]memba_weighted_policy.Member{}
	for _,seat:=range h.seats { members=append(members,seat.Member) }
	h.policy.Reconfigure(members)
	h.recordInvalidation(cause, id, ChannelsPath)
}
func (h *Host) ConsumeChannels(id uint64, s ChannelsState, rlm realm) ChannelsAction {
	assertCaller(h,rlm)
	p:=h.proposal(id)
	if p.channels==nil { panic("proposal is not a channels action") }
	h.validateChannels(p.channels.action,s)
	p.ballot.Consume(channelsCommitment(p.channels.action,s))
	h.invalidateChannelsPeers(InvalidatedByExecution, id)
	return p.channels.action
}
func (h *Host) PrepareChannelsEmergencyPause(s ChannelsState, rlm realm) {
	assertCaller(h,rlm)
	if h.channelsPolicy==nil || s.Owner!=h.channelsPolicy.DAO() || s.Paused || !s.OwnerMember || !s.DAOMember || s.DAORoles!=s.OwnerRoles {
		panic("channels emergency pause unavailable")
	}
	h.invalidateChannelsPeers(InvalidatedByPause, 0)
}
