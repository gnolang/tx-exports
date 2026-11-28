package tavernrules

import (
	"strconv"
	"testing"
)

// Real bech32 addresses (testnet throwaway deployer, questmaster,
// hearthbounty) used as distinct actors in tests.
const (
	sponsorAddr = "g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m"
	arbiterAddr = "g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8"
	hunterAddr  = "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
	hunter2Addr = "g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar"
)

// Reveal fixtures: every committed finding in the tests uses this
// title/PoC/salt unless a test says otherwise, so the commit hash and
// the revealed fields always agree.
const (
	revealTitle = "Missing access control on Withdraw"
	revealPoc   = "https://example.com/poc"
	revealSalt  = "saltsaltsaltsalt"
	revealSalt2 = "saltsaltsaltsal2"
)

func mustBounty(t *testing.T) Bounty {
	t.Helper()
	// Tiers 5/3/1/0.5 GNOT, as in design §6.4: pool 9.5 GNOT.
	b := NewBounty(1, sponsorAddr, arbiterAddr, "TavernVault audit",
		"gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/vault",
		5000000, 3000000, 1000000, 500000, 1000, 1000+2592000)
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("fresh bounty violates invariant: %s", msg)
	}
	return b
}

func repeatChar(c string, n int) string {
	s := ""
	for i := 0; i < n; i++ {
		s += c
	}
	return s
}

func TestSeverityValuesAndString(t *testing.T) {
	if SevLow != 1 || SevMedium != 2 || SevHigh != 3 || SevCritical != 4 {
		t.Fatalf("severity values wrong: %d %d %d %d", SevLow, SevMedium, SevHigh, SevCritical)
	}
	if SevCritical.String() != "Critical" || SevLow.String() != "Low" {
		t.Fatalf("severity strings wrong")
	}
	if SevCritical.Valid() != true || Severity(0).Valid() || Severity(5).Valid() {
		t.Fatalf("severity Valid() wrong")
	}
}

func TestStatusValues(t *testing.T) {
	if BountyOpen != 1 || BountyClosed != 2 || BountyCancelled != 3 {
		t.Fatalf("bounty status values wrong")
	}
	if FindingCommitted != 1 || FindingDisclosed != 7 {
		t.Fatalf("finding status values wrong")
	}
	if !FindingAccepted.IsFinal() || !FindingDuplicate.IsFinal() || !FindingDisclosed.IsFinal() {
		t.Fatalf("final statuses must report IsFinal")
	}
	if FindingCommitted.IsFinal() || FindingRevealed.IsFinal() || FindingDisputed.IsFinal() {
		t.Fatalf("non-final statuses must not report IsFinal")
	}
}

func TestValidateNewBountyValid(t *testing.T) {
	if msg := ValidateNewBounty(sponsorAddr, arbiterAddr, "T", "S",
		5000000, 3000000, 1000000, 500000, 1000, 2000); msg != "" {
		t.Fatalf("valid bounty rejected: %s", msg)
	}
}

func TestValidateNewBountyRejects(t *testing.T) {
	cases := []struct {
		name                 string
		sponsor, arbiter     address
		title, scope         string
		crit, high, med, low int64
		createdAt, deadline  int64
	}{
		{"empty sponsor", "", arbiterAddr, "T", "S", 5000000, 3000000, 1000000, 500000, 1000, 2000},
		{"empty arbiter", sponsorAddr, "", "T", "S", 5000000, 3000000, 1000000, 500000, 1000, 2000},
		{"empty title", sponsorAddr, arbiterAddr, "", "S", 5000000, 3000000, 1000000, 500000, 1000, 2000},
		{"title too long", sponsorAddr, arbiterAddr, repeatChar("x", 101), "S", 5000000, 3000000, 1000000, 500000, 1000, 2000},
		{"scope too long", sponsorAddr, arbiterAddr, "T", repeatChar("x", 1001), 5000000, 3000000, 1000000, 500000, 1000, 2000},
		{"tier below minimum", sponsorAddr, arbiterAddr, "T", "S", 5000000, 3000000, 1000000, 99999, 1000, 2000},
		{"pool below 1 GNOT", sponsorAddr, arbiterAddr, "T", "S", 100000, 100000, 100000, 100000, 1000, 2000},
		{"deadline before creation", sponsorAddr, arbiterAddr, "T", "S", 5000000, 3000000, 1000000, 500000, 2000, 1000},
		{"tier overflow", sponsorAddr, arbiterAddr, "T", "S", MaxInt64, MaxInt64, 100000, 100000, 1000, 2000},
	}
	for _, c := range cases {
		msg := ValidateNewBounty(c.sponsor, c.arbiter, c.title, c.scope,
			c.crit, c.high, c.med, c.low, c.createdAt, c.deadline)
		if msg == "" {
			t.Errorf("case %q: expected rejection, got valid", c.name)
		}
	}
}

func TestNewBountyPoolAndPrices(t *testing.T) {
	b := mustBounty(t)
	if b.PoolTotal() != 9500000 || b.PoolLeft() != 9500000 {
		t.Fatalf("pool wrong: total %d left %d", b.PoolTotal(), b.PoolLeft())
	}
	if b.PriceFor(SevCritical) != 5000000 || b.PriceFor(SevHigh) != 3000000 ||
		b.PriceFor(SevMedium) != 1000000 || b.PriceFor(SevLow) != 500000 {
		t.Fatalf("tier prices wrong")
	}
	if b.PriceFor(Severity(0)) != 0 {
		t.Fatalf("unknown severity price must be 0")
	}
	if b.Status() != BountyOpen {
		t.Fatalf("fresh bounty must be Open")
	}
}

func TestRecordPayoutKeepsInvariant(t *testing.T) {
	b := mustBounty(t)
	p := b.RecordPayout(hunterAddr, SevCritical, 5000000)
	if !p.Due() || p.Kind != PayoutPayHunter || p.To != hunterAddr || p.Amount != 5000000 {
		t.Fatalf("payout wrong: %+v", p)
	}
	if b.PoolLeft() != 4500000 || b.PaidOut() != 5000000 {
		t.Fatalf("after payout: left %d paid %d", b.PoolLeft(), b.PaidOut())
	}
	if b.AcceptedCount() != 1 {
		t.Fatalf("accepted count %d, want 1", b.AcceptedCount())
	}
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("invariant broken after payout: %s", msg)
	}
}

func TestRefundThenCloseKeepsInvariant(t *testing.T) {
	b := mustBounty(t)
	b.RecordPayout(hunterAddr, SevCritical, 5000000)
	p := b.RecordRefund(sponsorAddr, 4500000)
	if !p.Due() || p.Kind != PayoutRefundSponsor || p.Amount != 4500000 {
		t.Fatalf("refund payout wrong: %+v", p)
	}
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("invariant broken after refund: %s", msg)
	}
	b.Close()
	if b.Status() != BountyClosed {
		t.Fatalf("status %v, want Closed", b.Status())
	}
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("invariant broken after close: %s", msg)
	}
}

func TestCancelAfterFullRefund(t *testing.T) {
	b := mustBounty(t)
	b.RecordRefund(sponsorAddr, 9500000)
	b.Cancel()
	if b.Status() != BountyCancelled {
		t.Fatalf("status %v, want Cancelled", b.Status())
	}
}

func TestRecordDuplicateAndRejectedCounters(t *testing.T) {
	b := mustBounty(t)
	b.RecordDuplicate()
	b.RecordRejected()
	b.RecordRejected()
	if b.DuplicateCount() != 1 || b.RejectedCount() != 2 {
		t.Fatalf("counters wrong: dup %d rej %d", b.DuplicateCount(), b.RejectedCount())
	}
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("invariant broken by counters: %s", msg)
	}
}

