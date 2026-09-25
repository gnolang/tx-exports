// Package memba_weighted_host hosts the founding policy's governed role actions.
// This source-only component is not the current memba_dao and grants no external
// application authority. The owning realm must keep its Host private.
package memba_weighted_host

import (
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/samcrew/memba_weighted_policy"
)

type Role string

const (
	Admin   Role = "admin"
	Finance Role = "finance"
)

// Seat is copied at construction. Founder/core-developer voting eligibility is
// independent from these operational role labels; all members may execute.
type Seat struct {
	Member  memba_weighted_policy.Member
	Admin   bool
	Finance bool
}

type roleProposal struct {
	feedback    *feedbackProposal
	channels    *channelsProposal
	feed        *feedProposal
	badges      *badgesProposal
	escrow      *escrowProposal
	appstore    *appstoreProposal
	arcade      *arcadeProposal
	quest       *questProposal
	reviews     *reviewsProposal
	market      *marketProposal
	recovery    bool
	personID    string
	replacement address
	proposer    address
	target      address
	role        Role
	grant       bool
	ballot      *memba_weighted_policy.Proposal
	// roster indexes Host.rosters: the electorate frozen at creation. choices
	// and votedAt mirror each seat's current ballot and the height it was cast;
	// they are written only by Host.Vote, after the policy accepted the vote.
	roster  int
	choices [7]memba_weighted_policy.Vote
	votedAt [7]int64
	// epoch is len(Host.invalidations) at creation: the first reconfiguration
	// recorded after it is the one that invalidated this proposal.
	epoch int
}

// Invalidation causes recorded on every policy reconfiguration.
const (
	InvalidatedByExecution = "superseded-execution"
	InvalidatedByPause     = "pause"
)

// invalidation records one policy reconfiguration: every proposal open at that
// moment, other than the one executed, stopped accepting votes and execution.
type invalidation struct {
	height   int64
	at       time.Time
	cause    string
	proposal uint64
	target   string
}

type Host struct {
	feedbackPolicy *FeedbackPolicy
	channelsPolicy *ChannelsPolicy
	feedPolicy     *FeedPolicy
	badgesPolicy   *BadgesPolicy
	escrowPolicy   *EscrowPolicy
	appstorePolicy *AppstorePolicy
	arcadePolicy   *ArcadePolicy
	questPolicy    *QuestPolicy
	reviewsPolicy  *ReviewsPolicy
	marketPolicy   *MarketPolicy
	path           string
	seats          [7]Seat
	policy         *memba_weighted_policy.Policy
	proposals      []*roleProposal
	// rosters holds every distinct electorate, oldest first. A new entry is
	// appended only when a recovery changes a seat address.
	rosters [][7]address
	// invalidations mirrors the policy generation: one record per Reconfigure.
	invalidations []invalidation
}

// New must run inside the owning realm's init with its own live realm value.
// No realm value is persisted; each mutation requires a fresh live frame.
func New(seats []Seat, rlm realm) *Host {
	if !rlm.IsCurrent() || !strings.HasPrefix(rlm.PkgPath(), "gno.land/r/") {
		panic("host requires its owning live realm")
	}
	members := []memba_weighted_policy.Member{}
	admins := 0
	for _, seat := range seats {
		members = append(members, seat.Member)
		if seat.Admin {
			admins++
		}
	}
	policy := memba_weighted_policy.New(members)
	if admins == 0 {
		panic("host requires an admin")
	}
	h := &Host{path: rlm.PkgPath(), policy: policy}
	for i, seat := range seats {
		h.seats[i] = seat
	}
	h.snapshotRoster()
	return h
}

func (h *Host) snapshotRoster() {
	var roster [7]address
	for i, seat := range h.seats {
		roster[i] = seat.Member.Address
	}
	h.rosters = append(h.rosters, roster)
}

