package tavernboard

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"testing"
)

// Test actors (arbitrary valid bech32 addresses; test-only, no real funds).
var (
	posterAddr = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	workerAddr = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	otherAddr  = address("g1w3jhxap3ta047h6lta047h6lta047h6l4mfnm7")
)

func resetState() {
	tasks = nil
	nextID = 0
	totalDeposited = 0
	totalPaid = 0
	totalRefunded = 0
}

// assertPanics fails the test unless fn panics.
func assertPanics(t *testing.T, label string, fn func()) {
	t.Helper()
	if r := revive(fn); r == nil {
		t.Fatalf("expected panic for case %q, but it succeeded", label)
	}
}

// assertInvariant checks the conservation invariant both ways:
// locked (from totals) == locked (from task statuses), and
// locked + paid + refunded == deposited.
func assertInvariant(t *testing.T) {
	t.Helper()
	if lockedBalance() != lockedByStatus() {
		t.Fatalf("invariant: lockedBalance %d != lockedByStatus %d", lockedBalance(), lockedByStatus())
	}
	if lockedBalance()+totalPaid+totalRefunded != totalDeposited {
		t.Fatalf("invariant: locked(%d)+paid(%d)+refunded(%d) != deposited(%d)",
			lockedBalance(), totalPaid, totalRefunded, totalDeposited)
	}
}

// NOTE on test helpers: testing.SetRealm/SetOriginCaller override the
// *calling frame's* `cur` realm value (the override mutates the shared
// realm pointer), and the native override targets the frame that calls
// SetRealm directly — one extra helper layer in between breaks it (the
// override lands on the intermediate frame and is lost when it returns).
// Every helper below therefore takes `cur realm` as its first parameter,
// calls SetOriginCaller/SetRealm DIRECTLY (no indirection), AND makes its
// cross(cur) call inside itself — the same shape as MilestoneEscrow's
// fundAndCallCreate. Never switch caller in one helper and call in
// another.
func switchCaller(cur realm, addr address) {
	testing.SetOriginCaller(addr)
	testing.SetRealm(testing.NewUserRealm(addr))
}

// postAs simulates `gnokey maketx call PostTask -send <send>ugnot` from addr
// and returns the new task id.
//
// IMPORTANT: pkgAddr is derived from RealmPath, NOT from cur.Address().
// The SetRealm calls below mutate the shared `cur` realm pointer to the
// user realm, so cur.Address() after the first post in a test would give
// the *user's* address and the simulated -send would go user -> user
// (self-send), leaving the realm's real bank balance at zero while the
// accounting claims the escrow exists (Approve/Cancel would then fail
// with "cannot send" from an empty realm balance).
func postAs(cur realm, addr address, title, desc string, deadline, send int64) int64 {
	pkgAddr := chain.PackageAddress(RealmPath)
	coins := chain.NewCoins(chain.NewCoin(DenomUgnot, send))
	testing.IssueCoins(addr, coins)
	testing.SetOriginCaller(addr)
	testing.SetOriginSend(coins)
	testing.SetRealm(testing.NewUserRealm(addr))
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(addr, pkgAddr, coins)
	return PostTask(cross(cur), title, desc, deadline)
}

// postAsNoSend calls PostTask with an EMPTY send envelope (no -send),
// for testing the zero-reward validation. It must NOT use the banker
// simulation: NewCoins drops zero-amount coins, so a simulated send of 0
// would fail inside the bank before PostTask is even reached.
func postAsNoSend(cur realm, addr address, title, desc string, deadline int64) int64 {
	switchCaller(cur, addr)
	testing.SetOriginSend(chain.NewCoins())
	return PostTask(cross(cur), title, desc, deadline)
}

func claimAs(cur realm, addr address, id int64) {
	switchCaller(cur, addr)
	ClaimTask(cross(cur), id)
}

func submitAs(cur realm, addr address, id int64, proof string) {
	switchCaller(cur, addr)
	SubmitProof(cross(cur), id, proof)
}

func approveAs(cur realm, addr address, id int64) {
	switchCaller(cur, addr)
	Approve(cross(cur), id)
}

func rejectAs(cur realm, addr address, id int64) {
	switchCaller(cur, addr)
	RejectProof(cross(cur), id)
}

func cancelAs(cur realm, addr address, id int64) {
	switchCaller(cur, addr)
	CancelTask(cross(cur), id)
}

func releaseAs(cur realm, addr address, id int64) {
	switchCaller(cur, addr)
	ReleaseExpired(cross(cur), id)
}

func unclaimAs(cur realm, addr address, id int64) {
	switchCaller(cur, addr)
	Unclaim(cross(cur), id)
}

// balanceOf reads an address's ugnot balance from the test bank.
func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, DenomUgnot)
}