func TestMakeCommitmentKnownVector(t *testing.T) {
	// Cross-checked with system sha256sum (see gate report).
	got := MakeCommitment(1, SevCritical, "Missing access control on Withdraw",
		"https://example.com/poc", "saltsaltsaltsalt")
	want := "ceba4aa550e737510103fa7a74d5593628ca6afa4d5af1fe43e26ffe4e896c2c"
	if got != want {
		t.Fatalf("commitment mismatch: got %s want %s", got, want)
	}
	// Different salt / severity / bounty must change the hash.
	if MakeCommitment(1, SevCritical, "Missing access control on Withdraw",
		"https://example.com/poc", "saltsaltsaltsalx") == want {
		t.Fatalf("different salt must change commitment")
	}
	if MakeCommitment(2, SevCritical, "Missing access control on Withdraw",
		"https://example.com/poc", "saltsaltsaltsalt") == want {
		t.Fatalf("different bounty must change commitment")
	}
}

func TestValidateCommitHash(t *testing.T) {
	good := MakeCommitment(1, SevLow, "t", "https://example.com", "saltsaltsaltsalt")
	if msg := ValidateCommitHash(good); msg != "" {
		t.Fatalf("valid hash rejected: %s", msg)
	}
	for _, bad := range []string{
		"", "abc", repeatChar("a", 63), repeatChar("a", 65),
		repeatChar("A", 64), // uppercase hex not allowed
		repeatChar("g", 64), // not hex at all
	} {
		if msg := ValidateCommitHash(bad); msg == "" {
			t.Errorf("hash %q: expected rejection", bad)
		}
	}
}

func TestValidateSalt(t *testing.T) {
	if msg := ValidateSalt("saltsaltsaltsalt"); msg != "" {
		t.Fatalf("16-char salt rejected: %s", msg)
	}
	if msg := ValidateSalt("short"); msg == "" {
		t.Fatalf("short salt accepted")
	}
}

func TestValidateReveal(t *testing.T) {
	if msg := ValidateReveal("Missing access control", "https://example.com/poc", "saltsaltsaltsalt"); msg != "" {
		t.Fatalf("valid reveal rejected: %s", msg)
	}
	if msg := ValidateReveal("t", "http://example.com/poc", "saltsaltsaltsalt"); msg == "" {
		t.Errorf("http:// PoC URL accepted")
	}
	if msg := ValidateReveal(repeatChar("x", 101), "https://example.com", "saltsaltsaltsalt"); msg == "" {
		t.Errorf("overlong title accepted")
	}
	if msg := ValidateReveal("t", "https://example.com", "short"); msg == "" {
		t.Errorf("short salt accepted at reveal")
	}
}

func TestNewFindingAndInvariant(t *testing.T) {
	hash := MakeCommitment(1, SevCritical, "t", "https://example.com", "saltsaltsaltsalt")
	f := NewFinding(1, 1, hunterAddr, SevCritical, hash, 1000, 1000+RevealWindow)
	if f.Status() != FindingCommitted {
		t.Fatalf("fresh finding must be Committed")
	}
	if f.RevealDeadline() != 1000+RevealWindow {
		t.Fatalf("reveal deadline %d, want %d", f.RevealDeadline(), 1000+RevealWindow)
	}
	if msg := f.CheckInvariant(); msg != "" {
		t.Fatalf("fresh finding violates invariant: %s", msg)
	}
	if msg := ValidateNewFinding(hunterAddr, SevCritical, hash, 1000, 1000); msg == "" {
		t.Errorf("reveal deadline == commit height accepted")
	}
	if msg := ValidateNewFinding(hunterAddr, Severity(9), hash, 1000, 2000); msg == "" {
		t.Errorf("invalid severity accepted")
	}
	if msg := ValidateNewFinding("", SevCritical, hash, 1000, 2000); msg == "" {
		t.Errorf("empty hunter accepted")
	}
}

func TestHunterStats(t *testing.T) {
	s := NewHunterStats(hunterAddr)
	s.RecordSubmitted()
	s.RecordSubmitted()
	s.RecordAccepted(5000000)
	s.RecordDuplicate()
	s.RecordRejected()
	if s.Submitted() != 2 || s.Accepted() != 1 || s.Duplicates() != 1 || s.Rejected() != 1 {
		t.Fatalf("hunter stats wrong: %+v", s)
	}
	if s.Earned() != 5000000 {
		t.Fatalf("earned %d, want 5000000", s.Earned())
	}
}

func TestArbiterStats(t *testing.T) {
	s := NewArbiterStats(arbiterAddr)
	s.RecordVerdict(true, false, false)
	s.RecordVerdict(false, true, false)
	s.RecordVerdict(false, false, true)
	s.RecordTimeout()
	if s.Verdicts() != 3 || s.Accepted() != 1 || s.Rejected() != 1 || s.Duplicates() != 1 || s.Timeouts() != 1 {
		t.Fatalf("arbiter stats wrong: %+v", s)
	}
}

func TestPayoutDue(t *testing.T) {
	var zero Payout
	if zero.Due() {
		t.Fatalf("zero payout must not be due")
	}
	p := NewPayout(PayoutPayHunter, hunterAddr, 100000)
	if !p.Due() {
		t.Fatalf("real payout must be due")
	}
}

func TestCheckedMath(t *testing.T) {
	if v, ok := CheckedAdd(MaxInt64, 1); ok || v != 0 {
		t.Fatalf("CheckedAdd(MaxInt64,1) must overflow")
	}
	if v, ok := CheckedAdd(MaxInt64-1, 1); !ok || v != MaxInt64 {
		t.Fatalf("CheckedAdd(MaxInt64-1,1) = %d %v", v, ok)
	}
	if v, ok := CheckedSub(-MaxInt64-1, 1); ok || v != 0 {
		t.Fatalf("CheckedSub(MinInt64,1) must overflow")
	}
	if v, ok := CheckedSub(10, 3); !ok || v != 7 {
		t.Fatalf("CheckedSub(10,3) = %d %v", v, ok)
	}
}

// ---------------------------------------------------------------------------
// Day-2 helpers.
// ---------------------------------------------------------------------------

// expectPanic fails the test unless fn panics. Direct (non-cross)
// calls only: a panic from a crossing call aborts at the realm boundary
// and cannot be recovered in a unit test (see README).
func expectPanic(t *testing.T, fn func()) {
	t.Helper()
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("expected panic, got none")
		}
	}()
	fn()
}

// tryMove runs fn and reports whether it panicked (recovered here).
func tryMove(fn func()) (panicked bool) {
	defer func() {
		if r := recover(); r != nil {
			panicked = true
		}
	}()
	fn()
	return false
}

// commitWith commits a finding whose reveal fields are title/pocURL
// with the standard salt, so Reveal with the same fields matches.
func commitWith(t *testing.T, b *Bounty, id uint64, hunter address, sev Severity, title, pocURL string, height int64) Finding {
	t.Helper()
	hash := MakeCommitment(b.ID(), sev, title, pocURL, revealSalt)
	return CommitFinding(b, nil, id, hunter, sev, hash, height)
}

// mustCommit commits a finding with the standard reveal fixtures.
func mustCommit(t *testing.T, b *Bounty, id uint64, hunter address, sev Severity, height int64) Finding {
	t.Helper()
	return commitWith(t, b, id, hunter, sev, revealTitle, revealPoc, height)
}

