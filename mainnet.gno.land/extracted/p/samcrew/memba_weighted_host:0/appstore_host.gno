package memba_weighted_host

import "gno.land/p/samcrew/memba_weighted_policy"

type AppstoreListing struct {
	Exists                      bool
	ContentHash, Status, Reason string
	Credit                      bool
	Flags                       int
	ClearKeys                   string
}
type AppstoreState struct {
	Owner, PendingOwner, Treasury                                              address
	Fee                                                                        int64
	Paused, Sealed, OwnerCurator, DAOCurator, SuccessorCurator, SubjectCurator bool
	Listing                                                                    AppstoreListing
}
type appstoreProposal struct {
	action AppstoreAction
	before AppstoreState
}

func appstoreCommitment(a AppstoreAction, s AppstoreState) string {
	return a.Bytes() + "|before|" + appstoreStateJSON(s)
}
func (h *Host) validateAppstoreAuthority(s AppstoreState) {
	if h.appstorePolicy == nil {
		panic("appstore actions are not configured")
	}
	if !s.Owner.IsValid() || !s.Treasury.IsValid() || (s.PendingOwner != "" && !s.PendingOwner.IsValid()) || s.Fee < 0 || s.Fee > AppstoreMaxFee {
		panic("invalid appstore pre-state")
	}
}
func (h *Host) validateAppstore(a AppstoreAction, s AppstoreState) {
	h.validateAppstoreAuthority(s)
	a.Bytes()
	p := h.appstorePolicy
	if !a.IsListing() && s.Listing != (AppstoreListing{}) {
		panic("unexpected appstore listing state")
	}
	if a.kind != AppstoreAddCurator && a.kind != AppstoreRemoveCurator && s.SubjectCurator {
		panic("unexpected appstore curator state")
	}
	if a.kind == AppstoreAccept {
		if s.Owner == p.DAO() || s.PendingOwner != p.DAO() {
			panic("DAO is not pending appstore owner")
		}
		return
	}
	if s.Owner != p.DAO() {
		panic("DAO is not appstore owner")
	}
	if a.kind == AppstoreAbortReturn {
		if a.recipient != p.Successor() || s.PendingOwner != p.Successor() {
			panic("appstore return does not match policy")
		}
		return
	}
	if s.PendingOwner != "" {
		panic("appstore authority transfer is pending")
	}
	if a.IsListing() {
		l := s.Listing
		if !s.DAOCurator {
			panic("DAO is not appstore curator")
		}
		if !l.Exists || l.ContentHash == "" || l.Flags < 0 {
			panic("invalid appstore listing")
		}
		switch a.kind {
		case AppstoreApprove:
			if l.Status != "pending" && l.Status != "rejected" {
				panic("appstore approval requires pending or rejected listing")
			}
		case AppstoreReject:
			if l.Status != "pending" {
				panic("appstore rejection requires pending listing")
			}
		case AppstoreDelist:
			if l.Status == "delisted" {
				panic("appstore delist is a no-op")
			}
		case AppstoreRestore:
			if l.Status != "delisted" {
				panic("appstore restore requires delisted listing")
			}
		case AppstoreClearFlags:
			if l.Flags <= 0 || l.ClearKeys == "" {
				panic("appstore has no removable flags")
			}
		}
		return
	}
	switch a.kind {
	case AppstoreReturn:
		if a.recipient != p.Successor() {
			panic("appstore successor does not match policy")
		}
	case AppstoreTreasury:
		if a.recipient != p.Treasury() {
			panic("appstore treasury does not match policy")
		}
		if s.Treasury == a.recipient {
			panic("appstore treasury is a no-op")
		}
	case AppstoreFee:
		if s.Fee == a.fee {
			panic("appstore fee is a no-op")
		}
	case AppstoreAddCurator:
		if s.SubjectCurator {
			panic("appstore curator grant is a no-op")
		}
	case AppstoreRemoveCurator:
		if !s.SubjectCurator {
			panic("appstore curator removal is a no-op")
		}
	case AppstoreUnpause:
		if !s.Paused {
			panic("appstore unpause is a no-op")
		}
	case AppstoreSeal:
		if s.Sealed {
			panic("appstore import already sealed")
		}
	default:
		panic("unsupported appstore action")
	}
}
func (h *Host) ProposeAppstore(a AppstoreAction, s AppstoreState, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateAppstore(a, s)
	p := &roleProposal{proposer: who, appstore: &appstoreProposal{action: a, before: s}}
	p.ballot = h.policy.NewProposal(a.Category(), appstoreCommitment(a, s))
	h.addProposal(p)
	return uint64(len(h.proposals))
}
func (h *Host) invalidateAppstorePeers(cause string, id uint64) {
	members := []memba_weighted_policy.Member{}
	for _, seat := range h.seats {
		members = append(members, seat.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(cause, id, AppstorePath)
}
func (h *Host) ConsumeAppstore(id uint64, s AppstoreState, rlm realm) AppstoreAction {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.appstore == nil {
		panic("proposal is not an appstore action")
	}
	h.validateAppstore(p.appstore.action, s)
	p.ballot.Consume(appstoreCommitment(p.appstore.action, s))
	h.invalidateAppstorePeers(InvalidatedByExecution, id)
	return p.appstore.action
}
func (h *Host) PrepareAppstoreEmergencyPause(s AppstoreState, rlm realm) {
	assertCaller(h, rlm)
	h.validateAppstoreAuthority(s)
	if s.Owner != h.appstorePolicy.DAO() {
		panic("DAO is not appstore owner")
	}
	if s.Paused {
		panic("appstore is already paused")
	}
	if s.Listing != (AppstoreListing{}) || s.SubjectCurator {
		panic("unexpected appstore pause state")
	}
	h.invalidateAppstorePeers(InvalidatedByPause, 0)
}
