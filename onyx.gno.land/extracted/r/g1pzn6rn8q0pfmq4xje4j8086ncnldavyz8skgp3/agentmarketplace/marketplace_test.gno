package agentmarketplace

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const pkgPath = "gno.land/r/g1pzn6rn8q0pfmq4xje4j8086ncnldavyz8skgp3/agentmarketplace"

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
	dave  = testutils.TestAddress("dave")
	eve   = testutils.TestAddress("eve")
	frank = testutils.TestAddress("frank")
)

func reset() {
	nextTaskID = 1
	nextBidID = 1
	nextRatingID = 1
	agents = avl.NewTree()
	tasks = avl.NewTree()
	bids = avl.NewTree()
	bidByAgent = avl.NewTree()
	ratings = avl.NewTree()
	ratingsByAgent = avl.NewTree()
	ratingByTask = avl.NewTree()
	scores = avl.NewTree()
	scoreboard = avl.NewTree()
	posterStats = avl.NewTree()
	posterAgents = avl.NewTree()
}

func fundRealm(amount int64) {
	testing.IssueCoins(chain.PackageAddress(pkgPath), chain.Coins{{Denom: "ugnot", Amount: amount}})
}

// testing.SetRealm attaches to the first non-testing call frame. These
// helpers are crossing functions so that SetRealm and the exported call
// share a frame; a non-crossing wrapper would drop the override when it
// returns.

func register(cur realm, owner address, name, tags, kind string, rate int64) {
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginCaller(owner)
	RegisterAgent(cross(cur), name, tags, kind, rate)
}

func update(cur realm, owner address, name, tags, kind string, rate int64) {
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginCaller(owner)
	UpdateAgent(cross(cur), name, tags, kind, rate)
}

func post(cur realm, poster address, title, desc, spec string, budget int64) int {
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginCaller(poster)
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: budget}})
	fundRealm(budget)
	return PostTask(cross(cur), title, desc, spec, budget)
}

func postWithSend(cur realm, poster address, title, desc, spec string, budget int64, send chain.Coins) int {
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginCaller(poster)
	testing.SetOriginSend(send)
	return PostTask(cross(cur), title, desc, spec, budget)
}

func bid(cur realm, agent address, taskID int, amount int64, note string) int {
	testing.SetRealm(testing.NewUserRealm(agent))
	testing.SetOriginCaller(agent)
	return PlaceBid(cross(cur), taskID, amount, note)
}

func accept(cur realm, poster address, taskID, bidID int) {
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginCaller(poster)
	AcceptBid(cross(cur), taskID, bidID)
}

func complete(cur realm, agent address, taskID int) {
	testing.SetRealm(testing.NewUserRealm(agent))
	testing.SetOriginCaller(agent)
	CompleteTask(cross(cur), taskID)
}

func cancel(cur realm, poster address, taskID int) {
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginCaller(poster)
	CancelTask(cross(cur), taskID)
}

func rate(cur realm, poster address, taskID, score int, comment string) int {
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginCaller(poster)
	return Rate(cross(cur), taskID, score, comment)
}

func refreshScore(cur realm, caller, agent address) {
	testing.SetRealm(testing.NewUserRealm(caller))
	testing.SetOriginCaller(caller)
	RefreshScore(cross(cur), agent)
}

func postHash(cur realm, poster address, title, desc, spec string, budget int64, hash string, deadlineSecs int64) int {
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginCaller(poster)
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: budget}})
	fundRealm(budget)
	return PostHashTask(cross(cur), title, desc, spec, budget, hash, deadlineSecs)
}

func reveal(cur realm, agent address, taskID int, preimage string) {
	testing.SetRealm(testing.NewUserRealm(agent))
	testing.SetOriginCaller(agent)
	RevealAndComplete(cross(cur), taskID, preimage)
}

func timeoutHash(cur realm, caller address, taskID int) {
	testing.SetRealm(testing.NewUserRealm(caller))
	testing.SetOriginCaller(caller)
	TimeoutHashTask(cross(cur), taskID)
}

