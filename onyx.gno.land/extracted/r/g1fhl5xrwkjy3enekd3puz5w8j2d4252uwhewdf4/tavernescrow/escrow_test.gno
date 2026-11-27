package tavernescrow

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"testing"
)

const (
	sponsorAddr = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	workerAddr  = address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	arbiterAddr = address("g10p5yt46ypn5wey48zqevauwjlyaghh5vtdz7yg")
	stranger    = address("g1ecely4gjy0yl6s9kt409ll330q9hk2lj9ls3ec")
)

func realmAddr() address {
	return chain.PackageAddress("gno.land/r/g1fhl5xrwkjy3enekd3puz5w8j2d4252uwhewdf4/tavernescrow")
}

func assertPanics(t *testing.T, label string, fn func()) {
	t.Helper()
	if rec := revive(fn); rec == nil {
		t.Fatalf("expected panic for %s, but succeeded", label)
	}
}

func TestBountyLifecycleHappyPath(cur realm, t *testing.T) {
	expiry := runtime.ChainHeight() + 500
	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	testing.SetOriginCaller(sponsorAddr)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 3000000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 3000000)))

	id := CreateBounty(
		cross(cur),
		"GnoConnect Signing Kit",
		"Ship deterministic wallet signing adapter with unit tests",
		arbiterAddr.String(),
		"",
		"Spec & ABI,SDK Implementation",
		"1000000,2000000",
		expiry,
	)
	if id != 1 {
		t.Fatalf("expected bounty id 1, got %d", id)
	}

	// Open bounty claimed by worker
	testing.SetRealm(testing.NewUserRealm(workerAddr))
	testing.SetOriginSend(chain.Coins{})
	ClaimBounty(cross(cur), id)

	// Submit & approve milestone 0
	SubmitMilestone(cross(cur), id, 0, "https://github.com/cocvn157/pr/1", "sha256:abc1234")

	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	ApproveAndRelease(cross(cur), id, 0)

	// Reject then resubmit milestone 1
	testing.SetRealm(testing.NewUserRealm(workerAddr))
	SubmitMilestone(cross(cur), id, 1, "https://github.com/cocvn157/pr/2", "sha256:def5678")

	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	RejectMilestone(cross(cur), id, 1, "Missing edge test")

	testing.SetRealm(testing.NewUserRealm(workerAddr))
	SubmitMilestone(cross(cur), id, 1, "https://github.com/cocvn157/pr/3", "sha256:fff9999")

	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	ApproveAndRelease(cross(cur), id, 1)

	view := GetBountyView(id)
	if view.Status != StatusCompleted {
		t.Fatalf("expected COMPLETED, got %s", view.Status)
	}
	if view.ReleasedAmount != 3000000 || view.LockedUgnot != 0 {
		t.Fatalf("unexpected accounting: released=%d locked=%d", view.ReleasedAmount, view.LockedUgnot)
	}

	workerBal := banker.NewReadonlyBanker().GetCoin(workerAddr, "ugnot")
	if workerBal < 3000000 {
		t.Fatalf("expected worker balance >= 3000000, got %d", workerBal)
	}

	home := Render("")
	if !strings.Contains(home, "GnoConnect Signing Kit") {
		t.Fatalf("expected Render home to contain bounty title")
	}
	detail := Render("bounty/1")
	if !strings.Contains(detail, "COMPLETED") {
		t.Fatalf("expected Render bounty/1 to show COMPLETED")
	}
}

