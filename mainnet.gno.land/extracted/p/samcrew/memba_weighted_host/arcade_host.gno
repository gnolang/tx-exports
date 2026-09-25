package memba_weighted_host

import "gno.land/p/samcrew/memba_weighted_policy"

// Explicit allowlist bits are separate from the owner's implicit attester right.
type ArcadeState struct {
	Owner, PendingOwner                                            address
	Paused, OwnerListed, DAOListed, SuccessorListed, SubjectListed bool
}
type arcadeProposal struct {
	action ArcadeAction
	before ArcadeState
}

func arcadeCommitment(a ArcadeAction, s ArcadeState) string {
	return a.Bytes() + "|before|" + arcadeStateJSON(s)
}
func (h *Host) validateArcadeAuthority(s ArcadeState) {
	if h.arcadePolicy == nil {
		panic("arcade actions are not configured")
	}
	if !s.Owner.IsValid() || (s.PendingOwner != "" && !s.PendingOwner.IsValid()) {
		panic("invalid arcade authority pre-state")
	}
}
func (h *Host) validateArcade(a ArcadeAction, s ArcadeState) {
	h.validateArcadeAuthority(s)
	a.Bytes()
	p := h.arcadePolicy
	if a.Attester() == "" && s.SubjectListed {
		panic("unexpected arcade subject pre-state")
	}
	if a.Kind() == ArcadeAcceptOwner {
		if s.Owner == p.DAO() || s.PendingOwner != p.DAO() {
			panic("DAO is not pending arcade owner")
		}
		return
	}
	if s.Owner != p.DAO() {
		panic("DAO is not arcade owner")
	}
	if a.Kind() == ArcadeAbortReturn {
		if a.Recipient() != p.Successor() || s.PendingOwner != p.Successor() {
			panic("arcade return does not match policy")
		}
		return
	}
	if s.PendingOwner != "" {
		panic("arcade authority transfer is pending")
	}
	switch a.Kind() {
	case ArcadeReturnOwner:
		if a.Recipient() != p.Successor() {
			panic("arcade successor does not match policy")
		}
	case ArcadeAddAttester:
		p.AddAttester(a.Attester())
		if s.SubjectListed {
			panic("arcade attester grant is a no-op")
		}
	case ArcadeRemoveAttester:
		if !s.SubjectListed {
			panic("arcade attester removal is a no-op")
		}
	case ArcadeUnpause:
		if !s.Paused {
			panic("arcade unpause is a no-op")
		}
	default:
		panic("unsupported arcade action")
	}
}
func (h *Host) ProposeArcade(a ArcadeAction, s ArcadeState, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateArcade(a, s)
	p := &roleProposal{proposer: who, arcade: &arcadeProposal{action: a, before: s}}
	p.ballot = h.policy.NewProposal(a.Category(), arcadeCommitment(a, s))
	h.addProposal(p)
	return uint64(len(h.proposals))
}
func (h *Host) invalidateArcadePeers(cause string, id uint64) {
	members := []memba_weighted_policy.Member{}
	for _, seat := range h.seats {
		members = append(members, seat.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(cause, id, ArcadePath)
}
func (h *Host) ConsumeArcade(id uint64, s ArcadeState, rlm realm) ArcadeAction {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.arcade == nil {
		panic("proposal is not an arcade action")
	}
	h.validateArcade(p.arcade.action, s)
	p.ballot.Consume(arcadeCommitment(p.arcade.action, s))
	h.invalidateArcadePeers(InvalidatedByExecution, id)
	return p.arcade.action
}

// A fixed pause-only capability, not a proposal category or a bool-controlled
// escape. An already-paused call cannot invalidate pending unpause approvals.
func (h *Host) PrepareArcadeEmergencyPause(s ArcadeState, rlm realm) {
	assertCaller(h, rlm)
	h.validateArcadeAuthority(s)
	if s.Owner != h.arcadePolicy.DAO() {
		panic("DAO is not arcade owner")
	}
	if s.Paused {
		panic("arcade is already paused")
	}
	if s.SubjectListed {
		panic("unexpected arcade subject pre-state")
	}
	h.invalidateArcadePeers(InvalidatedByPause, 0)
}