// addProposal freezes the current electorate on the proposal and stores it.
// Every Propose* path goes through here, so ballots always have a snapshot.
func (h *Host) addProposal(p *roleProposal) {
	p.roster = len(h.rosters) - 1
	p.epoch = len(h.invalidations)
	h.proposals = append(h.proposals, p)
}

// recordInvalidation must follow every policy Reconfigure. It records why the
// open proposals stopped; it never decides which ones stop.
func (h *Host) recordInvalidation(cause string, id uint64, target string) {
	h.invalidations = append(h.invalidations, invalidation{height: runtime.ChainHeight(), at: time.Now(), cause: cause, proposal: id, target: target})
}

// ballotsQualified recomputes the policy threshold from the mirrored ballots.
// Ballots cannot change after a proposal closes or is invalidated, so this is
// the qualification the proposal had at that moment.
func (h *Host) ballotsQualified(p *roleProposal, category memba_weighted_policy.Category) bool {
	weight, people, developers := 0, 0, 0
	for i, vote := range p.choices {
		if vote != memba_weighted_policy.Yes {
			continue
		}
		people++
		weight++
		if h.seats[i].Member.Founder {
			weight++
		} else {
			developers++
		}
	}
	switch category {
	case memba_weighted_policy.Routine:
		return weight >= 3 && people >= 2
	case memba_weighted_policy.Financial:
		return weight >= 5 && people >= 3
	default:
		return weight >= 6 && people >= 4 || developers >= 5
	}
}

func (h *Host) memberIndex(who address) int {
	for i, seat := range h.seats {
		if seat.Member.Address == who {
			return i
		}
	}
	return -1
}

// Require both the owning path and its currently executing frame. A callee
// holding a previous DAO frame may not donate it back for authentication.
func assertCaller(h *Host, rlm realm) address {
	if rlm.PkgPath() != h.path || !rlm.IsCurrent() {
		panic("host realm mismatch")
	}
	who := rlm.Previous().Address()
	if !who.IsValid() || h.memberIndex(who) < 0 {
		panic("caller is not a member")
	}
	return who
}

func (h *Host) HasRole(who address, role Role) bool {
	i := h.memberIndex(who)
	if i < 0 {
		return false
	}
	switch role {
	case Admin:
		return h.seats[i].Admin
	case Finance:
		return h.seats[i].Finance
	default:
		return false
	}
}

func (h *Host) validateRoleChange(target address, role Role, grant bool) {
	if h.memberIndex(target) < 0 {
		panic("role target is not a member")
	}
	if role != Admin && role != Finance {
		panic("unsupported role")
	}
	if h.HasRole(target, role) == grant {
		panic("role change is a no-op")
	}
	if role == Admin && !grant {
		admins := 0
		for _, seat := range h.seats {
			if seat.Admin {
				admins++
			}
		}
		if admins <= 1 {
			panic("cannot remove last admin")
		}
	}
}

// Every role change is critical. The proposer cannot select a lower category,
// inject a callback or substitute the target/role/grant after voting begins.
func (h *Host) ProposeRole(target address, role Role, grant bool, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateRoleChange(target, role, grant)
	p := &roleProposal{proposer: who, target: target, role: role, grant: grant}
	p.ballot = h.policy.NewProposal(memba_weighted_policy.Critical, actionBytes(p))
	h.addProposal(p)
	return uint64(len(h.proposals))
}

// Recovery replaces one person's key, never their identity, weight or roles.
func (h *Host) validateRecovery(personID string, target, replacement address) {
	i := h.memberIndex(target)
	if i < 0 || h.seats[i].Member.PersonID != personID {
		panic("recovery seat does not match")
	}
	if !replacement.IsValid() || h.memberIndex(replacement) >= 0 {
		panic("replacement must be a valid unused address")
	}
}

