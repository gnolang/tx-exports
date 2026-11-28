package tavernrules

import "testing"

// Day-3 adversarial tests (hardening review).
//
// Each test pins a property an attacker would try to break. Tests
// marked [PRE-FIX FAIL] failed against the day-2 code and pass only
// after the day-3 fix; the others document behaviour that was already
// correct and must not regress.
//
// Shared helpers (mustBounty, mustCommit, mustRevealed, expectPanic,
// repeatChar, actor/title/salt constants) live in tavernrules_test.gno.

// mustBountyAs builds the standard 5/3/1/0.5 GNOT bounty with a
// caller-chosen sponsor and arbiter, for role-edge tests.
func mustBountyAs(t *testing.T, sponsor, arbiter address) Bounty {
	t.Helper()
	b := NewBounty(1, sponsor, arbiter, "TavernVault audit",
		"gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/vault",
		5000000, 3000000, 1000000, 500000, 1000, 1000+2592000)
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("fresh bounty violates invariant: %s", msg)
	}
	return b
}

// A third distinct reveal salt: several adversarial tests put three
// findings on one bounty, and each needs its own commit hash (the
// day-3 rule blocks re-committing a hash carried by any non-expired
// finding on the same bounty).
const revealSalt3 = "saltsaltsaltsal3"

// mustRevealedSalt commits and reveals a finding with an explicit
// salt, so tests with several findings per bounty get distinct
// commit hashes.
func mustRevealedSalt(t *testing.T, b *Bounty, id uint64, hunter address, sev Severity, commitHeight, revealHeight int64, salt string) Finding {
	t.Helper()
	hash := MakeCommitment(b.ID(), sev, revealTitle, revealPoc, salt)
	f := CommitFinding(b, nil, id, hunter, sev, hash, commitHeight)
	f.Reveal(b, f.Hunter(), revealTitle, revealPoc, salt, revealHeight)
	return f
}

// ---------------------------------------------------------------------------
// T2 / §5.6 — tier-once MUST NOT depend on the caller-supplied `others`
// slice. The day-2 code enforced tier-once ONLY via TierAlreadyPaid
// (others), so a realm that passes nil/empty others could pay the
// same tier twice — the pool check does not catch it for cheap tiers:
// a second Low accept costs 500k against a 9M pool.
// [PRE-FIX FAIL]
// ---------------------------------------------------------------------------

func TestAdversarialTierOnceWithoutOthers(t *testing.T) {
	b := mustBounty(t)
	// First Low finding: paid 500k.
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevLow, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevLow, "confirmed low", 0, nil, nil, 1200)
	if b.PoolLeft() != 9000000 {
		t.Fatalf("after first Low accept: left %d, want 9000000", b.PoolLeft())
	}
	// Second Low finding, decided with NO others list at all (a realm
	// that forgot to pass the bounty's findings). Must still panic.
	f2 := mustRevealedSalt(t, &b, 2, hunter2Addr, SevLow, 1300, 1400, revealSalt2)
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevLow, "also low", 0, nil, nil, 1500)
	})
	if f2.Status() != FindingRevealed || f2.PaidAmount() != 0 {
		t.Fatalf("failed second Low accept must leave finding Revealed/unpaid: %+v", f2)
	}
	if b.PoolLeft() != 9000000 || b.PaidOut() != 500000 {
		t.Fatalf("failed accept moved money: left %d paid %d", b.PoolLeft(), b.PaidOut())
	}
	assertInvariants(t, &b, []Finding{f1, f2})
}

