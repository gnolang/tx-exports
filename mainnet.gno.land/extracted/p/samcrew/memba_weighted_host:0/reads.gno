package memba_weighted_host

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/samcrew/memba_weighted_policy"
)

const ReadSchema = "memba-weighted-host/v2"
const MaxProposalPage = 50

func (h *Host) readSchema() string {
	if h.feedbackPolicy != nil {
		return "memba-weighted-host/v12"
	}
	if h.channelsPolicy != nil {
		return "memba-weighted-host/v11"
	}
	if h.feedPolicy != nil {
		return "memba-weighted-host/v10"
	}
	if h.badgesPolicy != nil {
		return "memba-weighted-host/v9"
	}
	if h.escrowPolicy != nil {
		return "memba-weighted-host/v8"
	}
	if h.appstorePolicy != nil {
		return "memba-weighted-host/v7"
	}
	if h.arcadePolicy != nil {
		return "memba-weighted-host/v6"
	}
	if h.questPolicy != nil {
		return "memba-weighted-host/v5"
	}
	if h.reviewsPolicy != nil {
		return "memba-weighted-host/v4"
	}
	if h.marketPolicy != nil {
		return "memba-weighted-host/v3"
	}
	return ReadSchema
}

func (h *Host) marketConfigJSON() string {
	if h.marketPolicy == nil {
		return ""
	}
	return `,"marketPolicy":{"target":` + quoteJSON(MarketConfigPath) + `,"treasury":` + quoteJSON(string(h.marketPolicy.Treasury())) + `,"successor":` + quoteJSON(string(h.marketPolicy.Successor())) + `,"feeCategory":"financial","treasuryCategory":"financial","returnStagesOnly":true,"invalidatesOtherProposals":true}`
}