// mustReveal reveals a finding with the standard fixtures.
func mustReveal(t *testing.T, b *Bounty, f *Finding, height int64) {
	t.Helper()
	f.Reveal(b, f.Hunter(), revealTitle, revealPoc, revealSalt, height)
}

// mustRevealed commits and reveals a finding, returning it Revealed.
func mustRevealed(t *testing.T, b *Bounty, id uint64, hunter address, sev Severity, commitHeight, revealHeight int64) Finding {
	t.Helper()
	f := mustCommit(t, b, id, hunter, sev, commitHeight)
	mustReveal(t, b, &f, revealHeight)
	return f
}

// othersExcluding returns all findings except index skip (for the
// tier-once check, which must not see the finding being decided).
func othersExcluding(all []Finding, skip int) []Finding {
	out := []Finding{}
	for i, f := range all {
		if i != skip {
			out = append(out, f)
		}
	}
	return out
}

// assertInvariants fails the test when the bounty or any finding
// violates design §4.2.
func assertInvariants(t *testing.T, b *Bounty, findings []Finding) {
	t.Helper()
	if msg := b.CheckInvariant(); msg != "" {
		t.Fatalf("bounty invariant violated: %s (bounty %+v)", msg, *b)
	}
	for i := range findings {
		if msg := findings[i].CheckInvariant(); msg != "" {
			t.Fatalf("finding %d invariant violated: %s (%+v)", i, msg, findings[i])
		}
	}
}

// ---------------------------------------------------------------------------
// Day-2 tests: deadline helpers.
// ---------------------------------------------------------------------------

func TestDeadlineHelpers(t *testing.T) {
	if RevealDeadlineAt(1000) != 1000+RevealWindow {
		t.Fatalf("RevealDeadlineAt wrong: %d", RevealDeadlineAt(1000))
	}
	if ReviewDeadlineAt(1100) != 1100+ReviewWindow {
		t.Fatalf("ReviewDeadlineAt wrong: %d", ReviewDeadlineAt(1100))
	}
	if SponsorDeadlineAt(73100) != 73100+SponsorWindow {
		t.Fatalf("SponsorDeadlineAt wrong: %d", SponsorDeadlineAt(73100))
	}
	if ClaimableAfter(73100) != 73100+SponsorWindow {
		t.Fatalf("ClaimableAfter wrong: %d", ClaimableAfter(73100))
	}
	if DisputeDeadlineAt(1200) != 1200+DisputeWindow {
		t.Fatalf("DisputeDeadlineAt wrong: %d", DisputeDeadlineAt(1200))
	}
	if DisclosureDeadlineAt(1200) != 1200+FixWindow {
		t.Fatalf("DisclosureDeadlineAt wrong: %d", DisclosureDeadlineAt(1200))
	}
	// Window constants must match design §6.3.
	if RevealWindow != 24600 || ReviewWindow != 72000 || SponsorWindow != 72000 ||
		DisputeWindow != 36000 || FixWindow != 345600 {
		t.Fatalf("window constants changed: %d %d %d %d %d",
			RevealWindow, ReviewWindow, SponsorWindow, DisputeWindow, FixWindow)
	}
	// Deadline math at MaxInt64 must panic, never wrap.
	expectPanic(t, func() { RevealDeadlineAt(MaxInt64) })
	expectPanic(t, func() { ReviewDeadlineAt(MaxInt64) })
	expectPanic(t, func() { SponsorDeadlineAt(MaxInt64) })
	expectPanic(t, func() { ClaimableAfter(MaxInt64) })
	expectPanic(t, func() { DisputeDeadlineAt(MaxInt64) })
	expectPanic(t, func() { DisclosureDeadlineAt(MaxInt64) })
}

func TestVerdictValues(t *testing.T) {
	if VerdictAccept != 1 || VerdictDuplicate != 2 || VerdictReject != 3 {
		t.Fatalf("verdict values wrong: %d %d %d", VerdictAccept, VerdictDuplicate, VerdictReject)
	}
	if !VerdictAccept.Valid() || Verdict(0).Valid() || Verdict(4).Valid() {
		t.Fatalf("verdict Valid() wrong")
	}
	if VerdictAccept.String() != "Accept" || VerdictDuplicate.String() != "Duplicate" ||
		VerdictReject.String() != "Reject" {
		t.Fatalf("verdict strings wrong")
	}
}

func TestExpiredStatus(t *testing.T) {
	if FindingExpired != 8 {
		t.Fatalf("FindingExpired must be 8, got %d", FindingExpired)
	}
	if !FindingExpired.IsFinal() {
		t.Fatalf("Expired must be final")
	}
	if FindingExpired.String() != "Expired" {
		t.Fatalf("Expired string wrong: %s", FindingExpired.String())
	}
}

// ---------------------------------------------------------------------------
// Day-2 tests: TopUp.
// ---------------------------------------------------------------------------

func TestTopUp(t *testing.T) {
	b := mustBounty(t)
	b.TopUp(1000000)
	if b.PoolTotal() != 10500000 || b.PoolLeft() != 10500000 {
		t.Fatalf("after top-up: total %d left %d", b.PoolTotal(), b.PoolLeft())
	}
	if b.PaidOut() != 0 || b.Refunded() != 0 {
		t.Fatalf("top-up must not move paid/refunded")
	}
	assertInvariants(t, &b, nil)
	// Minimum top-up (1 ugnot is allowed by the rules; the realm's
	// payment guard is what enforces a sane amount on-chain).
	b.TopUp(1)
	if b.PoolTotal() != 10500001 {
		t.Fatalf("1-ugnot top-up wrong: %d", b.PoolTotal())
	}
}

func TestTopUpRejects(t *testing.T) {
	b := mustBounty(t)
	expectPanic(t, func() { b.TopUp(0) })
	expectPanic(t, func() { b.TopUp(-1) })
	expectPanic(t, func() { b.TopUp(MaxInt64) })
	// Top-up on a closed bounty panics.
	CancelBounty(&b, sponsorAddr, 1000, nil)
	expectPanic(t, func() { b.TopUp(100000) })
	assertInvariants(t, &b, nil)
}

// ---------------------------------------------------------------------------
// Day-2 tests: Commit.
// ---------------------------------------------------------------------------

func TestCommitFindingHappyAndBoundaries(t *testing.T) {
	b := mustBounty(t)
	// Commit exactly at the deadline height is allowed (height <= deadline).
	f := mustCommit(t, &b, 1, hunterAddr, SevCritical, b.Deadline())
	if f.Status() != FindingCommitted {
		t.Fatalf("fresh finding must be Committed")
	}
	if f.RevealDeadline() != b.Deadline()+RevealWindow {
		t.Fatalf("reveal deadline %d, want %d", f.RevealDeadline(), b.Deadline()+RevealWindow)
	}
	assertInvariants(t, &b, []Finding{f})
	// One block past the deadline: no new commits.
	expectPanic(t, func() {
		mustCommit(t, &b, 2, hunterAddr, SevCritical, b.Deadline()+1)
	})
	// Bad hash / bad severity panic via NewFinding validation.
	expectPanic(t, func() {
		CommitFinding(&b, nil, 3, hunterAddr, SevCritical, "not-a-hash", 1000)
	})
	expectPanic(t, func() {
		CommitFinding(&b, nil, 4, hunterAddr, Severity(9), MakeCommitment(1, SevCritical, revealTitle, revealPoc, revealSalt), 1000)
	})
	// Commit at MaxInt64: the reveal deadline overflows and must panic.
	b2 := NewBounty(2, sponsorAddr, arbiterAddr, "T", "S",
		5000000, 3000000, 1000000, 500000, 1000, MaxInt64)
	expectPanic(t, func() {
		mustCommit(t, &b2, 1, hunterAddr, SevCritical, MaxInt64)
	})
}