func (h *Host) ProposeRecovery(personID string, target, replacement address, rlm realm) uint64 {
	who := assertCaller(h, rlm)
	h.validateRecovery(personID, target, replacement)
	p := &roleProposal{proposer: who, recovery: true, personID: personID, target: target, replacement: replacement}
	p.ballot = h.policy.NewProposal(memba_weighted_policy.Critical, actionBytes(p))
	h.addProposal(p)
	return uint64(len(h.proposals))
}

func actionBytes(p *roleProposal) string {
	if p.recovery {
		// Length-prefix the unrestricted human ID to make the commitment unambiguous.
		return "recover/v1|" + strconv.Itoa(len(p.personID)) + ":" + p.personID + "|" + string(p.target) + "|" + string(p.replacement)
	}
	// Address and role domains are validated and contain no delimiter.
	return "role/v1|" + string(p.target) + "|" + string(p.role) + "|" + strconv.FormatBool(p.grant)
}

func (h *Host) proposal(id uint64) *roleProposal {
	if id == 0 || id > uint64(len(h.proposals)) {
		panic("proposal not found")
	}
	return h.proposals[id-1]
}

func (h *Host) Vote(id uint64, vote memba_weighted_policy.Vote, rlm realm) {
	who := assertCaller(h, rlm)
	p := h.proposal(id)
	p.ballot.Vote(who, vote)
	// The policy accepted the ballot, so the proposal is active and its frozen
	// electorate is the current roster. A repeated identical ballot is a no-op
	// in the policy and keeps its original height here.
	i := rosterIndex(h.rosters[p.roster], who)
	if i < 0 {
		panic("voter is not in the proposal electorate")
	}
	if p.choices[i] != vote {
		p.choices[i] = vote
		p.votedAt[i] = runtime.ChainHeight()
	}
}

func rosterIndex(roster [7]address, who address) int {
	for i, a := range roster {
		if a == who {
			return i
		}
	}
	return -1
}

func (h *Host) Execute(id uint64, rlm realm) {
	assertCaller(h, rlm)
	p := h.proposal(id)
	if p.feedback != nil {
		panic("feedback action requires target adapter")
	}
	if p.channels != nil {
		panic("channels action requires target adapter")
	}
	if p.feed != nil {
		panic("feed action requires target adapter")
	}
	if p.badges != nil {
		panic("badges action requires target adapter")
	}
	if p.escrow != nil {
		panic("escrow action requires target adapter")
	}
	if p.appstore != nil {
		panic("appstore action requires target adapter")
	}
	if p.arcade != nil {
		panic("arcade action requires target adapter")
	}
	if p.quest != nil {
		panic("quest action requires target adapter")
	}
	if p.reviews != nil {
		panic("reviews action requires target adapter")
	}
	if p.market != nil {
		panic("market action requires target adapter")
	}
	if p.recovery {
		h.validateRecovery(p.personID, p.target, p.replacement)
	} else {
		h.validateRoleChange(p.target, p.role, p.grant)
	}
	p.ballot.Consume(actionBytes(p))
	i := h.memberIndex(p.target)
	if p.recovery {
		h.seats[i].Member.Address = p.replacement
		h.snapshotRoster()
	} else if p.role == Admin {
		h.seats[i].Admin = p.grant
	} else {
		h.seats[i].Finance = p.grant
	}
	// Any changed authority invalidates all outstanding authorizations. Roles
	// do not alter the approved weights or the independent developer route.
	members := []memba_weighted_policy.Member{}
	for _, seat := range h.seats {
		members = append(members, seat.Member)
	}
	h.policy.Reconfigure(members)
	h.recordInvalidation(InvalidatedByExecution, id, "")
}

