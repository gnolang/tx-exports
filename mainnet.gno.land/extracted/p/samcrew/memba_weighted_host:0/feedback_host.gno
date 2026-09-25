package memba_weighted_host

import (
	"chain"
	"gno.land/p/samcrew/memba_weighted_policy"
)

type FeedbackState struct {
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
type feedbackProposal struct { action FeedbackAction; before FeedbackState }

func feedbackCommitment(a FeedbackAction, s FeedbackState) string {
	return a.Bytes()+"|before|"+feedbackStateJSON(s)
}
func (h *Host) validateFeedback(a FeedbackAction, s FeedbackState) {
	if h.feedbackPolicy==nil { panic("feedback actions are not configured") }
	a.Bytes()
	p:=h.feedbackPolicy
	if !s.Owner.IsValid() || (s.PendingOwner!="" && !s.PendingOwner.IsValid()) || s.MemberCount<1 || !s.OwnerMember || s.ChannelCount<0 || s.ChannelCount>20 {
		panic("invalid feedback authority pre-state")
	}
	if a.Subject()=="" && (s.SubjectMember || s.SubjectRoles!="") { panic("unexpected feedback subject pre-state") }
	if a.Name()=="" && (s.ChannelExists || s.ChannelDescription!="" || s.ChannelType!="" || s.ChannelReadRoles!="" || s.ChannelWriteRoles!="") { panic("unexpected feedback creation pre-state") }
	if a.Kind()==FeedbackAcceptOwner {
		if s.Owner!=p.Successor() || s.PendingOwner!=p.DAO() || s.DAOMember || !s.SuccessorMember || s.OwnerRoles!="admin" || s.SuccessorRoles!="admin" {
			panic("publisher is not pending feedback handoff or DAO already has membership")
		}
		return
	}
	if s.Owner!=p.DAO() || !s.DAOMember || s.DAORoles!=s.OwnerRoles { panic("DAO is not feedback owner") }
	if a.Kind()==FeedbackAbortReturn {
		if a.Recipient()!=p.Successor() || s.PendingOwner!=p.Successor() { panic("feedback return does not match policy") }
		return
	}
	if s.PendingOwner!="" { panic("feedback authority transfer is pending") }
	switch a.Kind() {
	case FeedbackReturnOwner:
		if a.Recipient()!=p.Successor() || s.SuccessorMember { panic("feedback successor mismatch or preexisting membership") }
	case FeedbackAddMember, FeedbackRemoveMember, FeedbackSetRoles:
		if a.Subject()==p.DAO() || a.Subject()==chain.PackageAddress(FeedbackPath) || (a.Subject()==p.Successor() && a.Kind()!=FeedbackRemoveMember) {
			panic("feedback member action targets protected authority")
		}
		if a.Kind()==FeedbackAddMember && s.SubjectMember { panic("feedback member already exists") }
		if a.Kind()!=FeedbackAddMember && !s.SubjectMember { panic("feedback member does not exist") }
		if a.Kind()==FeedbackSetRoles && s.SubjectRoles==a.Roles() { panic("feedback roles are unchanged") }
	case FeedbackCreateText:
		if s.ChannelCount>=20 || s.ChannelExists { panic("feedback text creation unavailable") }
	case FeedbackUnpause:
		if !s.Paused { panic("feedback unpause is a no-op") }
	default: panic("unsupported feedback action")
	}
}
func (h *Host) ProposeFeedback(a FeedbackAction, s FeedbackState, rlm realm) uint64 {
	who:=assertCaller(h,rlm)
	h.validateFeedback(a,s)
	p:=&roleProposal{proposer:who,feedback:&feedbackProposal{action:a,before:s}}
	p.ballot=h.policy.NewProposal(a.Category(),feedbackCommitment(a,s))
	h.addProposal(p)
	return uint64(len(h.proposals))
}
func (h *Host) invalidateFeedbackPeers(cause string, id uint64) {
	members:=[]memba_weighted_policy.Member{}
	for _,seat:=range h.seats { members=append(members,seat.Member) }
	h.policy.Reconfigure(members)
	h.recordInvalidation(cause, id, FeedbackPath)
}
func (h *Host) ConsumeFeedback(id uint64, s FeedbackState, rlm realm) FeedbackAction {
	assertCaller(h,rlm)
	p:=h.proposal(id)
	if p.feedback==nil { panic("proposal is not a feedback action") }
	h.validateFeedback(p.feedback.action,s)
	p.ballot.Consume(feedbackCommitment(p.feedback.action,s))
	h.invalidateFeedbackPeers(InvalidatedByExecution, id)
	return p.feedback.action
}
func (h *Host) PrepareFeedbackEmergencyPause(s FeedbackState, rlm realm) {
	assertCaller(h,rlm)
	if h.feedbackPolicy==nil || s.Owner!=h.feedbackPolicy.DAO() || s.Paused || !s.OwnerMember || !s.DAOMember || s.DAORoles!=s.OwnerRoles {
		panic("feedback emergency pause unavailable")
	}
	h.invalidateFeedbackPeers(InvalidatedByPause, 0)
}
