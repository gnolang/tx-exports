package memba_weighted_host

import (
	"chain"
	"chain/runtime"
	"gno.land/p/samcrew/memba_weighted_policy"
)

type EscrowMilestone struct {
	ID                                int
	Amount                            int64
	Status                            string
	FundedAt, CompletedAt, DisputedAt int64
	PreDisputeStatus                  string
}
type EscrowContract struct {
	Exists                  bool
	ID, ContentHash, Status string
	Client, Freelancer      address
	Count                   int
	Milestones              [20]EscrowMilestone
}
type EscrowFeeTerms struct {
	RawBPS, EffectiveBPS                             int64
	RawTreasury, FallbackTreasury, EffectiveTreasury address
}
// EscrowState is the escrow_v4 state a proposal freezes. The pause fields copy
// PauseInfo except PausedBlocks, which grows every block. ExitsOpen is also
// height-derived: it is read fresh at proposal and execution time and never
// enters the commitment (escrowStateJSON), so a pause ageing past its blocking
// window cannot make a frozen proposal stale.
type EscrowState struct {
	Owner, PendingOwner               address
	FeeRecipient, PendingFeeRecipient address
	Paused                            bool
	PausedAt, ExitsReopenAt           int64
	CooldownUntil                     int64
	ExitsOpen                         bool
	Contract                          EscrowContract
	Fees                              EscrowFeeTerms
}
type escrowProposal struct {
	action EscrowAction
	before EscrowState
}

