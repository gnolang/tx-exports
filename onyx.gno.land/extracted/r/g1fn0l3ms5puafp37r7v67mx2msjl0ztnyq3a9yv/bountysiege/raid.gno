package bountysiege

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"
)

// Raid groups 2..4 independent role slots under a single mission page, Q&A,
// and derived parent status. Each slot runs the full Single-Claim Quest state
// machine independently, with max 1 slot per builder address per Raid.
type Raid struct {
	ID          uint64
	Sponsor     address
	Title       string
	Description string
	TotalReward int64
	CreatedAt   int64
	Slots       []*Quest
	// Tracks addresses that hold an active or completed slot in this Raid (append-only).
	slotHeldByAddr map[address]int
}

func (r *Raid) DerivedStatus() string {
	hasOpen := false
	hasActive := false
	for _, sl := range r.Slots {
		if sl.Status == bs_core.QuestOpen {
			hasOpen = true
		} else if !sl.Status.IsTerminal() {
			hasActive = true
		}
	}
	if hasOpen {
		return "open"
	}
	if hasActive {
		return "in_progress"
	}
	return "finished"
}

func (r *Raid) EscrowHeld() int64 {
	var sum int64
	for _, sl := range r.Slots {
		sum += sl.EscrowHeld
	}
	return sum
}

var (
	nextRaidID uint64
	raidsByID  = map[uint64]*Raid{}
	raidIDs    []uint64
)

// CreateRaid creates a Co-op Raid with 2..4 independent role slots and escrows
// the exact sum of all slot rewards.
//   - slotTitlesPipe: pipe-separated slot titles (e.g. "Smart Contract|Frontend UI")
//   - slotCriteriaPipe: pipe-separated acceptance criteria per slot
//   - slotCatsCSV: comma-separated Category enum ints (e.g. "0,1")
//   - slotRewardsCSV: comma-separated ugnot rewards per slot (each >= 1 GNOT)
//   - slotStakesCSV: comma-separated ugnot stakes per slot (each 5%..15% of its slot reward)
func CreateRaid(
	cur realm,
	title, description string,
	slotTitlesPipe, slotCriteriaPipe, slotCatsCSV, slotRewardsCSV, slotStakesCSV string,
	openDur, workDur, reviewDur int64,
) uint64 {
	requireRolesInitialized()

	if err := bs_core.ValidateText(title, bs_core.MaxTitleBytes, true, false); err != nil {
		panic("invalid raid title: " + err.Error())
	}
	if err := bs_core.ValidateText(description, bs_core.MaxDescBytes, true, true); err != nil {
		panic("invalid raid description: " + err.Error())
	}
	if err := bs_core.ValidateQuestDurations(openDur, workDur, reviewDur); err != nil {
		panic(err.Error())
	}

	titles := splitPipeNonEmpty(slotTitlesPipe, "slotTitles")
	criterias := splitPipeNonEmpty(slotCriteriaPipe, "slotCriteria")
	cats := parseIntCSV(slotCatsCSV, "slotCats")
	rewards := parseInt64CSV(slotRewardsCSV, "slotRewards")
	stakes := parseInt64CSV(slotStakesCSV, "slotStakes")

	n := len(titles)
	if n < bs_core.MinRaidSlots || n > bs_core.MaxRaidSlots {
		panic("Co-op Raid must have between 2 and 4 slots")
	}
	if len(criterias) != n || len(cats) != n || len(rewards) != n || len(stakes) != n {
		panic("all slot arrays must have identical length")
	}

	var totalReward int64
	for i := 0; i < n; i++ {
		if err := bs_core.ValidateText(titles[i], bs_core.MaxTitleBytes, true, false); err != nil {
			panic("invalid slot title #" + strconv.Itoa(i) + ": " + err.Error())
		}
		if err := bs_core.ValidateText(criterias[i], bs_core.MaxCriteriaBytes, true, true); err != nil {
			panic("invalid slot criteria #" + strconv.Itoa(i) + ": " + err.Error())
		}
		if !bs_core.Category(cats[i]).IsValid() {
			panic("invalid category on slot #" + strconv.Itoa(i))
		}
		if err := bs_core.ValidateStakeBounds(rewards[i], stakes[i]); err != nil {
			panic("invalid reward/stake on slot #" + strconv.Itoa(i) + ": " + err.Error())
		}
		sum, err := bs_core.StrictAdd64(totalReward, rewards[i])
		if err != nil {
			panic("total raid reward overflow")
		}
		totalReward = sum
	}

	// Enforce exact single ugnot coin equal to sum of all slot rewards!
	requireExactUgnot(totalReward, cur)

	sponsor := cur.Previous().Address()
	now := time.Now().Unix()

	nextRaidID++
	rid := nextRaidID
	slots := make([]*Quest, n)
	for i := 0; i < n; i++ {
		sl := &Quest{
			ID:               uint64(i),
			ParentRaidID:     rid,
			SlotIndex:        i,
			Sponsor:          sponsor,
			Title:            strings.TrimSpace(titles[i]),
			Description:      strings.TrimSpace(description),
			Criteria:         strings.TrimSpace(criterias[i]),
			Category:         bs_core.Category(cats[i]),
			Reward:           rewards[i],
			Stake:            stakes[i],
			OpenDuration:     openDur,
			WorkDuration:     workDur,
			ReviewDuration:   reviewDur,
			CreatedAt:        now,
			OpenDeadline:     now + openDur,
			Status:           bs_core.QuestOpen,
			EscrowHeld:       rewards[i],
			ActiveAttemptIdx: -1,
		}
		sl.addEvent(now, sponsor, "RAID_SLOT_CREATED", "raid="+strconv.FormatUint(rid, 10)+" slot="+strconv.Itoa(i)+" reward="+strconv.FormatInt(rewards[i], 10))
		slots[i] = sl
	}

	r := &Raid{
		ID:             rid,
		Sponsor:        sponsor,
		Title:          strings.TrimSpace(title),
		Description:    strings.TrimSpace(description),
		TotalReward:    totalReward,
		CreatedAt:      now,
		Slots:          slots,
		slotHeldByAddr: map[address]int{},
	}
	raidsByID[rid] = r
	raidIDs = append(raidIDs, rid)
	totalActiveEscrow += totalReward
	return rid
}