func TestCommitDuplicateLiveHashRejected(t *testing.T) {
	b := mustBounty(t)
	f1 := mustCommit(t, &b, 1, hunterAddr, SevCritical, 1000)
	// A second hunter copying the visible commit hash is rejected
	// while the first finding is live (design §7 T3). The live-hash
	// check needs the other findings passed in as `others`.
	expectPanic(t, func() {
		CommitFinding(&b, []Finding{f1}, 2, hunter2Addr, SevCritical,
			MakeCommitment(b.ID(), SevCritical, revealTitle, revealPoc, revealSalt), 1001)
	})
	_ = f1
	// ... but once the first commit has expired, the same hash may be
	// committed again (fresh commit, new salt in practice).
	f1.ExpireCommit(1000 + RevealWindow + 1)
	f2 := CommitFinding(&b, []Finding{f1}, 2, hunter2Addr, SevCritical,
		MakeCommitment(b.ID(), SevCritical, revealTitle, revealPoc, revealSalt), 30000)
	if f2.Status() != FindingCommitted {
		t.Fatalf("re-commit after expiry must succeed")
	}
	assertInvariants(t, &b, []Finding{f1, f2})
}

// ---------------------------------------------------------------------------
// Day-2 tests: Reveal.
// ---------------------------------------------------------------------------

func TestRevealHappyAndBoundaries(t *testing.T) {
	b := mustBounty(t)
	f := mustCommit(t, &b, 1, hunterAddr, SevCritical, 1000)
	// Wrong hunter cannot reveal.
	expectPanic(t, func() {
		f.Reveal(&b, hunter2Addr, revealTitle, revealPoc, revealSalt, 1100)
	})
	// Wrong salt: the recomputed commitment does not match.
	expectPanic(t, func() {
		f.Reveal(&b, hunterAddr, revealTitle, revealPoc, "saltsaltsaltsalx", 1100)
	})
	// Reveal exactly at the reveal deadline is allowed.
	f.Reveal(&b, hunterAddr, revealTitle, revealPoc, revealSalt, 1000+RevealWindow)
	if f.Status() != FindingRevealed {
		t.Fatalf("status %v, want Revealed", f.Status())
	}
	if f.ReviewDeadline() != 1000+RevealWindow+ReviewWindow {
		t.Fatalf("review deadline %d, want %d", f.ReviewDeadline(), 1000+RevealWindow+ReviewWindow)
	}
	if f.RevealedAt() != 1000+RevealWindow {
		t.Fatalf("revealedAt %d", f.RevealedAt())
	}
	assertInvariants(t, &b, []Finding{f})
	// A second reveal panics (wrong state).
	expectPanic(t, func() {
		f.Reveal(&b, hunterAddr, revealTitle, revealPoc, revealSalt, 1100)
	})
}

func TestRevealAfterDeadlinePanics(t *testing.T) {
	b := mustBounty(t)
	f := mustCommit(t, &b, 1, hunterAddr, SevCritical, 1000)
	expectPanic(t, func() {
		f.Reveal(&b, hunterAddr, revealTitle, revealPoc, revealSalt, 1000+RevealWindow+1)
	})
	if f.Status() != FindingCommitted {
		t.Fatalf("failed reveal must leave the finding Committed")
	}
}

func TestRevealFieldBoundaries(t *testing.T) {
	b := mustBounty(t)
	// Title of exactly 100 chars reveals fine; 101 panics.
	f100 := commitWith(t, &b, 1, hunterAddr, SevCritical, repeatChar("x", 100), revealPoc, 1000)
	f100.Reveal(&b, hunterAddr, repeatChar("x", 100), revealPoc, revealSalt, 1100)
	if f100.Status() != FindingRevealed {
		t.Fatalf("100-char title must reveal")
	}
	f101 := commitWith(t, &b, 2, hunterAddr, SevCritical, repeatChar("x", 101), revealPoc, 1000)
	expectPanic(t, func() {
		f101.Reveal(&b, hunterAddr, repeatChar("x", 101), revealPoc, revealSalt, 1100)
	})
	// Empty title panics.
	fEmpty := commitWith(t, &b, 3, hunterAddr, SevCritical, "", revealPoc, 1000)
	expectPanic(t, func() {
		fEmpty.Reveal(&b, hunterAddr, "", revealPoc, revealSalt, 1100)
	})
	// PoC URL of exactly 300 chars (https:// + 292) reveals fine; 301 panics.
	url300 := "https://" + repeatChar("x", 292)
	f300 := commitWith(t, &b, 4, hunterAddr, SevCritical, revealTitle, url300, 1000)
	f300.Reveal(&b, hunterAddr, revealTitle, url300, revealSalt, 1100)
	if f300.Status() != FindingRevealed {
		t.Fatalf("300-char PoC URL must reveal")
	}
	url301 := "https://" + repeatChar("x", 293)
	f301 := commitWith(t, &b, 5, hunterAddr, SevCritical, revealTitle, url301, 1000)
	expectPanic(t, func() {
		f301.Reveal(&b, hunterAddr, revealTitle, url301, revealSalt, 1100)
	})
	// http:// (no s) panics; short salt panics.
	fHttp := commitWith(t, &b, 6, hunterAddr, SevCritical, revealTitle, "http://example.com/poc", 1000)
	expectPanic(t, func() {
		fHttp.Reveal(&b, hunterAddr, revealTitle, "http://example.com/poc", revealSalt, 1100)
	})
	fSalt := mustCommit(t, &b, 7, hunterAddr, SevCritical, 1000)
	expectPanic(t, func() {
		fSalt.Reveal(&b, hunterAddr, revealTitle, revealPoc, "short", 1100)
	})
	assertInvariants(t, &b, []Finding{f100, f101, fEmpty, f300, f301, fHttp, fSalt})
}

// ---------------------------------------------------------------------------
// Day-2 tests: ExpireCommit.
// ---------------------------------------------------------------------------

func TestExpireCommit(t *testing.T) {
	b := mustBounty(t)
	f := mustCommit(t, &b, 1, hunterAddr, SevCritical, 1000)
	// At the deadline itself the commit is still alive.
	expectPanic(t, func() { f.ExpireCommit(1000 + RevealWindow) })
	expectPanic(t, func() { f.ExpireCommit(1000) })
	// One block past: expired, final, and no longer in flight.
	f.ExpireCommit(1000 + RevealWindow + 1)
	if f.Status() != FindingExpired || !f.Status().IsFinal() {
		t.Fatalf("status %v, want final Expired", f.Status())
	}
	if IsInFlight(f.Status()) {
		t.Fatalf("expired finding must not be in flight")
	}
	assertInvariants(t, &b, []Finding{f})
	// Expiring twice panics; revealing an expired commit panics.
	expectPanic(t, func() { f.ExpireCommit(1000 + RevealWindow + 2) })
	expectPanic(t, func() {
		f.Reveal(&b, hunterAddr, revealTitle, revealPoc, revealSalt, 1000+RevealWindow+2)
	})
}

// ---------------------------------------------------------------------------
// Day-2 tests: Verdict — Accept.
// ---------------------------------------------------------------------------

