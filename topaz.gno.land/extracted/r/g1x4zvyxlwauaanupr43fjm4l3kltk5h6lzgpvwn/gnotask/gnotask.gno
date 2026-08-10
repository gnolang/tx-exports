package gnotask

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

const (
	StatusOpen             = "Open"
	StatusClaimed          = "Claimed"
	StatusSubmitted        = "Submitted"
	StatusChangesRequested = "ChangesRequested"
	StatusPaid             = "Paid"
	StatusRefunded         = "Refunded"
	StatusCancelled        = "Cancelled"

	NativeRewardDenom       = "ugnot"
	MinReviewWindowSeconds  = int64(60 * 60)
	MaxReviewWindowSeconds  = int64(30 * 24 * 60 * 60)
)

// Task is the authoritative escrow record. Descriptions, GitHub evidence,
// search metadata, and private operational data remain off-chain.
type Task struct {
	ID                  string
	Sponsor             address
	Contributor         address
	SpecHash            string
	RewardAmount        int64
	RewardDenom         string
	DeliveryDueAt       time.Time
	ReviewWindowSeconds int64
	ReviewDeadline      time.Time
	Status              string
	RevisionRequests    int
	EvidenceHash        string
	ReviewHash          string
	Escrowed            bool
	ReleaseReason       string
}

var (
	tasks   = make(map[string]*Task)
	taskIDs []string
)

// A direct MsgCall is required anywhere an address authorizes a state change.
// IsUserCall deliberately rejects intermediate code and user-run ephemeral
// realms, which is required when unsafe.OriginSend is treated as a receipt.
func requireDirectUser(cur realm) address {
	previous := cur.Previous()
	if !previous.IsUserCall() {
		panic("direct user call required")
	}
	return previous.Address()
}

func requireTask(taskID string) *Task {
	task := tasks[taskID]
	if task == nil {
		panic("task not found")
	}
	return task
}

func requireSponsor(task *Task, caller address) {
	if task.Sponsor != caller {
		panic("only sponsor")
	}
}

func requireContributor(task *Task, caller address) {
	if task.Contributor != caller {
		panic("only selected contributor")
	}
}

func requireTaskID(taskID string) {
	if len(taskID) == 0 || len(taskID) > 64 {
		panic("invalid task id")
	}
	for index := 0; index < len(taskID); index++ {
		char := taskID[index]
		valid := char >= 'a' && char <= 'z' || char >= '0' && char <= '9' || char == '-' || char == '_'
		if !valid {
			panic("invalid task id")
		}
	}
}

func requireHash(value, field string) {
	if len(value) != 64 {
		panic(field + " must be a lowercase sha256 hash")
	}
	for index := 0; index < len(value); index++ {
		char := value[index]
		if !(char >= '0' && char <= '9' || char >= 'a' && char <= 'f') {
			panic(field + " must be a lowercase sha256 hash")
		}
	}
}

func requireExactEscrow(rewardAmount int64, rewardDenom string) {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != rewardDenom || sent[0].Amount != rewardAmount {
		panic("exact reward must be attached")
	}
}

func settleEscrow(cur realm, task *Task, recipient address, reason, terminalStatus string) {
	if !task.Escrowed {
		panic("reward is not escrowed")
	}
	task.Escrowed = false
	task.ReleaseReason = reason
	task.Status = terminalStatus
	coins := chain.Coins{{Denom: task.RewardDenom, Amount: task.RewardAmount}}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), recipient, coins)
}

// CreateTask locks the exact GNOT reward attached to this direct transaction.
// No Task becomes Open from a URL, promise, or off-chain balance screenshot.
func CreateTask(
	cur realm,
	taskID string,
	specHash string,
	rewardAmount int64,
	rewardDenom string,
	deliveryDueUnix int64,
	reviewWindowSeconds int64,
) {
	sponsor := requireDirectUser(cur)
	requireTaskID(taskID)
	if tasks[taskID] != nil {
		panic("task already exists")
	}
	requireHash(specHash, "spec hash")
	if rewardAmount <= 0 {
		panic("reward must be positive")
	}
	if rewardDenom != NativeRewardDenom {
		panic("only ugnot rewards are supported")
	}
	if deliveryDueUnix <= time.Now().Unix() {
		panic("delivery deadline must be in the future")
	}
	if reviewWindowSeconds < MinReviewWindowSeconds || reviewWindowSeconds > MaxReviewWindowSeconds {
		panic("invalid review window")
	}
	requireExactEscrow(rewardAmount, rewardDenom)

	tasks[taskID] = &Task{
		ID:                  taskID,
		Sponsor:             sponsor,
		SpecHash:            specHash,
		RewardAmount:        rewardAmount,
		RewardDenom:         rewardDenom,
		DeliveryDueAt:       time.Unix(deliveryDueUnix, 0),
		ReviewWindowSeconds: reviewWindowSeconds,
		Status:              StatusOpen,
		Escrowed:            true,
	}
	taskIDs = append(taskIDs, taskID)
	chain.Emit("TaskCreated",
		"task_id", taskID,
		"sponsor", sponsor.String(),
		"spec_hash", specHash,
	)
	chain.Emit("FundingLocked",
		"task_id", taskID,
		"amount", strconv.FormatInt(rewardAmount, 10),
		"denom", rewardDenom,
		"delivery_due_unix", strconv.FormatInt(deliveryDueUnix, 10),
	)
}