func TestAdversarialClaimTierOnceWithoutOthers(t *testing.T) {
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevLow, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevLow, "confirmed low", 0, nil, nil, 1200)
	// Second Low finding waits out both windows, then claims — with no
	// others list. The per-tier flag on the bounty must stop it.
	f2 := mustRevealedSalt(t, &b, 2, hunter2Addr, SevLow, 1300, 1400, revealSalt2)
	expectPanic(t, func() {
		f2.ClaimPayout(&b, hunter2Addr, nil, ClaimableAfter(f2.ReviewDeadline())+1)
	})
	if f2.Status() != FindingRevealed || f2.PaidAmount() != 0 {
		t.Fatalf("failed claim must leave finding Revealed/unpaid: %+v", f2)
	}
	if b.PoolLeft() != 9000000 || b.PaidOut() != 500000 {
		t.Fatalf("failed claim moved money: left %d paid %d", b.PoolLeft(), b.PaidOut())
	}
	assertInvariants(t, &b, []Finding{f1, f2})
}

// ---------------------------------------------------------------------------
// T3/T7 — commit-hash squatting after the original is decided. The
// day-2 live-hash check only blocked hashes carried by IN-FLIGHT
// findings, so once the original was Accepted (salt now public from
// the reveal) anyone could re-commit the identical hash and reveal
// it — and, if the arbiter corrected the tier, be paid for the same
// bug a second time at a different tier. Only an Expired (never
// revealed) hash may be committed again.
// [PRE-FIX FAIL]
// ---------------------------------------------------------------------------

