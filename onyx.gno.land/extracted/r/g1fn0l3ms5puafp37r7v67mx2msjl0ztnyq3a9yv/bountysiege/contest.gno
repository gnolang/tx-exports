package bountysiege

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"
	"gno.land/r/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/siege_rep"
)

type ContestEntry struct {
	Submitter address
	Proofs    []ProofEntry // append-only so updates never shrink storage
	Claimed   bool         // for Pull-Payment equal split
}

type Contest struct {
	ID                uint64
	Sponsor           address
	Title             string
	Description       string
	Criteria          string
	Category          bs_core.Category
	Reward            int64
	WinnerShares      []int // sums to 100, each >= 5
	CreatedAt         int64
	SubmitDeadline    int64
	JudgingDeadline   int64
	Status            bs_core.ContestStatus
	EscrowHeld        int64
	Entries           []ContestEntry
	entryIdxByAddr    map[address]int
	Winners           []address
	WinnerPayouts     []int64
	LockedArbiter     address
	DisputedAt        int64
	DisputeDeadline   int64
	ResolutionNote    string
	PerSubmitterSplit int64
	ClaimDeadline     int64
	Swept             bool
	Timeline          []TimelineEvent
}

func (c *Contest) addEvent(ts int64, actor address, action, detail string) {
	c.Timeline = append(c.Timeline, TimelineEvent{
		Timestamp: ts,
		Actor:     actor,
		Action:    action,
		Detail:    detail,
	})
}

func (c *Contest) effectiveStatus(now int64) bs_core.ContestStatus {
	if c.Status == bs_core.ContestOpen && now > c.SubmitDeadline && len(c.Entries) > 0 {
		return bs_core.ContestJudging
	}
	return c.Status
}

var (
	nextContestID uint64
	contestsByID  = map[uint64]*Contest{}
	contestIDs    []uint64
)

// CreateContest creates a multi-winner Open Contest and escrows exact `reward` ugnot.
// `sharesCSV` is a comma-separated list of integer percentages summing to 100 (e.g. "50,30,20").
func CreateContest(
	cur realm,
	title, description, criteria string,
	cat uint8,
	reward int64,
	sharesCSV string,
	submitDur, judgingDur int64,
) uint64 {
	requireRolesInitialized()
	requireExactUgnot(reward, cur)

	if err := bs_core.ValidateReward(reward); err != nil {
		panic(err.Error())
	}
	if err := bs_core.ValidateContestDurations(submitDur, judgingDur); err != nil {
		panic(err.Error())
	}
	shares := parseSharesCSV(sharesCSV)
	if err := bs_core.ValidateContestShares(shares); err != nil {
		panic(err.Error())
	}
	category := bs_core.Category(cat)
	if !category.IsValid() {
		panic("invalid skill category")
	}
	if err := bs_core.ValidateText(title, bs_core.MaxTitleBytes, true, false); err != nil {
		panic("invalid title: " + err.Error())
	}
	if err := bs_core.ValidateText(description, bs_core.MaxDescBytes, true, true); err != nil {
		panic("invalid description: " + err.Error())
	}
	if err := bs_core.ValidateText(criteria, bs_core.MaxCriteriaBytes, true, true); err != nil {
		panic("invalid acceptance criteria: " + err.Error())
	}

	sponsor := cur.Previous().Address()
	now := time.Now().Unix()

	nextContestID++
	id := nextContestID
	c := &Contest{
		ID:              id,
		Sponsor:         sponsor,
		Title:           strings.TrimSpace(title),
		Description:     strings.TrimSpace(description),
		Criteria:        strings.TrimSpace(criteria),
		Category:        category,
		Reward:          reward,
		WinnerShares:    shares,
		CreatedAt:       now,
		SubmitDeadline:  now + submitDur,
		JudgingDeadline: now + submitDur + judgingDur,
		Status:          bs_core.ContestOpen,
		EscrowHeld:      reward,
		entryIdxByAddr:  map[address]int{},
	}
	c.addEvent(now, sponsor, "CREATED", "reward="+strconv.FormatInt(reward, 10)+"ugnot shares="+sharesCSV)

	contestsByID[id] = c
	contestIDs = append(contestIDs, id)
	totalActiveEscrow += reward
	return id
}

// CancelContest cancels an Open Contest ONLY while submissionCount == 0.
func CancelContest(cur realm, contestID uint64) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	caller := cur.Previous().Address()
	if caller != c.Sponsor {
		panic("unauthorized: only sponsor can cancel contest")
	}
	if c.Status != bs_core.ContestOpen {
		panic("contest is not Open")
	}
	if len(c.Entries) > 0 {
		panic("cannot cancel contest after submissions have been received")
	}
	refund := c.Reward
	c.Status = bs_core.ContestCancelled
	c.EscrowHeld -= refund
	totalActiveEscrow -= refund
	c.addEvent(time.Now().Unix(), caller, "CANCELLED", "refund="+strconv.FormatInt(refund, 10)+"ugnot")

	sendUgnot(c.Sponsor, refund, cur)
}

