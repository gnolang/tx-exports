package quests

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nym-tavern777/escrow"
)

// Distinct throwaway test addresses per test: the test banker persists
// across tests in a run, so reusing addresses would leak balances.
//
// NOTE on style: testing.SetRealm / SetOriginSend and every cross(cur)
// call are written inline in each test body, mirroring the upstream
// atomicswap tests — the realm value must be the test's own `cur`,
// mutated in place by SetRealm; routing it through a helper function
// breaks the user-call context that PostQuest verifies.
const (
	alice   = address("g1wdjkuer9wgc47h6lta047h6lta047h6l56jtjc")
	bob     = address("g1wfjkx6tsd9jkuap3ta047h6lta047h6lkk20gv")
	carol   = address("g1wdjkuer9wge97h6lta047h6lta047h6ltfacad")
	dave    = address("g1wfjkx6tsd9jkuapjta047h6lta047h6lducc3v")
	eve     = address("g1wdjkuer9wge47h6lta047h6lta047h6l5rk38l")
	frank   = address("g1wfjkx6tsd9jkuapnta047h6lta047h6ly6k4pv")
	grace   = address("g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh")
	heidi   = address("g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu")
	ivan    = address("g1vd5xzunv09047h6lta047h6lta047h6lhsyveh")
	pkgPath = "gno.land/r/nym-tavern777/quests"
)

func resetState() {
	quests = nil
	counter = 0
}

func fundRealm(t *testing.T, amt int64) address {
	t.Helper()
	pkgAddr := chain.PackageAddress(pkgPath)
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: denom, Amount: amt}})
	return pkgAddr
}

func balance(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, denom)
}

// assertPanics asserts fn aborts (panics across the realm boundary) with
// a message containing want. Cross-realm aborts cannot be caught with
// recover(); the revive builtin captures the abort value instead.
func assertPanics(t *testing.T, want string, fn func()) {
	t.Helper()
	r := revive(fn)
	if r == nil {
		t.Fatalf("expected panic containing %q, got none", want)
	}
	var msg string
	switch v := r.(type) {
	case string:
		msg = v
	case error:
		msg = v.Error()
	default:
		t.Fatalf("expected panic containing %q, got non-string panic", want)
	}
	if !strings.Contains(msg, want) {
		t.Fatalf("expected panic containing %q, got %q", want, msg)
	}
}

func TestHappyPath(cur realm, t *testing.T) {
	defer resetState()
	pkgAddr := fundRealm(t, 100_000)
	realmBefore := balance(pkgAddr)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 1000}})
	id := PostQuest(cross(cur), "Write the tavern chronicle", "A short history of the tavern.")
	if id != 1 {
		t.Fatalf("first quest id = %d, want 1", id)
	}
	q := quests[0]
	if q.Status != escrow.Open || q.Poster != alice || q.Reward != 1000 {
		t.Fatalf("after post: status=%v poster=%v reward=%d", q.Status, q.Poster, q.Reward)
	}

	testing.SetRealm(testing.NewUserRealm(bob))
	ClaimQuest(cross(cur), id)
	if q.Status != escrow.Claimed || q.Claimant != bob {
		t.Fatalf("after claim: status=%v claimant=%v", q.Status, q.Claimant)
	}

	SubmitWork(cross(cur), id, "delivered: https://example.org/chronicle")
	if q.Status != escrow.Submitted {
		t.Fatalf("after submit: status=%v", q.Status)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveQuest(cross(cur), id)
	if q.Status != escrow.Completed {
		t.Fatalf("after approve: status=%v", q.Status)
	}
	if got := balance(bob); got != 1000 {
		t.Fatalf("claimant balance = %d, want 1000 (escrow released)", got)
	}
	if got := balance(pkgAddr); got != realmBefore-1000 {
		t.Fatalf("realm balance = %d, want %d", got, realmBefore-1000)
	}

	board := Render("")
	if !strings.Contains(board, "Write the tavern chronicle") {
		t.Fatalf("board render missing quest title:\n%s", board)
	}
	detail := Render("1")
	if !strings.Contains(detail, "completed") {
		t.Fatalf("detail render missing status:\n%s", detail)
	}
}

func TestCancelRefundsPoster(cur realm, t *testing.T) {
	defer resetState()
	fundRealm(t, 100_000)

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 500}})
	id := PostQuest(cross(cur), "Sweep the tavern floor", "Broom provided.")
	CancelQuest(cross(cur), id) // carol is still the current user realm

	if quests[0].Status != escrow.Cancelled {
		t.Fatalf("after cancel: status=%v", quests[0].Status)
	}
	if got := balance(carol); got != 500 {
		t.Fatalf("poster balance = %d, want 500 (escrow refunded)", got)
	}
}