func TestAdversarialSameHashAfterAcceptRejected(t *testing.T) {
	sameHash := MakeCommitment(1, SevCritical, revealTitle, revealPoc, revealSalt)
	// After Accept: the hash is public, the finding is paid — no one
	// may squat it again.
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	expectPanic(t, func() {
		CommitFinding(&b, []Finding{f1}, 2, hunter2Addr, SevCritical, sameHash, 1300)
	})
	// After Reject: contents were revealed (public) and judged invalid
	// — the identical report must not be re-filed under a new id.
	b2 := mustBounty(t)
	g1 := mustRevealed(t, &b2, 1, hunterAddr, SevCritical, 1000, 1100)
	g1.ApplyVerdict(&b2, arbiterAddr, VerdictReject, 0, "not valid", 0, nil, nil, 1200)
	expectPanic(t, func() {
		CommitFinding(&b2, []Finding{g1}, 2, hunter2Addr, SevCritical, sameHash, 1300)
	})
	// After Duplicate: same — the hash stays spent.
	b3 := mustBounty(t)
	h1 := mustRevealed(t, &b3, 1, hunterAddr, SevCritical, 1000, 1100)
	h1.ApplyVerdict(&b3, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	hash2 := MakeCommitment(b3.ID(), SevCritical, revealTitle, revealPoc, revealSalt2)
	h2 := CommitFinding(&b3, []Finding{h1}, 2, hunter2Addr, SevCritical, hash2, 1300)
	h2.Reveal(&b3, hunter2Addr, revealTitle, revealPoc, revealSalt2, 1400)
	h2.ApplyVerdict(&b3, arbiterAddr, VerdictDuplicate, 0, "same bug as #1", h1.ID(), &h1, []Finding{h1}, 1500)
	expectPanic(t, func() {
		CommitFinding(&b3, []Finding{h1, h2}, 3, hunterAddr, SevCritical, hash2, 1600)
	})
	assertInvariants(t, &b3, []Finding{h1, h2})
}

// ---------------------------------------------------------------------------
// T7 — first-valid-wins tie: two commits in the SAME block have equal
// committedAt, so the day-2 strict-earlier check made a same-block
// duplicate unmarkable (arbiter could neither Duplicate it — panic —
// nor Accept it — tier already paid). The commit order inside a
// block is the finding id order, so an original with equal height
// but a LOWER id is a valid duplicate target; equal height with a
// HIGHER id is not.
// [PRE-FIX FAIL]
// ---------------------------------------------------------------------------

func TestAdversarialDuplicateSameHeightTieBreak(t *testing.T) {
	b := mustBounty(t)
	// Both commits land at height 1000; #1 is first in the block.
	// f2 uses its own salt, so its hash differs from f1's.
	f1 := mustCommit(t, &b, 1, hunterAddr, SevCritical, 1000)
	f2 := CommitFinding(&b, []Finding{f1}, 2, hunter2Addr, SevCritical,
		MakeCommitment(b.ID(), SevCritical, revealTitle, revealPoc, revealSalt2), 1000)
	f1.Reveal(&b, hunterAddr, revealTitle, revealPoc, revealSalt, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	f2.Reveal(&b, hunter2Addr, revealTitle, revealPoc, revealSalt2, 1300)
	p := f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "same bug, same block, #1 first", f1.ID(), &f1, []Finding{f1}, 1400)
	if p.Due() {
		t.Fatalf("same-block duplicate must not pay: %+v", p)
	}
	if f2.Status() != FindingDuplicate || f2.DuplicateOf() != f1.ID() {
		t.Fatalf("same-block duplicate wrong: %+v", f2)
	}
	// The reverse direction must still fail: #1 cannot duplicate #2 —
	// same height, but the "original" has the HIGHER id.
	b2 := mustBounty(t)
	g1 := mustRevealed(t, &b2, 1, hunterAddr, SevCritical, 1000, 1100)
	g2 := mustRevealedSalt(t, &b2, 2, hunter2Addr, SevCritical, 1000, 1100, revealSalt2)
	all := []Finding{g1, g2}
	expectPanic(t, func() {
		g1.ApplyVerdict(&b2, arbiterAddr, VerdictDuplicate, 0, "backwards", 2, &all[1], nil, 1200)
	})
	assertInvariants(t, &b, []Finding{f1, f2})
}

// ---------------------------------------------------------------------------
// T4 — self-payment: an arbiter who is also the hunter (or a sponsor
// who is also the hunter) must not be able to verdict Accept on their
// own finding and pay themselves from the sponsor's pool. The bar is
// on the money path only (doAccept); Duplicate/Reject pay nothing.
// [PRE-FIX FAIL]
// ---------------------------------------------------------------------------

func TestAdversarialSelfAcceptBarred(t *testing.T) {
	// Arbiter == hunter: the arbiter cannot Accept their own finding.
	b := mustBountyAs(t, sponsorAddr, hunterAddr)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	expectPanic(t, func() {
		f.ApplyVerdict(&b, hunterAddr, VerdictAccept, SevCritical, "self-dealing", 0, nil, nil, 1200)
	})
	if f.Status() != FindingRevealed || f.PaidAmount() != 0 {
		t.Fatalf("blocked self-accept must leave finding Revealed/unpaid: %+v", f)
	}
	// The finding is NOT bricked: the sponsor (a different address)
	// can still decide it after the arbiter window.
	p := f.SponsorVerdict(&b, sponsorAddr, VerdictAccept, SevCritical, "sponsor confirms", 0, nil, nil, f.ReviewDeadline()+1)
	if !p.Due() || p.Amount != 5000000 {
		t.Fatalf("sponsor verdict after blocked self-accept wrong: %+v", p)
	}
	assertInvariants(t, &b, []Finding{f})
}

func TestAdversarialSponsorSelfAcceptBarred(t *testing.T) {
	// Sponsor == hunter: the sponsor cannot SponsorVerdict Accept on
	// their own finding once the arbiter window has passed.
	b := mustBountyAs(t, hunterAddr, arbiterAddr)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	expectPanic(t, func() {
		f.SponsorVerdict(&b, hunterAddr, VerdictAccept, SevCritical, "paying myself", 0, nil, nil, f.ReviewDeadline()+1)
	})
	if f.Status() != FindingRevealed || f.PaidAmount() != 0 {
		t.Fatalf("blocked sponsor self-accept must leave finding Revealed/unpaid: %+v", f)
	}
	// The timeout backstop still works: the hunter claims after the
	// sponsor window (that path pays the hunter by design, and the
	// money is the sponsor's own pool here — no third-party theft).
	p := f.ClaimPayout(&b, hunterAddr, nil, ClaimableAfter(f.ReviewDeadline())+1)
	if !p.Due() || p.Amount != 5000000 {
		t.Fatalf("claim after blocked sponsor self-accept wrong: %+v", p)
	}
	assertInvariants(t, &b, []Finding{f})
}

// ---------------------------------------------------------------------------
// T5 — Disputed findings had NO timeout ladder: a Disputed finding
// could only move by arbiter re-verdict, and SponsorVerdict /
// ClaimPayout both required Revealed. If the arbiter went silent
// after a dispute, the finding (and the bounty — Close/Cancel are
// blocked by in-flight Disputed findings) was stuck forever, pool
// locked forever. The ladder now applies to disputes too: arbiter
// re-verdict within ReviewWindow of the dispute, then sponsor within
// a further SponsorWindow, then hunter claim.
// [PRE-FIX FAIL]
// ---------------------------------------------------------------------------

func TestAdversarialDisputedTimeoutLadder(t *testing.T) {
	// Arbiter re-verdict exactly at disputedAt + ReviewWindow: allowed.
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "no", 0, nil, nil, 1200)
	f1.Dispute(hunterAddr, "dispute", 1300)
	p := f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "on re-review, confirmed", 0, nil, nil, 1300+ReviewWindow)
	if !p.Due() || p.Amount != 5000000 {
		t.Fatalf("arbiter re-verdict at dispute deadline wrong: %+v", p)
	}
	assertInvariants(t, &b, []Finding{f1})

	// One block past that deadline the arbiter loses the re-verdict.
	b2 := mustBounty(t)
	f2 := mustRevealed(t, &b2, 1, hunterAddr, SevCritical, 1000, 1100)
	f2.ApplyVerdict(&b2, arbiterAddr, VerdictReject, 0, "no", 0, nil, nil, 1200)
	f2.Dispute(hunterAddr, "dispute", 1300)
	expectPanic(t, func() {
		f2.ApplyVerdict(&b2, arbiterAddr, VerdictAccept, SevCritical, "too late", 0, nil, nil, 1300+ReviewWindow+1)
	})
	// ... and the sponsor may decide instead, one block into the
	// sponsor window.
	p2 := f2.SponsorVerdict(&b2, sponsorAddr, VerdictAccept, SevCritical, "sponsor decides the dispute", 0, nil, nil, 1300+ReviewWindow+1)
	if !p2.Due() || p2.Amount != 5000000 {
		t.Fatalf("sponsor verdict on disputed finding wrong: %+v", p2)
	}
	assertInvariants(t, &b2, []Finding{f2})

	// Sponsor window for disputes ends at disputedAt + ReviewWindow +
	// SponsorWindow; after that the hunter may claim the finding.
	b3 := mustBounty(t)
	f3 := mustRevealed(t, &b3, 1, hunterAddr, SevHigh, 1000, 1100)
	f3.ApplyVerdict(&b3, arbiterAddr, VerdictReject, 0, "no", 0, nil, nil, 1200)
	f3.Dispute(hunterAddr, "dispute", 1300)
	claimable := 1300 + ReviewWindow + SponsorWindow
	expectPanic(t, func() {
		f3.SponsorVerdict(&b3, sponsorAddr, VerdictAccept, SevHigh, "too late", 0, nil, nil, claimable+1)
	})
	expectPanic(t, func() {
		f3.ClaimPayout(&b3, hunterAddr, nil, claimable)
	})
	p3 := f3.ClaimPayout(&b3, hunterAddr, nil, claimable+1)
	if !p3.Due() || p3.Amount != 3000000 {
		t.Fatalf("claim on disputed finding wrong: %+v", p3)
	}
	if f3.Status() != FindingAccepted || f3.SeverityFinal() != SevHigh {
		t.Fatalf("claimed disputed finding wrong: %+v", f3)
	}
	assertInvariants(t, &b3, []Finding{f3})
}