func TestVerdictAcceptHappy(t *testing.T) {
	b := mustBounty(t)
	// Hunter claims High; the arbiter corrects the tier up to Critical.
	f := mustRevealed(t, &b, 1, hunterAddr, SevHigh, 1000, 1100)
	p := f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed, drains vault", 0, nil, nil, 1200)
	if !p.Due() || p.Kind != PayoutPayHunter || p.To != hunterAddr || p.Amount != 5000000 {
		t.Fatalf("accept payout wrong: %+v", p)
	}
	if f.Status() != FindingAccepted || f.SeverityFinal() != SevCritical || f.PaidAmount() != 5000000 {
		t.Fatalf("accepted finding wrong: %+v", f)
	}
	if f.VerdictBy() != arbiterAddr || f.VerdictAt() != 1200 {
		t.Fatalf("verdict record wrong: by %s at %d", f.VerdictBy(), f.VerdictAt())
	}
	if b.PoolLeft() != 4500000 || b.PaidOut() != 5000000 || b.AcceptedCount() != 1 {
		t.Fatalf("bounty after accept: left %d paid %d accepted %d",
			b.PoolLeft(), b.PaidOut(), b.AcceptedCount())
	}
	assertInvariants(t, &b, []Finding{f})
	// Accepting twice panics: Accepted is final (no double payout, §7 T2).
	expectPanic(t, func() {
		f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "again", 0, nil, nil, 1300)
	})
}

func TestVerdictAcceptTierAlreadyPaid(t *testing.T) {
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	// A second Critical finding cannot be paid: the tier paid once (§5.6).
	f2 := mustRevealed(t, &b, 2, hunter2Addr, SevCritical, 1300, 1400)
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "also critical", 0, nil, []Finding{f1}, 1500)
	})
	if f2.Status() != FindingRevealed || f2.PaidAmount() != 0 {
		t.Fatalf("failed accept must leave the finding Revealed and unpaid")
	}
	if b.PoolLeft() != 4500000 || b.PaidOut() != 5000000 {
		t.Fatalf("failed accept must not move pool money")
	}
	assertInvariants(t, &b, []Finding{f1, f2})
}

func TestRecordPayoutInsufficientPoolPanics(t *testing.T) {
	// NOTE: at the Verdict level an insufficient pool is unreachable
	// while the tier-once rule holds — the pool always holds exactly
	// the sum of the unpaid tiers. The check is defence-in-depth, so
	// it is tested directly on RecordPayout instead.
	b := mustBounty(t)
	expectPanic(t, func() { b.RecordPayout(hunterAddr, SevCritical, 9500001) })
	expectPanic(t, func() { b.RecordPayout(hunterAddr, SevCritical, 0) })
	expectPanic(t, func() { b.RecordPayout(hunterAddr, SevCritical, -1) })
	expectPanic(t, func() { b.RecordPayout("", SevCritical, 100000) })
	b.RecordPayout(hunterAddr, SevCritical, 9500000)
	expectPanic(t, func() { b.RecordPayout(hunterAddr, SevCritical, 100000) })
	assertInvariants(t, &b, nil)
}

// ---------------------------------------------------------------------------
// Day-2 tests: Verdict — Duplicate.
// ---------------------------------------------------------------------------

func TestVerdictDuplicateHappy(t *testing.T) {
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	// Second hunter, same bug, own salt/hash, committed later.
	hash2 := MakeCommitment(b.ID(), SevCritical, revealTitle, revealPoc, revealSalt2)
	f2 := CommitFinding(&b, []Finding{f1}, 2, hunter2Addr, SevCritical, hash2, 1300)
	f2.Reveal(&b, hunter2Addr, revealTitle, revealPoc, revealSalt2, 1400)
	p := f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "same bug as #1", f1.ID(), &f1, []Finding{f1}, 1500)
	if p.Due() {
		t.Fatalf("duplicate must not pay: %+v", p)
	}
	if f2.Status() != FindingDuplicate || f2.DuplicateOf() != 1 || f2.PaidAmount() != 0 {
		t.Fatalf("duplicate finding wrong: %+v", f2)
	}
	if b.DuplicateCount() != 1 || b.PoolLeft() != 4500000 || b.PaidOut() != 5000000 {
		t.Fatalf("bounty after duplicate: dup %d left %d paid %d",
			b.DuplicateCount(), b.PoolLeft(), b.PaidOut())
	}
	assertInvariants(t, &b, []Finding{f1, f2})
	// Duplicate is final: no further verdict.
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "changed mind", 0, nil, nil, 1600)
	})
}

func TestVerdictDuplicateRejects(t *testing.T) {
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f2 := mustRevealed(t, &b, 2, hunter2Addr, SevCritical, 1300, 1400)
	// duplicateOf == 0, nil original, mismatched id.
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup", 0, &f1, nil, 1500)
	})
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup", f1.ID(), nil, nil, 1500)
	})
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup", 99, &f1, nil, 1500)
	})
	// Self-duplicate.
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup", f2.ID(), &f2, nil, 1500)
	})
	// Original committed LATER than the finding (not first-valid-wins).
	f3 := mustCommit(t, &b, 3, hunterAddr, SevCritical, 2000)
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup", f3.ID(), &f3, nil, 1500)
	})
	// Original still only Committed (not Revealed/Accepted/Disclosed).
	f4 := mustCommit(t, &b, 4, hunterAddr, SevCritical, 900)
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup", f4.ID(), &f4, nil, 1500)
	})
	// Original on another bounty.
	b2 := NewBounty(2, sponsorAddr, arbiterAddr, "Other audit", "scope",
		5000000, 3000000, 1000000, 500000, 1000, 1000+2592000)
	fx := mustCommit(t, &b2, 9, hunterAddr, SevCritical, 900)
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "dup", fx.ID(), &fx, nil, 1500)
	})
	assertInvariants(t, &b, []Finding{f1, f2, f3, f4})
}

// ---------------------------------------------------------------------------
// Day-2 tests: Verdict — Reject + Dispute.
// ---------------------------------------------------------------------------

func TestVerdictRejectAndDispute(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	// Reject without a reason panics.
	expectPanic(t, func() {
		f.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "", 0, nil, nil, 1200)
	})
	f.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "not reproducible", 0, nil, nil, 1200)
	if f.Status() != FindingRejected || f.VerdictReason() != "not reproducible" {
		t.Fatalf("rejected finding wrong: %+v", f)
	}
	if b.RejectedCount() != 1 || b.PoolLeft() != 9500000 {
		t.Fatalf("reject must not move money: rej %d left %d", b.RejectedCount(), b.PoolLeft())
	}
	// Dispute by anyone but the hunter panics.
	expectPanic(t, func() { f.Dispute(arbiterAddr, "please reconsider", 1300) })
	// Dispute exactly at the dispute deadline is allowed.
	f.Dispute(hunterAddr, "it reproduces on Onyx, see updated PoC", 1200+DisputeWindow)
	if f.Status() != FindingDisputed || !f.DisputedBefore() {
		t.Fatalf("disputed finding wrong: %+v", f)
	}
	assertInvariants(t, &b, []Finding{f})
	// Disputing a Disputed finding panics (wrong state).
	expectPanic(t, func() { f.Dispute(hunterAddr, "again", 1300) })
	// Re-verdict: reject again — now final, the one dispute is spent.
	f.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "still not reproducible", 0, nil, nil, 38000)
	if f.Status() != FindingRejected {
		t.Fatalf("re-rejected status %v", f.Status())
	}
	expectPanic(t, func() { f.Dispute(hunterAddr, "second dispute", 39000) })
	assertInvariants(t, &b, []Finding{f})
}

