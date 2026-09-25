package memba_weighted_host

import "gno.land/p/samcrew/memba_weighted_policy"

// Feed moderators are explicit grants. Ownership itself can moderate, so the
// outgoing owner must not retain a separate moderator grant after handoff.
type FeedState struct {
	Owner, PendingOwner                                                address
	Paused                                                             bool
	ModeratorCount                                                     int
	OwnerModerator, DAOModerator, SuccessorModerator, SubjectModerator bool
}
type feedProposal struct {
	action FeedAction
	before FeedState
}

func feedCommitment(a FeedAction, s FeedState) string {
	return a.Bytes() + "|before|" + feedStateJSON(s)
}
func (h *Host) validateFeedAuthority(s FeedState) {
	if h.feedPolicy == nil {
		panic("feed actions are not configured")
	}
	if !s.Owner.IsValid() || (s.PendingOwner != "" && !s.PendingOwner.IsValid()) {
		panic("invalid feed authority pre-state")
	}
	if s.ModeratorCount < 0 {
		panic("invalid feed moderator count")
	}
}
func (h *Host) validateFeed(a FeedAction, s FeedState) {
	h.validateFeedAuthority(s)
	a.Bytes()
	p := h.feedPolicy
	if a.Subject() == "" && s.SubjectModerator {
		panic("unexpected feed subject pre-state")
	}
	if a.Kind() == FeedAcceptOwner {
		if s.Owner == p.DAO() || s.PendingOwner != p.DAO() || s.OwnerModerator {
			panic("DAO is not pending feed owner or previous owner retains moderation")
		}
		return
	}
	if s.Owner != p.DAO() {
		panic("DAO is not feed owner")
	}
	if a.Kind() == FeedAbortReturn {
		if a.Recipient() != p.Successor() || s.PendingOwner != p.Successor() {
			panic("feed return does not match policy")
		}
		return
	}
	if s.PendingOwner != "" {
		panic("feed authority transfer is pending")
	}
	switch a.Kind() {
	case FeedReturnOwner:
		if a.Recipient() != p.Successor() || s.DAOModerator {
			panic("feed successor mismatch or DAO retains moderation")
		}
	case FeedAddModerator:
		p.AddModerator(a.Subject())
		if s.SubjectModerator {
			panic("feed moderator grant is a no-op")
		}
	case FeedRemoveModerator:
		if !s.SubjectModerator {
			panic("feed moderator removal is a no-op")
		}
	case FeedUnpause:
		if !s.Paused {
			panic("feed unpause is a no-op")
		}
	default:
		panic("unsupported feed action")
	}
}
func (h *Host) ProposeFeed(a FeedAction, s FeedState, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateFeed(a, s)
	p := &roleProposal{proposer: who, feed: &feedProposal{action: a, before: s}}
	p.ballot = h.policy.NewProposal(a.Category(), feedCommitment(a, s))
	h.addProposal(p)
	return uint64(len(h.proposals))
}
func (h *Host) invalidateFeedPeers(cause string, id uint64) {
	members := []memba_weighted_policy.Member{}
	for _, seat := range h.seats {
		members = append(members, seat.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(cause, id, FeedPath)
}
func (h *Host) ConsumeFeed(id uint64, s FeedState, rlm realm) FeedAction {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.feed == nil {
		panic("proposal is not a feed action")
	}
	h.validateFeed(p.feed.action, s)
	p.ballot.Consume(feedCommitment(p.feed.action, s))
	h.invalidateFeedPeers(InvalidatedByExecution, id)
	return p.feed.action
}
func (h *Host) PrepareFeedEmergencyPause(s FeedState, rlm realm) {
	assertCaller(h, rlm)
	h.validateFeedAuthority(s)
	if s.Owner != h.feedPolicy.DAO() || s.Paused || s.SubjectModerator {
		panic("feed emergency pause unavailable")
	}
	h.invalidateFeedPeers(InvalidatedByPause, 0)
}
