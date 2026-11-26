package tavern

import (
	"chain"
	"chain/runtime"
	"strings"
	"testing"
)

const (
	validSpecHash  = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	validProofHash = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
)

var (
	addrSponsor    = chain.PackageAddress("gno.land/r/gnometavern/test_sponsor")
	addrWorker     = chain.PackageAddress("gno.land/r/gnometavern/test_worker")
	addrArbitrator = chain.PackageAddress("gno.land/r/gnometavern/test_arbitrator")
	addrIntruder   = chain.PackageAddress("gno.land/r/gnometavern/test_intruder")
)

func assertPanics(t *testing.T, label string, fn func()) {
	t.Helper()
	if ex := revive(fn); ex == nil {
		t.Fatalf("%s: expected panic/abort, but call succeeded", label)
	}
}

func TestHappyPathLifecycleAndEscrowConservation(cur realm, t *testing.T) {
	resetStateForTests()
	pkgAddr := chain.PackageAddress("gno.land/r/nym-tavern247/tavern")
	testing.IssueCoins(pkgAddr, chain.NewCoins(chain.NewCoin(DenomUgnot, 50_000_000)))

	// 1. Sponsor posts quest with 1,000,000 ugnot escrow; invalid or self-realm arbitrator rejected.
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(DenomUgnot, 1_000_000)))
	deadline := runtime.ChainHeight() + 50
	assertPanics(t, "invalid bech32 arbitrator", func() {
		PostQuest(cross(cur), "Bad Arb", validSpecHash, "Criteria", address("not_a_valid_bech32"), deadline)
	})
	assertPanics(t, "self-realm arbitrator", func() {
		PostQuest(cross(cur), "Realm Arb", validSpecHash, "Criteria", pkgAddr, deadline)
	})
	qid := PostQuest(
		cross(cur),
		"Deterministic Gno Escrow Verifier | v1",
		validSpecHash,
		"All unit tests and conservation invariants pass",
		addrArbitrator,
		deadline,
	)
	if qid != 1 {
		t.Fatalf("expected quest id 1, got %d", qid)
	}
	if TotalEscrowLocked() != 1_000_000 || ComputeActiveEscrowSum() != 1_000_000 {
		t.Fatalf("escrow mismatch after post: locked=%d sum=%d", TotalEscrowLocked(), ComputeActiveEscrowSum())
	}

	// 2. Unauthorized actor cannot claim if sponsor, worker claims cleanly.
	assertPanics(t, "sponsor self-claim", func() {
		ClaimQuest(cross(cur), qid, "self")
	})
	testing.SetRealm(testing.NewUserRealm(addrWorker))
	ClaimQuest(cross(cur), qid, "Implementing deterministic state machine")

	// 3. Invalid SHA-256 proof and unsafe URI schemes rejected; valid 64-hex SHA-256 + https succeeds.
	assertPanics(t, "short proof hash", func() {
		SubmitProof(cross(cur), qid, "deadbeef", "https://github.com/HindsightWise/gnome-tavern")
	})
	assertPanics(t, "javascript proof URI", func() {
		SubmitProof(cross(cur), qid, validProofHash, "javascript:alert(1)")
	})
	SubmitProof(cross(cur), qid, validProofHash, "https://github.com/HindsightWise/gnome-tavern")

	// 4. Intruder cannot release funds.
	testing.SetRealm(testing.NewUserRealm(addrIntruder))
	assertPanics(t, "intruder release", func() {
		ApproveAndRelease(cross(cur), qid)
	})

	// 5. Sponsor approves and releases escrowed ugnot; double release panics.
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	ApproveAndRelease(cross(cur), qid)
	if TotalEscrowLocked() != 0 || ComputeActiveEscrowSum() != 0 {
		t.Fatalf("escrow not zero after settlement: locked=%d sum=%d", TotalEscrowLocked(), ComputeActiveEscrowSum())
	}
	if TotalSettledUgnot() != 1_000_000 {
		t.Fatalf("expected settled=1000000, got %d", TotalSettledUgnot())
	}
	assertPanics(t, "double release", func() {
		ApproveAndRelease(cross(cur), qid)
	})

	// 6. Verify gnoweb Render routes and Markdown table sanitization.
	home := Render("")
	if !strings.Contains(home, "Deterministic Gno Escrow Verifier / v1") || !strings.Contains(home, "SETTLED") {
		t.Fatalf("unexpected home render: %s", home)
	}
	detail := Render("quest/1")
	if !strings.Contains(detail, validProofHash) {
		t.Fatalf("detail render missing proof hash: %s", detail)
	}
	guild := Render("guild")
	if !strings.Contains(guild, string(addrWorker)) || !strings.Contains(guild, "1000000") {
		t.Fatalf("guild render missing worker payout: %s", guild)
	}
}