func TestHappyPathPostClaimProofApprove(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()
	workerBefore := ro.GetCoin(workerAddr, DenomUgnot)

	id := postAs(cur, posterAddr, "Write a README", "One page, English", 0, 5000000)
	if id != 1 {
		t.Fatalf("expected task id 1, got %d", id)
	}
	if TaskCount() != 1 {
		t.Fatalf("expected TaskCount 1, got %d", TaskCount())
	}
	if lockedBalance() != 5000000 {
		t.Fatalf("expected locked 5000000, got %d", lockedBalance())
	}
	assertInvariant(t)

	// Worker claims.
	claimAs(cur, workerAddr, id)
	task := GetTask(id)
	if task.Status != StatusClaimed || task.Worker != workerAddr {
		t.Fatalf("expected CLAIMED by worker, got status %s worker %s", task.Status, task.Worker)
	}
	assertInvariant(t)

	// Worker submits proof.
	submitAs(cur, workerAddr, id, "Done: https://example.com/pr/7")
	task = GetTask(id)
	if task.Status != StatusSubmitted || task.Proof == "" {
		t.Fatalf("expected SUBMITTED with proof, got status %s", task.Status)
	}
	assertInvariant(t)

	// Poster approves: worker is paid, escrow empties.
	approveAs(cur, posterAddr, id)
	task = GetTask(id)
	if task.Status != StatusDone {
		t.Fatalf("expected DONE, got %s", task.Status)
	}
	if ro.GetCoin(workerAddr, DenomUgnot)-workerBefore != 5000000 {
		t.Fatalf("expected worker +5000000 ugnot after approve")
	}
	if lockedBalance() != 0 {
		t.Fatalf("expected locked 0 after approve, got %d", lockedBalance())
	}
	if totalPaid != 5000000 || totalDeposited != 5000000 {
		t.Fatalf("expected paid==deposited==5000000, got paid %d deposited %d", totalPaid, totalDeposited)
	}
	assertInvariant(t)
}

func TestCancelRefundsPoster(cur realm, t *testing.T) {
	resetState()
	posterBefore := balanceOf(posterAddr)
	id := postAs(cur, posterAddr, "Translate docs", "ID -> EN", 0, 2000000)
	assertInvariant(t)

	cancelAs(cur, posterAddr, id)
	task := GetTask(id)
	if task.Status != StatusCancelled {
		t.Fatalf("expected CANCELLED, got %s", task.Status)
	}
	if balanceOf(posterAddr)-posterBefore != 2000000 {
		t.Fatalf("expected poster refunded +2000000 ugnot")
	}
	if lockedBalance() != 0 || totalRefunded != 2000000 {
		t.Fatalf("expected locked 0 refunded 2000000, got locked %d refunded %d", lockedBalance(), totalRefunded)
	}
	assertInvariant(t)
}

func TestExpiredRefund(cur realm, t *testing.T) {
	resetState()
	// Post with a deadline 100 blocks ahead of the current test height
	// (the test machine's height is not 0, so deadlines must be relative).
	id := postAs(cur, posterAddr, "Quick logo", "SVG, 1 color", runtime.ChainHeight()+100, 3000000)
	assertInvariant(t)

	// Before the deadline, releasing must fail.
	assertPanics(t, "release before deadline", func() {
		releaseAs(cur, otherAddr, id)
	})

	// Move past the deadline and release: poster is refunded.
	testing.SkipHeights(150)
	releaseAs(cur, otherAddr, id)
	task := GetTask(id)
	if task.Status != StatusExpired {
		t.Fatalf("expected EXPIRED, got %s", task.Status)
	}
	if lockedBalance() != 0 || totalRefunded != 3000000 {
		t.Fatalf("expected locked 0 refunded 3000000, got locked %d refunded %d", lockedBalance(), totalRefunded)
	}
	assertInvariant(t)

	// A task without a deadline can never expire.
	id2 := postAs(cur, posterAddr, "No deadline task", "open ended", 0, 1000000)
	assertPanics(t, "release task without deadline", func() {
		releaseAs(cur, otherAddr, id2)
	})
	// And a settled task cannot be released again.
	assertPanics(t, "release already-expired task", func() {
		releaseAs(cur, otherAddr, id)
	})
}