// settleJob posts a task, accepts a full-budget bid, and settles it.
func settleJob(cur realm, poster, agent address, title, desc, spec string, budget int64) int {
	id := post(cur, poster, title, desc, spec, budget)
	bidID := bid(cur, agent, id, budget, "ready")
	accept(cur, poster, id, bidID)
	complete(cur, agent, id)
	return id
}

func TestRegisterAgent(cur realm, t *testing.T) {
	reset()
	register(cur, alice, "Research Bot", "research, writing", RateHourly, 500000)
	uassert.Equal(t, 1, AgentCount())
	a := mustGetAgent(alice)
	uassert.Equal(t, alice, a.Owner)
	uassert.Equal(t, "Research Bot", a.Name)
	uassert.Equal(t, "research, writing", a.Tags, "tags are lowercased, unique and sorted")
	uassert.Equal(t, RateHourly, a.RateKind)
	uassert.Equal(t, int64(500000), a.RateUgnot)
	uassert.Equal(t, 0, a.Completed)

	register(cur, bob, "Code Agent", "Code, review, code", RateFlat, 2000000)
	uassert.Equal(t, 2, AgentCount())
	uassert.Equal(t, "code, review", mustGetAgent(bob).Tags)
}

func TestRegisterValidation(cur realm, t *testing.T) {
	reset()
	cases := []struct {
		name, tags, kind string
		rate             int64
		want             string
	}{
		{"ab", "code", RateFlat, 1, "name must be 3-48 characters"},
		{" lead", "code", RateFlat, 1, "name must not start or end with a space"},
		{"bad|pipe", "code", RateFlat, 1, "name contains an unsupported character: only letters, digits, spaces and - . , ( ) ' / + : @ # % & = are allowed"},
		{"Bot", "x", RateFlat, 1, "tags must be 2-200 characters"},
		{"Bot", "code", "weekly", 1, "rate kind must be one of: hourly, flat"},
		{"Bot", "code", RateFlat, 0, "rate must be between 1 and 1000000000000 ugnot"},
	}
	for _, c := range cases {
		urequire.AbortsWithMessage(t, cur, c.want, func() {
			register(cur, alice, c.name, c.tags, c.kind, c.rate)
		})
	}
	uassert.Equal(t, 0, AgentCount(), "no invalid agent was stored")
}

func TestRegisterOnce(cur realm, t *testing.T) {
	reset()
	register(cur, alice, "Research Bot", "research", RateHourly, 1)
	urequire.AbortsWithMessage(t, cur, "this address is already registered as an agent", func() {
		register(cur, alice, "Other Name", "writing", RateFlat, 2)
	})
}

func TestUpdateAgentAccess(cur realm, t *testing.T) {
	reset()
	register(cur, alice, "Research Bot", "research", RateHourly, 500000)
	update(cur, alice, "Alice Research", "research, writing", RateFlat, 750000)
	a := mustGetAgent(alice)
	uassert.Equal(t, "Alice Research", a.Name)
	uassert.Equal(t, "research, writing", a.Tags)
	uassert.Equal(t, RateFlat, a.RateKind)
	uassert.Equal(t, int64(750000), a.RateUgnot)

	urequire.AbortsWithMessage(t, cur, "no agent is registered at this address", func() {
		update(cur, bob, "Stolen", "code", RateFlat, 1)
	})
}

func TestPostTaskEscrow(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "Research", 2000000)
	uassert.Equal(t, 1, id)
	uassert.Equal(t, 1, TaskCount())
	tk := mustGetTask(id)
	uassert.Equal(t, alice, tk.Poster)
	uassert.Equal(t, StatusOpen, tk.Status)
	uassert.Equal(t, "research", tk.Specialty)
	uassert.Equal(t, int64(2000000), tk.BudgetUgnot)
	uassert.False(t, tk.Settled)
	_, open, _, _, escrow := Stats()
	uassert.Equal(t, 1, open)
	uassert.Equal(t, int64(2000000), escrow)
}