// ExpireOpenContest allows anyone to refund 100% reward (no fee) when submitDeadline
// passes with 0 submissions.
func ExpireOpenContest(cur realm, contestID uint64) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	if c.Status != bs_core.ContestOpen {
		panic("contest is not Open")
	}
	now := time.Now().Unix()
	if now <= c.SubmitDeadline {
		panic("submitDeadline has not elapsed yet")
	}
	if len(c.Entries) > 0 {
		panic("contest has submissions; must proceed to judging or escalation")
	}
	refund := c.Reward
	c.Status = bs_core.ContestCancelled
	c.EscrowHeld -= refund
	totalActiveEscrow -= refund
	c.addEvent(now, cur.Previous().Address(), "EXPIRED_OPEN", "refund="+strconv.FormatInt(refund, 10)+"ugnot")

	sendUgnot(c.Sponsor, refund, cur)
}

// SubmitContestEntry submits (or appends an update to) a contest entry before submitDeadline.
// No stake required; max 1 submitter entry per address, max 200 unique submitters.
func SubmitContestEntry(cur realm, contestID uint64, proofURL, note string) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	if c.Status != bs_core.ContestOpen {
		panic("contest is not Open for submissions")
	}
	now := time.Now().Unix()
	if now > c.SubmitDeadline {
		panic("submitDeadline has passed")
	}
	submitter := cur.Previous().Address()
	if submitter == c.Sponsor {
		panic("self-dealing forbidden: sponsor cannot submit to own contest")
	}
	if isExcludedWorkerRole(submitter) {
		panic("arbiter and treasury addresses cannot submit to contests")
	}
	if err := bs_core.ValidateHTTPSURL(proofURL); err != nil {
		panic("invalid proof URL: " + err.Error())
	}
	if err := bs_core.ValidateText(note, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("invalid proof note: " + err.Error())
	}

	if idx, exists := c.entryIdxByAddr[submitter]; exists {
		// Append-only update guarantees bytes_delta >= 0
		entry := &c.Entries[idx]
		entry.Proofs = append(entry.Proofs, ProofEntry{
			URL:         proofURL,
			Note:        strings.TrimSpace(note),
			SubmittedAt: now,
			RevisionIdx: len(entry.Proofs),
		})
		c.addEvent(now, submitter, "ENTRY_UPDATED", "version="+strconv.Itoa(len(entry.Proofs)))
		return
	}

	if len(c.Entries) >= bs_core.MaxContestSubmissions {
		panic("maximum contest submissions (200) reached")
	}
	entry := ContestEntry{
		Submitter: submitter,
		Proofs: []ProofEntry{
			{
				URL:         proofURL,
				Note:        strings.TrimSpace(note),
				SubmittedAt: now,
				RevisionIdx: 0,
			},
		},
	}
	c.Entries = append(c.Entries, entry)
	c.entryIdxByAddr[submitter] = len(c.Entries) - 1
	c.addEvent(now, submitter, "ENTRY_SUBMITTED", "entries="+strconv.Itoa(len(c.Entries)))
}

// FinalizeWinners lets the sponsor select `min(len(WinnerShares), len(Entries))`
// distinct registered submitters after submitDeadline and before judgingDeadline.
func FinalizeWinners(cur realm, contestID uint64, winnersCSV string) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	caller := cur.Previous().Address()
	if caller != c.Sponsor {
		panic("unauthorized: only sponsor can finalize contest winners")
	}
	if c.Status != bs_core.ContestOpen {
		panic("contest cannot be finalized in current state")
	}
	now := time.Now().Unix()
	if now <= c.SubmitDeadline {
		panic("cannot finalize winners before submitDeadline")
	}
	if now > c.JudgingDeadline {
		panic("judgingDeadline has passed; contest must be escalated to arbiter")
	}
	if len(c.Entries) == 0 {
		panic("no submissions to judge; use ExpireOpenContest")
	}

	winners := parseAndValidateWinners(c, winnersCSV)
	distributeContestWinners(c, winners, caller, "FINALIZED_WINNERS", now, cur)
}

