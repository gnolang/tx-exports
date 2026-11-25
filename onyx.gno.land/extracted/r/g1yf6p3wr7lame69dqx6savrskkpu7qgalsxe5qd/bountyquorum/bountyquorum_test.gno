package bountyquorum

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"
)

func expectPanic(t *testing.T, substr string, fn func()) {
	t.Helper()
	r := revive(fn)
	if r == nil {
		t.Fatalf("expected abort containing %q, but did not abort", substr)
	}
	got, _ := r.(string)
	if substr != "" && !strings.Contains(got, substr) {
		t.Fatalf("expected abort containing %q, got %q", substr, got)
	}
}

func TestFullQuestLifecycleAndZeroDustPayout(cur realm, t *testing.T) {
	defer resetState()

	pkgAddr := chain.PackageAddress("gno.land/r/g1yf6p3wr7lame69dqx6savrskkpu7qgalsxe5qd/bountyquorum")
	sponsor := chain.PackageAddress("gno.land/r/test/sponsor1")
	rev1 := chain.PackageAddress("gno.land/r/test/rev1")
	rev2 := chain.PackageAddress("gno.land/r/test/rev2")
	rev3 := chain.PackageAddress("gno.land/r/test/rev3")
	builder := chain.PackageAddress("gno.land/r/test/builder1")

	// Seed realm bank balance to simulate chain transfer on CreateQuest + TopUpQuest
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: 10000000}})

	// 1. Sponsor creates a 2-of-3 quorum quest funded with 1,000,000 ugnot (1 GNOT)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	csv := rev1.String() + "," + rev2.String() + "," + rev3.String()
	qid := CreateQuest(cross(cur), "Build Gno Indexer", "Index on-chain realms into SQLite", csv, 2, 72)
	if qid != 1 {
		t.Fatalf("expected quest id 1, got %d", qid)
	}

	// 2. Community tops up +500,000 ugnot -> total 1,500,000 ugnot
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 500000}})
	TopUpQuest(cross(cur), qid)

	// 3. Sponsor defines 3 milestones summing to 10000 bps (3333 + 3333 + 3334)
	m0 := AddMilestone(cross(cur), qid, "Schema & Parser", 3333)
	m1 := AddMilestone(cross(cur), qid, "Sync Engine", 3333)
	m2 := AddMilestone(cross(cur), qid, "CLI & Docs", 3334)
	if m0 != 0 || m1 != 1 || m2 != 2 {
		t.Fatalf("unexpected milestone indices: %d %d %d", m0, m1, m2)
	}

	// Adding beyond 10000 bps must panic
	expectPanic(t, "exceeds 10000", func() {
		AddMilestone(cross(cur), qid, "Overflow", 1)
	})

	// 4. Builder submits M#0; rev1 rejects, rev2 rejects -> REJECTED -> builder resubmits!
	testing.SetRealm(testing.NewUserRealm(builder))
	SubmitDeliverable(cross(cur), qid, 0, "https://github.com/example/pr/1", "sha256:v1", "initial draft")

	// Builder cannot review own submission
	expectPanic(t, "not a designated reviewer", func() {
		ReviewMilestone(cross(cur), qid, 0, true, "self approve")
	})

	testing.SetRealm(testing.NewUserRealm(rev1))
	out := ReviewMilestone(cross(cur), qid, 0, false, "missing migration tests")
	if out != "pending" {
		t.Fatalf("expected pending after 1 reject in 2-of-3, got %s", out)
	}
	// Double voting in same round must panic
	expectPanic(t, "already voted", func() {
		ReviewMilestone(cross(cur), qid, 0, true, "flip vote")
	})

	testing.SetRealm(testing.NewUserRealm(rev2))
	out = ReviewMilestone(cross(cur), qid, 0, false, "needs error handling")
	if out != "rejected" {
		t.Fatalf("expected rejected after 2 rejects in 2-of-3, got %s", out)
	}

	// 5. Builder fixes and resubmits Round 2 -> rev1 + rev3 approve -> auto-payout!
	testing.SetRealm(testing.NewUserRealm(builder))
	SubmitDeliverable(cross(cur), qid, 0, "https://github.com/example/pr/2", "sha256:v2", "added tests & error handling")

	testing.SetRealm(testing.NewUserRealm(rev1))
	if got := ReviewMilestone(cross(cur), qid, 0, true, "tests pass now"); got != "pending" {
		t.Fatalf("expected pending, got %s", got)
	}
	testing.SetRealm(testing.NewUserRealm(rev3))
	if got := ReviewMilestone(cross(cur), qid, 0, true, "LGTM"); got != "approved" {
		t.Fatalf("expected approved, got %s", got)
	}

	// Complete M#1 and M#2 to verify exact zero-dust payout summing to 1,500,000 ugnot
	for _, idx := range []int{1, 2} {
		testing.SetRealm(testing.NewUserRealm(builder))
		SubmitDeliverable(cross(cur), qid, idx, "https://github.com/example/pr/done", "sha256:ok", "done")
		testing.SetRealm(testing.NewUserRealm(rev1))
		ReviewMilestone(cross(cur), qid, idx, true, "good")
		testing.SetRealm(testing.NewUserRealm(rev2))
		if got := ReviewMilestone(cross(cur), qid, idx, true, "ship it"); got != "approved" {
			t.Fatalf("M#%d expected approved, got %s", idx, got)
		}
	}

	b := banker.NewReadonlyBanker()
	builderBal := b.GetCoins(builder).AmountOf("ugnot")
	if builderBal != 1500000 {
		t.Fatalf("expected builder to receive exact 1500000 ugnot (zero dust), got %d", builderBal)
	}

	q := questByID[qid]
	if q.Status != StatusCompleted || q.RemainingEscrow != 0 || q.PaidOut != 1500000 {
		t.Fatalf("unexpected final quest state: status=%s rem=%d paid=%d", q.Status, q.RemainingEscrow, q.PaidOut)
	}

	// Verify all Render routes produce expected output
	home := Render("")
	if !strings.Contains(home, "Build Gno Indexer") || !strings.Contains(home, "COMPLETED") {
		t.Fatalf("unexpected home render: %s", home)
	}
	detail := Render("quest/1")
	if !strings.Contains(detail, "Schema & Parser") || !strings.Contains(detail, "missing migration tests") {
		t.Fatalf("unexpected quest detail render: %s", detail)
	}
	prof := Render("builder/" + builder.String())
	if !strings.Contains(prof, "1.50 GNOT") || !strings.Contains(prof, "Q#1 M#2") {
		t.Fatalf("unexpected builder render: %s", prof)
	}
	stats := Render("stats")
	if !strings.Contains(stats, "\"total_disbursed_ugnot\":1500000") {
		t.Fatalf("unexpected stats json: %s", stats)
	}
}