// Views contain copied values only, never pointers to policy, ballots or seats.
type ProposalView struct {
	Feedback       bool
	FeedbackAction FeedbackAction
	FeedbackBefore FeedbackState
	Channels       bool
	ChannelsAction ChannelsAction
	ChannelsBefore ChannelsState
	Feed           bool
	FeedAction     FeedAction
	FeedBefore     FeedState
	Badges         bool
	BadgesAction   BadgesAction
	BadgesBefore   BadgesState
	Escrow         bool
	EscrowAction   EscrowAction
	EscrowBefore   EscrowState
	Appstore       bool
	AppstoreAction AppstoreAction
	AppstoreBefore AppstoreState
	Arcade         bool
	ArcadeAction   ArcadeAction
	ArcadeBefore   ArcadeState
	Quest          bool
	QuestAction    QuestAction
	QuestBefore    QuestState
	Reviews        bool
	ReviewsAction  ReviewsAction
	ReviewsBefore  ReviewsState
	Market         bool
	MarketAction   MarketAction
	MarketBefore   MarketState
	Recovery       bool
	PersonID       string
	Replacement    address
	ID             uint64
	Proposer       address
	Target         address
	Role           Role
	Grant          bool
	State          memba_weighted_policy.State
	// Invalidation is set only for an INVALIDATED proposal. A proposal whose
	// vote had already closed without qualifying stays EXPIRED instead.
	Invalidated          bool
	InvalidationCause    string
	InvalidationHeight   int64
	InvalidationProposal uint64
	InvalidationTarget   string
	ExpiredBeforeInvalidation bool
}

func (h *Host) Proposal(id uint64) ProposalView {
	v := h.proposalView(id)
	p := h.proposal(id)
	s := v.State
	if s.Invalidated && !s.Consumed && p.epoch < len(h.invalidations) {
		rec := h.invalidations[p.epoch]
		if !rec.at.Before(s.VotingDeadline) && !h.ballotsQualified(p, s.Category) {
			v.ExpiredBeforeInvalidation = true
		} else {
			v.Invalidated = true
			v.InvalidationCause = rec.cause
			v.InvalidationHeight = rec.height
			v.InvalidationProposal = rec.proposal
			v.InvalidationTarget = rec.target
		}
	}
	return v
}

func (h *Host) proposalView(id uint64) ProposalView {
	p := h.proposal(id)
	if p.feedback != nil {
		return ProposalView{Feedback: true, FeedbackAction: p.feedback.action, FeedbackBefore: p.feedback.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.channels != nil {
		return ProposalView{Channels: true, ChannelsAction: p.channels.action, ChannelsBefore: p.channels.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.feed != nil {
		return ProposalView{Feed: true, FeedAction: p.feed.action, FeedBefore: p.feed.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.badges != nil {
		return ProposalView{Badges: true, BadgesAction: p.badges.action, BadgesBefore: p.badges.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.escrow != nil {
		return ProposalView{Escrow: true, EscrowAction: p.escrow.action, EscrowBefore: p.escrow.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.appstore != nil {
		return ProposalView{Appstore: true, AppstoreAction: p.appstore.action, AppstoreBefore: p.appstore.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.arcade != nil {
		return ProposalView{Arcade: true, ArcadeAction: p.arcade.action, ArcadeBefore: p.arcade.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.quest != nil {
		return ProposalView{Quest: true, QuestAction: p.quest.action, QuestBefore: p.quest.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.reviews != nil {
		return ProposalView{Reviews: true, ReviewsAction: p.reviews.action, ReviewsBefore: p.reviews.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	if p.market != nil {
		return ProposalView{Market: true, MarketAction: p.market.action, MarketBefore: p.market.before, ID: id, Proposer: p.proposer, State: p.ballot.State()}
	}
	return ProposalView{Recovery: p.recovery, PersonID: p.personID, Replacement: p.replacement, ID: id, Proposer: p.proposer, Target: p.target, Role: p.role, Grant: p.grant, State: p.ballot.State()}
}

func (h *Host) Members() []Seat {
	out := []Seat{}
	for _, seat := range h.seats {
		out = append(out, seat)
	}
	return out
}

func (h *Host) ProposalCount() uint64 { return uint64(len(h.proposals)) }
