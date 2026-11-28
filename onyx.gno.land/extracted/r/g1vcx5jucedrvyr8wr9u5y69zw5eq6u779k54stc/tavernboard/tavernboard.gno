// Package tavernboard is a single-realm open task board with GNOT escrow.
//
// Anyone can post a task by attaching ugnot to the call (the reward is
// escrowed in this realm). Anyone except the poster can claim it, submit
// proof of work, and the poster approves to release the escrow to the
// worker. Unclaimed/unfinished work past its deadline can be released
// back to the poster by anyone, so escrowed funds can never be locked
// forever. Every ugnot has exactly one reachable destination (worker or
// poster); the conservation invariant is:
//
//	totalLocked + totalPaid + totalRefunded == totalDeposited
//
// where totalLocked is the sum of rewards of tasks in OPEN, CLAIMED or
// SUBMITTED status.
//
// Security notes (see Gno Security Guide):
//   - Caller identity always comes from cur.Previous().Address(), never
//     from a parameter.
//   - PostTask (the only payable function) additionally requires a direct
//     user call (cur.Previous().IsUserCall()) and reads the attached
//     amount from unsafe.OriginSend().
//   - All coin movements follow Checks-Effects-Interactions: state and
//     accounting are updated first, banker.SendCoins runs last.
//   - Getters return value copies, never pointers to mutable state.
package tavernboard

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const (
	// DenomUgnot is the native Gno.land coin denomination (1 GNOT = 1e6 ugnot).
	DenomUgnot = "ugnot"

	// Input size limits keep on-chain state and Render output bounded.
	MaxTitleLen = 120
	MaxDescLen  = 2000
	MaxProofLen = 1000

	// DefaultListLimit is used by ListTasks when the caller passes limit <= 0.
	DefaultListLimit = 50
	// MaxListLimit caps a single ListTasks response.
	MaxListLimit = 100
)

// TaskStatus is the lifecycle state of a task.
type TaskStatus int

const (
	StatusOpen TaskStatus = iota
	StatusClaimed
	StatusSubmitted
	StatusDone
	StatusCancelled
	StatusExpired
)

// String returns the human-readable status name.
func (s TaskStatus) String() string {
	switch s {
	case StatusOpen:
		return "OPEN"
	case StatusClaimed:
		return "CLAIMED"
	case StatusSubmitted:
		return "SUBMITTED"
	case StatusDone:
		return "DONE"
	case StatusCancelled:
		return "CANCELLED"
	case StatusExpired:
		return "EXPIRED"
	default:
		return "UNKNOWN"
	}
}

// Task is one escrowed job on the board.
type Task struct {
	ID          int64
	Poster      address
	Worker      address // empty (zero address) while unclaimed
	Title       string
	Description string
	Reward      int64 // ugnot, escrowed in this realm
	Deadline    int64 // block height; 0 = no deadline
	Proof       string
	Status      TaskStatus
	CreatedAt   int64 // block height at posting time
}

var (
	tasks          map[int64]*Task
	nextID         int64
	totalDeposited int64
	totalPaid      int64
	totalRefunded  int64
)

// emptyAddress is the zero value of address, used for "no worker yet".
var emptyAddress address

// ensureInit lazily initialises realm state (maps cannot be assigned while nil).
func ensureInit() {
	if tasks == nil {
		tasks = make(map[int64]*Task)
	}
	if nextID == 0 {
		nextID = 1
	}
}

// mustTask returns the task with the given id, or panics if it does not exist.
func mustTask(id int64) *Task {
	ensureInit()
	task, ok := tasks[id]
	if !ok {
		panic("tavernboard: task not found")
	}
	return task
}

// payCoins moves amount ugnot from this realm to `to`.
// Caller must have already updated state and accounting (CEI).
func payCoins(cur realm, to address, amount int64) {
	if amount <= 0 {
		panic("tavernboard: payment amount must be > 0")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(DenomUgnot, amount)))
}

// lockedBalance returns the ugnot currently escrowed by unfinished tasks,
// computed from the accounting totals.
func lockedBalance() int64 {
	return totalDeposited - totalPaid - totalRefunded
}

// lockedByStatus recomputes the locked amount independently by summing the
// rewards of every task in OPEN, CLAIMED or SUBMITTED status. Render's
// stats route compares the two; a mismatch would mean an accounting bug.
func lockedByStatus() int64 {
	var sum int64
	for _, task := range tasks {
		if task.Status == StatusOpen || task.Status == StatusClaimed || task.Status == StatusSubmitted {
			sum += task.Reward
		}
	}
	return sum
}

// ---------------------------------------------------------------------------
// Crossing functions (state-changing)
// ---------------------------------------------------------------------------