func TestDisputeResolutionBothOutcomes(cur realm, t *testing.T) {
	resetStateForTests()
	pkgAddr := chain.PackageAddress("gno.land/r/nym-tavern247/tavern")
	testing.IssueCoins(pkgAddr, chain.NewCoins(chain.NewCoin(DenomUgnot, 50_000_000)))

	// Quest 1: Dispute awarded to worker.
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(DenomUgnot, 750_000)))
	q1 := PostQuest(cross(cur), "Audit Parser", validSpecHash, "Zero panics", addrArbitrator, runtime.ChainHeight()+40)

	testing.SetRealm(testing.NewUserRealm(addrWorker))
	ClaimQuest(cross(cur), q1, "Starting audit")
	SubmitProof(cross(cur), q1, validProofHash, "ipfs://bafyproof1")
	OpenDispute(cross(cur), q1, "Sponsor delayed approval past review window")

	// Non-arbitrator cannot resolve.
	assertPanics(t, "worker resolve dispute", func() {
		ResolveDispute(cross(cur), q1, true)
	})

	testing.SetRealm(testing.NewUserRealm(addrArbitrator))
	ResolveDispute(cross(cur), q1, true)
	if TotalEscrowLocked() != 0 || TotalSettledUgnot() != 750_000 {
		t.Fatalf("unexpected state after worker dispute win: locked=%d paid=%d", TotalEscrowLocked(), TotalSettledUgnot())
	}

	// Quest 2: Dispute refunded to sponsor.
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(DenomUgnot, 500_000)))
	q2 := PostQuest(cross(cur), "Indexer Hook", validSpecHash, "Matches schema", addrArbitrator, runtime.ChainHeight()+40)

	testing.SetRealm(testing.NewUserRealm(addrWorker))
	ClaimQuest(cross(cur), q2, "On it")
	SubmitProof(cross(cur), q2, validProofHash, "ipfs://bafyproof2")

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	OpenDispute(cross(cur), q2, "Artifact fails schema invariant")

	testing.SetRealm(testing.NewUserRealm(addrArbitrator))
	ResolveDispute(cross(cur), q2, false)
	if TotalEscrowLocked() != 0 || TotalSettledUgnot() != 750_000 {
		t.Fatalf("unexpected state after sponsor refund: locked=%d paid=%d", TotalEscrowLocked(), TotalSettledUgnot())
	}
	if ComputeActiveEscrowSum() != TotalEscrowLocked() {
		t.Fatalf("conservation invariant broken")
	}
}

func TestExpiredQuestRefund(cur realm, t *testing.T) {
	resetStateForTests()
	pkgAddr := chain.PackageAddress("gno.land/r/nym-tavern247/tavern")
	testing.IssueCoins(pkgAddr, chain.NewCoins(chain.NewCoin(DenomUgnot, 50_000_000)))

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(DenomUgnot, 250_000)))
	deadline := runtime.ChainHeight() + 10
	qid := PostQuest(cross(cur), "Expired Task", validSpecHash, "Complete before height", addrArbitrator, deadline)

	// Cannot cancel before deadline.
	assertPanics(t, "early cancel", func() {
		CancelExpired(cross(cur), qid)
	})

	testing.SkipHeights(15)
	CancelExpired(cross(cur), qid)
	if TotalEscrowLocked() != 0 || ComputeActiveEscrowSum() != 0 {
		t.Fatalf("escrow not cleared after expiry refund")
	}
}
