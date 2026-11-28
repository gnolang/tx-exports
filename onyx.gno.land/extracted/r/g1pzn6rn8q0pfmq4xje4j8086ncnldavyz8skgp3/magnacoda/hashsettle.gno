package magnacoda

import (
	"chain"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"time"
)

// PostHashTask is like PostTask, but settlement requires the winning agent
// to reveal a preimage of commitHash (lowercase hex SHA-256 of the expected
// result). If they miss RevealBy, anyone may call TimeoutHashTask to refund
// the poster. The budget is still sent with the call and held in escrow.
func PostHashTask(cur realm, title, description, specialty string, budgetUgnot int64, commitHash string, deadlineSecs int64) int {
	caller := mustUserCall(cur)
	checkText("title", title, minTitleLen, maxTitleLen)
	checkText("description", description, minDescLen, maxDescLen)
	spec := checkSpecialty(specialty)
	checkBudget(budgetUgnot)
	hash := checkCommitHash(commitHash)
	checkRevealDeadline(deadlineSecs)
	requireExactUgnotSend(budgetUgnot)
	if tasks.Size() >= maxTasks {
		panic("the task board is full")
	}

	now := time.Now()
	t := &Task{
		ID:          nextTaskID,
		Poster:      caller,
		Title:       title,
		Description: description,
		Specialty:   spec,
		BudgetUgnot: budgetUgnot,
		Status:      StatusOpen,
		PostedAt:    now,
		CommitHash:  hash,
		RevealBy:    now.Add(time.Duration(deadlineSecs) * time.Second),
	}
	nextTaskID++
	tasks.Set(padID(t.ID), t)
	chain.Emit("TaskPosted",
		"id", strconv.Itoa(t.ID),
		"poster", caller.String(),
		"specialty", spec,
		"budgetUgnot", strconv.FormatInt(budgetUgnot, 10),
		"commitHash", hash,
	)
	return t.ID
}

// RevealAndComplete is the hash-commit settle path: only the winning agent
// may call it, and only if sha256(preimage) matches the posted commit hash.
// On a match, escrow is released exactly as in CompleteTask.
func RevealAndComplete(cur realm, taskID int, preimage string) {
	caller := mustUserCall(cur)
	t := mustGetTask(taskID)
	if t.CommitHash == "" {
		panic("this task does not use hash-commit settlement; call CompleteTask")
	}
	if t.Status != StatusInProgress {
		panic("only an in-progress task can be completed")
	}
	if t.Winner != caller {
		panic("only the winning agent can mark this task complete")
	}
	if t.Settled {
		panic("this task has already been settled")
	}
	if preimage == "" {
		panic("preimage must not be empty")
	}
	got := sha256Hex(preimage)
	if got != t.CommitHash {
		panic("preimage does not match the commit hash")
	}
	if !t.RevealBy.IsZero() && time.Now().After(t.RevealBy) {
		panic("the reveal deadline has passed; the poster can be refunded with TimeoutHashTask")
	}
	settleTask(cur, t, "hash")
}

// TimeoutHashTask refunds a hash-commit task to the poster after the
// reveal deadline, if it is still in progress and unpaid. Anyone may call it.
func TimeoutHashTask(cur realm, taskID int) {
	mustUserCall(cur)
	t := mustGetTask(taskID)
	if t.CommitHash == "" {
		panic("this task does not use hash-commit settlement")
	}
	if t.Status != StatusInProgress {
		panic("only an in-progress hash task can time out")
	}
	if t.Settled {
		panic("this task has already been settled")
	}
	if t.RevealBy.IsZero() || !time.Now().After(t.RevealBy) {
		panic("the reveal deadline has not passed")
	}

	t.Status = StatusCancelled
	t.Settled = true
	chain.Emit("TaskCancelled",
		"task", strconv.Itoa(taskID),
		"poster", t.Poster.String(),
		"refundedUgnot", strconv.FormatInt(t.BudgetUgnot, 10),
		"reason", "reveal-timeout",
	)
	sendUgnot(cur, t.Poster, t.BudgetUgnot)
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}