// ---------------------------------------------------------------------------
// T2 — double payout, every path combination. (Single-path repeats
// were covered on day 2; these pin the cross-path combinations.)
// ---------------------------------------------------------------------------

func TestAdversarialDoublePayoutAllPaths(t *testing.T) {
	// SponsorVerdict Accept, then SponsorVerdict again, then Claim.
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f1.SponsorVerdict(&b, sponsorAddr, VerdictAccept, SevCritical, "arbiter silent", 0, nil, nil, f1.ReviewDeadline()+1)
	expectPanic(t, func() {
		f1.SponsorVerdict(&b, sponsorAddr, VerdictAccept, SevCritical, "again", 0, nil, nil, f1.ReviewDeadline()+2)
	})
	expectPanic(t, func() {
		f1.ClaimPayout(&b, hunterAddr, nil, ClaimableAfter(f1.ReviewDeadline())+1)
	})
	expectPanic(t, func() {
		f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "again", 0, nil, nil, 1300)
	})
	if b.PaidOut() != 5000000 || f1.PaidAmount() != 5000000 {
		t.Fatalf("double payout moved money: paid %d finding paid %d", b.PaidOut(), f1.PaidAmount())
	}
	assertInvariants(t, &b, []Finding{f1})

	// Dispute -> Accept, then Accept again, then Dispute again.
	b2 := mustBounty(t)
	f2 := mustRevealed(t, &b2, 1, hunterAddr, SevHigh, 1000, 1100)
	f2.ApplyVerdict(&b2, arbiterAddr, VerdictReject, 0, "no", 0, nil, nil, 1200)
	f2.Dispute(hunterAddr, "dispute", 1300)
	f2.ApplyVerdict(&b2, arbiterAddr, VerdictAccept, SevHigh, "confirmed on re-review", 0, nil, nil, 1400)
	expectPanic(t, func() {
		f2.ApplyVerdict(&b2, arbiterAddr, VerdictAccept, SevHigh, "again", 0, nil, nil, 1500)
	})
	expectPanic(t, func() { f2.Dispute(hunterAddr, "dispute an accepted finding", 1500) })
	expectPanic(t, func() {
		f2.ClaimPayout(&b2, hunterAddr, nil, ClaimableAfter(f2.ReviewDeadline())+1)
	})
	if b2.PaidOut() != 3000000 {
		t.Fatalf("dispute-accept double payout: paid %d", b2.PaidOut())
	}
	assertInvariants(t, &b2, []Finding{f2})

	// Accept, then ClaimPayout.
	b3 := mustBounty(t)
	f3 := mustRevealed(t, &b3, 1, hunterAddr, SevCritical, 1000, 1100)
	f3.ApplyVerdict(&b3, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	expectPanic(t, func() {
		f3.ClaimPayout(&b3, hunterAddr, nil, ClaimableAfter(f3.ReviewDeadline())+1)
	})
	assertInvariants(t, &b3, []Finding{f3})
}