func TestReclaimExpiredAndCancelSecurity(cur realm, t *testing.T) {
	defer resetState()

	pkgAddr := chain.PackageAddress("gno.land/r/g1yf6p3wr7lame69dqx6savrskkpu7qgalsxe5qd/bountyquorum")
	sponsor := chain.PackageAddress("gno.land/r/test/sponsor2")
	rev1 := chain.PackageAddress("gno.land/r/test/revA")
	stranger := chain.PackageAddress("gno.land/r/test/stranger")

	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: 5000000}})

	// Create quest 1 (to test cancel before payout)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 400000}})
	q1 := CreateQuest(cross(cur), "Cancelable Quest", "Summary", rev1.String(), 1, 24)

	// Stranger cannot cancel
	testing.SetRealm(testing.NewUserRealm(stranger))
	expectPanic(t, "only the sponsor", func() {
		CancelUnstarted(cross(cur), q1)
	})

	// Sponsor cancels cleanly
	testing.SetRealm(testing.NewUserRealm(sponsor))
	refund := CancelUnstarted(cross(cur), q1)
	if refund != 400000 {
		t.Fatalf("expected 400000 refund, got %d", refund)
	}

	// Create quest 2 (to test deadline enforcement & reclaim)
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 600000}})
	q2 := CreateQuest(cross(cur), "Expiring Quest", "Summary", rev1.String(), 1, 1)

	// Early reclaim must panic
	expectPanic(t, "not yet passed", func() {
		ReclaimExpired(cross(cur), q2)
	})

	// Advance time past 1 hour deadline
	testing.SkipHeights(1)
	questByID[q2].Deadline = time.Now().Add(-1 * time.Minute)
	refund2 := ReclaimExpired(cross(cur), q2)
	if refund2 != 600000 {
		t.Fatalf("expected 600000 expired refund, got %d", refund2)
	}
	if questByID[q2].Status != StatusReclaimed {
		t.Fatalf("expected RECLAIMED status, got %s", questByID[q2].Status)
	}
}
