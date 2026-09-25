package memba_weighted_host

import (
	"gno.land/p/samcrew/memba_weighted_policy"
	"strconv"
)

// MarketState is copied from the fixed target by the owning realm adapter.
// BPS is read only for a fee action; other actions commit zero in that field.
type MarketState struct {
	Admin        address
	PendingAdmin address
	Treasury     address
	BPS          int64
}

type marketProposal struct {
	action MarketAction
	before MarketState
}

// NewWithMarket binds immutable destinations. Keep the Host private; the realm
// must expose only the reviewed fixed-target adapter, never ConsumeMarket.
func NewWithMarket(seats []Seat, policy MarketPolicy, rlm realm) *Host {
	policy = NewMarketPolicy(policy.DAO(), policy.Treasury(), policy.Successor())
	if rlm.Address() != policy.DAO() {
		panic("market policy DAO does not own this host")
	}
	h := New(seats, rlm)
	h.marketPolicy = &policy
	return h
}

func marketCommitment(action MarketAction, before MarketState) string {
	if !before.Admin.IsValid() || !before.Treasury.IsValid() || (before.PendingAdmin != "" && !before.PendingAdmin.IsValid()) || before.BPS < 0 || before.BPS > 500 {
		panic("invalid market pre-state")
	}
	if action.Kind() != MarketSetFee && before.BPS != 0 {
		panic("unexpected market fee pre-state")
	}
	return action.Bytes() + "|before|" + string(before.Admin) + "|" + string(before.PendingAdmin) + "|" + string(before.Treasury) + "|" + strconv.FormatInt(before.BPS, 10)
}

func (h *Host) validateMarket(action MarketAction, before MarketState) {
	if h.marketPolicy == nil {
		panic("market actions are not configured")
	}
	marketCommitment(action, before)
	p := h.marketPolicy
	if action.Kind() == MarketAcceptAdmin {
		if before.Admin == p.DAO() || before.PendingAdmin != p.DAO() {
			panic("DAO is not pending market admin")
		}
		return
	}
	if before.Admin != p.DAO() {
		panic("DAO is not market admin")
	}
	if action.Kind() == MarketAbortReturn {
		if action.Recipient() != p.Successor() || before.PendingAdmin != p.Successor() {
			panic("market return does not match policy")
		}
		return
	}
	if before.PendingAdmin != "" {
		panic("market authority transfer is pending")
	}
	switch action.Kind() {
	case MarketSetFee:
		if action.BPS() == before.BPS {
			panic("market fee change is a no-op")
		}
	case MarketSetTreasury:
		if action.Recipient() != p.Treasury() {
			panic("market treasury does not match policy")
		}
		if before.Treasury == p.Treasury() {
			panic("market treasury change is a no-op")
		}
	case MarketReturnAdmin:
		if action.Recipient() != p.Successor() {
			panic("market successor does not match policy")
		}
	default:
		panic("unsupported market action")
	}
}

func (h *Host) ProposeMarket(action MarketAction, before MarketState, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateMarket(action, before)
	p := &roleProposal{proposer: who, market: &marketProposal{action: action, before: before}}
	p.ballot = h.policy.NewProposal(action.Category(), marketCommitment(action, before))
	h.addProposal(p)
	return uint64(len(h.proposals))
}

// ConsumeMarket is for the owning realm's fixed adapter only. It checks the
// fresh target state and consumes authorization BEFORE crossing. No recovery
// is permitted in that adapter: a target panic must abort the transaction.
func (h *Host) ConsumeMarket(id uint64, before MarketState, rlm realm) MarketAction {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.market == nil {
		panic("proposal is not a market action")
	}
	h.validateMarket(p.market.action, before)
	p.ballot.Consume(marketCommitment(p.market.action, before))
	// A successful application action invalidates all other authorizations.
	// An old approval cannot revive after a return/reaccept or intervening fee
	// change. The realm lets dispatch failure abort this mutation too.
	members := []memba_weighted_policy.Member{}
	for _, seat := range h.seats {
		members = append(members, seat.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(InvalidatedByExecution, id, MarketConfigPath)
	return p.market.action
}
