// Package bountyquorum implements an on-chain milestone escrow and
// quorum-verified bounty board for DAOs, grants, and agent/builder quests.
//
// Security design:
//   - All ugnot funding entry points require a direct EOA user call
//     (cur.Previous().IsUserCall()) before reading unsafe.OriginSend(),
//     eliminating phantom OriginSend draining via intermediary realms.
//   - Milestone weights are denominated in basis points (sum <= 10000).
//     The final milestone covering 100% receives exact remainingEscrow,
//     guaranteeing zero integer-division dust is ever stranded.
//   - Double-voting is prevented per (milestone, submissionRound, reviewer).
//   - Rejected milestones cleanly reset into an iterative resubmission cycle.
//   - Sponsors can safely reclaim unspent escrow only after the deadline,
//     or cancel before any milestone has been paid out.
package bountyquorum

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1yf6p3wr7lame69dqx6savrskkpu7qgalsxe5qd/quorummath"
)

const (
	// StatusOpen means the quest is actively accepting submissions and reviews.
	StatusOpen = "OPEN"
	// StatusCompleted means all escrow has been paid out to builders.
	StatusCompleted = "COMPLETED"
	// StatusReclaimed means unspent escrow was reclaimed after expiry.
	StatusReclaimed = "RECLAIMED"
	// StatusCancelled means the quest was cancelled before any payout.
	StatusCancelled = "CANCELLED"

	// MilestonePending means no submission is awaiting review yet.
	MilestonePending = "PENDING"
	// MilestoneSubmitted means a builder deliverable is currently under quorum review.
	MilestoneSubmitted = "SUBMITTED"
	// MilestoneRejected means reviewers could no longer reach quorum; open for resubmission.
	MilestoneRejected = "REJECTED"
	// MilestonePaid means approval quorum was reached and ugnot was transferred to the builder.
	MilestonePaid = "PAID"
)

// ReviewRecord logs an individual reviewer's vote on a milestone submission round.
type ReviewRecord struct {
	Round    int
	Reviewer address
	Approve  bool
	Comment  string
	At       time.Time
}

// Milestone represents a single weighted deliverable within a Quest.
type Milestone struct {
	Label          string
	WeightBps      int
	Status         string
	Round          int
	Builder        address
	DeliverableURL string
	ProofHash      string
	Notes          string
	Approvals      int
	Rejections     int
	PaidAmount     int64
	PaidAt         time.Time
	VotedInRound   map[string]bool // "<round>:<reviewer>" -> voted
	History        []*ReviewRecord
}

// Quest represents an escrowed bounty with multiple milestones and a reviewer quorum.
type Quest struct {
	ID              int
	Title           string
	Summary         string
	Sponsor         address
	Reviewers       []address
	ReviewerSet     map[string]bool
	Quorum          int
	TotalEscrow     int64
	RemainingEscrow int64
	PaidOut         int64
	AllocatedBps    int
	PaidBps         int
	Status          string
	CreatedAt       time.Time
	Deadline        time.Time
	Milestones      []*Milestone
}

// BuilderStats tracks cumulative verified earnings per builder address.
type BuilderStats struct {
	Builder         address
	TotalEarned     int64
	MilestonesWon   int
	CompletedQuests []string // "Q#<id> M#<idx>"
}

var (
	quests          []*Quest
	questByID       map[int]*Quest
	builderStatsMap map[string]*BuilderStats
	builderList     []*BuilderStats
	nextQuestID     int
	totalEscrowed   int64
	totalDisbursed  int64
)

func init() {
	resetState()
}

func resetState() {
	quests = make([]*Quest, 0)
	questByID = make(map[int]*Quest)
	builderStatsMap = make(map[string]*BuilderStats)
	builderList = make([]*BuilderStats, 0)
	nextQuestID = 1
	totalEscrowed = 0
	totalDisbursed = 0
}

func mustUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls (maketx call) are accepted")
	}
	return cur.Previous().Address()
}