func TestDisputeAfterWindowPanics(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "not valid", 0, nil, nil, 1200)
	// One block past verdictAt + DisputeWindow: too late.
	expectPanic(t, func() {
		f.Dispute(hunterAddr, "too late", 1200+DisputeWindow+1)
	})
	// Empty or overlong dispute reason panics.
	expectPanic(t, func() { f.Dispute(hunterAddr, "", 1300) })
	expectPanic(t, func() { f.Dispute(hunterAddr, repeatChar("x", 301), 1300) })
	if f.Status() != FindingRejected {
		t.Fatalf("failed dispute must leave the finding Rejected")
	}
}

func TestDisputeThenAcceptPays(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevHigh, 1000, 1100)
	f.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "needs clearer PoC", 0, nil, nil, 1200)
	f.Dispute(hunterAddr, "PoC clarified in the link", 1300)
	p := f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevHigh, "confirmed on re-review", 0, nil, nil, 1400)
	if !p.Due() || p.Amount != 3000000 {
		t.Fatalf("re-verdict accept payout wrong: %+v", p)
	}
	if f.Status() != FindingAccepted || b.PaidOut() != 3000000 {
		t.Fatalf("after re-accept: status %v paid %d", f.Status(), b.PaidOut())
	}
	assertInvariants(t, &b, []Finding{f})
}

// ---------------------------------------------------------------------------
// Day-2 tests: verdict actors and windows.
// ---------------------------------------------------------------------------

func TestVerdictWrongActorAndWindow(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	// Only the appointed arbiter may give a verdict.
	expectPanic(t, func() {
		f.ApplyVerdict(&b, sponsorAddr, VerdictAccept, SevCritical, "sponsor meddling", 0, nil, nil, 1200)
	})
	expectPanic(t, func() {
		f.ApplyVerdict(&b, hunterAddr, VerdictAccept, SevCritical, "hunter meddling", 0, nil, nil, 1200)
	})
	// Invalid verdict value.
	expectPanic(t, func() {
		f.ApplyVerdict(&b, arbiterAddr, Verdict(9), SevCritical, "?", 0, nil, nil, 1200)
	})
	// Invalid final severity on Accept.
	expectPanic(t, func() {
		f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, Severity(0), "?", 0, nil, nil, 1200)
	})
	// Arbiter verdict one block past the review deadline panics.
	expectPanic(t, func() {
		f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "too late", 0, nil, nil, f.ReviewDeadline()+1)
	})
	// Exactly at the review deadline the arbiter may still decide.
	f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "just in time", 0, nil, nil, f.ReviewDeadline())
	if f.Status() != FindingAccepted {
		t.Fatalf("verdict at review deadline must succeed")
	}
	assertInvariants(t, &b, []Finding{f})
}

func TestVerdictOnCommittedPanics(t *testing.T) {
	b := mustBounty(t)
	f := mustCommit(t, &b, 1, hunterAddr, SevCritical, 1000)
	expectPanic(t, func() {
		f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "too early", 0, nil, nil, 1100)
	})
	expectPanic(t, func() {
		f.SponsorVerdict(&b, sponsorAddr, VerdictAccept, SevCritical, "too early", 0, nil, nil, 1100)
	})
}

func TestSponsorVerdictWindows(t *testing.T) {
	b := mustBounty(t)
	// Sponsor verdict before the review deadline panics (arbiter's turn).
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	expectPanic(t, func() {
		f1.SponsorVerdict(&b, sponsorAddr, VerdictAccept, SevCritical, "early", 0, nil, nil, f1.ReviewDeadline())
	})
	// ... and by the arbiter through the sponsor path panics too.
	expectPanic(t, func() {
		f1.SponsorVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "wrong actor", 0, nil, nil, f1.ReviewDeadline()+1)
	})
	// One block into the sponsor window: the sponsor may decide.
	p := f1.SponsorVerdict(&b, sponsorAddr, VerdictAccept, SevCritical, "arbiter silent, confirmed", 0, nil, nil, f1.ReviewDeadline()+1)
	if !p.Due() || p.Amount != 5000000 {
		t.Fatalf("sponsor verdict payout wrong: %+v", p)
	}
	assertInvariants(t, &b, []Finding{f1})

	// Sponsor verdict one block past the sponsor window panics.
	f2 := mustRevealed(t, &b, 2, hunter2Addr, SevHigh, 2000, 2100)
	expectPanic(t, func() {
		f2.SponsorVerdict(&b, sponsorAddr, VerdictAccept, SevHigh, "too late", 0, nil, nil, SponsorDeadlineAt(f2.ReviewDeadline())+1)
	})
	// Exactly at the sponsor deadline it still succeeds.
	f2.SponsorVerdict(&b, sponsorAddr, VerdictReject, 0, "sponsor rejects in time", 0, nil, nil, SponsorDeadlineAt(f2.ReviewDeadline()))
	if f2.Status() != FindingRejected {
		t.Fatalf("sponsor verdict at sponsor deadline must succeed")
	}
	assertInvariants(t, &b, []Finding{f1, f2})

	// Sponsor verdict on a Disputed finding panics (arbiter owns disputes).
	f3 := mustRevealed(t, &b, 3, hunterAddr, SevLow, 3000, 3100)
	f3.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "no", 0, nil, nil, 3200)
	f3.Dispute(hunterAddr, "dispute", 3300)
	expectPanic(t, func() {
		f3.SponsorVerdict(&b, sponsorAddr, VerdictAccept, SevLow, "sponsor overrules", 0, nil, nil, f3.ReviewDeadline()+1)
	})
}

func TestVerdictReasonBoundaries(t *testing.T) {
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, repeatChar("x", 300), 0, nil, nil, 1200)
	if f1.Status() != FindingRejected {
		t.Fatalf("300-char reject reason must be accepted")
	}
	f2 := mustRevealed(t, &b, 2, hunter2Addr, SevCritical, 1300, 1400)
	expectPanic(t, func() {
		f2.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, repeatChar("x", 301), 0, nil, nil, 1500)
	})
	assertInvariants(t, &b, []Finding{f1, f2})
}

// ---------------------------------------------------------------------------
// Day-2 tests: ClaimPayout.
// ---------------------------------------------------------------------------

func TestClaimPayout(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevHigh, 1000, 1100)
	claimable := ClaimableAfter(f.ReviewDeadline())
	// At the claimable height itself the window has NOT opened yet.
	expectPanic(t, func() { f.ClaimPayout(&b, hunterAddr, nil, claimable) })
	// One block later: the hunter claims the CLAIMED tier price.
	p := f.ClaimPayout(&b, hunterAddr, nil, claimable+1)
	if !p.Due() || p.Kind != PayoutPayHunter || p.Amount != 3000000 {
		t.Fatalf("claim payout wrong: %+v", p)
	}
	if f.Status() != FindingAccepted || f.SeverityFinal() != SevHigh || f.PaidAmount() != 3000000 {
		t.Fatalf("claimed finding wrong: %+v", f)
	}
	if b.PoolLeft() != 6500000 || b.PaidOut() != 3000000 {
		t.Fatalf("bounty after claim: left %d paid %d", b.PoolLeft(), b.PaidOut())
	}
	assertInvariants(t, &b, []Finding{f})
	// Claiming twice panics (Accepted is final).
	expectPanic(t, func() { f.ClaimPayout(&b, hunterAddr, nil, claimable+2) })
}

