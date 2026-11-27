package latch

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"testing"
)

var (
	alice = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	bob   = address("g1y0n2geu0rmdrm9u30c5fmk3ykkl2enw9n9yr2k")
	carol = address("g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr")
	dave  = address("g127j32x34c6y7j5d8t7s0s8u3w9x0y2z4a6b8c9") // only used when valid; let's stick to known valid bech32 below if needed
	realmAddr = address("g1f32nmr66mmu8yu3kty2z9y9pvsmwtymx7yz595")
)

const (
	baseNow = int64(1_800_000_000)
	daySec  = int64(86400)
)

func mustPanic(t *testing.T, label string, f func()) {
	t.Helper()
	defer func() {
		if r := recover(); r == nil {
			t.Fatalf("%s: expected panic, got none", label)
		}
	}()
	f()
}

func mustAbort(t *testing.T, label string, f func()) {
	t.Helper()
	if r := revive(f); r == nil {
		t.Fatalf("%s: expected cross-realm abort, got none", label)
	}
}

func TestCreateAndHappyPathAssigned(t *testing.T) {
	id := createDeal(alice, realmAddr, 3_000_000, "Audit vault", bob, carol, 1440, "Threat model|PoC suite", "1000000,2000000", baseNow)
	d := mustDeal(id)
	if d.Status != DealActive || d.WasOpenBounty {
		t.Fatalf("expected Active assigned deal, got status=%s open=%v", d.Status, d.WasOpenBounty)
	}
	if d.Remaining != 3_000_000 {
		t.Fatalf("expected remaining 3000000, got %d", d.Remaining)
	}

	submitMilestone(bob, id, 0, "https://github.com/org/repo/pull/1", baseNow+100)
	if d.Milestones[0].Status != MilestoneSubmitted {
		t.Fatalf("expected Submitted, got %s", d.Milestones[0].Status)
	}

	// Only client can release.
	mustPanic(t, "bob cannot release", func() {
		releaseMilestone(bob, id, 0)
	})

	to, amt := releaseMilestone(alice, id, 0)
	if to != bob || amt != 1_000_000 || d.Remaining != 2_000_000 || d.Status != DealActive {
		t.Fatalf("unexpected release state: to=%s amt=%d rem=%d st=%s", to, amt, d.Remaining, d.Status)
	}

	// Double release must panic.
	mustPanic(t, "double release", func() {
		releaseMilestone(alice, id, 0)
	})

	// Release second milestone directly (Pending -> Released allowed for client).
	_, amt2 := releaseMilestone(alice, id, 1)
	if amt2 != 2_000_000 || d.Remaining != 0 || d.Status != DealCompleted {
		t.Fatalf("expected Completed after final release: amt=%d rem=%d st=%s", amt2, d.Remaining, d.Status)
	}
}

func TestOpenBountyClaimReclaimAndCancel(t *testing.T) {
	id := createDeal(alice, realmAddr, 5_000_000, "CLI indexer", "", carol, 100, "Part 1", "5000000", baseNow)
	d := mustDeal(id)
	if d.Status != DealOpen || !d.WasOpenBounty {
		t.Fatalf("expected Open bounty, got %s", d.Status)
	}

	// Client and arbiter cannot claim.
	mustPanic(t, "client claim", func() { claimDeal(alice, id, baseNow+10) })
	mustPanic(t, "arbiter claim", func() { claimDeal(carol, id, baseNow+10) })

	claimDeal(bob, id, baseNow+10)
	if d.Status != DealActive || d.Worker != bob {
		t.Fatalf("expected Active bob, got %s %s", d.Status, d.Worker)
	}

	// Cancel blocked while Active.
	mustPanic(t, "cancel while active", func() { cancelDeal(alice, id) })

	// Reclaim blocked before inactivity timeout (half of 100m = 50m = 3000s).
	mustPanic(t, "reclaim too early", func() { reclaimInactiveDeal(alice, id, baseNow+10+2999) })

	// Reclaim succeeds after inactivity timeout when 0 milestones submitted.
	reclaimInactiveDeal(alice, id, baseNow+10+3000)
	if d.Status != DealOpen || d.Worker != "" || d.ClaimedAt != 0 {
		t.Fatalf("expected reopened Open deal, got %s %s", d.Status, d.Worker)
	}

	// Now client can cancel the open deal and recover 100%.
	refund := cancelDeal(alice, id)
	if refund != 5_000_000 || d.Remaining != 0 || d.Status != DealCancelled {
		t.Fatalf("unexpected cancel result: refund=%d rem=%d st=%s", refund, d.Remaining, d.Status)
	}
	mustPanic(t, "double cancel", func() { cancelDeal(alice, id) })
}