func mustOriginUGNOT() int64 {
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		panic("must send ugnot to fund escrow")
	}
	amount := sent.AmountOf("ugnot")
	if amount <= 0 || len(sent) != 1 {
		panic("escrow accepts strictly positive ugnot only")
	}
	return amount
}

func sendEscrowUGNOT(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{{Denom: "ugnot", Amount: amount}})
}

func mustGetQuest(questID int) *Quest {
	q, ok := questByID[questID]
	if !ok {
		panic("quest not found: " + strconv.Itoa(questID))
	}
	return q
}

// CreateQuest locks sent ugnot in escrow and creates a new quorum-verified bounty quest.
// Returns the new quest ID.
func CreateQuest(
	cur realm,
	title string,
	summary string,
	reviewersCSV string,
	quorum int,
	durationHours int64,
) int {
	sponsor := mustUserCall(cur)
	amount := mustOriginUGNOT()

	title = strings.TrimSpace(title)
	summary = strings.TrimSpace(summary)
	if title == "" {
		panic("quest title cannot be empty")
	}
	if durationHours <= 0 {
		panic("durationHours must be positive")
	}

	reviewers, errMsg := quorummath.ParseCSVAddresses(reviewersCSV)
	if errMsg != "" {
		panic(errMsg)
	}
	if qErr := quorummath.ValidateQuorum(len(reviewers), quorum); qErr != "" {
		panic(qErr)
	}

	revSet := make(map[string]bool)
	for _, r := range reviewers {
		revSet[r.String()] = true
	}

	now := time.Now()
	id := nextQuestID
	nextQuestID++

	q := &Quest{
		ID:              id,
		Title:           title,
		Summary:         summary,
		Sponsor:         sponsor,
		Reviewers:       reviewers,
		ReviewerSet:     revSet,
		Quorum:          quorum,
		TotalEscrow:     amount,
		RemainingEscrow: amount,
		Status:          StatusOpen,
		CreatedAt:       now,
		Deadline:        now.Add(time.Duration(durationHours) * time.Hour),
		Milestones:      make([]*Milestone, 0),
	}

	quests = append(quests, q)
	questByID[id] = q
	totalEscrowed += amount

	chain.Emit(
		"QuestCreated",
		"quest_id", strconv.Itoa(id),
		"sponsor", sponsor.String(),
		"escrow_ugnot", strconv.FormatInt(amount, 10),
		"quorum", strconv.Itoa(quorum),
	)
	return id
}

// TopUpQuest lets any sponsor or community contributor add more ugnot into an open quest.
func TopUpQuest(cur realm, questID int) {
	contributor := mustUserCall(cur)
	amount := mustOriginUGNOT()

	q := mustGetQuest(questID)
	if q.Status != StatusOpen {
		panic("can only top up an open quest")
	}
	if time.Now().After(q.Deadline) {
		panic("quest deadline has already passed")
	}

	q.TotalEscrow += amount
	q.RemainingEscrow += amount
	totalEscrowed += amount

	chain.Emit(
		"QuestToppedUp",
		"quest_id", strconv.Itoa(questID),
		"contributor", contributor.String(),
		"added_ugnot", strconv.FormatInt(amount, 10),
	)
}

// AddMilestone defines a weighted deliverable milestone for an open quest.
// Only the quest sponsor can add milestones, and total weights cannot exceed 10000 bps (100%).
func AddMilestone(cur realm, questID int, label string, weightBps int) int {
	caller := cur.Previous().Address()
	q := mustGetQuest(questID)

	if caller != q.Sponsor {
		panic("only the quest sponsor can add milestones")
	}
	if q.Status != StatusOpen {
		panic("quest is not open")
	}
	label = strings.TrimSpace(label)
	if label == "" {
		panic("milestone label cannot be empty")
	}
	if weightBps <= 0 || q.AllocatedBps+weightBps > quorummath.MaxBps {
		panic("milestone weightBps invalid or exceeds 10000 bps total")
	}

	m := &Milestone{
		Label:        label,
		WeightBps:    weightBps,
		Status:       MilestonePending,
		VotedInRound: make(map[string]bool),
		History:      make([]*ReviewRecord, 0),
	}
	q.Milestones = append(q.Milestones, m)
	q.AllocatedBps += weightBps

	idx := len(q.Milestones) - 1
	chain.Emit(
		"MilestoneAdded",
		"quest_id", strconv.Itoa(questID),
		"milestone_idx", strconv.Itoa(idx),
		"weight_bps", strconv.Itoa(weightBps),
	)
	return idx
}