func TestClaimPayoutRejects(t *testing.T) {
	b := mustBounty(t)
	// Wrong actor.
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	expectPanic(t, func() {
		f1.ClaimPayout(&b, hunter2Addr, nil, ClaimableAfter(f1.ReviewDeadline())+1)
	})
	// Still Committed.
	f2 := mustCommit(t, &b, 2, hunterAddr, SevCritical, 1000)
	expectPanic(t, func() { f2.ClaimPayout(&b, hunterAddr, nil, 200000) })
	// Tier already paid by an earlier verdict.
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	f3 := mustRevealed(t, &b, 3, hunter2Addr, SevCritical, 1300, 1400)
	expectPanic(t, func() {
		f3.ClaimPayout(&b, hunter2Addr, []Finding{f1}, ClaimableAfter(f3.ReviewDeadline())+1)
	})
	assertInvariants(t, &b, []Finding{f1, f2, f3})
}

// ---------------------------------------------------------------------------
// Day-2 tests: Cancel / Close.
// ---------------------------------------------------------------------------

func TestCancelBounty(t *testing.T) {
	b := mustBounty(t)
	p := CancelBounty(&b, sponsorAddr, 1000, nil)
	if !p.Due() || p.Kind != PayoutRefundSponsor || p.To != sponsorAddr || p.Amount != 9500000 {
		t.Fatalf("cancel refund wrong: %+v", p)
	}
	if b.Status() != BountyCancelled || b.PoolLeft() != 0 || b.Refunded() != 9500000 {
		t.Fatalf("cancelled bounty wrong: %+v", b)
	}
	assertInvariants(t, &b, nil)
	// Cancelling twice panics.
	expectPanic(t, func() { CancelBounty(&b, sponsorAddr, 1001, nil) })
}

func TestCancelBountyRejects(t *testing.T) {
	b := mustBounty(t)
	// Wrong actor.
	expectPanic(t, func() { CancelBounty(&b, arbiterAddr, 1000, nil) })
	// A live Committed finding blocks cancellation.
	f := mustCommit(t, &b, 1, hunterAddr, SevCritical, 1000)
	expectPanic(t, func() { CancelBounty(&b, sponsorAddr, 1100, []Finding{f}) })
	// ... but an expired commit does not block.
	f.ExpireCommit(1000 + RevealWindow + 1)
	p := CancelBounty(&b, sponsorAddr, 30000, []Finding{f})
	if !p.Due() || p.Amount != 9500000 {
		t.Fatalf("cancel after expiry refund wrong: %+v", p)
	}
	assertInvariants(t, &b, []Finding{f})
}

func TestCancelBlockedWhileDisputable(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "no", 0, nil, nil, 1200)
	// Inside the dispute window the hunter may still dispute, so
	// cancelling (which would strand the dispute) panics.
	expectPanic(t, func() { CancelBounty(&b, sponsorAddr, 1300, []Finding{f}) })
	// Past the dispute window the rejection is final: cancel succeeds.
	p := CancelBounty(&b, sponsorAddr, 1200+DisputeWindow+1, []Finding{f})
	if !p.Due() || p.Amount != 9500000 {
		t.Fatalf("cancel after dispute window refund wrong: %+v", p)
	}
	assertInvariants(t, &b, []Finding{f})
}

func TestCancelAfterPartialPayoutRefundsRemainder(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	p := CancelBounty(&b, sponsorAddr, 1300, []Finding{f})
	if !p.Due() || p.Amount != 4500000 {
		t.Fatalf("partial cancel refund wrong: %+v", p)
	}
	if b.PaidOut() != 5000000 || b.Refunded() != 4500000 || b.PoolLeft() != 0 {
		t.Fatalf("accounting after partial cancel wrong: %+v", b)
	}
	assertInvariants(t, &b, []Finding{f})
}

func TestCloseBounty(t *testing.T) {
	b := mustBounty(t)
	// Before the deadline, and exactly at it, closing panics.
	expectPanic(t, func() { CloseBounty(&b, sponsorAddr, 2000, nil) })
	expectPanic(t, func() { CloseBounty(&b, sponsorAddr, b.Deadline(), nil) })
	// Wrong actor panics even after the deadline.
	expectPanic(t, func() { CloseBounty(&b, arbiterAddr, b.Deadline()+1, nil) })
	p := CloseBounty(&b, sponsorAddr, b.Deadline()+1, nil)
	if !p.Due() || p.Kind != PayoutRefundSponsor || p.Amount != 9500000 {
		t.Fatalf("close refund wrong: %+v", p)
	}
	if b.Status() != BountyClosed || b.PoolLeft() != 0 {
		t.Fatalf("closed bounty wrong: %+v", b)
	}
	assertInvariants(t, &b, nil)
	// Closing twice panics.
	expectPanic(t, func() { CloseBounty(&b, sponsorAddr, b.Deadline()+2, nil) })
}

func TestCloseBlockedByInFlight(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	expectPanic(t, func() { CloseBounty(&b, sponsorAddr, b.Deadline()+1, []Finding{f}) })
	// A Disputed finding also blocks.
	f.ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "no", 0, nil, nil, 1200)
	f.Dispute(hunterAddr, "dispute", 1300)
	expectPanic(t, func() { CloseBounty(&b, sponsorAddr, b.Deadline()+1, []Finding{f}) })
	// Once the dispute is resolved (accepted here), closing succeeds.
	f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "on re-review, confirmed", 0, nil, nil, 1400)
	p := CloseBounty(&b, sponsorAddr, b.Deadline()+1, []Finding{f})
	if !p.Due() || p.Amount != 4500000 {
		t.Fatalf("close after resolution refund wrong: %+v", p)
	}
	assertInvariants(t, &b, []Finding{f})
}

// ---------------------------------------------------------------------------
// Day-2 tests: MarkFixed / disclosure.
// ---------------------------------------------------------------------------

func TestMarkFixedBounty(t *testing.T) {
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	f2 := mustCommit(t, &b, 2, hunter2Addr, SevHigh, 1300)
	// Only the Accepted finding is disclosed; the Committed one is untouched.
	n := MarkFixedBounty(&b, sponsorAddr, 2000, []*Finding{&f1, &f2})
	if n != 1 {
		t.Fatalf("MarkFixed disclosed %d, want 1", n)
	}
	if f1.Status() != FindingDisclosed || f1.DisclosedAt() != 2000 {
		t.Fatalf("disclosed finding wrong: %+v", f1)
	}
	if f2.Status() != FindingCommitted {
		t.Fatalf("committed finding must be untouched")
	}
	assertInvariants(t, &b, []Finding{f1, f2})
	// MarkFixed is idempotent over already-disclosed findings.
	n = MarkFixedBounty(&b, sponsorAddr, 2100, []*Finding{&f1, &f2})
	if n != 0 {
		t.Fatalf("second MarkFixed disclosed %d, want 0", n)
	}
}

func TestMarkFixedRejects(t *testing.T) {
	b := mustBounty(t)
	f1 := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f1.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	// Wrong actor.
	expectPanic(t, func() { MarkFixedBounty(&b, arbiterAddr, 2000, []*Finding{&f1}) })
	// A finding from another bounty in the list.
	b2 := NewBounty(2, sponsorAddr, arbiterAddr, "Other audit", "scope",
		5000000, 3000000, 1000000, 500000, 1000, 1000+2592000)
	fx := mustCommit(t, &b2, 9, hunterAddr, SevCritical, 1000)
	expectPanic(t, func() { MarkFixedBounty(&b, sponsorAddr, 2000, []*Finding{&fx}) })
	// Nil finding in the list.
	expectPanic(t, func() { MarkFixedBounty(&b, sponsorAddr, 2000, []*Finding{nil}) })
	// MarkDisclosed on a non-Accepted finding panics.
	f2 := mustCommit(t, &b, 2, hunter2Addr, SevHigh, 1300)
	expectPanic(t, func() { f2.MarkDisclosed(2000) })
	assertInvariants(t, &b, []Finding{f1, f2})
}