func TestDoubleClaimPanics(cur realm, t *testing.T) {
	defer resetState()
	fundRealm(t, 100_000)

	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 700}})
	id := PostQuest(cross(cur), "Sharpen the tavern knives", "Careful, they bite.")

	testing.SetRealm(testing.NewUserRealm(eve))
	ClaimQuest(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(frank))
	assertPanics(t, "quest is not open", func() {
		ClaimQuest(cross(cur), id)
	})
	if quests[0].Claimant != eve {
		t.Fatalf("claimant changed after double claim: %v", quests[0].Claimant)
	}
}

func TestPosterSelfClaimPanics(cur realm, t *testing.T) {
	defer resetState()
	fundRealm(t, 100_000)

	testing.SetRealm(testing.NewUserRealm(grace))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 300}})
	id := PostQuest(cross(cur), "Brew the house ale", "One barrel, not too hoppy.")

	assertPanics(t, "poster cannot claim their own quest", func() {
		ClaimQuest(cross(cur), id)
	})
	if quests[0].Status != escrow.Open {
		t.Fatalf("status changed after self-claim attempt: %v", quests[0].Status)
	}
}

func TestWrongApproverPanics(cur realm, t *testing.T) {
	defer resetState()
	fundRealm(t, 100_000)

	testing.SetRealm(testing.NewUserRealm(heidi))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 900}})
	id := PostQuest(cross(cur), "Paint the tavern sign", "Gold leaf, purple background.")

	testing.SetRealm(testing.NewUserRealm(ivan))
	ClaimQuest(cross(cur), id)
	SubmitWork(cross(cur), id, "done: https://example.org/sign")

	// The claimant cannot approve their own work.
	assertPanics(t, "only the poster can approve", func() {
		ApproveQuest(cross(cur), id)
	})
	// Nor reject it.
	assertPanics(t, "only the poster can reject", func() {
		RejectQuest(cross(cur), id)
	})
	if quests[0].Status != escrow.Submitted {
		t.Fatalf("status changed after wrong-approver attempts: %v", quests[0].Status)
	}
	if got := balance(ivan); got != 0 {
		t.Fatalf("claimant paid out despite no approval: %d", got)
	}
}

func TestCancelAfterClaimPanics(cur realm, t *testing.T) {
	defer resetState()
	fundRealm(t, 100_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 400}})
	id := PostQuest(cross(cur), "Mend the tavern roof", "Mind the leak over the bar.")

	testing.SetRealm(testing.NewUserRealm(bob))
	ClaimQuest(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(alice))
	assertPanics(t, "only an open quest can be cancelled", func() {
		CancelQuest(cross(cur), id)
	})
	if quests[0].Status != escrow.Claimed {
		t.Fatalf("status changed after cancel-after-claim: %v", quests[0].Status)
	}
}

func TestPostQuestPaymentRules(cur realm, t *testing.T) {
	defer resetState()
	fundRealm(t, 100_000)

	testing.SetRealm(testing.NewUserRealm(carol))

	// No coins sent at all.
	testing.SetOriginSend(chain.Coins{})
	assertPanics(t, "send exactly "+denom, func() {
		PostQuest(cross(cur), "Free quest", "no reward")
	})

	// Wrong denom sent.
	testing.SetOriginSend(chain.Coins{{Denom: "uatom", Amount: 100}})
	assertPanics(t, "send exactly "+denom, func() {
		PostQuest(cross(cur), "Wrong coin quest", "paid in uatom")
	})

	if len(quests) != 0 {
		t.Fatalf("quests recorded despite bad payments: %d", len(quests))
	}
}

func TestRejectThenResubmit(cur realm, t *testing.T) {
	defer resetState()
	fundRealm(t, 100_000)

	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 800}})
	id := PostQuest(cross(cur), "Catalog the wine cellar", "Every bottle, counted twice.")

	testing.SetRealm(testing.NewUserRealm(eve))
	ClaimQuest(cross(cur), id)
	SubmitWork(cross(cur), id, "v1: partial list")

	testing.SetRealm(testing.NewUserRealm(dave))
	RejectQuest(cross(cur), id)
	if quests[0].Status != escrow.Claimed {
		t.Fatalf("after reject: status=%v, want claimed", quests[0].Status)
	}

	testing.SetRealm(testing.NewUserRealm(eve))
	SubmitWork(cross(cur), id, "v2: complete list")

	testing.SetRealm(testing.NewUserRealm(dave))
	ApproveQuest(cross(cur), id)
	if got := balance(eve); got != 800 {
		t.Fatalf("claimant balance = %d, want 800", got)
	}
}
