package agentmarketplace

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

// Tunables.
const (
	maxAgents      = 1000
	maxTasks       = 5000
	maxBidsPerTask = 50
)

var (
	nextTaskID = 1
	nextBidID  = 1

	agents     = avl.NewTree() // owner.String() -> *Agent
	tasks      = avl.NewTree() // padID(taskID) -> *Task
	bids       = avl.NewTree() // padID(taskID) + "/" + padID(bidID) -> *Bid
	bidByAgent = avl.NewTree() // owner + "/" + padID(taskID) -> bidID
)

// realmURL is this realm's gnoweb path, e.g. /r/demo/agentmarketplace.
var realmURL string

func init(cur realm) {
	realmURL = strings.TrimPrefix(cur.PkgPath(), "gno.land")
}

// ---------------------------------------------------------------------------
// Agent actions. Every crossing function is a signed transaction, so the
// caller address is authenticated by the chain itself.

// RegisterAgent registers the caller as an agent. name is a display name,
// tags is a comma-separated list of specialties, rateKind is "hourly" or
// "flat", and rateUgnot is the listed price in ugnot (1 GNOT = 1,000,000 ugnot).
// The caller's address is the agent id; an address may register only once.
func RegisterAgent(cur realm, name, tags, rateKind string, rateUgnot int64) {
	caller := mustUserCall(cur)
	if agents.Get(caller.String()) != nil {
		panic("this address is already registered as an agent")
	}
	if agents.Size() >= maxAgents {
		panic("the agent registry is full")
	}
	checkText("name", name, minNameLen, maxNameLen)
	canonical := parseTags(tags)
	checkRateKind(rateKind)
	checkRate(rateUgnot)

	a := &Agent{
		Owner:        caller,
		Name:         name,
		Tags:         canonical,
		RateKind:     rateKind,
		RateUgnot:    rateUgnot,
		RegisteredAt: time.Now(),
	}
	agents.Set(caller.String(), a)
	chain.Emit("AgentRegistered",
		"agent", caller.String(),
		"name", name,
		"tags", canonical,
		"rateKind", rateKind,
		"rateUgnot", strconv.FormatInt(rateUgnot, 10),
	)
}

// UpdateAgent changes the caller's display name, specialties and rate.
func UpdateAgent(cur realm, name, tags, rateKind string, rateUgnot int64) {
	caller := mustUserCall(cur)
	a := mustGetAgent(caller)
	checkText("name", name, minNameLen, maxNameLen)
	canonical := parseTags(tags)
	checkRateKind(rateKind)
	checkRate(rateUgnot)
	a.Name = name
	a.Tags = canonical
	a.RateKind = rateKind
	a.RateUgnot = rateUgnot
	chain.Emit("AgentUpdated",
		"agent", caller.String(),
		"name", name,
		"tags", canonical,
		"rateKind", rateKind,
		"rateUgnot", strconv.FormatInt(rateUgnot, 10),
	)
}

// ---------------------------------------------------------------------------
// Tasks and escrow.

// PostTask posts a new open task and escrows the budget. The caller must
// attach exactly budgetUgnot ugnot with the transaction (-send). Only a
// direct user call is accepted, so OriginSend cannot be spoofed by an
// intermediate realm. Returns the new task ID.
func PostTask(cur realm, title, description, specialty string, budgetUgnot int64) int {
	caller := mustUserCall(cur)
	checkText("title", title, minTitleLen, maxTitleLen)
	checkText("description", description, minDescLen, maxDescLen)
	spec := checkSpecialty(specialty)
	checkBudget(budgetUgnot)
	requireExactUgnotSend(budgetUgnot)
	if tasks.Size() >= maxTasks {
		panic("the task board is full")
	}

	t := &Task{
		ID:          nextTaskID,
		Poster:      caller,
		Title:       title,
		Description: description,
		Specialty:   spec,
		BudgetUgnot: budgetUgnot,
		Status:      StatusOpen,
		PostedAt:    time.Now(),
	}
	nextTaskID++
	tasks.Set(padID(t.ID), t)
	chain.Emit("TaskPosted",
		"id", strconv.Itoa(t.ID),
		"poster", caller.String(),
		"specialty", spec,
		"budgetUgnot", strconv.FormatInt(budgetUgnot, 10),
	)
	return t.ID
}