// EscalateContest allows anyone (WITHOUT dispute fee) to escalate an Open Contest
// to the arbiter if the sponsor misses judgingDeadline while submissions exist.
func EscalateContest(cur realm, contestID uint64) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	if c.Status != bs_core.ContestOpen {
		panic("contest cannot be escalated in current state")
	}
	now := time.Now().Unix()
	if now <= c.JudgingDeadline {
		panic("judgingDeadline has not elapsed yet")
	}
	if len(c.Entries) == 0 {
		panic("no submissions exist; use ExpireOpenContest instead")
	}

	c.LockedArbiter = arbiter
	c.DisputedAt = now
	c.DisputeDeadline = now + bs_core.ArbiterTimeoutSec
	c.Status = bs_core.ContestDisputed
	c.addEvent(now, cur.Previous().Address(), "ESCALATED", "arbiter="+arbiter.String())

	if repRecordingEnabled {
		siege_rep.RecordLateJudging(cross(cur), c.Sponsor)
	}
}

// ArbiterResolveContest lets ONLY the contest's lockedArbiter pick valid winners
// from existing submitters according to the contest's share structure.
func ArbiterResolveContest(cur realm, contestID uint64, winnersCSV, resolutionNote string) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	if c.Status != bs_core.ContestDisputed {
		panic("contest is not Disputed/Escalated")
	}
	caller := cur.Previous().Address()
	if caller != c.LockedArbiter {
		panic("unauthorized: only locked arbiter can resolve escalated contest")
	}
	now := time.Now().Unix()
	if now > c.DisputeDeadline {
		panic("arbiter 7-day deadline has passed; anyone may trigger ExpireContestDispute")
	}
	if err := bs_core.ValidateText(resolutionNote, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("resolution note is required: " + err.Error())
	}

	winners := parseAndValidateWinners(c, winnersCSV)
	c.ResolutionNote = strings.TrimSpace(resolutionNote)
	distributeContestWinners(c, winners, caller, "ARBITER_RESOLVED_WINNERS", now, cur)
}

// ArbiterRefundContest lets ONLY the contest's lockedArbiter refund 100% reward
// to sponsor if all submissions are spam/invalid.
func ArbiterRefundContest(cur realm, contestID uint64, resolutionNote string) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	if c.Status != bs_core.ContestDisputed {
		panic("contest is not Disputed/Escalated")
	}
	caller := cur.Previous().Address()
	if caller != c.LockedArbiter {
		panic("unauthorized: only locked arbiter can refund escalated contest")
	}
	now := time.Now().Unix()
	if now > c.DisputeDeadline {
		panic("arbiter 7-day deadline has passed; anyone may trigger ExpireContestDispute")
	}
	if err := bs_core.ValidateText(resolutionNote, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("resolution note is required: " + err.Error())
	}

	refund := c.Reward
	c.ResolutionNote = strings.TrimSpace(resolutionNote)
	c.Status = bs_core.ContestCancelled
	c.EscrowHeld -= refund
	totalActiveEscrow -= refund
	c.addEvent(now, caller, "ARBITER_REFUNDED", "refund="+strconv.FormatInt(refund, 10)+"ugnot")

	sendUgnot(c.Sponsor, refund, cur)
}

// ExpireContestDispute enables Pull-Payment equal split across all submitters
// if the arbiter also times out (> 7 days). 2% fee + integer remainder go to Treasury,
// and unclaimed shares expire after 30 days (SweepExpiredContestSplit).
func ExpireContestDispute(cur realm, contestID uint64) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	if c.Status != bs_core.ContestDisputed {
		panic("contest is not Disputed/Escalated")
	}
	now := time.Now().Unix()
	if now <= c.DisputeDeadline {
		panic("arbiter 7-day deadline has not elapsed yet")
	}

	per, heldEscrow, trTotal, err := bs_core.CalcContestEqualSplit(c.Reward, len(c.Entries))
	if err != nil {
		panic(err.Error())
	}

	// Checks-Effects-Interactions: only treasury portion leaves active escrow now;
	// `heldEscrow` stays locked in c.EscrowHeld for Pull-Payment claims!
	c.Status = bs_core.ContestResolvedTimeout
	c.PerSubmitterSplit = per
	c.ClaimDeadline = now + bs_core.PullPaymentClaimExpiry
	c.EscrowHeld = heldEscrow
	totalActiveEscrow -= trTotal
	treasuryBalance += trTotal
	c.addEvent(now, cur.Previous().Address(), "CONTEST_ARBITER_TIMEOUT", "per_submitter="+strconv.FormatInt(per, 10)+" treasury="+strconv.FormatInt(trTotal, 10))
}

// ClaimContestSplit lets each registered submitter pull their equal split once
// within the 30-day claim window (no loop gas limit!).
func ClaimContestSplit(cur realm, contestID uint64) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	if c.Status != bs_core.ContestResolvedTimeout {
		panic("contest is not in ResolvedTimeout Pull-Payment state")
	}
	now := time.Now().Unix()
	if now > c.ClaimDeadline || c.Swept {
		panic("30-day pull-payment claim window has expired")
	}
	caller := cur.Previous().Address()
	idx, ok := c.entryIdxByAddr[caller]
	if !ok {
		panic("unauthorized: caller is not a registered submitter for this contest")
	}
	entry := &c.Entries[idx]
	if entry.Claimed {
		panic("split share already claimed")
	}

	amt := c.PerSubmitterSplit
	entry.Claimed = true
	c.EscrowHeld -= amt
	totalActiveEscrow -= amt
	totalPaidOut += amt
	c.addEvent(now, caller, "SPLIT_CLAIMED", "amount="+strconv.FormatInt(amt, 10)+"ugnot")

	sendUgnot(caller, amt, cur)
}

