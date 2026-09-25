package memba_weighted_host

import "gno.land/p/samcrew/memba_weighted_policy"

const BadgesMaxAdmins = 10

// Admin bits are explicit grants. The current owner's authority to appoint is
// separate from those bits, but target ownership always installs an admin grant.
type BadgesState struct {
	Owner, PendingOwner                                address
	Paused                                             bool
	AdminCount                                         int
	OwnerAdmin, DAOAdmin, SuccessorAdmin, SubjectAdmin bool
}
type badgesProposal struct {
	action BadgesAction
	before BadgesState
}

func badgesCommitment(a BadgesAction, s BadgesState) string {
	return a.Bytes() + "|before|" + badgesStateJSON(s)
}
func (h *Host) validateBadgesAuthority(s BadgesState) {
	if h.badgesPolicy == nil {
		panic("badges actions are not configured")
	}
	if !s.Owner.IsValid() || (s.PendingOwner != "" && !s.PendingOwner.IsValid()) || !s.OwnerAdmin || s.AdminCount < 1 || s.AdminCount > BadgesMaxAdmins {
		panic("invalid badges authority pre-state")
	}
}
func (h *Host) validateBadges(a BadgesAction, s BadgesState) {
	h.validateBadgesAuthority(s)
	a.Bytes()
	p := h.badgesPolicy
	if a.Subject() == "" && s.SubjectAdmin {
		panic("unexpected badges subject pre-state")
	}
	if a.Kind() == BadgesAcceptOwner {
		if s.Owner == p.DAO() || s.PendingOwner != p.DAO() {
			panic("DAO is not pending badges owner")
		}
		return
	}
	if s.Owner != p.DAO() || !s.DAOAdmin {
		panic("DAO is not badges owner/admin")
	}
	if a.Kind() == BadgesAbortReturn {
		if a.Recipient() != p.Successor() || s.PendingOwner != p.Successor() {
			panic("badges return does not match policy")
		}
		return
	}
	if s.PendingOwner != "" {
		panic("badges authority transfer is pending")
	}
	switch a.Kind() {
	case BadgesReturnOwner:
		if a.Recipient() != p.Successor() {
			panic("badges successor does not match policy")
		}
	case BadgesAddAdmin:
		p.AddAdmin(a.Subject())
		if s.SubjectAdmin {
			panic("badges admin grant is a no-op")
		}
		if s.AdminCount >= BadgesMaxAdmins {
			panic("badges admin limit reached")
		}
	case BadgesRemoveAdmin:
		if a.Subject() == s.Owner {
			panic("cannot remove badges owner admin")
		}
		if !s.SubjectAdmin {
			panic("badges admin removal is a no-op")
		}
	case BadgesUnpause:
		if !s.Paused {
			panic("badges unpause is a no-op")
		}
	default:
		panic("unsupported badges action")
	}
}
func (h *Host) ProposeBadges(a BadgesAction, s BadgesState, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateBadges(a, s)
	p := &roleProposal{proposer: who, badges: &badgesProposal{action: a, before: s}}
	p.ballot = h.policy.NewProposal(a.Category(), badgesCommitment(a, s))
	h.addProposal(p)
	return uint64(len(h.proposals))
}
func (h *Host) invalidateBadgesPeers(cause string, id uint64) {
	members := []memba_weighted_policy.Member{}
	for _, seat := range h.seats {
		members = append(members, seat.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(cause, id, BadgesPath)
}
func (h *Host) ConsumeBadges(id uint64, s BadgesState, rlm realm) BadgesAction {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.badges == nil {
		panic("proposal is not a badges action")
	}
	h.validateBadges(p.badges.action, s)
	p.ballot.Consume(badgesCommitment(p.badges.action, s))
	h.invalidateBadgesPeers(InvalidatedByExecution, id)
	return p.badges.action
}
func (h *Host) PrepareBadgesEmergencyPause(s BadgesState, rlm realm) {
	assertCaller(h, rlm)
	h.validateBadgesAuthority(s)
	if s.Owner != h.badgesPolicy.DAO() || !s.DAOAdmin {
		panic("DAO is not badges owner/admin")
	}
	if s.Paused {
		panic("badges is already paused")
	}
	if s.SubjectAdmin {
		panic("unexpected badges subject pre-state")
	}
	h.invalidateBadgesPeers(InvalidatedByPause, 0)
}
