package memba_weighted_host

import "gno.land/p/samcrew/memba_weighted_policy"

// ReviewsItem contains copied moderation-relevant state only. Ordinary reactions
// do not invalidate moderation; content edits, deletion and visibility do.
type ReviewsItem struct {
	ID        uint64
	Review    bool
	ParentID  uint64
	Subject   string
	Author    address
	Rating    int
	BodyHash  string
	CreatedAt int64
	EditedAt  int64
	Hidden    bool
	Deleted   bool
	Flagged   bool
}
type ReviewsState struct {
	Moderator        address
	PendingModerator address
	Item             ReviewsItem
}
type reviewsProposal struct {
	action ReviewsAction
	before ReviewsState
}

func attachReviews(h *Host, policy ReviewsPolicy, rlm realm) *Host {
	policy = NewReviewsPolicy(policy.DAO(), policy.Target(), policy.Successor())
	if rlm.Address() != policy.DAO() {
		panic("reviews policy DAO does not own this host")
	}
	h.reviewsPolicy = &policy
	return h
}
func NewWithReviews(seats []Seat, policy ReviewsPolicy, rlm realm) *Host {
	return attachReviews(New(seats, rlm), policy, rlm)
}
func NewWithMarketAndReviews(seats []Seat, market MarketPolicy, reviews ReviewsPolicy, rlm realm) *Host {
	return attachReviews(NewWithMarket(seats, market, rlm), reviews, rlm)
}
func reviewsCommitment(action ReviewsAction, before ReviewsState) string {
	return action.Bytes() + "|before|" + reviewsStateJSON(before)
}
func (h *Host) validateReviews(a ReviewsAction, before ReviewsState) {
	if h.reviewsPolicy == nil {
		panic("reviews actions are not configured")
	}
	a.Bytes()
	p := h.reviewsPolicy
	if a.Target() != p.Target() {
		panic("reviews target does not match policy")
	}
	if !before.Moderator.IsValid() || (before.PendingModerator != "" && !before.PendingModerator.IsValid()) {
		panic("invalid reviews authority pre-state")
	}
	if a.ID() == 0 && before.Item != (ReviewsItem{}) {
		panic("unexpected reviews item pre-state")
	}
	if a.Kind() == ReviewsAcceptModerator {
		if before.Moderator == p.DAO() || before.PendingModerator != p.DAO() {
			panic("DAO is not pending reviews moderator")
		}
		return
	}
	if before.Moderator != p.DAO() {
		panic("DAO is not reviews moderator")
	}
	if a.Kind() == ReviewsAbortReturn {
		if a.Recipient() != p.Successor() || before.PendingModerator != p.Successor() {
			panic("reviews return does not match policy")
		}
		return
	}
	if before.PendingModerator != "" {
		panic("reviews authority transfer is pending")
	}
	if a.Kind() == ReviewsReturnModerator {
		if a.Recipient() != p.Successor() {
			panic("reviews successor does not match policy")
		}
		return
	}
	item := before.Item
	if item.ID != a.ID() || item.ID == 0 {
		panic("reviews item not found")
	}
	// Legacy v1 retains flagged-index entries after deletion. Unhide may
	// clear only such a flagged tombstone; the adapter preserves Deleted.
	if item.Deleted && !(a.Kind() == ReviewsUnhide && item.Flagged) {
		panic("reviews item is deleted")
	}
	if !item.Author.IsValid() || len(item.BodyHash) != 64 {
		panic("invalid reviews item pre-state")
	}
	if item.Review {
		if item.ParentID != 0 || item.Subject == "" || item.Rating < 1 || item.Rating > 5 {
			panic("invalid review pre-state")
		}
	} else if item.ParentID == 0 || item.Subject != "" || item.Rating != 0 {
		panic("invalid comment pre-state")
	}
	switch a.Kind() {
	case ReviewsHideReview:
		if !item.Review {
			panic("reviews item is not a review")
		}
		if item.Hidden {
			panic("reviews hide is a no-op")
		}
	case ReviewsHideComment:
		if item.Review {
			panic("reviews item is not a comment")
		}
		if item.Hidden {
			panic("reviews hide is a no-op")
		}
	case ReviewsUnhide:
		if !item.Hidden && !item.Flagged {
			panic("reviews unhide is a no-op")
		}
	default:
		panic("unsupported reviews action")
	}
}
func (h *Host) ProposeReviews(action ReviewsAction, before ReviewsState, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateReviews(action, before)
	p := &roleProposal{proposer: who, reviews: &reviewsProposal{action: action, before: before}}
	p.ballot = h.policy.NewProposal(action.Category(), reviewsCommitment(action, before))
	h.addProposal(p)
	return uint64(len(h.proposals))
}

// Only the owning realm's fixed adapter may use this. Keep Host private and
// let target panics/postcondition failures abort the entire transaction.
func (h *Host) ConsumeReviews(id uint64, before ReviewsState, rlm realm) ReviewsAction {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.reviews == nil {
		panic("proposal is not a reviews action")
	}
	h.validateReviews(p.reviews.action, before)
	p.ballot.Consume(reviewsCommitment(p.reviews.action, before))
	members := []memba_weighted_policy.Member{}
	for _, seat := range h.seats {
		members = append(members, seat.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(InvalidatedByExecution, id, h.reviewsPolicy.Target())
	return p.reviews.action
}