// ---------------------------------------------------------------------------
// T7 — duplicate target must be a live, valid original: Rejected,
// Disputed, Duplicate and Expired originals are all rejected.
// (Committed and cross-bounty originals were covered on day 2.)
// ---------------------------------------------------------------------------

func TestAdversarialDuplicateOriginalMustBeLive(t *testing.T) {
	b := mustBounty(t)
	orig := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 900, 1000)
	f := mustRevealedSalt(t, &b, 2, hunter2Addr, SevCritical, 1300, 1400, revealSalt2)
	// Original Rejected.
	orig.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "not valid", 0, nil, nil, 1100)
	expectPanic(t, func() {
		f.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup of rejected", orig.ID(), &orig, nil, 1500)
	})
	// Original Disputed (rejected, then disputed).
	orig.Dispute(hunterAddr, "dispute", 1200)
	expectPanic(t, func() {
		f.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup of disputed", orig.ID(), &orig, nil, 1500)
	})
	// Original Duplicate: a duplicate may not point at a duplicate.
	b2 := mustBounty(t)
	o1 := mustRevealed(t, &b2, 1, hunterAddr, SevCritical, 900, 1000)
	o1.ApplyVerdict(&b2, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1100)
	o2 := mustRevealedSalt(t, &b2, 2, hunter2Addr, SevCritical, 1200, 1300, revealSalt2)
	o2.ApplyVerdict(&b2, arbiterAddr, VerdictDuplicate, 0, "dup of #1", o1.ID(), &o1, nil, 1400)
	g := mustRevealedSalt(t, &b2, 3, hunterAddr, SevCritical, 1500, 1600, revealSalt3)
	expectPanic(t, func() {
		g.ApplyVerdict(&b2, arbiterAddr, VerdictDuplicate, 0, "dup of a duplicate", o2.ID(), &o2, nil, 1700)
	})
	// Original Expired (never revealed).
	b3 := mustBounty(t)
	e := mustCommit(t, &b3, 1, hunterAddr, SevCritical, 900)
	e.ExpireCommit(900 + RevealWindow + 1)
	h := mustRevealed(t, &b3, 2, hunter2Addr, SevCritical, 30000, 30100)
	expectPanic(t, func() {
		h.ApplyVerdict(&b3, arbiterAddr, VerdictDuplicate, 0, "dup of expired", e.ID(), &e, nil, 30200)
	})
	assertInvariants(t, &b, []Finding{orig, f})
	assertInvariants(t, &b2, []Finding{o1, o2, g})
	assertInvariants(t, &b3, []Finding{e, h})
}