func TestReclaimBlockedAfterSubmissionAndAntiRansomDispute(t *testing.T) {
	id := createDeal(alice, realmAddr, 4_000_000, "Anti-ransom test", "", carol, 120, "M1|M2", "2000000,2000000", baseNow)
	claimDeal(bob, id, baseNow+10)

	// Zero-work ransom dispute MUST panic when 0 milestones are Submitted.
	mustPanic(t, "dispute with zero submitted", func() {
		raiseDispute(bob, id, baseNow+20)
	})

	submitMilestone(bob, id, 0, "commit:abc123", baseNow+30)

	// Reclaim must panic once worker submitted work.
	mustPanic(t, "reclaim after submit", func() {
		reclaimInactiveDeal(alice, id, baseNow+10+86400)
	})

	// Now dispute succeeds.
	raiseDispute(bob, id, baseNow+40)
	d := mustDeal(id)
	if d.Status != DealDisputed || d.DisputeDeadline != baseNow+40+7*daySec {
		t.Fatalf("unexpected dispute state: st=%s dl=%d", d.Status, d.DisputeDeadline)
	}
}

func TestMixedRefundExpiredWithAndWithoutArbiter(t *testing.T) {
	// With arbiter: M0 Released, M1 Submitted, M2 Pending.
	id1 := createDeal(alice, realmAddr, 6_000_000, "Mixed arbiter", bob, carol, 60, "M0|M1|M2", "1000000,2000000,3000000", baseNow)
	submitMilestone(bob, id1, 0, "done-0", baseNow+10)
	releaseMilestone(alice, id1, 0)
	submitMilestone(bob, id1, 1, "done-1", baseNow+20)

	// Before deadline panics.
	mustPanic(t, "refund before deadline", func() {
		refundExpired(alice, id1, baseNow+3599)
	})

	// At deadline, ONLY Pending M2 refunds; Submitted M1 stays protected for arbiter.
	ref1 := refundExpired(alice, id1, baseNow+3600)
	d1 := mustDeal(id1)
	if ref1 != 3_000_000 || d1.Remaining != 2_000_000 || d1.Status != DealActive {
		t.Fatalf("expected partial refund 3M rem 2M Active, got ref=%d rem=%d st=%s", ref1, d1.Remaining, d1.Status)
	}
	if d1.Milestones[2].Status != MilestoneRefunded || d1.Milestones[1].Status != MilestoneSubmitted {
		t.Fatalf("wrong milestone statuses: M1=%s M2=%s", d1.Milestones[1].Status, d1.Milestones[2].Status)
	}

	// Second refund call with only Submitted remaining must panic (no 0-ugnot refund).
	mustPanic(t, "no refundable milestones", func() {
		refundExpired(alice, id1, baseNow+3601)
	})

	// Without arbiter: Submitted M1 ALSO refunds after deadline.
	id2 := createDeal(alice, realmAddr, 3_000_000, "No arbiter expiry", bob, "", 60, "M0|M1", "1000000,2000000", baseNow)
	submitMilestone(bob, id2, 0, "done-0", baseNow+10)
	ref2 := refundExpired(alice, id2, baseNow+3600)
	d2 := mustDeal(id2)
	if ref2 != 3_000_000 || d2.Remaining != 0 || d2.Status != DealCancelled {
		t.Fatalf("expected full Cancelled refund 3M, got ref=%d rem=%d st=%s", ref2, d2.Remaining, d2.Status)
	}
}