// CancelOpenTask returns the full escrow while nobody has been selected.
func CancelOpenTask(cur realm, taskID string) {
	caller := requireDirectUser(cur)
	task := requireTask(taskID)
	requireSponsor(task, caller)
	if task.Status != StatusOpen {
		panic("only an open task can be cancelled")
	}
	settleEscrow(cur, task, task.Sponsor, "sponsor_cancelled", StatusCancelled)
	chain.Emit("TaskCancelled", "task_id", taskID)
	chain.Emit("RewardRefunded", "task_id", taskID, "reason", task.ReleaseReason)
}

// SelectContributor records the one contributor chosen through the off-chain
// application flow. The reward remains in the Realm.
func SelectContributor(cur realm, taskID string, contributor address) {
	caller := requireDirectUser(cur)
	task := requireTask(taskID)
	requireSponsor(task, caller)
	if task.Status != StatusOpen {
		panic("task is not open")
	}
	if !contributor.IsValid() || contributor == caller {
		panic("invalid contributor")
	}
	task.Contributor = contributor
	task.Status = StatusClaimed
	chain.Emit("ContributorSelected",
		"task_id", taskID,
		"contributor", contributor.String(),
	)
}

// SubmitEvidence anchors a canonical hash and starts the on-chain review timer.
func SubmitEvidence(cur realm, taskID, evidenceHash string) {
	caller := requireDirectUser(cur)
	task := requireTask(taskID)
	requireContributor(task, caller)
	if task.Status != StatusClaimed && task.Status != StatusChangesRequested {
		panic("task does not accept evidence")
	}
	now := time.Now()
	if task.Status == StatusClaimed && !now.Before(task.DeliveryDueAt) {
		panic("delivery deadline reached")
	}
	if task.Status == StatusChangesRequested && (task.ReviewDeadline.IsZero() || !now.Before(task.ReviewDeadline)) {
		panic("revision deadline reached")
	}
	requireHash(evidenceHash, "evidence hash")
	task.EvidenceHash = evidenceHash
	task.ReviewDeadline = now.Add(time.Duration(task.ReviewWindowSeconds) * time.Second)
	task.Status = StatusSubmitted
	chain.Emit("WorkSubmitted",
		"task_id", taskID,
		"contributor", caller.String(),
		"evidence_hash", evidenceHash,
		"review_deadline_unix", strconv.FormatInt(task.ReviewDeadline.Unix(), 10),
	)
}

// Review either requests the one allowed revision or atomically accepts and
// releases the escrow to the selected Contributor.
func Review(cur realm, taskID string, accept bool, reviewHash string) {
	caller := requireDirectUser(cur)
	task := requireTask(taskID)
	requireSponsor(task, caller)
	if task.Status != StatusSubmitted {
		panic("task is not submitted")
	}
	requireHash(reviewHash, "review hash")
	now := time.Now()
	if !accept && (task.ReviewDeadline.IsZero() || !now.Before(task.ReviewDeadline)) {
		panic("review deadline reached")
	}
	task.ReviewHash = reviewHash
	if accept {
		settleEscrow(cur, task, task.Contributor, "sponsor_accepted", StatusPaid)
		chain.Emit("TaskAccepted", "task_id", taskID, "review_hash", reviewHash)
		chain.Emit("RewardReleased",
			"task_id", taskID,
			"contributor", task.Contributor.String(),
			"reason", task.ReleaseReason,
		)
		return
	}
	if task.RevisionRequests >= 1 {
		panic("revision limit reached")
	}
	task.RevisionRequests++
	// The same bounded window now becomes the Contributor's revision window.
	task.ReviewDeadline = now.Add(time.Duration(task.ReviewWindowSeconds) * time.Second)
	task.Status = StatusChangesRequested
	chain.Emit("ChangesRequested", "task_id", taskID, "review_hash", reviewHash)
}