// SweepExpiredContestSplit lets anyone sweep unclaimed Pull-Payment funds into
// treasuryBalance after the 30-day claim window expires (zero state deletions!).
func SweepExpiredContestSplit(cur realm, contestID uint64) {
	requireNonPayableEOA(0, cur)
	c := mustGetContest(contestID)
	if c.Status != bs_core.ContestResolvedTimeout {
		panic("contest is not in ResolvedTimeout state")
	}
	now := time.Now().Unix()
	if now <= c.ClaimDeadline {
		panic("30-day claim window has not expired yet")
	}
	if c.Swept || c.EscrowHeld == 0 {
		panic("no unclaimed escrow remaining to sweep")
	}

	rem := c.EscrowHeld
	c.EscrowHeld = 0
	c.Swept = true
	totalActiveEscrow -= rem
	treasuryBalance += rem
	c.addEvent(now, cur.Previous().Address(), "SPLIT_SWEPT_TO_TREASURY", "amount="+strconv.FormatInt(rem, 10)+"ugnot")
}

//----------------------------------------
// Contest Helpers (Non-crossing; rlm is NEVER param #1)
//----------------------------------------

func distributeContestWinners(c *Contest, winners []address, actor address, action string, now int64, rlm realm) {
	winnerNets, sponsorRefund, treasuryTotal, err := bs_core.CalcContestPayouts(c.Reward, c.WinnerShares, len(winners))
	if err != nil {
		panic(err.Error())
	}

	// Gross payouts for reputation tracking (each filled slot's gross award)
	grossPayouts := make([]int64, len(winners))
	var totalGrossPaid int64
	for i := range winners {
		g := (c.Reward * int64(c.WinnerShares[i])) / 100
		grossPayouts[i] = g
		totalGrossPaid += g
	}

	// Checks-Effects-Interactions: settle all ledgers BEFORE any coin send or cross-realm call.
	reward := c.Reward
	c.Status = bs_core.ContestCompleted
	c.Winners = winners
	c.WinnerPayouts = winnerNets
	c.EscrowHeld -= reward
	totalActiveEscrow -= reward
	treasuryBalance += treasuryTotal
	totalPaidOut += totalGrossPaid
	c.addEvent(now, actor, action, "winners="+strconv.Itoa(len(winners))+" sponsor_refund="+strconv.FormatInt(sponsorRefund, 10)+" treasury="+strconv.FormatInt(treasuryTotal, 10))

	for i, w := range winners {
		sendUgnot(w, winnerNets[i], rlm)
	}
	if sponsorRefund > 0 {
		sendUgnot(c.Sponsor, sponsorRefund, rlm)
	}
	if repRecordingEnabled {
		siege_rep.RecordContestWinners(cross(rlm), c.Sponsor, winners, uint8(c.Category), grossPayouts)
	}
}

func parseSharesCSV(csv string) []int {
	trimmed := strings.TrimSpace(csv)
	if trimmed == "" {
		panic("winner shares CSV is required")
	}
	parts := strings.Split(trimmed, ",")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil {
			panic("invalid integer in sharesCSV: " + p)
		}
		out = append(out, n)
	}
	return out
}

func parseAndValidateWinners(c *Contest, csv string) []address {
	trimmed := strings.TrimSpace(csv)
	if trimmed == "" {
		panic("winners CSV is required")
	}
	parts := strings.Split(trimmed, ",")
	expected := len(c.WinnerShares)
	if len(c.Entries) < expected {
		expected = len(c.Entries)
	}
	if len(parts) != expected {
		panic("must select exactly " + strconv.Itoa(expected) + " unique winners")
	}
	seen := map[address]bool{}
	winners := make([]address, 0, expected)
	for _, p := range parts {
		w := address(strings.TrimSpace(p))
		if _, ok := c.entryIdxByAddr[w]; !ok {
			panic("selected winner is not a registered submitter: " + w.String())
		}
		if seen[w] {
			panic("duplicate winner address: " + w.String())
		}
		seen[w] = true
		winners = append(winners, w)
	}
	return winners
}

func mustGetContest(id uint64) *Contest {
	c, ok := contestsByID[id]
	if !ok {
		panic("contest not found: " + strconv.FormatUint(id, 10))
	}
	return c
}

func ContestCount() int {
	return len(contestIDs)
}