func TestDisputeAndArbiterResolution(cur realm, t *testing.T) {
	expiry := runtime.ChainHeight() + 500
	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 2500000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 2500000)))

	id := CreateBounty(
		cross(cur),
		"Onyx Indexer",
		"Deterministic event indexer with gnoweb dashboard",
		arbiterAddr.String(),
		workerAddr.String(),
		"Parser,Dashboard",
		"1500000,1000000",
		expiry,
	)

	testing.SetRealm(testing.NewUserRealm(workerAddr))
	testing.SetOriginSend(chain.Coins{})
	SubmitMilestone(cross(cur), id, 0, "https://github.com/cocvn157/indexer", "sha256:11223344")
	RaiseDispute(cross(cur), id, 0, "Deliverable passes all vectors")

	// Sponsor cannot reclaim while dispute is active even if blocks skip past expiry
	testing.SkipHeights(600)
	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	assertPanics(t, "ReclaimExpired during active dispute", func() {
		ReclaimExpired(cross(cur), id)
	})

	// Non-arbiter cannot resolve dispute
	assertPanics(t, "Sponsor resolving dispute", func() {
		ResolveDispute(cross(cur), id, 0, false, "self favor")
	})

	// Arbiter releases milestone 0 to worker -> bounty unfreezes back to ACTIVE
	testing.SetRealm(testing.NewUserRealm(arbiterAddr))
	ResolveDispute(cross(cur), id, 0, true, "Tests verified by arbiter")

	view := GetBountyView(id)
	if view.Status != StatusActive || view.ReleasedAmount != 1500000 || view.LockedUgnot != 1000000 {
		t.Fatalf("unexpected dispute state: %+v", view)
	}

	// Now expired bounty remaining balance can be reclaimed by sponsor
	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	reclaimed := ReclaimExpired(cross(cur), id)
	if reclaimed != 1000000 {
		t.Fatalf("expected 1000000 reclaimed, got %d", reclaimed)
	}
	view = GetBountyView(id)
	if view.Status != StatusCancelled || view.LockedUgnot != 0 {
		t.Fatalf("expected CANCELLED with 0 locked, got %+v", view)
	}
}

func TestSecurityGuardsAndAdversarialAborts(cur realm, t *testing.T) {
	expiry := runtime.ChainHeight() + 300

	// 1. CodeRealm MITM cannot spoof OriginSend payment
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/drain"))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000000)))
	assertPanics(t, "CodeRealm CreateBounty", func() {
		CreateBounty(
			cross(cur),
			"MITM Attempt",
			"Should abort at IsUserCall boundary",
			arbiterAddr.String(),
			"",
			"Step 1",
			"1000000",
			expiry,
		)
	})

	// 2. Underfunded -send must abort
	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 500)))
	assertPanics(t, "Underfunded CreateBounty", func() {
		CreateBounty(
			cross(cur),
			"Short Payment",
			"Milestone requires 1000000 ugnot",
			arbiterAddr.String(),
			"",
			"Step 1",
			"1000000",
			expiry,
		)
	})

	// 3. Create valid bounty to test unauthorized release & double-claim
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 1000000)))
	id := CreateBounty(
		cross(cur),
		"Guard Check Bounty",
		"Verify unauthorized transitions abort deterministically",
		arbiterAddr.String(),
		workerAddr.String(),
		"Audit",
		"1000000",
		expiry,
	)

	// Stranger cannot submit milestone
	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginSend(chain.Coins{})
	assertPanics(t, "Stranger SubmitMilestone", func() {
		SubmitMilestone(cross(cur), id, 0, "https://evil.invalid/pr", "deadbeef")
	})

	// Worker submits, then worker tries to self-approve
	testing.SetRealm(testing.NewUserRealm(workerAddr))
	SubmitMilestone(cross(cur), id, 0, "https://github.com/cocvn157/ok", "sha256:7777777")
	assertPanics(t, "Worker self-approve", func() {
		ApproveAndRelease(cross(cur), id, 0)
	})

	// Sponsor approves once, second approve must fail
	testing.SetRealm(testing.NewUserRealm(sponsorAddr))
	ApproveAndRelease(cross(cur), id, 0)
	assertPanics(t, "Double release", func() {
		ApproveAndRelease(cross(cur), id, 0)
	})

	if !strings.Contains(Render("audit"), "MILESTONE_RELEASED") {
		t.Fatalf("expected audit route to record MILESTONE_RELEASED")
	}
	if !strings.Contains(Render("safety"), "IsUserCall()") {
		t.Fatalf("expected safety route to document IsUserCall invariant")
	}
}