func TestPostTaskSendValidation(cur realm, t *testing.T) {
	reset()
	title, desc := "Summarize a paper", "Write a one-page summary of the attached paper."
	urequire.AbortsWithMessage(t, cur, "must send exactly 2000000ugnot with this call (got nothing)", func() {
		postWithSend(cur, alice, title, desc, "research", 2000000, nil)
	})
	urequire.AbortsWithMessage(t, cur, "must send exactly 2000000ugnot with this call (got 1999999ugnot)", func() {
		postWithSend(cur, alice, title, desc, "research", 2000000, chain.Coins{{Denom: "ugnot", Amount: 1999999}})
	})
	urequire.AbortsWithMessage(t, cur, "must send exactly 2000000ugnot with this call (got 2000000uatom)", func() {
		postWithSend(cur, alice, title, desc, "research", 2000000, chain.Coins{{Denom: "uatom", Amount: 2000000}})
	})
	uassert.Equal(t, 0, TaskCount())
}

func TestPlaceBidRules(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 3000000)

	urequire.AbortsWithMessage(t, cur, "no agent is registered at this address", func() {
		bid(cur, bob, id, 2000000, "I can do this")
	})

	register(cur, bob, "Code Agent", "code, review", RateFlat, 1000000)
	urequire.AbortsWithMessage(t, cur, "this agent does not list the required specialty: research", func() {
		bid(cur, bob, id, 2000000, "I can do this")
	})

	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	register(cur, alice, "Alice Also", "research", RateHourly, 1)
	urequire.AbortsWithMessage(t, cur, "the task poster cannot bid on their own task", func() {
		bid(cur, alice, id, 1000000, "self bid")
	})
	bidID := bid(cur, carol, id, 2500000, "I will deliver tomorrow")
	uassert.Equal(t, 1, bidID)
	uassert.Equal(t, int64(2500000), mustGetBid(id, bidID).Amount)

	same := bid(cur, carol, id, 2000000, "Lower offer")
	uassert.Equal(t, bidID, same)
	uassert.Equal(t, int64(2000000), mustGetBid(id, bidID).Amount)
	uassert.Equal(t, "Lower offer", mustGetBid(id, bidID).Note)

	urequire.AbortsWithMessage(t, cur, "bid amount must be between 1 and the task budget of 3000000 ugnot", func() {
		bid(cur, carol, id, 3000001, "too high")
	})
	urequire.AbortsWithMessage(t, cur, "task 99 not found", func() {
		bid(cur, carol, 99, 1, "")
	})
}

func TestAcceptBidAccess(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 3000000)
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	bidID := bid(cur, carol, id, 2000000, "ready")

	urequire.AbortsWithMessage(t, cur, "only the task poster can accept a bid", func() {
		accept(cur, carol, id, bidID)
	})
	urequire.AbortsWithMessage(t, cur, "only the task poster can accept a bid", func() {
		accept(cur, bob, id, bidID)
	})
	urequire.AbortsWithMessage(t, cur, "bid 99 not found on task 1", func() {
		accept(cur, alice, id, 99)
	})

	accept(cur, alice, id, bidID)
	tk := mustGetTask(id)
	uassert.Equal(t, StatusInProgress, tk.Status)
	uassert.Equal(t, carol, tk.Winner)
	uassert.Equal(t, bidID, tk.WinningBidID)

	urequire.AbortsWithMessage(t, cur, "only an open task can accept a bid", func() {
		accept(cur, alice, id, bidID)
	})
	register(cur, bob, "Other Research", "research", RateHourly, 1)
	urequire.AbortsWithMessage(t, cur, "bids are only accepted on open tasks", func() {
		bid(cur, bob, id, 1000000, "late")
	})
}