func TestRoleGuards(cur realm, t *testing.T) {
	resetState()
	id := postAs(cur, posterAddr, "Guarded task", "test guards", 0, 1000000)

	// Poster cannot claim their own task.
	assertPanics(t, "poster claims own task", func() {
		claimAs(cur, posterAddr, id)
	})

	// A stranger cannot submit proof for a task nobody claimed.
	assertPanics(t, "submit proof on open task", func() {
		submitAs(cur, otherAddr, id, "proof")
	})

	// Worker claims; another user cannot submit proof in their place.
	claimAs(cur, workerAddr, id)
	assertPanics(t, "non-worker submits proof", func() {
		submitAs(cur, otherAddr, id, "proof")
	})
	assertPanics(t, "non-worker unclaims", func() {
		unclaimAs(cur, otherAddr, id)
	})

	// Worker submits; a stranger cannot approve or reject.
	submitAs(cur, workerAddr, id, "my work: https://example.com/x")
	assertPanics(t, "non-poster approves", func() {
		approveAs(cur, otherAddr, id)
	})
	assertPanics(t, "non-poster rejects", func() {
		rejectAs(cur, otherAddr, id)
	})

	// Poster approves once; a second approve must fail.
	approveAs(cur, posterAddr, id)
	assertPanics(t, "double approve", func() {
		approveAs(cur, posterAddr, id)
	})

	// Cancel only works on OPEN tasks, and only by the poster.
	id2 := postAs(cur, posterAddr, "Second task", "cancel guards", 0, 1000000)
	claimAs(cur, workerAddr, id2)
	assertPanics(t, "cancel claimed task", func() {
		cancelAs(cur, posterAddr, id2)
	})
	assertPanics(t, "non-poster cancels open task", func() {
		cancelAs(cur, otherAddr, id2)
	})
	assertInvariant(t)
}

func TestRejectAndResubmit(cur realm, t *testing.T) {
	resetState()
	id := postAs(cur, posterAddr, "Fix a typo", "one line", 0, 1000000)
	claimAs(cur, workerAddr, id)
	submitAs(cur, workerAddr, id, "weak proof")

	// Poster rejects; task goes back to CLAIMED with proof cleared.
	rejectAs(cur, posterAddr, id)
	task := GetTask(id)
	if task.Status != StatusClaimed || task.Proof != "" {
		t.Fatalf("expected CLAIMED with cleared proof after reject, got %s proof %q", task.Status, task.Proof)
	}
	assertInvariant(t)

	// Worker submits better proof; poster approves.
	submitAs(cur, workerAddr, id, "better proof: https://example.com/fix")
	approveAs(cur, posterAddr, id)
	if GetTask(id).Status != StatusDone {
		t.Fatalf("expected DONE after re-submit + approve")
	}
	assertInvariant(t)
}

func TestUnclaimReopens(cur realm, t *testing.T) {
	resetState()
	id := postAs(cur, posterAddr, "Unclaimable", "test", 0, 1000000)
	claimAs(cur, workerAddr, id)
	unclaimAs(cur, workerAddr, id)
	task := GetTask(id)
	if task.Status != StatusOpen || task.Worker != emptyAddress {
		t.Fatalf("expected OPEN with no worker after unclaim, got %s worker %s", task.Status, task.Worker)
	}
	// Someone else can now claim it.
	claimAs(cur, otherAddr, id)
	if GetTask(id).Worker != otherAddr {
		t.Fatalf("expected otherAddr as worker after re-claim")
	}
	assertInvariant(t)
}

func TestPostValidation(cur realm, t *testing.T) {
	resetState()
	// Zero reward (no -send attached at all).
	assertPanics(t, "zero reward", func() {
		postAsNoSend(cur, posterAddr, "Free work", "no pay", 0)
	})
	// Empty title / description.
	assertPanics(t, "empty title", func() {
		postAs(cur, posterAddr, "   ", "desc", 0, 1000000)
	})
	assertPanics(t, "empty description", func() {
		postAs(cur, posterAddr, "title", "", 0, 1000000)
	})
	// Deadline in the past (advance the test height first, then use a
	// deadline below it).
	testing.SkipHeights(10)
	assertPanics(t, "past deadline", func() {
		postAs(cur, posterAddr, "Late", "too late", 5, 1000000)
	})
	// Nonexistent task ids (crossing call path; mustTask panics).
	assertPanics(t, "claim missing task", func() {
		claimAs(cur, workerAddr, 999)
	})
	// NOTE: no assertPanics case for GetTask(999) here. revive() in
	// Gno v1.8.0's `gno test` only recovers panics raised inside a
	// crossing call; a panic from a plain (non-crossing) function like
	// GetTask propagates uncaught and fails the test. The mustTask
	// panic path is already covered by "claim missing task" above.
	assertInvariant(t)
}