func TestResolveDisputeAndTimeoutOddDust(t *testing.T) {
	// Case A: Arbiter rules workerWins = true -> Submitted goes to worker, Pending goes to client.
	id1 := createDeal(alice, realmAddr, 5_000_000, "Dispute worker wins", bob, carol, 120, "M0|M1", "2000000,3000000", baseNow)
	submitMilestone(bob, id1, 0, "pr/1", baseNow+10)
	raiseDispute(bob, id1, baseNow+20)
	mustPanic(t, "non-arbiter cannot resolve", func() { resolveDispute(alice, id1, true) })

	w, wp, c, cr := resolveDispute(carol, id1, true)
	d1 := mustDeal(id1)
	if w != bob || wp != 2_000_000 || c != alice || cr != 3_000_000 || d1.Remaining != 0 || d1.Status != DealCompleted {
		t.Fatalf("unexpected dispute split: wp=%d cr=%d rem=%d st=%s", wp, cr, d1.Remaining, d1.Status)
	}
	mustPanic(t, "double resolve", func() { resolveDispute(carol, id1, false) })

	// Case B: Arbiter rules workerWins = false -> 100% refund to client, Cancelled if none released.
	id2 := createDeal(alice, realmAddr, 2_000_000, "Dispute client wins", bob, carol, 120, "M0", "2000000", baseNow)
	submitMilestone(bob, id2, 0, "bad-pr", baseNow+10)
	raiseDispute(alice, id2, baseNow+20)
	_, wp2, _, cr2 := resolveDispute(carol, id2, false)
	d2 := mustDeal(id2)
	if wp2 != 0 || cr2 != 2_000_000 || d2.Status != DealCancelled {
		t.Fatalf("expected Cancelled 2M refund, got wp=%d cr=%d st=%s", wp2, cr2, d2.Status)
	}

	// Case C: Timeout fallback on 1 ugnot submitted + 4 ugnot pending (odd dust safety).
	id3 := createDeal(alice, realmAddr, 5, "Odd dust timeout", bob, carol, 120, "M0|M1", "1,4", baseNow)
	submitMilestone(bob, id3, 0, "tiny-proof", baseNow+10)
	raiseDispute(bob, id3, baseNow+20)

	mustPanic(t, "timeout too early", func() {
		resolveDisputeTimeout(bob, id3, baseNow+20+7*daySec-1)
	})
	_, wp3, _, cr3 := resolveDisputeTimeout(bob, id3, baseNow+20+7*daySec)
	d3 := mustDeal(id3)
	// submittedSum = 1 -> workerPayout = 0, clientRefund = 4 + 1 = 5.
	if wp3 != 0 || cr3 != 5 || d3.Remaining != 0 || d3.Status != DealCancelled {
		t.Fatalf("unexpected odd dust fallback: wp=%d cr=%d rem=%d st=%s", wp3, cr3, d3.Remaining, d3.Status)
	}
}

func TestValidationOverflowAndSanitization(t *testing.T) {
	// Invalid addresses & role collisions.
	mustPanic(t, "invalid worker addr", func() {
		createDeal(alice, realmAddr, 100, "Bad", address("not-bech32"), "", 60, "M0", "100", baseNow)
	})
	mustPanic(t, "invalid arbiter addr", func() {
		createDeal(alice, realmAddr, 100, "Bad", bob, address("g1bad"), 60, "M0", "100", baseNow)
	})
	mustPanic(t, "worker == client", func() {
		createDeal(alice, realmAddr, 100, "Bad", alice, "", 60, "M0", "100", baseNow)
	})
	mustPanic(t, "arbiter == worker", func() {
		createDeal(alice, realmAddr, 100, "Bad", bob, bob, 60, "M0", "100", baseNow)
	})
	mustPanic(t, "worker == realmAddr", func() {
		createDeal(alice, realmAddr, 100, "Bad", realmAddr, "", 60, "M0", "100", baseNow)
	})

	// Overflow & count & mismatch & whitespace guards.
	mustPanic(t, "int64 overflow sum", func() {
		createDeal(alice, realmAddr, 100, "Overflow", bob, "", 60, "M0|M1", "9223372036854775807,1", baseNow)
	})
	mustPanic(t, "sent mismatch", func() {
		createDeal(alice, realmAddr, 99, "Mismatch", bob, "", 60, "M0", "100", baseNow)
	})
	mustPanic(t, "whitespace/zero-width only title", func() {
		createDeal(alice, realmAddr, 100, " \u200b \n ", bob, "", 60, "M0", "100", baseNow)
	})
	mustPanic(t, "unicode blank-only title", func() {
		createDeal(alice, realmAddr, 100, "\u3000\u00a0\u2003", bob, "", 60, "M0", "100", baseNow)
	})
	folded := validateText("line1\nline2\tline3", maxTitleRunes, false)
	if folded != "line1 line2 line3" {
		t.Fatalf("expected newline/tab folded to space, got %q", folded)
	}
	mustPanic(t, "over 80 runes title", func() {
		createDeal(alice, realmAddr, 100, strings.Repeat("a", 81), bob, "", 60, "M0", "100", baseNow)
	})
	mustPanic(t, "11 milestones", func() {
		createDeal(alice, realmAddr, 11, "Too many", bob, "", 60, "a|b|c|d|e|f|g|h|i|j|k", "1,1,1,1,1,1,1,1,1,1,1", baseNow)
	})

	// Markdown / table injection neutralization & truncate-before-escape.
	inj := "Fix [phish](https://evil.com) | `code`\nnext\u202eline\\trail"
	clean := sanitizeInline(inj, 80)
	if strings.Contains(clean, "\n") || strings.Contains(clean, "\u202e") {
		t.Fatalf("unsafe sanitized string: %q", clean)
	}
	if !strings.Contains(clean, `\|`) || !strings.Contains(clean, `\[`) {
		t.Fatalf("expected escaped markdown tokens, got %q", clean)
	}
	cut := sanitizeInline(`abc\def`, 4)
	if cut != `abc\\...` {
		t.Fatalf("unexpected truncated backslash escape: %q", cut)
	}

	// Render & ExportDealsJSON sanity (including deliverableRef without outer backticks).
	idInj := createDeal(alice, realmAddr, 100, "Render check", bob, "", 60, "M0", "100", baseNow)
	submitMilestone(bob, idInj, 0, "foo` https://evil.com | bar", baseNow+10)
	injOut := Render("deal/" + strconv.Itoa(idInj))
	if !strings.Contains(injOut, "foo\\`") || strings.Contains(injOut, "`foo\\`") {
		t.Fatalf("expected escaped backtick outside code span, got %s", injOut)
	}

	// Render & ExportDealsJSON sanity.
	home := Render("")
	if !strings.Contains(home, "Latch") {
		t.Fatalf("unexpected Render output: %s", home)
	}
	clamped := Render("?page=9999")
	if !strings.Contains(clamped, "Deals (Page") {
		t.Fatalf("expected clamped page render, got %s", clamped)
	}
	detail := Render("deal/1")
	if !strings.Contains(detail, "Latch Deal #1") {
		t.Fatalf("expected deal detail render, got %s", detail)
	}
	badDetail := Render("deal/999999")
	if !strings.Contains(badDetail, "Deals (Page") {
		t.Fatalf("expected fallback to list on bad deal id, got %s", badDetail)
	}
	js := ExportDealsJSON(0, 10)
	if !strings.HasPrefix(js, `{"stats":`) || !strings.Contains(js, `"deals":[`) {
		t.Fatalf("invalid ExportDealsJSON output: %s", js)
	}
}