// SubmitDeliverable submits (or resubmits after rejection) a builder's proof of work for a milestone.
func SubmitDeliverable(
	cur realm,
	questID int,
	milestoneIdx int,
	deliverableURL string,
	proofHash string,
	notes string,
) {
	builder := cur.Previous().Address()
	q := mustGetQuest(questID)

	if q.Status != StatusOpen {
		panic("quest is not open")
	}
	if time.Now().After(q.Deadline) {
		panic("quest deadline has passed")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(q.Milestones) {
		panic("milestone index out of range")
	}

	m := q.Milestones[milestoneIdx]
	if m.Status == MilestonePaid {
		panic("milestone is already paid")
	}
	if m.Status == MilestoneSubmitted {
		panic("milestone already has a submission under active review")
	}

	deliverableURL = strings.TrimSpace(deliverableURL)
	if deliverableURL == "" {
		panic("deliverableURL cannot be empty")
	}

	m.Round++
	m.Builder = builder
	m.DeliverableURL = deliverableURL
	m.ProofHash = strings.TrimSpace(proofHash)
	m.Notes = strings.TrimSpace(notes)
	m.Approvals = 0
	m.Rejections = 0
	m.Status = MilestoneSubmitted

	chain.Emit(
		"DeliverableSubmitted",
		"quest_id", strconv.Itoa(questID),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"round", strconv.Itoa(m.Round),
		"builder", builder.String(),
	)
}

// ReviewMilestone records a designated reviewer's approve/reject vote for the current submission round.
// Automatically releases escrowed ugnot to the builder the moment approval quorum is reached.
func ReviewMilestone(
	cur realm,
	questID int,
	milestoneIdx int,
	approve bool,
	comment string,
) string {
	reviewer := cur.Previous().Address()
	q := mustGetQuest(questID)

	if q.Status != StatusOpen {
		panic("quest is not open")
	}
	if !q.ReviewerSet[reviewer.String()] {
		panic("caller is not a designated reviewer for this quest")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(q.Milestones) {
		panic("milestone index out of range")
	}

	m := q.Milestones[milestoneIdx]
	if m.Status != MilestoneSubmitted {
		panic("milestone is not awaiting review")
	}
	if reviewer == m.Builder {
		panic("builder cannot review their own deliverable")
	}

	voteKey := strconv.Itoa(m.Round) + ":" + reviewer.String()
	if m.VotedInRound[voteKey] {
		panic("reviewer has already voted in this submission round")
	}
	m.VotedInRound[voteKey] = true

	if approve {
		m.Approvals++
	} else {
		m.Rejections++
	}

	m.History = append(m.History, &ReviewRecord{
		Round:    m.Round,
		Reviewer: reviewer,
		Approve:  approve,
		Comment:  strings.TrimSpace(comment),
		At:       time.Now(),
	})

	outcome := quorummath.QuorumOutcome(len(q.Reviewers), q.Quorum, m.Approvals, m.Rejections)
	if outcome == "approved" {
		isFinalFull := (q.AllocatedBps == quorummath.MaxBps) && (q.PaidBps+m.WeightBps == quorummath.MaxBps)
		payout := quorummath.ComputeMilestonePayout(q.TotalEscrow, q.RemainingEscrow, m.WeightBps, isFinalFull)

		m.Status = MilestonePaid
		m.PaidAmount = payout
		m.PaidAt = time.Now()

		q.RemainingEscrow -= payout
		q.PaidOut += payout
		q.PaidBps += m.WeightBps
		totalDisbursed += payout

		if q.RemainingEscrow == 0 || q.PaidBps >= quorummath.MaxBps {
			q.Status = StatusCompleted
		}

		recordBuilderWin(m.Builder, payout, q.ID, milestoneIdx)
		sendEscrowUGNOT(cur, m.Builder, payout)

		chain.Emit(
			"MilestonePaid",
			"quest_id", strconv.Itoa(questID),
			"milestone_idx", strconv.Itoa(milestoneIdx),
			"builder", m.Builder.String(),
			"payout_ugnot", strconv.FormatInt(payout, 10),
		)
	} else if outcome == "rejected" {
		m.Status = MilestoneRejected
		chain.Emit(
			"MilestoneRejected",
			"quest_id", strconv.Itoa(questID),
			"milestone_idx", strconv.Itoa(milestoneIdx),
			"round", strconv.Itoa(m.Round),
		)
	}
	return outcome
}

func recordBuilderWin(builder address, payout int64, questID, milestoneIdx int) {
	key := builder.String()
	st, ok := builderStatsMap[key]
	if !ok {
		st = &BuilderStats{
			Builder:         builder,
			CompletedQuests: make([]string, 0),
		}
		builderStatsMap[key] = st
		builderList = append(builderList, st)
	}
	st.TotalEarned += payout
	st.MilestonesWon++
	st.CompletedQuests = append(st.CompletedQuests, "Q#"+strconv.Itoa(questID)+" M#"+strconv.Itoa(milestoneIdx))
}

// ReclaimExpired lets the sponsor reclaim any unspent escrow after the quest deadline passes.
func ReclaimExpired(cur realm, questID int) int64 {
	caller := cur.Previous().Address()
	q := mustGetQuest(questID)

	if caller != q.Sponsor {
		panic("only the sponsor can reclaim expired escrow")
	}
	if q.Status != StatusOpen {
		panic("quest is not open")
	}
	if !time.Now().After(q.Deadline) {
		panic("quest deadline has not yet passed")
	}

	refund := q.RemainingEscrow
	q.RemainingEscrow = 0
	q.Status = StatusReclaimed
	sendEscrowUGNOT(cur, q.Sponsor, refund)

	chain.Emit(
		"QuestReclaimed",
		"quest_id", strconv.Itoa(questID),
		"sponsor", q.Sponsor.String(),
		"refund_ugnot", strconv.FormatInt(refund, 10),
	)
	return refund
}

// CancelUnstarted lets the sponsor cancel an open quest and recover 100% of escrow
// only if zero milestones have been paid out.
func CancelUnstarted(cur realm, questID int) int64 {
	caller := cur.Previous().Address()
	q := mustGetQuest(questID)

	if caller != q.Sponsor {
		panic("only the sponsor can cancel the quest")
	}
	if q.Status != StatusOpen {
		panic("quest is not open")
	}
	if q.PaidOut > 0 {
		panic("cannot cancel quest after a milestone has already been paid")
	}

	refund := q.RemainingEscrow
	q.RemainingEscrow = 0
	q.Status = StatusCancelled
	sendEscrowUGNOT(cur, q.Sponsor, refund)

	chain.Emit(
		"QuestCancelled",
		"quest_id", strconv.Itoa(questID),
		"sponsor", q.Sponsor.String(),
		"refund_ugnot", strconv.FormatInt(refund, 10),
	)
	return refund
}

// Render serves a multi-page gnoweb Markdown portal and a machine-readable JSON stats route.
// Routes:
//   - ""              -> Dashboard & Quest Board
//   - "quest/<id>"    -> Quest detail, milestones, deliverables & review audit log
//   - "builder/<addr>"-> Builder earnings & completed milestone history
//   - "stats"         -> JSON metrics for agents and indexers
func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderHome()
	}
	if path == "stats" {
		return renderStatsJSON()
	}
	if strings.HasPrefix(path, "quest/") {
		idStr := strings.TrimPrefix(path, "quest/")
		id, err := strconv.Atoi(idStr)
		if err != nil {
			return "# Invalid Quest ID\n\nExpected `quest/<number>`."
		}
		q, ok := questByID[id]
		if !ok {
			return "# Quest #" + idStr + " Not Found"
		}
		return renderQuest(q)
	}
	if strings.HasPrefix(path, "builder/") {
		addrStr := strings.TrimPrefix(path, "builder/")
		return renderBuilder(addrStr)
	}
	return "# BountyQuorum\n\nUnknown route: `" + path + "`. Try [Home](./) or [Stats](./:stats)."
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# BountyQuorum — On-Chain Milestone Escrow & Quorum Bounty Board\n\n")
	sb.WriteString("Trustless `ugnot` escrow with weighted milestones, multi-reviewer quorum release, and iterative resubmissions.\n\n")

	openCount := 0
	completedCount := 0
	for _, q := range quests {
		if q.Status == StatusOpen {
			openCount++
		} else if q.Status == StatusCompleted {
			completedCount++
		}
	}

	sb.WriteString("## Protocol Metrics\n\n")
	sb.WriteString("| Total Quests | Open | Completed | Total Escrowed | Total Disbursed | Active Builders |\n")
	sb.WriteString("| --- | --- | --- | --- | --- | --- |\n")
	sb.WriteString("| " + strconv.Itoa(len(quests)) +
		" | " + strconv.Itoa(openCount) +
		" | " + strconv.Itoa(completedCount) +
		" | " + quorummath.FormatUGNOT(totalEscrowed) +
		" | " + quorummath.FormatUGNOT(totalDisbursed) +
		" | " + strconv.Itoa(len(builderList)) + " |\n\n")

	sb.WriteString("## Quests\n\n")
	if len(quests) == 0 {
		sb.WriteString("_No quests created yet. Call `CreateQuest` with `-send <amount>ugnot` to fund the first quest!_\n\n")
	} else {
		sb.WriteString("| ID | Title | Status | Escrow | Quorum | Progress | Milestones |\n")
		sb.WriteString("| --- | --- | --- | --- | --- | --- | --- |\n")
		for i := len(quests) - 1; i >= 0; i-- {
			q := quests[i]
			sb.WriteString("| [#" + strconv.Itoa(q.ID) + "](:quest/" + strconv.Itoa(q.ID) + ") | " +
				q.Title + " | `" + q.Status + "` | " +
				quorummath.FormatUGNOT(q.TotalEscrow) + " | " +
				strconv.Itoa(q.Quorum) + "/" + strconv.Itoa(len(q.Reviewers)) + " | " +
				"`" + quorummath.ProgressBar(q.PaidBps, 10) + "` | " +
				strconv.Itoa(len(q.Milestones)) + " |\n")
		}
		sb.WriteString("\n")
	}

	if len(builderList) > 0 {
		sb.WriteString("## Verified Builder Leaderboard\n\n")
		sb.WriteString("| Builder | Milestones Paid | Total Earned |\n")
		sb.WriteString("| --- | --- | --- |\n")
		for _, b := range builderList {
			sb.WriteString("| [" + quorummath.ShortAddr(b.Builder) + "](:builder/" + b.Builder.String() + ") | " +
				strconv.Itoa(b.MilestonesWon) + " | " +
				quorummath.FormatUGNOT(b.TotalEarned) + " |\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("---\n")
	sb.WriteString("Machine-readable feed: [`:stats`](:stats)\n")
	return sb.String()
}

func renderQuest(q *Quest) string {
	var sb strings.Builder
	sb.WriteString("# Quest #" + strconv.Itoa(q.ID) + ": " + q.Title + "\n\n")
	if q.Summary != "" {
		sb.WriteString(q.Summary + "\n\n")
	}
	sb.WriteString("- **Status:** `" + q.Status + "`\n")
	sb.WriteString("- **Sponsor:** `" + q.Sponsor.String() + "`\n")
	sb.WriteString("- **Escrow Pool:** " + quorummath.FormatUGNOT(q.TotalEscrow) +
		" (Remaining: " + quorummath.FormatUGNOT(q.RemainingEscrow) +
		", Paid: " + quorummath.FormatUGNOT(q.PaidOut) + ")\n")
	sb.WriteString("- **Progress:** `" + quorummath.ProgressBar(q.PaidBps, 12) + "` (Allocated: " + strconv.Itoa(q.AllocatedBps/100) + "%)\n")
	sb.WriteString("- **Quorum Rule:** " + strconv.Itoa(q.Quorum) + " of " + strconv.Itoa(len(q.Reviewers)) + " reviewers\n")
	sb.WriteString("- **Deadline (UTC):** `" + q.Deadline.UTC().Format(time.RFC3339) + "`\n\n")

	sb.WriteString("## Reviewers\n\n")
	for _, r := range q.Reviewers {
		sb.WriteString("- `" + r.String() + "`\n")
	}
	sb.WriteString("\n")

	sb.WriteString("## Milestones\n\n")
	if len(q.Milestones) == 0 {
		sb.WriteString("_No milestones configured yet. Sponsor can call `AddMilestone`._\n\n")
	} else {
		sb.WriteString("| # | Milestone | Weight | Status | Votes (A/R) | Builder | Deliverable |\n")
		sb.WriteString("| --- | --- | --- | --- | --- | --- | --- |\n")
		for idx, m := range q.Milestones {
			bStr := "-"
			if m.Builder != "" {
				bStr = "[" + quorummath.ShortAddr(m.Builder) + "](:builder/" + m.Builder.String() + ")"
			}
			dStr := "-"
			if m.DeliverableURL != "" {
				dStr = "[proof](" + m.DeliverableURL + ")"
			}
			sb.WriteString("| " + strconv.Itoa(idx) +
				" | " + m.Label +
				" | " + strconv.Itoa(m.WeightBps/100) + "% (" + strconv.Itoa(m.WeightBps) + " bps)" +
				" | `" + m.Status + "`" +
				" | " + strconv.Itoa(m.Approvals) + "/" + strconv.Itoa(m.Rejections) +
				" | " + bStr +
				" | " + dStr + " |\n")
		}
		sb.WriteString("\n")

		sb.WriteString("## Review Audit Log\n\n")
		hasLogs := false
		for idx, m := range q.Milestones {
			for _, rec := range m.History {
				hasLogs = true
				verdict := "REJECT"
				if rec.Approve {
					verdict = "APPROVE"
				}
				sb.WriteString("- **M#" + strconv.Itoa(idx) + " (Round " + strconv.Itoa(rec.Round) + ")** `" +
					verdict + "` by `" + quorummath.ShortAddr(rec.Reviewer) + "`: " + rec.Comment + "\n")
			}
		}
		if !hasLogs {
			sb.WriteString("_No review votes recorded yet._\n")
		}
	}

	sb.WriteString("\n[Back to BountyQuorum Board](./)\n")
	return sb.String()
}

func renderBuilder(addrStr string) string {
	st, ok := builderStatsMap[addrStr]
	if !ok {
		return "# Builder Profile\n\nNo verified milestone payouts yet for `" + addrStr + "`.\n\n[Back](./)"
	}
	var sb strings.Builder
	sb.WriteString("# Builder Profile: `" + st.Builder.String() + "`\n\n")
	sb.WriteString("- **Total Earned:** " + quorummath.FormatUGNOT(st.TotalEarned) + "\n")
	sb.WriteString("- **Milestones Won:** " + strconv.Itoa(st.MilestonesWon) + "\n\n")
	sb.WriteString("## Completed Milestones\n\n")
	for _, item := range st.CompletedQuests {
		sb.WriteString("- " + item + "\n")
	}
	sb.WriteString("\n[Back to Board](./)\n")
	return sb.String()
}

func renderStatsJSON() string {
	return "{\"quests\":" + strconv.Itoa(len(quests)) +
		",\"builders\":" + strconv.Itoa(len(builderList)) +
		",\"total_escrowed_ugnot\":" + strconv.FormatInt(totalEscrowed, 10) +
		",\"total_disbursed_ugnot\":" + strconv.FormatInt(totalDisbursed, 10) + "}"
}