// JSON strings use JSON escapes, not Go's \xNN/\a/\v escapes. Invalid UTF-8
// decodes as U+FFFD, matching JSON's Unicode string domain.
func quoteJSON(value string) string {
	var b strings.Builder
	b.WriteByte('"')
	const hex = "0123456789abcdef"
	for _, r := range value {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		default:
			if r < 0x20 {
				b.WriteString(`\u00`)
				b.WriteByte(hex[byte(r)>>4])
				b.WriteByte(hex[byte(r)&15])
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func timestampJSON(value time.Time) string {
	if value.IsZero() {
		return "null"
	}
	return quoteJSON(value.UTC().Format(time.RFC3339Nano))
}

// ConfigJSON describes only implemented host capabilities. Fixed founding
// thresholds are not configurable through a role action. Operational role labels
// have no additional vote or execution privilege.
func (h *Host) ConfigJSON() string {
	return `{"schema":` + quoteJSON(h.readSchema()) + `,"kind":"config","realmPath":` + quoteJSON(h.path) + `,"rosterSize":7,"totalPoints":8,"founderWeight":2,"developerWeight":1,"votingPeriodSeconds":604800,"roleChanges":{"category":"critical","weightedPoints":6,"weightedPeople":4,"weightedDelaySeconds":86400,"independentDevelopers":5,"independentDelaySeconds":259200},"mutableRoles":["admin","finance"],"capabilities":{"roleProposals":true,"memberReplacement":true,"migration":false,"treasuryExecution":false,"applicationActions":` + strconv.FormatBool(h.marketPolicy != nil || h.reviewsPolicy != nil || h.questPolicy != nil || h.arcadePolicy != nil || h.appstorePolicy != nil || h.escrowPolicy != nil || h.badgesPolicy != nil || h.feedPolicy != nil || h.channelsPolicy != nil || h.feedbackPolicy != nil) + `},"maxProposalPage":50` + h.marketConfigJSON() + h.reviewsConfigJSON() + h.questConfigJSON() + h.arcadeConfigJSON() + h.appstoreConfigJSON() + h.escrowConfigJSON() + h.badgesConfigJSON() + h.feedConfigJSON() + h.channelsConfigJSON() + h.feedbackConfigJSON() + `}`
}

func (h *Host) MembersJSON() string {
	var b strings.Builder
	b.WriteString(`{"schema":` + quoteJSON(h.readSchema()) + `,"kind":"members","members":[`)
	for i, seat := range h.seats {
		if i > 0 {
			b.WriteByte(',')
		}
		weight := 1
		if seat.Member.Founder {
			weight = 2
		}
		b.WriteString(`{"personId":` + quoteJSON(seat.Member.PersonID) + `,"address":` + quoteJSON(string(seat.Member.Address)) + `,"founder":` + strconv.FormatBool(seat.Member.Founder) + `,"weight":` + strconv.Itoa(weight) + `,"admin":` + strconv.FormatBool(seat.Admin) + `,"finance":` + strconv.FormatBool(seat.Finance) + `}`)
	}
	b.WriteString(`]}`)
	return b.String()
}

func status(s memba_weighted_policy.State) string {
	// Successful role execution also advances the configuration generation.
	// Consumed therefore takes precedence over subsequent invalidation.
	if s.Consumed {
		return "EXECUTED"
	}
	if s.Invalidated {
		return "INVALIDATED"
	}
	if s.Expired {
		return "EXPIRED"
	}
	if s.Ready {
		return "READY"
	}
	if s.Qualified {
		return "TIMELOCKED"
	}
	return "VOTING"
}

// viewStatus keeps EXPIRED sticky: a proposal whose voting closed without
// qualifying reports EXPIRED even after a later reconfiguration.
func viewStatus(v ProposalView) string {
	if !v.State.Consumed && v.ExpiredBeforeInvalidation {
		return "EXPIRED"
	}
	return status(v.State)
}

// invalidationJSON is null unless the status is INVALIDATED. cause is
// "superseded-execution" (proposalId is the executed proposal) or "pause"
// (proposalId is null). target is the application realm, or null for a
// role or recovery execution.
func invalidationJSON(v ProposalView) string {
	if !v.Invalidated {
		return "null"
	}
	id, target := "null", "null"
	if v.InvalidationProposal != 0 {
		id = quoteJSON(strconv.FormatUint(v.InvalidationProposal, 10))
	}
	if v.InvalidationTarget != "" {
		target = quoteJSON(v.InvalidationTarget)
	}
	return `{"cause":` + quoteJSON(v.InvalidationCause) + `,"height":` + quoteJSON(strconv.FormatInt(v.InvalidationHeight, 10)) + `,"proposalId":` + id + `,"target":` + target + `}`
}

// Terminal policy states clear current tallies; they are not evidence of zero
// historical votes. Do not invent a receipt the host did not retain.
func tallyJSON(n int, s memba_weighted_policy.State) string {
	if s.Consumed || s.Invalidated {
		return "null"
	}
	return strconv.Itoa(n)
}

func proposalActionJSON(v ProposalView) string {
	if v.Feedback {
		return feedbackActionJSON(v.FeedbackAction, v.FeedbackBefore)
	}
	if v.Channels {
		return channelsActionJSON(v.ChannelsAction, v.ChannelsBefore)
	}
	if v.Feed {
		return feedActionJSON(v.FeedAction, v.FeedBefore)
	}
	if v.Badges {
		return badgesActionJSON(v.BadgesAction, v.BadgesBefore)
	}
	if v.Escrow {
		return escrowActionJSON(v.EscrowAction, v.EscrowBefore)
	}
	if v.Appstore {
		return appstoreActionJSON(v.AppstoreAction, v.AppstoreBefore)
	}
	if v.Arcade {
		return arcadeActionJSON(v.ArcadeAction, v.ArcadeBefore)
	}
	if v.Quest {
		return questActionJSON(v.QuestAction, v.QuestBefore)
	}
	if v.Reviews {
		return reviewsActionJSON(v.ReviewsAction, v.ReviewsBefore)
	}
	if v.Market {
		a := v.MarketAction
		b := v.MarketBefore
		return `{"type":"market-config","target":` + quoteJSON(MarketConfigPath) + `,"operation":` + quoteJSON(string(a.Kind())) + `,"lane":` + quoteJSON(string(a.Lane())) + `,"bps":` + quoteJSON(strconv.FormatInt(a.BPS(), 10)) + `,"recipient":` + quoteJSON(string(a.Recipient())) + `,"before":{"admin":` + quoteJSON(string(b.Admin)) + `,"pendingAdmin":` + quoteJSON(string(b.PendingAdmin)) + `,"treasury":` + quoteJSON(string(b.Treasury)) + `,"bps":` + quoteJSON(strconv.FormatInt(b.BPS, 10)) + `}}`
	}
	if v.Recovery {
		return `{"type":"recover-member","personId":` + quoteJSON(v.PersonID) + `,"oldAddress":` + quoteJSON(string(v.Target)) + `,"newAddress":` + quoteJSON(string(v.Replacement)) + `}`
	}
	return `{"type":"set-role","target":` + quoteJSON(string(v.Target)) + `,"role":` + quoteJSON(string(v.Role)) + `,"grant":` + strconv.FormatBool(v.Grant) + `}`
}

func proposalJSON(v ProposalView) string {
	s := v.State
	return `{"id":` + quoteJSON(strconv.FormatUint(v.ID, 10)) + `,"proposer":` + quoteJSON(string(v.Proposer)) + `,"action":` + proposalActionJSON(v) + `,"category":` + quoteJSON(string(s.Category)) + `,"status":` + quoteJSON(viewStatus(v)) + `,"qualified":` + strconv.FormatBool(s.Qualified) + `,"ready":` + strconv.FormatBool(s.Ready) + `,"votingClosed":` + strconv.FormatBool(s.VotingClosed) + `,"talliesAvailable":` + strconv.FormatBool(!s.Consumed && !s.Invalidated) + `,"weightYes":` + tallyJSON(s.WeightYes, s) + `,"peopleYes":` + tallyJSON(s.PeopleYes, s) + `,"developersYes":` + tallyJSON(s.DevelopersYes, s) + `,"createdAt":` + timestampJSON(s.CreatedAt) + `,"votingDeadline":` + timestampJSON(s.VotingDeadline) + `,"weightedAfter":` + timestampJSON(s.WeightedAfter) + `,"developerAfter":` + timestampJSON(s.DeveloperAfter) + `,"invalidation":` + invalidationJSON(v) + `}`
}

func (h *Host) ProposalJSON(id uint64) string {
	return `{"schema":` + quoteJSON(h.readSchema()) + `,"kind":"proposal","proposal":` + proposalJSON(h.Proposal(id)) + `}`
}

// ProposalsJSON uses an exclusive descending ID cursor. before=0 means newest;
// a returned nextBefore remains stable when newer proposals are appended.
// IDs/cursors/counts are decimal strings so uint64 values never lose precision
// in a JavaScript client. A null cursor ends pagination, not an empty page guess.
func (h *Host) ProposalsJSON(before uint64, limit int) string {
	if limit < 1 || limit > MaxProposalPage {
		panic("invalid proposal page size")
	}
	count := h.ProposalCount()
	if before > count {
		panic("invalid proposal cursor")
	}
	id := count
	if before > 0 {
		id = before - 1
	}
	var b strings.Builder
	b.WriteString(`{"schema":` + quoteJSON(h.readSchema()) + `,"kind":"proposals","total":` + quoteJSON(strconv.FormatUint(count, 10)) + `,"proposals":[`)
	n := 0
	last := uint64(0)
	for id > 0 && n < limit {
		if n > 0 {
			b.WriteByte(',')
		}
		b.WriteString(proposalJSON(h.Proposal(id)))
		last = id
		id--
		n++
	}
	b.WriteString(`],"nextBefore":`)
	if id > 0 {
		b.WriteString(quoteJSON(strconv.FormatUint(last, 10)))
	} else {
		b.WriteString("null")
	}
	b.WriteByte('}')
	return b.String()
}

// Ballot reads. Pending pages hold at most MaxPendingPage proposals, and one
// call examines at most MaxPendingScan proposals before handing back a cursor.
const MaxPendingPage = 50
const MaxPendingScan = 200

// parseDecimalID accepts only canonical unsigned decimal strings, the same
// form every read emits, so one ID has exactly one spelling.
func parseDecimalID(value, what string) uint64 {
	n, err := strconv.ParseUint(value, 10, 64)
	if err != nil || strconv.FormatUint(n, 10) != value {
		panic("invalid " + what)
	}
	return n
}

func ballotChoiceJSON(v memba_weighted_policy.Vote) string {
	if v == "" {
		return "null"
	}
	return quoteJSON(string(v))
}

// BallotJSON reports one address's ballot on one proposal. Eligibility is the
// electorate frozen when the proposal was created, so a recovered key keeps
// its ballot on older proposals and has none on newer ones. choice is "yes",
// "no" or "abstain" (the host's three ballot values), or null with a null
// votedAtHeight when the address has not voted. Ballots stay readable after a
// proposal is executed, invalidated or expired; tallies do not.
func (h *Host) BallotJSON(proposalID string, voter address) string {
	id := parseDecimalID(proposalID, "proposal id")
	p := h.proposal(id)
	i := rosterIndex(h.rosters[p.roster], voter)
	choice, height := "null", "null"
	if i >= 0 && p.choices[i] != "" {
		choice = ballotChoiceJSON(p.choices[i])
		height = quoteJSON(strconv.FormatInt(p.votedAt[i], 10))
	}
	return `{"schema":` + quoteJSON(h.readSchema()) + `,"proposalId":` + quoteJSON(strconv.FormatUint(id, 10)) + `,"voter":` + quoteJSON(string(voter)) + `,"eligible":` + strconv.FormatBool(i >= 0) + `,"choice":` + choice + `,"votedAtHeight":` + height + `}`
}

// PendingVotesJSON lists, newest first, the proposals that are still open for
// voting where voter is in the frozen electorate and has not voted. before is
// an exclusive decimal cursor ("" or "0" for newest); limit is clamped to
// 1..MaxPendingPage. Executing any action invalidates every older open
// proposal, and deadlines follow creation order, so the scan stops at the first
// proposal that no longer accepts votes: nothing older can be pending. The
// scan also stops after MaxPendingScan proposals; next then resumes it. next
// is null when nothing older can be pending.
func (h *Host) PendingVotesJSON(voter address, before string, limit int) string {
	if limit < 1 {
		limit = 1
	}
	if limit > MaxPendingPage {
		limit = MaxPendingPage
	}
	count := h.ProposalCount()
	id := count
	if before != "" && before != "0" {
		cursor := parseDecimalID(before, "proposal cursor")
		if cursor > count {
			panic("invalid proposal cursor")
		}
		id = cursor - 1
	}
	var b strings.Builder
	b.WriteString(`{"schema":` + quoteJSON(h.readSchema()) + `,"voter":` + quoteJSON(string(voter)) + `,"items":[`)
	n, scanned, closed := 0, 0, false
	for id > 0 && n < limit && scanned < MaxPendingScan {
		p := h.proposals[id-1]
		s := p.ballot.State()
		if s.Consumed || s.Invalidated || s.VotingClosed {
			closed = true
			break
		}
		scanned++
		i := rosterIndex(h.rosters[p.roster], voter)
		if i >= 0 && p.choices[i] == "" {
			if n > 0 {
				b.WriteByte(',')
			}
			b.WriteString(proposalJSON(h.Proposal(id)))
			n++
		}
		id--
	}
	b.WriteString(`],"next":`)
	if closed || id == 0 {
		b.WriteString("null")
	} else {
		b.WriteString(quoteJSON(strconv.FormatUint(id+1, 10)))
	}
	b.WriteByte('}')
	return b.String()
}
