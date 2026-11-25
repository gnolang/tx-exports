package tavernboard

import (
	"chain"
	"strings"
	"testing"
)

// Project testnet accounts (see testnet-account.txt in the project vault;
// addresses are public and safe to embed).
var (
	posterAddr = address("g1wcgeganvf6zkpyt8j2tx3h7p3f8afn0my8pw0k")
	agentAddr  = address("g1n9u4cn09v7mdzsusu7k75c6yxnscxdkrcas26u")
	pkgAddr    = chain.PackageAddress("gno.land/r/g1wcgeganvf6zkpyt8j2tx3h7p3f8afn0my8pw0k/tavernboard/v1")
)

func setupEscrow() {
	// Fund the realm account so escrow payouts/refunds can be made.
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: 100000000}})
	testing.SetHeight(1000)
}


// assertAborts runs f and fails the test unless f aborts (a panic crossing
// the realm boundary) with a message containing substr. It uses the revive
// builtin, the same mechanism as gno.land/p/nt/uassert — reimplemented here
// so the test suite needs no external package downloads.
func assertAborts(cur realm, t *testing.T, substr string, f func()) {
	t.Helper()
	r := revive(f)
	if r == nil {
		t.Fatalf("expected abort containing %q, but the call succeeded", substr)
	}
	msg, ok := r.(string)
	if !ok {
		t.Fatalf("expected abort containing %q, got non-string abort: %v", substr, r)
	}
	if !strings.Contains(msg, substr) {
		t.Fatalf("expected abort containing %q, got %q", substr, msg)
	}
}

// Full happy path: post -> claim -> submit -> confirm, escrow paid out,
// reputation credited.
func TestFullFlow(cur realm, t *testing.T) {
	setupEscrow()

	// Poster posts a quest with a 5 GNOT bounty attached.
	testing.SetRealm(testing.NewUserRealm(posterAddr))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 5000000}})
	id := PostQuest(cross(cur), "Write a tavern ballad", "Compose a short song about the Gnome Tavern.", 100)
	if id == 0 {
		t.Fatalf("expected non-zero quest id")
	}
	if got := QuestCount(); got != id {
		t.Fatalf("QuestCount = %d, want %d", got, id)
	}
	q := quests[id]
	if q.Status != StatusOpen || q.Bounty != 5000000 || q.Poster != posterAddr {
		t.Fatalf("unexpected quest after post: %+v", q)
	}
	if q.Deadline != 1100 {
		t.Fatalf("deadline = %d, want 1100", q.Deadline)
	}

	// Poster cannot claim their own quest.
	assertAborts(cur, t, "poster cannot claim their own quest", func() { ClaimQuest(cross(cur), id) })

	// Agent claims it.
	testing.SetRealm(testing.NewUserRealm(agentAddr))
	ClaimQuest(cross(cur), id)
	if q.Status != StatusClaimed || q.Claimer != agentAddr {
		t.Fatalf("unexpected quest after claim: %+v", q)
	}

	// Poster cannot submit proof; only the claimer can.
	testing.SetRealm(testing.NewUserRealm(posterAddr))
	assertAborts(cur, t, "only the claimer can submit proof", func() {
		SubmitProof(cross(cur), id, "https://example.com/ballad", "abc123")
	})

	// Claimer submits proof.
	testing.SetRealm(testing.NewUserRealm(agentAddr))
	SubmitProof(cross(cur), id, "https://example.com/ballad", "abc123")
	if q.Status != StatusSubmitted || q.ProofURL != "https://example.com/ballad" || q.ProofHash != "abc123" {
		t.Fatalf("unexpected quest after submit: %+v", q)
	}

	// Claimer cannot confirm their own work.
	assertAborts(cur, t, "only the poster can confirm", func() { ConfirmComplete(cross(cur), id) })

	// Poster confirms -> completed + reputation.
	testing.SetRealm(testing.NewUserRealm(posterAddr))
	ConfirmComplete(cross(cur), id)
	if q.Status != StatusCompleted {
		t.Fatalf("status = %v, want COMPLETED", q.Status)
	}
	if rep := ReputationOf(agentAddr); rep != 1 {
		t.Fatalf("agent reputation = %d, want 1", rep)
	}

	// Render output mentions the quest.
	if out := Render(""); !strings.Contains(out, "Write a tavern ballad") {
		t.Fatalf("board render missing quest title:\n%s", out)
	}
	if out := Render("quest/" + u64(id)); !strings.Contains(out, "COMPLETED") {
		t.Fatalf("quest render missing status:\n%s", out)
	}
	if s := GetQuest(id); !strings.Contains(s, "COMPLETED") {
		t.Fatalf("GetQuest = %q", s)
	}
}

// A quest with no attached bounty must be rejected.
func TestPostQuestRequiresBounty(cur realm, t *testing.T) {
	setupEscrow()
	testing.SetRealm(testing.NewUserRealm(posterAddr))
	testing.SetOriginSend(chain.Coins{})
	assertAborts(cur, t, "attach a bounty", func() {
		PostQuest(cross(cur), "Free labour", "No bounty attached.", 10)
	})
}

// Cancelling an OPEN quest refunds the poster and closes the quest.
func TestCancelOpen(cur realm, t *testing.T) {
	setupEscrow()
	testing.SetRealm(testing.NewUserRealm(posterAddr))
	id := createQuest(posterAddr, "Deliver a keg", "Bring one keg to the tavern cellar.", 2000000, 50)

	// A stranger cannot cancel it.
	testing.SetRealm(testing.NewUserRealm(agentAddr))
	assertAborts(cur, t, "only the poster can cancel", func() { CancelQuest(cross(cur), id) })

	testing.SetRealm(testing.NewUserRealm(posterAddr))
	CancelQuest(cross(cur), id)
	if quests[id].Status != StatusCancelled {
		t.Fatalf("status = %v, want CANCELLED", quests[id].Status)
	}
}

// A CLAIMED quest can only be cancelled after its deadline has passed.
func TestCancelClaimedAfterDeadline(cur realm, t *testing.T) {
	setupEscrow()
	testing.SetRealm(testing.NewUserRealm(posterAddr))
	id := createQuest(posterAddr, "Polish the mugs", "Every mug in the tavern, shining.", 1000000, 10)

	testing.SetRealm(testing.NewUserRealm(agentAddr))
	ClaimQuest(cross(cur), id)

	// Before the deadline the poster cannot cancel.
	testing.SetRealm(testing.NewUserRealm(posterAddr))
	assertAborts(cur, t, "cannot be cancelled", func() { CancelQuest(cross(cur), id) })

	// After the deadline the refund path opens.
	testing.SetHeight(2000)
	CancelQuest(cross(cur), id)
	if quests[id].Status != StatusCancelled {
		t.Fatalf("status = %v, want CANCELLED", quests[id].Status)
	}
}

// Unknown quest IDs are rejected everywhere.
func TestUnknownQuest(cur realm, t *testing.T) {
	setupEscrow()
	testing.SetRealm(testing.NewUserRealm(posterAddr))
	assertAborts(cur, t, "quest not found", func() { ClaimQuest(cross(cur), 999999) })
	if s := GetQuest(999999); s != "quest not found" {
		t.Fatalf("GetQuest(unknown) = %q", s)
	}
}