// PostTask creates a new OPEN task and escrows the attached ugnot as its
// reward. Call with `-send <reward>ugnot`. The reward is exactly the
// attached amount; there is no separate amount parameter (it cannot be
// faked). Returns the new task id.
//
// Panics unless called directly by a user (EOA), the attached amount is
// positive, title/description are non-empty and within limits, and the
// deadline (when set) is a future block height.
func PostTask(cur realm, title, desc string, deadline int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("PostTask: only a direct user call may post a task")
	}
	caller := cur.Previous().Address()
	sent := unsafe.OriginSend().AmountOf(DenomUgnot)
	if sent <= 0 {
		panic("PostTask: reward must be > 0 ugnot (attach with -send)")
	}
	title = strings.TrimSpace(title)
	desc = strings.TrimSpace(desc)
	if title == "" {
		panic("PostTask: title must not be empty")
	}
	if desc == "" {
		panic("PostTask: description must not be empty")
	}
	if len(title) > MaxTitleLen {
		panic("PostTask: title too long (max 120 chars)")
	}
	if len(desc) > MaxDescLen {
		panic("PostTask: description too long (max 2000 chars)")
	}
	height := runtime.ChainHeight()
	if deadline != 0 && deadline <= height {
		panic("PostTask: deadline must be a future block height (0 = none)")
	}
	ensureInit()
	id := nextID
	nextID++
	tasks[id] = &Task{
		ID:          id,
		Poster:      caller,
		Worker:      emptyAddress,
		Title:       title,
		Description: desc,
		Reward:      sent,
		Deadline:    deadline,
		Proof:       "",
		Status:      StatusOpen,
		CreatedAt:   height,
	}
	totalDeposited += sent
	chain.Emit(
		"TaskPosted",
		"task_id", strconv.FormatInt(id, 10),
		"poster", caller.String(),
		"reward_ugnot", strconv.FormatInt(sent, 10),
	)
	return id
}

// ClaimTask moves an OPEN task to CLAIMED and records the caller as worker.
// The poster cannot claim their own task.
func ClaimTask(cur realm, id int64) {
	caller := cur.Previous().Address()
	task := mustTask(id)
	if task.Status != StatusOpen {
		panic("ClaimTask: task is not open")
	}
	if caller == task.Poster {
		panic("ClaimTask: poster cannot claim their own task")
	}
	task.Status = StatusClaimed
	task.Worker = caller
	chain.Emit(
		"TaskClaimed",
		"task_id", strconv.FormatInt(id, 10),
		"worker", caller.String(),
	)
}

// SubmitProof records the worker's proof of work and moves a CLAIMED task
// to SUBMITTED, awaiting the poster's decision.
func SubmitProof(cur realm, id int64, proof string) {
	caller := cur.Previous().Address()
	task := mustTask(id)
	if task.Status != StatusClaimed {
		panic("SubmitProof: task is not claimed")
	}
	if caller != task.Worker {
		panic("SubmitProof: only the claiming worker may submit proof")
	}
	proof = strings.TrimSpace(proof)
	if proof == "" {
		panic("SubmitProof: proof must not be empty")
	}
	if len(proof) > MaxProofLen {
		panic("SubmitProof: proof too long (max 1000 chars)")
	}
	task.Proof = proof
	task.Status = StatusSubmitted
	chain.Emit(
		"ProofSubmitted",
		"task_id", strconv.FormatInt(id, 10),
		"worker", caller.String(),
	)
}

// Approve accepts the submitted proof: the task becomes DONE and the
// escrowed reward is released to the worker. Only the poster may approve.
// State and accounting are updated before any coins move (CEI).
func Approve(cur realm, id int64) {
	caller := cur.Previous().Address()
	task := mustTask(id)
	if task.Status != StatusSubmitted {
		panic("Approve: task has no submitted proof to approve")
	}
	if caller != task.Poster {
		panic("Approve: only the poster may approve")
	}
	reward := task.Reward
	worker := task.Worker
	task.Status = StatusDone
	totalPaid += reward
	payCoins(cur, worker, reward)
	chain.Emit(
		"TaskApproved",
		"task_id", strconv.FormatInt(id, 10),
		"worker", worker.String(),
		"paid_ugnot", strconv.FormatInt(reward, 10),
	)
}

// RejectProof sends a SUBMITTED task back to CLAIMED so the worker can
// submit better proof. Only the poster may reject. The escrow stays locked.
func RejectProof(cur realm, id int64) {
	caller := cur.Previous().Address()
	task := mustTask(id)
	if task.Status != StatusSubmitted {
		panic("RejectProof: task has no submitted proof to reject")
	}
	if caller != task.Poster {
		panic("RejectProof: only the poster may reject proof")
	}
	task.Status = StatusClaimed
	task.Proof = ""
	chain.Emit(
		"ProofRejected",
		"task_id", strconv.FormatInt(id, 10),
		"poster", caller.String(),
	)
}