func escrowCommitment(a EscrowAction, s EscrowState) string {
	return a.Bytes() + "|before|" + escrowStateJSON(s)
}
func (h *Host) validateEscrowAuthority(s EscrowState) {
	if h.escrowPolicy == nil {
		panic("escrow actions are not configured")
	}
	if !s.Owner.IsValid() || (s.PendingOwner != "" && !s.PendingOwner.IsValid()) || !s.FeeRecipient.IsValid() || (s.PendingFeeRecipient != "" && !s.PendingFeeRecipient.IsValid()) {
		panic("invalid escrow authority pre-state")
	}
	if s.CooldownUntil < 0 || (!s.Paused && (s.PausedAt != 0 || s.ExitsReopenAt != 0 || !s.ExitsOpen)) || (s.Paused && (s.PausedAt <= 0 || s.ExitsReopenAt <= s.PausedAt)) {
		panic("invalid escrow pause pre-state")
	}
}
func (h *Host) validateEscrow(a EscrowAction, s EscrowState) {
	h.validateEscrowAuthority(s)
	a.Bytes()
	p := h.escrowPolicy
	if !a.IsResolution() && (s.Contract != (EscrowContract{}) || s.Fees != (EscrowFeeTerms{})) {
		panic("unexpected escrow dispute pre-state")
	}
	if a.Kind() == EscrowAcceptOwner {
		if s.Owner == p.DAO() || s.PendingOwner != p.DAO() {
			panic("DAO is not pending escrow owner")
		}
		return
	}
	if s.Owner != p.DAO() {
		panic("DAO is not escrow owner")
	}
	if a.Kind() == EscrowAbortReturn {
		if a.Recipient() != p.Successor() || s.PendingOwner != p.Successor() {
			panic("escrow return does not match policy")
		}
		return
	}
	if s.PendingOwner != "" {
		panic("escrow authority transfer is pending")
	}
	switch a.Kind() {
	case EscrowReturnOwner:
		if a.Recipient() != p.Successor() {
			panic("escrow successor does not match policy")
		}
	case EscrowUnpause:
		if !s.Paused {
			panic("escrow unpause is a no-op")
		}
	case EscrowSetFeeRecipient:
		r := a.Recipient()
		if r == p.DAO() || r == chain.PackageAddress(EscrowPath) {
			panic("escrow fee recipient cannot be governance or escrow")
		}
		if r == s.FeeRecipient || r == s.PendingFeeRecipient {
			panic("escrow fee recipient change is a no-op")
		}
	case EscrowRefundClient, EscrowPayFreelancer:
		// escrow_v4 refuses ResolveDispute inside a pause's blocking window;
		// refuse the proposal then too, at creation and again at execution.
		if s.Paused && !s.ExitsOpen {
			panic("escrow exits are paused")
		}
		c := s.Contract
		if !c.Exists || c.ID != a.ContractID() || c.Count < 1 || c.Count > 20 || a.Milestone() >= c.Count || len(c.ContentHash) != 64 || !c.Client.IsValid() {
			panic("invalid escrow contract pre-state")
		}
		for i, m := range c.Milestones {
			if i >= c.Count {
				if m != (EscrowMilestone{}) {
					panic("unexpected escrow milestone pre-state")
				}
				continue
			}
			if m.Amount <= 0 {
				panic("invalid escrow milestone amount")
			}
		}
		m := c.Milestones[a.Milestone()]
		if c.Status != "disputed" || m.Status != "disputed" || (m.PreDisputeStatus != "funded" && m.PreDisputeStatus != "completed") {
			panic("escrow milestone is not disputed")
		}
		if a.Kind() == EscrowRefundClient {
			if c.Client == p.DAO() || c.Client == chain.PackageAddress(EscrowPath) {
				panic("escrow payout cannot be trapped in governance or escrow")
			}
			if s.Fees != (EscrowFeeTerms{}) {
				panic("unexpected escrow refund fee terms")
			}
			return
		}
		if !c.Freelancer.IsValid() || s.Fees.EffectiveBPS < 0 || s.Fees.EffectiveBPS > 500 {
			panic("invalid escrow payout terms")
		}
		if c.Freelancer == p.DAO() || c.Freelancer == chain.PackageAddress(EscrowPath) {
			panic("escrow payout cannot be trapped in governance or escrow")
		}
		fee := (m.Amount/10000)*s.Fees.EffectiveBPS + ((m.Amount%10000)*s.Fees.EffectiveBPS)/10000
		if fee > 0 && (s.Fees.EffectiveTreasury == p.DAO() || s.Fees.EffectiveTreasury == chain.PackageAddress(EscrowPath)) {
			panic("escrow payout cannot be trapped in governance or escrow")
		}
		if fee > 0 && !s.Fees.EffectiveTreasury.IsValid() {
			panic("invalid escrow fee recipient")
		}
	default:
		panic("unsupported escrow action")
	}
}
func (h *Host) ProposeEscrow(a EscrowAction, s EscrowState, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateEscrow(a, s)
	p := &roleProposal{proposer: who, escrow: &escrowProposal{action: a, before: s}}
	p.ballot = h.policy.NewProposal(a.Category(), escrowCommitment(a, s))
	h.addProposal(p)
	return uint64(len(h.proposals))
}
func (h *Host) invalidateEscrowPeers(cause string, id uint64) {
	members := []memba_weighted_policy.Member{}
	for _, s := range h.seats {
		members = append(members, s.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(cause, id, EscrowPath)
}
func (h *Host) ConsumeEscrow(id uint64, s EscrowState, rlm realm) EscrowAction {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.escrow == nil {
		panic("proposal is not an escrow action")
	}
	h.validateEscrow(p.escrow.action, s)
	p.ballot.Consume(escrowCommitment(p.escrow.action, s))
	h.invalidateEscrowPeers(InvalidatedByExecution, id)
	return p.escrow.action
}
func (h *Host) PrepareEscrowEmergencyPause(s EscrowState, rlm realm) {
	assertCaller(h, rlm)
	h.validateEscrowAuthority(s)
	if s.Owner != h.escrowPolicy.DAO() {
		panic("DAO is not escrow owner")
	}
	if s.Paused {
		panic("escrow is already paused")
	}
	// escrow_v4 refuses a Pause before its cooldown ends. Refuse here first,
	// before invalidating any proposal.
	if runtime.ChainHeight() < s.CooldownUntil {
		panic("escrow pause cooldown")
	}
	if s.Contract != (EscrowContract{}) || s.Fees != (EscrowFeeTerms{}) {
		panic("unexpected escrow dispute pre-state")
	}
	h.invalidateEscrowPeers(InvalidatedByPause, 0)
}