// Per-slot lifecycle functions (independent state machines reusing quest core).

func CancelRaidSlot(cur realm, raidID uint64, slotIdx int) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	cancelQuestCore(sl, cur)
}

func ExpireOpenRaidSlot(cur realm, raidID uint64, slotIdx int) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	expireOpenQuestCore(sl, cur)
}

func ClaimRaidSlot(cur realm, raidID uint64, slotIdx int) {
	r, sl := mustGetRaidSlot(raidID, slotIdx)
	builder := cur.Previous().Address()
	// Enforce max 1 slot per address per Raid (never deleting map keys!).
	for idx, other := range r.Slots {
		if idx == slotIdx {
			continue
		}
		if att := other.activeAttempt(); att != nil && att.Builder == builder {
			panic("builder already holds another slot in this Raid (max 1 slot per address)")
		}
		for _, a := range other.Attempts {
			if a.Builder == builder && (a.Outcome == bs_core.AttemptApproved || a.Outcome == bs_core.AttemptTimeoutClaimed || a.Outcome == bs_core.AttemptDisputeWon) {
				panic("builder already completed another slot in this Raid (max 1 slot per address)")
			}
		}
	}
	claimQuestCore(sl, cur)
	r.slotHeldByAddr[builder] = slotIdx
}

func ExpireRaidClaim(cur realm, raidID uint64, slotIdx int) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	expireClaimCore(sl, cur)
}

func SubmitRaidWork(cur realm, raidID uint64, slotIdx int, proofURL, note string) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	submitWorkCore(sl, proofURL, note, cur)
}

func ApproveRaidSlot(cur realm, raidID uint64, slotIdx int) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	approveQuestCore(sl, true, cur)
}

func RequestRaidRevision(cur realm, raidID uint64, slotIdx int, note string) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	requestRevisionCore(sl, note, cur)
}

func ExpireRaidRevision(cur realm, raidID uint64, slotIdx int) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	expireRevisionCore(sl, cur)
}

func TimeoutRaidClaim(cur realm, raidID uint64, slotIdx int) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	timeoutClaimCore(sl, true, cur)
}

func RejectRaidSlot(cur realm, raidID uint64, slotIdx int, reason string) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	rejectSubmissionCore(sl, reason, cur)
}

func FinalizeRaidRejection(cur realm, raidID uint64, slotIdx int) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	finalizeRejectionCore(sl, cur)
}

func OpenRaidDispute(cur realm, raidID uint64, slotIdx int, reason string) {
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	openDisputeCore(sl, reason, cur)
}

func ResolveRaidDispute(cur realm, raidID uint64, slotIdx int, releaseToBuilder bool, resolutionNote string) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	resolveDisputeCore(sl, releaseToBuilder, resolutionNote, true, cur)
}

func ExpireRaidDispute(cur realm, raidID uint64, slotIdx int) {
	requireNonPayableEOA(0, cur)
	_, sl := mustGetRaidSlot(raidID, slotIdx)
	expireDisputeCore(sl, cur)
}

//----------------------------------------
// Raid Helpers
//----------------------------------------

func mustGetRaid(id uint64) *Raid {
	r, ok := raidsByID[id]
	if !ok {
		panic("raid not found: " + strconv.FormatUint(id, 10))
	}
	return r
}

func mustGetRaidSlot(raidID uint64, slotIdx int) (*Raid, *Quest) {
	r := mustGetRaid(raidID)
	if slotIdx < 0 || slotIdx >= len(r.Slots) {
		panic("invalid raid slot index: " + strconv.Itoa(slotIdx))
	}
	return r, r.Slots[slotIdx]
}

func splitPipeNonEmpty(s, name string) []string {
	if strings.TrimSpace(s) == "" {
		panic(name + " is required")
	}
	parts := strings.Split(s, "|")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}

func parseIntCSV(csv, name string) []int {
	if strings.TrimSpace(csv) == "" {
		panic(name + " is required")
	}
	parts := strings.Split(csv, ",")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil {
			panic("invalid integer in " + name + ": " + p)
		}
		out = append(out, n)
	}
	return out
}

func parseInt64CSV(csv, name string) []int64 {
	if strings.TrimSpace(csv) == "" {
		panic(name + " is required")
	}
	parts := strings.Split(csv, ",")
	out := make([]int64, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.ParseInt(strings.TrimSpace(p), 10, 64)
		if err != nil {
			panic("invalid int64 in " + name + ": " + p)
		}
		out = append(out, n)
	}
	return out
}

func RaidCount() int {
	return len(raidIDs)
}
