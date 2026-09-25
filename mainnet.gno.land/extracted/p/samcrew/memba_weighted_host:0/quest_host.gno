package memba_weighted_host

import "gno.land/p/samcrew/memba_weighted_policy"

// ApplicationPolicies is copied and validated by construction. No policy can
// subsequently be attached or changed on an existing host.
type ApplicationPolicies struct {
	Feedback FeedbackPolicy
	Channels ChannelsPolicy
	Feed     FeedPolicy
	Badges   BadgesPolicy
	Escrow   EscrowPolicy
	Appstore AppstorePolicy
	Arcade   ArcadePolicy
	Market   MarketPolicy
	Reviews  ReviewsPolicy
	Quest    QuestPolicy
}

func NewWithApplications(seats []Seat, policies ApplicationPolicies, rlm realm) *Host {
	h := New(seats, rlm)
	if policies.Market != (MarketPolicy{}) {
		h = NewWithMarket(seats, policies.Market, rlm)
	}
	if policies.Reviews != (ReviewsPolicy{}) {
		h = attachReviews(h, policies.Reviews, rlm)
	}
	if policies.Quest != (QuestPolicy{}) {
		p := NewQuestPolicy(policies.Quest.DAO(), policies.Quest.Successor())
		if rlm.Address() != p.DAO() {
			panic("quest policy DAO does not own this host")
		}
		h.questPolicy = &p
	}
	if policies.Arcade != (ArcadePolicy{}) {
		p := NewArcadePolicy(policies.Arcade.DAO(), policies.Arcade.Successor())
		if rlm.Address() != p.DAO() {
			panic("arcade policy DAO does not own this host")
		}
		h.arcadePolicy = &p
	}
	if policies.Appstore != (AppstorePolicy{}) {
		p := NewAppstorePolicy(policies.Appstore.DAO(), policies.Appstore.Successor(), policies.Appstore.Treasury())
		if rlm.Address() != p.DAO() {
			panic("appstore policy DAO does not own this host")
		}
		h.appstorePolicy = &p
	}
	if policies.Escrow != (EscrowPolicy{}) {
		p := NewEscrowPolicy(policies.Escrow.DAO(), policies.Escrow.Successor())
		if rlm.Address() != p.DAO() {
			panic("escrow policy DAO does not own this host")
		}
		h.escrowPolicy = &p
	}
	if policies.Badges != (BadgesPolicy{}) {
		p := NewBadgesPolicy(policies.Badges.DAO(), policies.Badges.Successor())
		if rlm.Address() != p.DAO() {
			panic("badges policy DAO does not own this host")
		}
		h.badgesPolicy = &p
	}
	if policies.Feed != (FeedPolicy{}) {
		p := NewFeedPolicy(policies.Feed.DAO(), policies.Feed.Successor())
		if rlm.Address() != p.DAO() {
			panic("feed policy DAO does not own this host")
		}
		h.feedPolicy = &p
	}
	if policies.Channels != (ChannelsPolicy{}) {
		p := NewChannelsPolicy(policies.Channels.DAO(), policies.Channels.Successor())
		if rlm.Address() != p.DAO() {
			panic("channels policy DAO does not own this host")
		}
		h.channelsPolicy = &p
	}
	if policies.Feedback != (FeedbackPolicy{}) {
		p := NewFeedbackPolicy(policies.Feedback.DAO(), policies.Feedback.Successor())
		if rlm.Address() != p.DAO() {
			panic("feedback policy DAO does not own this host")
		}
		h.feedbackPolicy = &p
	}
	return h
}

type QuestState struct {
	Owner, PendingOwner address
	Signer              string
}
type questProposal struct {
	action QuestAction
	before QuestState
}

func questCommitment(a QuestAction, before QuestState) string {
	return a.Bytes() + "|before|" + questStateJSON(before)
}
func (h *Host) validateQuest(a QuestAction, before QuestState) {
	if h.questPolicy == nil {
		panic("quest actions are not configured")
	}
	a.Bytes()
	p := h.questPolicy
	if !before.Owner.IsValid() || (before.PendingOwner != "" && !before.PendingOwner.IsValid()) || (before.Signer != "" && !canonicalQuestKey(before.Signer)) {
		panic("invalid quest pre-state")
	}
	if a.Kind() == QuestAcceptOwner {
		if before.Owner == p.DAO() || before.PendingOwner != p.DAO() {
			panic("DAO is not pending quest owner")
		}
		return
	}
	if before.Owner != p.DAO() {
		panic("DAO is not quest owner")
	}
	if a.Kind() == QuestAbortReturn {
		if a.Recipient() != p.Successor() || before.PendingOwner != p.Successor() {
			panic("quest return does not match policy")
		}
		return
	}
	if before.PendingOwner != "" {
		panic("quest authority transfer is pending")
	}
	switch a.Kind() {
	case QuestSetSigner:
		if before.Signer == a.Key() {
			panic("quest signer change is a no-op")
		}
	case QuestReturnOwner:
		if a.Recipient() != p.Successor() {
			panic("quest successor does not match policy")
		}
	default:
		panic("unsupported quest action")
	}
}
func (h *Host) ProposeQuest(a QuestAction, before QuestState, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateQuest(a, before)
	p := &roleProposal{proposer: who, quest: &questProposal{action: a, before: before}}
	p.ballot = h.policy.NewProposal(a.Category(), questCommitment(a, before))
	h.addProposal(p)
	return uint64(len(h.proposals))
}
func (h *Host) ConsumeQuest(id uint64, before QuestState, rlm realm) QuestAction {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.quest == nil {
		panic("proposal is not a quest action")
	}
	h.validateQuest(p.quest.action, before)
	p.ballot.Consume(questCommitment(p.quest.action, before))
	members := []memba_weighted_policy.Member{}
	for _, seat := range h.seats {
		members = append(members, seat.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(InvalidatedByExecution, id, QuestPath)
	return p.quest.action
}