func TestListTasksAndStats(cur realm, t *testing.T) {
	resetState()
	postAs(cur, posterAddr, "Task A", "a", 0, 1000000)
	postAs(cur, posterAddr, "Task B", "b", 0, 2000000)
	idC := postAs(cur, posterAddr, "Task C", "c", 0, 3000000)
	claimAs(cur, workerAddr, idC)

	all := ListTasks(-1, 0)
	if len(all) != 3 {
		t.Fatalf("expected 3 tasks, got %d", len(all))
	}
	if all[0].ID != 3 || all[1].ID != 2 || all[2].ID != 1 {
		t.Fatalf("expected newest-first order 3,2,1, got %d,%d,%d", all[0].ID, all[1].ID, all[2].ID)
	}
	open := ListTasks(int64(StatusOpen), 0)
	if len(open) != 2 {
		t.Fatalf("expected 2 open tasks, got %d", len(open))
	}
	claimed := ListTasks(int64(StatusClaimed), 0)
	if len(claimed) != 1 || claimed[0].ID != idC {
		t.Fatalf("expected 1 claimed task (id %d)", idC)
	}
	limited := ListTasks(-1, 2)
	if len(limited) != 2 || limited[0].ID != 3 {
		t.Fatalf("expected limit 2 starting at id 3")
	}

	o, c, s, d, x, e, locked, paid, refunded, deposited := Stats()
	if o != 2 || c != 1 || s != 0 || d != 0 || x != 0 || e != 0 {
		t.Fatalf("unexpected status counts: open %d claimed %d submitted %d done %d cancelled %d expired %d", o, c, s, d, x, e)
	}
	if locked != 6000000 || paid != 0 || refunded != 0 || deposited != 6000000 {
		t.Fatalf("unexpected accounting: locked %d paid %d refunded %d deposited %d", locked, paid, refunded, deposited)
	}
	assertInvariant(t)
}

func TestRenderAndSanitize(cur realm, t *testing.T) {
	resetState()
	id := postAs(cur, posterAddr, "Title | with [markdown] `tricks`", "Desc with | pipe and <angle> brackets", 0, 2500000)

	home := Render("")
	if !strings.Contains(home, "Tavern Board") {
		t.Fatalf("home render missing title")
	}
	if !strings.Contains(home, "2.5 GNOT") {
		t.Fatalf("home render missing formatted reward, got:\n%s", home)
	}
	if strings.Contains(home, "[markdown]") || strings.Contains(home, "| with") {
		t.Fatalf("home render leaked unsanitized user text:\n%s", home)
	}

	detail := Render("task/1")
	if !strings.Contains(detail, "Task #1") || !strings.Contains(detail, "2.5 GNOT") {
		t.Fatalf("task render missing id/reward:\n%s", detail)
	}

	stats := Render("stats")
	if !strings.Contains(stats, "PASS") {
		t.Fatalf("stats render should show invariant PASS:\n%s", stats)
	}
	if !strings.Contains(stats, "locked + paid + refunded == deposited") {
		t.Fatalf("stats render missing invariant statement")
	}

	guide := Render("guide")
	if !strings.Contains(guide, "PostTask") || !strings.Contains(guide, "Approve") {
		t.Fatalf("guide render missing function names")
	}
	if !strings.Contains(guide, RealmPath) {
		t.Fatalf("guide render missing realm path")
	}

	missing := Render("task/999")
	if !strings.Contains(missing, "Not Found") {
		t.Fatalf("missing task render should say Not Found")
	}
	unknown := Render("nope")
	if !strings.Contains(unknown, "404") {
		t.Fatalf("unknown route render should say 404")
	}
	_ = id
}

func TestConservationAcrossMixedFlow(cur realm, t *testing.T) {
	resetState()
	// Task 1: full happy path (paid).
	id1 := postAs(cur, posterAddr, "One", "1", 0, 1000000)
	claimAs(cur, workerAddr, id1)
	submitAs(cur, workerAddr, id1, "proof 1")
	approveAs(cur, posterAddr, id1)
	// Task 2: cancelled (refunded).
	id2 := postAs(cur, posterAddr, "Two", "2", 0, 2000000)
	cancelAs(cur, posterAddr, id2)
	// Task 3: expired (refunded).
	id3 := postAs(cur, posterAddr, "Three", "3", runtime.ChainHeight()+50, 3000000)
	testing.SkipHeights(100)
	releaseAs(cur, otherAddr, id3)
	// Task 4: still open (locked).
	postAs(cur, posterAddr, "Four", "4", 0, 4000000)

	if totalDeposited != 10000000 {
		t.Fatalf("expected deposited 10000000, got %d", totalDeposited)
	}
	if totalPaid != 1000000 {
		t.Fatalf("expected paid 1000000, got %d", totalPaid)
	}
	if totalRefunded != 5000000 {
		t.Fatalf("expected refunded 5000000, got %d", totalRefunded)
	}
	if lockedBalance() != 4000000 {
		t.Fatalf("expected locked 4000000, got %d", lockedBalance())
	}
	assertInvariant(t)
}