// ---------------------------------------------------------------------------
// T3 — reveal must reject a wrong title or a wrong PoC URL, not just
// a wrong salt (salt was covered on day 2).
// ---------------------------------------------------------------------------

func TestAdversarialRevealMismatchVariants(t *testing.T) {
	b := mustBounty(t)
	f1 := mustCommit(t, &b, 1, hunterAddr, SevCritical, 1000)
	expectPanic(t, func() {
		f1.Reveal(&b, hunterAddr, "A different title", revealPoc, revealSalt, 1100)
	})
	// f2 commits with salt2 (distinct hash from f1) and reveals with a
	// different PoC URL but the matching salt, so only the URL mismatches.
	hash2 := MakeCommitment(b.ID(), SevCritical, revealTitle, revealPoc, revealSalt2)
	f2 := CommitFinding(&b, nil, 2, hunterAddr, SevCritical, hash2, 1000)
	expectPanic(t, func() {
		f2.Reveal(&b, hunterAddr, revealTitle, "https://example.com/other-poc", revealSalt2, 1100)
	})
	if f1.Status() != FindingCommitted || f2.Status() != FindingCommitted {
		t.Fatalf("failed reveals must leave findings Committed")
	}
	assertInvariants(t, &b, []Finding{f1, f2})
}

// ---------------------------------------------------------------------------
// T11 — TopUp that lands exactly on MaxInt64 is allowed (checked
// math, not a ban on big values); one ugnot more must panic, and
// the invariant must still hold at the boundary.
// ---------------------------------------------------------------------------

func TestAdversarialTopUpMaxInt64Boundary(t *testing.T) {
	b := mustBounty(t)
	b.TopUp(MaxInt64 - b.PoolTotal())
	if b.PoolTotal() != MaxInt64 || b.PoolLeft() != MaxInt64 {
		t.Fatalf("exact MaxInt64 top-up wrong: total %d left %d", b.PoolTotal(), b.PoolLeft())
	}
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("invariant broken at MaxInt64 pool: %s", msg)
	}
	expectPanic(t, func() { b.TopUp(1) })
	if b.PoolTotal() != MaxInt64 {
		t.Fatalf("failed top-up changed the pool: %d", b.PoolTotal())
	}
}