func TestCrossingBankerAndOriginSendGuards(cur realm, t *testing.T) {
	pkgAddr := chain.PackageAddress("gno.land/r/g13dx8qxkxcjnhazc0wx3d9n4jw729m5h2g2nt35/latch")
	testing.IssueCoins(pkgAddr, chain.NewCoins(chain.NewCoin(ugnotDenom, 10_000_000)))
	testing.IssueCoins(alice, chain.NewCoins(chain.NewCoin(ugnotDenom, 10_000_000)))
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(ugnotDenom, 2_500_000)))

	id := CreateDeal(cross(cur), "Crossing live test", "", carol, 120, "Step 1|Step 2", "1000000,1500000")
	if id < 1 {
		t.Fatalf("expected valid id, got %d", id)
	}

	// Sending coins to ClaimDeal must panic.
	testing.IssueCoins(bob, chain.NewCoins(chain.NewCoin(ugnotDenom, 100)))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(ugnotDenom, 1)))
	mustAbort(t, "ClaimDeal rejects attached coins", func() {
		ClaimDeal(cross(cur), id)
	})

	// ClaimDeal with 0 coins succeeds.
	testing.SetOriginSend(nil)
	ClaimDeal(cross(cur), id)

	// Non-EOA code realm caller must panic.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/proxy"))
	mustAbort(t, "non-EOA rejected", func() {
		SubmitMilestone(cross(cur), id, 0, "https://github.com/org/repo/pull/1")
	})

	// Bob submits and Alice releases via real banker.SendCoins.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	SubmitMilestone(cross(cur), id, 0, "https://github.com/org/repo/pull/99")

	ro := banker.NewReadonlyBanker()
	bobBefore := ro.GetCoin(bob, ugnotDenom)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	paid := ReleaseMilestone(cross(cur), id, 0)
	if paid != 1_000_000 {
		t.Fatalf("expected paid 1000000, got %d", paid)
	}
	bobAfter := ro.GetCoin(bob, ugnotDenom)
	if bobAfter-bobBefore != 1_000_000 {
		t.Fatalf("expected bob balance +1000000, got %d", bobAfter-bobBefore)
	}

	// Render shows the created deal id.
	out := Render("deal/" + strconv.Itoa(id))
	if !strings.Contains(out, "Crossing live test") {
		t.Fatalf("expected crossing deal in Render, got %s", out)
	}
}