// PlaceBid lets a registered agent offer to do an open task. The agent must
// list the task's required specialty. One bid per agent per task; a later
// call updates the amount and note. Returns the bid ID. Agents cannot bid
// on their own tasks.
func PlaceBid(cur realm, taskID int, amountUgnot int64, note string) int {
	caller := mustUserCall(cur)
	a := mustGetAgent(caller)
	t := mustGetTask(taskID)
	if t.Status != StatusOpen {
		panic("bids are only accepted on open tasks")
	}
	if t.Poster == caller {
		panic("the task poster cannot bid on their own task")
	}
	if !agentHasSpecialty(a.Tags, t.Specialty) {
		panic("this agent does not list the required specialty: " + t.Specialty)
	}
	if amountUgnot < 1 || amountUgnot > t.BudgetUgnot {
		panic("bid amount must be between 1 and the task budget of " + strconv.FormatInt(t.BudgetUgnot, 10) + " ugnot")
	}
	if note != "" {
		checkText("note", note, 1, maxNoteLen)
	}

	if existing := bidByAgent.Get(caller.String() + "/" + padID(taskID)); existing != nil {
		bidID := existing.(int)
		b := mustGetBid(taskID, bidID)
		b.Amount = amountUgnot
		b.Note = note
		b.PlacedAt = time.Now()
		chain.Emit("BidUpdated",
			"task", strconv.Itoa(taskID),
			"bid", strconv.Itoa(bidID),
			"agent", caller.String(),
			"amountUgnot", strconv.FormatInt(amountUgnot, 10),
		)
		return bidID
	}
	if taskBidCount(taskID) >= maxBidsPerTask {
		panic("this task already has the maximum number of bids")
	}

	b := &Bid{
		ID:       nextBidID,
		TaskID:   taskID,
		Agent:    caller,
		Amount:   amountUgnot,
		Note:     note,
		PlacedAt: time.Now(),
	}
	nextBidID++
	bids.Set(bidKey(taskID, b.ID), b)
	bidByAgent.Set(caller.String()+"/"+padID(taskID), b.ID)
	chain.Emit("BidPlaced",
		"task", strconv.Itoa(taskID),
		"bid", strconv.Itoa(b.ID),
		"agent", caller.String(),
		"amountUgnot", strconv.FormatInt(amountUgnot, 10),
	)
	return b.ID
}

// AcceptBid is called by the task poster to pick a bid. The task moves to
// in-progress and the winning agent is recorded. Escrow stays locked until
// CompleteTask or (only while still open) CancelTask.
func AcceptBid(cur realm, taskID, bidID int) {
	caller := mustUserCall(cur)
	t := mustGetTask(taskID)
	if t.Poster != caller {
		panic("only the task poster can accept a bid")
	}
	if t.Status != StatusOpen {
		panic("only an open task can accept a bid")
	}
	b := mustGetBid(taskID, bidID)
	t.Status = StatusInProgress
	t.WinningBidID = b.ID
	t.Winner = b.Agent
	t.AcceptedAt = time.Now()
	chain.Emit("BidAccepted",
		"task", strconv.Itoa(taskID),
		"bid", strconv.Itoa(bidID),
		"agent", b.Agent.String(),
		"amountUgnot", strconv.FormatInt(b.Amount, 10),
	)
}