func TestCompleteAndSettle(cur realm, t *testing.T) {
	reset()
	budget := int64(3000000)
	pay := int64(2000000)
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", budget)
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	bidID := bid(cur, carol, id, pay, "ready")
	accept(cur, alice, id, bidID)

	urequire.AbortsWithMessage(t, cur, "only the winning agent can mark this task complete", func() {
		complete(cur, alice, id)
	})
	urequire.AbortsWithMessage(t, cur, "only the winning agent can mark this task complete", func() {
		complete(cur, bob, id)
	})

	pkg := chain.PackageAddress(pkgPath)
	rb := banker.NewReadonlyBanker()
	beforeRealm := rb.GetCoin(pkg, "ugnot")
	uassert.Equal(t, budget, beforeRealm, "realm still holds the escrow")

	complete(cur, carol, id)

	tk := mustGetTask(id)
	uassert.Equal(t, StatusCompleted, tk.Status)
	uassert.True(t, tk.Settled)
	uassert.Equal(t, 1, mustGetAgent(carol).Completed)
	uassert.Equal(t, pay, mustGetAgent(carol).EarnedUgnot)

	uassert.Equal(t, pay, rb.GetCoin(carol, "ugnot"))
	uassert.Equal(t, budget-pay, rb.GetCoin(alice, "ugnot"), "leftover budget refunded to poster")
	uassert.Equal(t, int64(0), rb.GetCoin(pkg, "ugnot"), "realm escrow drained")

	_, open, prog, done, escrow := Stats()
	uassert.Equal(t, 0, open)
	uassert.Equal(t, 0, prog)
	uassert.Equal(t, 1, done)
	uassert.Equal(t, int64(0), escrow)

	urequire.AbortsWithMessage(t, cur, "only an in-progress task can be completed", func() {
		complete(cur, carol, id)
	})
}

func TestCancelRefund(cur realm, t *testing.T) {
	reset()
	budget := int64(4000000)
	id := post(cur, alice, "Review a realm", "Look over an escrow realm for footguns please.", "review", budget)
	register(cur, bob, "Code Agent", "code, review", RateFlat, 1000000)
	bid(cur, bob, id, 3500000, "I can review this")

	urequire.AbortsWithMessage(t, cur, "only the task poster can cancel this task", func() {
		cancel(cur, bob, id)
	})

	cancel(cur, alice, id)
	tk := mustGetTask(id)
	uassert.Equal(t, StatusCancelled, tk.Status)
	uassert.True(t, tk.Settled)

	rb := banker.NewReadonlyBanker()
	uassert.Equal(t, budget, rb.GetCoin(alice, "ugnot"))
	uassert.Equal(t, int64(0), rb.GetCoin(chain.PackageAddress(pkgPath), "ugnot"))

	urequire.AbortsWithMessage(t, cur, "only an open task can be cancelled", func() {
		cancel(cur, alice, id)
	})
	urequire.AbortsWithMessage(t, cur, "bids are only accepted on open tasks", func() {
		bid(cur, bob, id, 1, "too late")
	})
}

func TestCannotCancelAfterAccept(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 2000000)
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	bidID := bid(cur, carol, id, 1500000, "ok")
	accept(cur, alice, id, bidID)
	urequire.AbortsWithMessage(t, cur, "only an open task can be cancelled", func() {
		cancel(cur, alice, id)
	})
	uassert.Equal(t, StatusInProgress, mustGetTask(id).Status)
	uassert.False(t, mustGetTask(id).Settled)
}

func TestCompleteOpenTaskRejected(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 2000000)
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	urequire.AbortsWithMessage(t, cur, "only an in-progress task can be completed", func() {
		complete(cur, carol, id)
	})
}

func TestHappyPathSummaries(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	id := post(cur, alice, "Summarize a paper", "Write a one-page summary of the attached paper.", "research", 2000000)
	bidID := bid(cur, carol, id, 2000000, "full budget")
	accept(cur, alice, id, bidID)
	complete(cur, carol, id)

	uassert.True(t, strings.Contains(AgentSummary(carol), "Research Bot"))
	uassert.True(t, strings.Contains(AgentSummary(carol), "completed 1"))
	uassert.True(t, strings.Contains(TaskSummary(id), StatusCompleted))
	uassert.Equal(t, "", AgentSummary(bob))
	uassert.Equal(t, "", TaskSummary(99))
}