// ClaimAfterReviewDeadline protects a Contributor from an absent Sponsor.
func ClaimAfterReviewDeadline(cur realm, taskID string) {
	caller := requireDirectUser(cur)
	task := requireTask(taskID)
	requireContributor(task, caller)
	if task.Status != StatusSubmitted {
		panic("task is not awaiting review")
	}
	if task.ReviewDeadline.IsZero() || time.Now().Before(task.ReviewDeadline) {
		panic("review deadline not reached")
	}
	settleEscrow(cur, task, task.Contributor, "review_timeout", StatusPaid)
	chain.Emit("RewardReleased",
		"task_id", taskID,
		"contributor", task.Contributor.String(),
		"reason", task.ReleaseReason,
	)
}

// RefundExpiredTask returns the escrow when the selected Contributor misses
// either the initial delivery deadline or the bounded revision deadline.
// Submitted work is protected by the review timer and cannot use this path.
func RefundExpiredTask(cur realm, taskID string) {
	caller := requireDirectUser(cur)
	task := requireTask(taskID)
	requireSponsor(task, caller)
	if task.Status != StatusClaimed && task.Status != StatusChangesRequested {
		panic("task is not refundable after delivery timeout")
	}
	deadline := task.DeliveryDueAt
	if task.Status == StatusChangesRequested {
		deadline = task.ReviewDeadline
	}
	if deadline.IsZero() || time.Now().Before(deadline) {
		panic("delivery deadline not reached")
	}
	settleEscrow(cur, task, task.Sponsor, "delivery_timeout", StatusRefunded)
	chain.Emit("RewardRefunded", "task_id", taskID, "reason", task.ReleaseReason)
}

func TaskCount() int {
	return len(taskIDs)
}

func GetTask(taskID string) (
	string,
	address,
	address,
	string,
	string,
	int64,
	string,
	int64,
	int64,
	int64,
	int,
	string,
	string,
	bool,
	string,
) {
	task := requireTask(taskID)
	reviewDeadlineUnix := int64(0)
	if !task.ReviewDeadline.IsZero() {
		reviewDeadlineUnix = task.ReviewDeadline.Unix()
	}
	return task.ID,
		task.Sponsor,
		task.Contributor,
		task.Status,
		task.SpecHash,
		task.RewardAmount,
		task.RewardDenom,
		task.DeliveryDueAt.Unix(),
		task.ReviewWindowSeconds,
		reviewDeadlineUnix,
		task.RevisionRequests,
		task.EvidenceHash,
		task.ReviewHash,
		task.Escrowed,
		task.ReleaseReason
}

// GetTaskState is a compact, query-friendly representation for off-chain
// indexers. Every field is constrained so the pipe delimiter is unambiguous.
func GetTaskState(taskID string) string {
	task := requireTask(taskID)
	contributor := ""
	if task.Contributor.IsValid() {
		contributor = task.Contributor.String()
	}
	reviewDeadlineUnix := int64(0)
	if !task.ReviewDeadline.IsZero() {
		reviewDeadlineUnix = task.ReviewDeadline.Unix()
	}
	return strings.Join([]string{
		task.ID,
		task.Sponsor.String(),
		contributor,
		task.Status,
		task.SpecHash,
		strconv.FormatInt(task.RewardAmount, 10),
		task.RewardDenom,
		strconv.FormatInt(task.DeliveryDueAt.Unix(), 10),
		strconv.FormatInt(task.ReviewWindowSeconds, 10),
		strconv.FormatInt(reviewDeadlineUnix, 10),
		strconv.Itoa(task.RevisionRequests),
		task.EvidenceHash,
		task.ReviewHash,
		strconv.FormatBool(task.Escrowed),
		task.ReleaseReason,
	}, "|")
}

func Render(path string) string {
	taskID := strings.TrimPrefix(path, "/")
	if taskID == "" {
		return "# GnoTask\n\nGNOT-escrowed open-source work.\n\nOn-chain Tasks: **" + strconv.Itoa(len(taskIDs)) + "**"
	}
	task := requireTask(taskID)
	contributor := "Not selected"
	if task.Contributor.IsValid() {
		contributor = task.Contributor.String()
	}
	escrow := "Released"
	if task.Escrowed {
		escrow = "Locked in Realm"
	}
	return "# Task `" + task.ID + "`\n\n" +
		"- Status: **" + task.Status + "**\n" +
		"- Escrow: **" + escrow + "**\n" +
		"- Sponsor: `" + task.Sponsor.String() + "`\n" +
		"- Contributor: `" + contributor + "`\n" +
		"- Reward: **" + strconv.FormatInt(task.RewardAmount, 10) + " " + task.RewardDenom + "**\n" +
		"- Delivery deadline: `" + task.DeliveryDueAt.Format(time.RFC3339) + "`\n" +
		"- Spec hash: `" + task.SpecHash + "`"
}