// CancelTask cancels an OPEN task and refunds the full escrow to the
// poster. Only the poster may cancel, and only before anyone claims it.
func CancelTask(cur realm, id int64) {
	caller := cur.Previous().Address()
	task := mustTask(id)
	if task.Status != StatusOpen {
		panic("CancelTask: only an open task can be cancelled")
	}
	if caller != task.Poster {
		panic("CancelTask: only the poster may cancel")
	}
	reward := task.Reward
	task.Status = StatusCancelled
	totalRefunded += reward
	payCoins(cur, task.Poster, reward)
	chain.Emit(
		"TaskCancelled",
		"task_id", strconv.FormatInt(id, 10),
		"poster", caller.String(),
		"refunded_ugnot", strconv.FormatInt(reward, 10),
	)
}

// ReleaseExpired refunds the escrow of a task whose deadline has passed
// without completion. Anyone may call it. It only applies to tasks that
// still hold escrow (OPEN, CLAIMED or SUBMITTED); settled tasks are
// untouched. This is what guarantees funds can never be locked forever.
func ReleaseExpired(cur realm, id int64) {
	task := mustTask(id)
	if task.Deadline == 0 {
		panic("ReleaseExpired: task has no deadline")
	}
	if runtime.ChainHeight() <= task.Deadline {
		panic("ReleaseExpired: deadline has not passed yet")
	}
	if task.Status != StatusOpen && task.Status != StatusClaimed && task.Status != StatusSubmitted {
		panic("ReleaseExpired: task is already settled")
	}
	reward := task.Reward
	task.Status = StatusExpired
	totalRefunded += reward
	payCoins(cur, task.Poster, reward)
	chain.Emit(
		"TaskExpired",
		"task_id", strconv.FormatInt(id, 10),
		"poster", task.Poster.String(),
		"refunded_ugnot", strconv.FormatInt(reward, 10),
	)
}

// Unclaim lets the claiming worker step back from a CLAIMED task before
// submitting proof; the task returns to OPEN for someone else to claim.
func Unclaim(cur realm, id int64) {
	caller := cur.Previous().Address()
	task := mustTask(id)
	if task.Status != StatusClaimed {
		panic("Unclaim: task is not claimed")
	}
	if caller != task.Worker {
		panic("Unclaim: only the claiming worker may unclaim")
	}
	task.Status = StatusOpen
	task.Worker = emptyAddress
	chain.Emit(
		"TaskUnclaimed",
		"task_id", strconv.FormatInt(id, 10),
		"worker", caller.String(),
	)
}

// ---------------------------------------------------------------------------
// Read-only functions (callable via vm/qeval and from Render)
// ---------------------------------------------------------------------------

// GetTask returns a copy of one task. It panics if the task does not exist.
// The returned value is a copy, never a pointer to realm state.
func GetTask(id int64) Task {
	return *mustTask(id)
}

// TaskCount returns how many tasks have ever been posted.
func TaskCount() int64 {
	ensureInit()
	return nextID - 1
}

// ListTasks returns tasks with the given status, newest first.
// Pass status -1 for all statuses. limit <= 0 means the default (50);
// the result is capped at 100 entries.
func ListTasks(status int64, limit int64) []Task {
	ensureInit()
	if limit <= 0 {
		limit = DefaultListLimit
	}
	if limit > MaxListLimit {
		limit = MaxListLimit
	}
	// Collect ids, newest first (insertion sort, descending).
	ids := make([]int64, 0, len(tasks))
	for id := range tasks {
		ids = append(ids, id)
	}
	for i := 1; i < len(ids); i++ {
		for j := i; j > 0 && ids[j] > ids[j-1]; j-- {
			ids[j], ids[j-1] = ids[j-1], ids[j]
		}
	}
	out := make([]Task, 0, limit)
	for _, id := range ids {
		if int64(len(out)) >= limit {
			break
		}
		task := tasks[id]
		if status != -1 && int64(task.Status) != status {
			continue
		}
		out = append(out, *task)
	}
	return out
}

// Stats returns realm-wide counters: open, claimed, submitted, done,
// cancelled, expired task counts, then locked, paid, refunded and
// deposited ugnot. The invariant locked+paid+refunded == deposited
// must hold at all times.
func Stats() (open, claimed, submitted, done, cancelled, expired, locked, paid, refunded, deposited int64) {
	ensureInit()
	for _, task := range tasks {
		switch task.Status {
		case StatusOpen:
			open++
		case StatusClaimed:
			claimed++
		case StatusSubmitted:
			submitted++
		case StatusDone:
			done++
		case StatusCancelled:
			cancelled++
		case StatusExpired:
			expired++
		}
	}
	locked = lockedBalance()
	paid = totalPaid
	refunded = totalRefunded
	deposited = totalDeposited
	return open, claimed, submitted, done, cancelled, expired, locked, paid, refunded, deposited
}