func TestAutoDisclose(t *testing.T) {
	b := mustBounty(t)
	f := mustRevealed(t, &b, 1, hunterAddr, SevCritical, 1000, 1100)
	f.ApplyVerdict(&b, arbiterAddr, VerdictAccept, SevCritical, "confirmed", 0, nil, nil, 1200)
	// Exactly at verdictAt + FixWindow the window has NOT elapsed.
	expectPanic(t, func() { f.AutoDisclose(1200 + FixWindow) })
	f.AutoDisclose(1200 + FixWindow + 1)
	if f.Status() != FindingDisclosed || f.DisclosedAt() != 1200+FixWindow+1 {
		t.Fatalf("auto-disclosed finding wrong: %+v", f)
	}
	assertInvariants(t, &b, []Finding{f})
}

// ---------------------------------------------------------------------------
// Day-2 test: mixed-run invariant fuzz (design §7 T2 pattern).
// 3 seeds x 1000 pseudo-random moves (day 3: was 1 seed x 300 steps);
// the §4.2 invariant must hold after EVERY step, whether the
// attempted move succeeded or panicked.
// ---------------------------------------------------------------------------

func TestMixedRunInvariant(t *testing.T) {
	for _, seed := range []uint64{0x9E3779B97F4A7C15, 0x123456789ABCDEF0, 0xDEADBEEFCAFEBABE} {
		runMixedInvariant(t, seed, 1000)
	}
}

func runMixedInvariant(t *testing.T, seed uint64, steps int) {
	b := mustBounty(t)
	height := int64(1000)
	// Deterministic LCG (no math/rand dependency in Gno tests).
	var rng uint64 = seed
	next := func() uint64 {
		rng = rng*6364136223846793005 + 1442695040888963407
		return rng >> 33
	}
	findings := []Finding{}
	salts := []string{}
	titles := []string{}
	successes := 0
	for step := 0; step < steps; step++ {
		action := next() % 12
		var panicked bool
		switch action {
		case 0: // commit a new finding
			id := uint64(len(findings) + 1)
			var hunter address = hunterAddr
			if next()%2 == 0 {
				hunter = hunter2Addr
			}
			sev := Severity(1 + next()%4)
			salt := revealSalt
			if next()%2 == 0 {
				salt = revealSalt2
			}
			// One distinct title per finding index: the day-3 hash
			// rule blocks re-committing a hash carried by any
			// non-expired finding, and the fuzz only has two salts
			// — without a varying title it would run out of fresh
			// hashes after the first few findings.
			title := revealTitle
			if len(findings) > 0 {
				title = revealTitle + " #" + strconv.Itoa(len(findings))
			}
			hash := MakeCommitment(b.ID(), sev, title, revealPoc, salt)
			panicked = tryMove(func() {
				f := CommitFinding(&b, findings, id, hunter, sev, hash, height)
				findings = append(findings, f)
				salts = append(salts, salt)
				titles = append(titles, title)
			})
		case 1: // reveal a random finding
			if len(findings) == 0 {
				continue
			}
			i := int(next() % uint64(len(findings)))
			salt := salts[i]
			title := titles[i]
			panicked = tryMove(func() {
				findings[i].Reveal(&b, findings[i].Hunter(), title, revealPoc, salt, height)
			})
		case 2: // arbiter accept, random final tier
			if len(findings) == 0 {
				continue
			}
			i := int(next() % uint64(len(findings)))
			finalSev := Severity(1 + next()%4)
			others := othersExcluding(findings, i)
			panicked = tryMove(func() {
				findings[i].ApplyVerdict(&b, arbiterAddr, VerdictAccept, finalSev, "fuzz verdict", 0, nil, others, height)
			})
		case 3: // arbiter reject
			if len(findings) == 0 {
				continue
			}
			i := int(next() % uint64(len(findings)))
			panicked = tryMove(func() {
				findings[i].ApplyVerdict(&b, arbiterAddr, VerdictReject, 0, "fuzz reject", 0, nil, nil, height)
			})
		case 4: // arbiter duplicate against another finding
			if len(findings) < 2 {
				continue
			}
			i := int(next() % uint64(len(findings)))
			j := int(next() % uint64(len(findings)))
			if i == j {
				continue
			}
			orig := &findings[j]
			panicked = tryMove(func() {
				findings[i].ApplyVerdict(&b, arbiterAddr, VerdictDuplicate, 0, "fuzz duplicate", orig.ID(), orig, nil, height)
			})
		case 5: // dispute
			if len(findings) == 0 {
				continue
			}
			i := int(next() % uint64(len(findings)))
			panicked = tryMove(func() {
				findings[i].Dispute(findings[i].Hunter(), "fuzz dispute", height)
			})
		case 6: // claim payout
			if len(findings) == 0 {
				continue
			}
			i := int(next() % uint64(len(findings)))
			others := othersExcluding(findings, i)
			panicked = tryMove(func() {
				findings[i].ClaimPayout(&b, findings[i].Hunter(), others, height)
			})
		case 7: // top up the pool
			amount := int64(100000 + next()%900000)
			panicked = tryMove(func() { b.TopUp(amount) })
		case 8: // expire a commit
			if len(findings) == 0 {
				continue
			}
			i := int(next() % uint64(len(findings)))
			panicked = tryMove(func() { findings[i].ExpireCommit(height) })
		case 9: // advance the chain
			height += int64(1 + next()%5000)
			panicked = false
		case 10: // sponsor verdict (accept or reject)
			if len(findings) == 0 {
				continue
			}
			i := int(next() % uint64(len(findings)))
			if next()%2 == 0 {
				finalSev := Severity(1 + next()%4)
				others := othersExcluding(findings, i)
				panicked = tryMove(func() {
					findings[i].SponsorVerdict(&b, sponsorAddr, VerdictAccept, finalSev, "fuzz sponsor accept", 0, nil, others, height)
				})
			} else {
				panicked = tryMove(func() {
					findings[i].SponsorVerdict(&b, sponsorAddr, VerdictReject, 0, "fuzz sponsor reject", 0, nil, nil, height)
				})
			}
		case 11: // mark fixed + auto-disclose sweep
			ptrs := []*Finding{}
			for i := range findings {
				ptrs = append(ptrs, &findings[i])
			}
			panicked = tryMove(func() { MarkFixedBounty(&b, sponsorAddr, height, ptrs) })
			for i := range findings {
				tryMove(func() { findings[i].AutoDisclose(height) })
			}
		}
		if !panicked {
			successes++
		}
		// The invariant must hold after every step, success or panic.
		assertInvariants(t, &b, findings)
	}
	if len(findings) < 10 {
		t.Fatalf("fuzz seed %x committed only %d findings in %d steps", seed, len(findings), steps)
	}
	if successes < 100 {
		t.Fatalf("fuzz seed %x succeeded only %d/%d moves — the run is not exercising the machine", seed, successes, steps)
	}
	// Money accounting must close exactly (also covered by CheckInvariant).
	if b.PoolLeft()+b.PaidOut()+b.Refunded() != b.PoolTotal() {
		t.Fatalf("fuzz seed %x pool accounting broken: left %d paid %d refunded %d total %d",
			seed, b.PoolLeft(), b.PaidOut(), b.Refunded(), b.PoolTotal())
	}
	t.Logf("fuzz seed %x: %d steps, %d findings, %d successful moves, pool left %d paid %d",
		seed, steps, len(findings), successes, b.PoolLeft(), b.PaidOut())
}