// CompleteTask is called by the winning agent to mark the work done and
// settle escrow. The winning bid amount is sent to the agent; any leftover
// budget (budget minus bid) is refunded to the poster. State is updated
// before coins move, so a re-entrant call cannot settle twice.
// Hash-commit tasks must use RevealAndComplete instead.
func CompleteTask(cur realm, taskID int) {
	caller := mustUserCall(cur)
	t := mustGetTask(taskID)
	if t.CommitHash != "" {
		panic("this task requires a hash reveal: call RevealAndComplete")
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
	settleTask(cur, t, "open")
}

// settleTask applies the completed-and-paid state and moves coins.
// caller checks must already have been performed.
func settleTask(cur realm, t *Task, method string) {
	b := mustGetBid(t.ID, t.WinningBidID)
	pay := b.Amount
	refund := t.BudgetUgnot - pay
	if refund < 0 {
		panic("invariant: bid exceeds escrowed budget")
	}

	// Effects first, then interactions.
	t.Status = StatusCompleted
	t.Settled = true
	t.CompletedAt = time.Now()
	if av := agents.Get(t.Winner.String()); av != nil {
		a := av.(*Agent)
		a.Completed++
		a.EarnedUgnot += pay
	}
	recordPosterPayment(t.Poster, t.Winner, t.BudgetUgnot)
	chain.Emit("TaskCompleted",
		"task", strconv.Itoa(t.ID),
		"agent", t.Winner.String(),
		"paidUgnot", strconv.FormatInt(pay, 10),
		"refundedUgnot", strconv.FormatInt(refund, 10),
		"method", method,
	)
	sendUgnot(cur, t.Winner, pay)
	sendUgnot(cur, t.Poster, refund)
}

// CancelTask is called by the poster of an open task to withdraw it and
// refund the full escrowed budget. In-progress, completed or already
// cancelled tasks cannot be cancelled.
func CancelTask(cur realm, taskID int) {
	caller := mustUserCall(cur)
	t := mustGetTask(taskID)
	if t.Poster != caller {
		panic("only the task poster can cancel this task")
	}
	if t.Status != StatusOpen {
		panic("only an open task can be cancelled")
	}
	if t.Settled {
		panic("this task has already been settled")
	}

	t.Status = StatusCancelled
	t.Settled = true
	chain.Emit("TaskCancelled",
		"task", strconv.Itoa(taskID),
		"poster", caller.String(),
		"refundedUgnot", strconv.FormatInt(t.BudgetUgnot, 10),
	)
	sendUgnot(cur, t.Poster, t.BudgetUgnot)
}

// ---------------------------------------------------------------------------
// Read-only helpers (safe to query with vm/qeval).

// AgentCount returns the number of registered agents.
func AgentCount() int { return agents.Size() }

// TaskCount returns the number of tasks ever posted (including settled).
func TaskCount() int { return tasks.Size() }

// Stats returns agents, open tasks, in-progress tasks, completed tasks
// and the ugnot still held in escrow.
func Stats() (int, int, int, int, int64) {
	open, prog, done := 0, 0, 0
	var escrow int64
	tasks.Iterate("", "", func(_ string, v any) bool {
		t := v.(*Task)
		switch t.Status {
		case StatusOpen:
			open++
			escrow += t.BudgetUgnot
		case StatusInProgress:
			prog++
			escrow += t.BudgetUgnot
		case StatusCompleted:
			done++
		}
		return false
	})
	return agents.Size(), open, prog, done, escrow
}

// AgentSummary returns a one-line text summary, or "" if unknown.
func AgentSummary(owner address) string {
	v := agents.Get(owner.String())
	if v == nil {
		return ""
	}
	a := v.(*Agent)
	return a.Name + " | " + a.Tags + " | " + a.RateKind + " " + fmtUgnot(a.RateUgnot) + " | completed " + strconv.Itoa(a.Completed)
}

// TaskSummary returns a one-line text summary, or "" if unknown.
func TaskSummary(id int) string {
	v := tasks.Get(padID(id))
	if v == nil {
		return ""
	}
	t := v.(*Task)
	return t.Title + " | " + t.Status + " | " + t.Specialty + " | " + fmtUgnot(t.BudgetUgnot)
}

// ---------------------------------------------------------------------------
// internals

func mustUserCall(cur realm) address {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("only a direct user call is accepted")
	}
	return prev.Address()
}

func mustGetAgent(owner address) *Agent {
	v := agents.Get(owner.String())
	if v == nil {
		panic("no agent is registered at this address")
	}
	return v.(*Agent)
}

func mustGetTask(id int) *Task {
	v := tasks.Get(padID(id))
	if v == nil {
		panic("task " + strconv.Itoa(id) + " not found")
	}
	return v.(*Task)
}

func mustGetBid(taskID, bidID int) *Bid {
	v := bids.Get(bidKey(taskID, bidID))
	if v == nil {
		panic("bid " + strconv.Itoa(bidID) + " not found on task " + strconv.Itoa(taskID))
	}
	return v.(*Bid)
}

func bidKey(taskID, bidID int) string {
	return padID(taskID) + "/" + padID(bidID)
}

func taskBidCount(taskID int) int {
	count := 0
	prefix := padID(taskID) + "/"
	bids.Iterate(prefix, prefix+"~", func(_ string, _ any) bool {
		count++
		return false
	})
	return count
}

func requireExactUgnotSend(budget int64) {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != budget {
		got := "nothing"
		if len(sent) != 0 {
			got = sent.String()
		}
		panic("must send exactly " + strconv.FormatInt(budget, 10) + "ugnot with this call (got " + got + ")")
	}
}

func sendUgnot(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

// padID makes IDs sort numerically as avl keys.
func padID(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 9 {
		s = "0" + s
	}
	return s
}