// ---------------------------------------------------------------------------
// Negative heights are nonsense input from a chain that never goes
// below 0: reject them at construction instead of building
// deadlines from them.
// [PRE-FIX FAIL]
// ---------------------------------------------------------------------------

func TestAdversarialNegativeHeightsRejected(t *testing.T) {
	expectPanic(t, func() {
		NewBounty(9, sponsorAddr, arbiterAddr, "T", "S",
			5000000, 3000000, 1000000, 500000, -1, 1000)
	})
	expectPanic(t, func() {
		NewFinding(9, 1, hunterAddr, SevCritical,
			MakeCommitment(1, SevCritical, revealTitle, revealPoc, revealSalt), -1, 1000)
	})
	if msg := ValidateNewBounty(sponsorAddr, arbiterAddr, "T", "S",
		5000000, 3000000, 1000000, 500000, -1, 1000); msg == "" {
		t.Errorf("negative createdAt accepted by ValidateNewBounty")
	}
	if msg := ValidateNewFinding(hunterAddr, SevCritical,
		MakeCommitment(1, SevCritical, revealTitle, revealPoc, revealSalt), -1, 1000); msg == "" {
		t.Errorf("negative committedAt accepted by ValidateNewFinding")
	}
}

// ---------------------------------------------------------------------------
// T2 / §5.6 — the per-tier flag lives in RecordPayout itself, the
// single choke point for hunter money: a second payout for the same
// tier panics even when the pool could cover it, while a different
// tier still pays. TopUp must not re-open a paid tier.
// ---------------------------------------------------------------------------

func TestAdversarialRecordPayoutTierFlag(t *testing.T) {
	b := mustBounty(t)
	if b.TierPaid(SevLow) || b.TierPaid(SevCritical) {
		t.Fatalf("fresh bounty must have no tier paid")
	}
	if b.TierPaid(Severity(0)) || b.TierPaid(Severity(9)) {
		t.Fatalf("invalid severity must report unpaid, not panic")
	}
	p := b.RecordPayout(hunterAddr, SevLow, 500000)
	if !p.Due() || !b.TierPaid(SevLow) {
		t.Fatalf("Low tier must be flagged paid after payout: %+v", b)
	}
	// Same tier again: pool could cover it (9M left), flag must stop it.
	expectPanic(t, func() { b.RecordPayout(hunter2Addr, SevLow, 500000) })
	// Invalid severity panics too.
	expectPanic(t, func() { b.RecordPayout(hunterAddr, Severity(0), 500000) })
	// A different tier still pays.
	b.RecordPayout(hunterAddr, SevCritical, 5000000)
	if !b.TierPaid(SevCritical) || b.PoolLeft() != 4000000 {
		t.Fatalf("Critical payout after Low wrong: left %d", b.PoolLeft())
	}
	// TopUp does not re-open a paid tier.
	b.TopUp(1000000)
	expectPanic(t, func() { b.RecordPayout(hunterAddr, SevLow, 500000) })
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("invariant broken: %s", msg)
	}
}

// ---------------------------------------------------------------------------
// Payout.Due must not report a hand-built zero-amount payout as due.
// (NewPayout already refuses amount <= 0; Due is the second line of
// defence for a struct literal with Kind set and Amount 0.)
// [PRE-FIX FAIL]
// ---------------------------------------------------------------------------

func TestAdversarialPayoutDueRequiresPositiveAmount(t *testing.T) {
	zero := Payout{Kind: PayoutPayHunter, To: hunterAddr, Amount: 0}
	if zero.Due() {
		t.Fatalf("zero-amount payout must not be due")
	}
	neg := Payout{Kind: PayoutPayHunter, To: hunterAddr, Amount: -5}
	if neg.Due() {
		t.Fatalf("negative-amount payout must not be due")
	}
}
