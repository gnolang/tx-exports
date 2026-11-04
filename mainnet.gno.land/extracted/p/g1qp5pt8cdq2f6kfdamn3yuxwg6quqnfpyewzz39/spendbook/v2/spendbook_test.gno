package spendbook

import "testing"

const (
	alice = "g1alice" // owner
	bob   = "g1bob"   // spender
	carol = "g1carol" // neither
)

// day is the default PeriodLength: a round number so window boundaries in the
// tests are readable as multiples of it from the anchor.
const day = int64(100)

// openDefault opens one allowance anchored at `anchor` with a window cap of
// 50 per `day`, no lifetime cap and no expiry.
func openDefault(t *testing.T, anchor int64) (*Book, uint64) {
	t.Helper()
	b := MustNew(8)
	id, err := b.Open(alice, bob, anchor, Terms{PerPeriod: 50, PeriodLength: day})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return b, id
}

// mustSpend fails the test if a permitted draw is refused.
func mustSpend(t *testing.T, b *Book, id uint64, now, amount int64) {
	t.Helper()
	if err := b.Spend(id, bob, now, amount); err != nil {
		t.Fatalf("Spend(%d, now=%d, amt=%d): %v", id, now, amount, err)
	}
}

// refuse fails the test unless the draw is refused with want.
func refuse(t *testing.T, b *Book, id uint64, now, amount int64, want error) {
	t.Helper()
	if err := b.Spend(id, bob, now, amount); err != want {
		t.Fatalf("Spend(%d, now=%d, amt=%d): got %v, want %v",
			id, now, amount, err, want)
	}
}

// --- construction ---------------------------------------------------------

func TestNewRejectsBadConfig(t *testing.T) {
	for _, maxLive := range []int{0, -1, MaxLiveLimit + 1} {
		if _, err := New(maxLive); err != ErrInvalidConfig {
			t.Errorf("New(%d): got %v, want ErrInvalidConfig", maxLive, err)
		}
	}
}

func TestNewAcceptsTheBoundaries(t *testing.T) {
	for _, maxLive := range []int{1, MaxLiveLimit} {
		b, err := New(maxLive)
		if err != nil {
			t.Fatalf("New(%d): %v", maxLive, err)
		}
		if b.MaxLive() != maxLive {
			t.Errorf("MaxLive: got %d, want %d", b.MaxLive(), maxLive)
		}
		if b.Count() != 0 {
			t.Errorf("fresh Count: got %d, want 0", b.Count())
		}
	}
}

func TestMustNewPanicsOnBadConfig(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("MustNew(0) did not panic")
		}
	}()
	MustNew(0)
}

// --- Open -----------------------------------------------------------------

func TestOpenRejectsBadKeys(t *testing.T) {
	b := MustNew(4)
	long := ""
	for i := 0; i <= MaxKeyLen; i++ {
		long += "x"
	}
	ok := Terms{PerPeriod: 10, PeriodLength: day}

	cases := []struct {
		name            string
		owner, spender  string
		want            error
	}{
		{"empty owner", "", bob, ErrEmptyOwner},
		{"empty spender", alice, "", ErrEmptySpender},
		{"owner too long", long, bob, ErrKeyTooLong},
		{"spender too long", alice, long, ErrKeyTooLong},
	}
	for _, c := range cases {
		if _, err := b.Open(c.owner, c.spender, 0, ok); err != c.want {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
	// The boundary itself is allowed: MaxKeyLen characters exactly.
	exact := long[:MaxKeyLen]
	if _, err := b.Open(exact, exact, 0, ok); err != nil {
		t.Errorf("key of exactly MaxKeyLen: %v", err)
	}
}

func TestOpenRejectsNegativeNow(t *testing.T) {
	b := MustNew(4)
	_, err := b.Open(alice, bob, -1, Terms{PerPeriod: 10, PeriodLength: day})
	if err != ErrInvalidNow {
		t.Errorf("got %v, want ErrInvalidNow", err)
	}
}

func TestOpenRejectsInvalidTerms(t *testing.T) {
	b := MustNew(4)
	cases := []struct {
		name  string
		terms Terms
	}{
		{"zero PerPeriod", Terms{PerPeriod: 0, PeriodLength: day}},
		{"negative PerPeriod", Terms{PerPeriod: -1, PeriodLength: day}},
		{"negative PeriodLength", Terms{PerPeriod: 10, PeriodLength: -1}},
		{"negative Total", Terms{PerPeriod: 10, PeriodLength: day, Total: -1}},
		{"negative ExpiresAt", Terms{PerPeriod: 10, PeriodLength: day, ExpiresAt: -1}},
		// An expiry at or before the anchor can never authorize anything.
		{"expiry at anchor", Terms{PerPeriod: 10, PeriodLength: day, ExpiresAt: 1000}},
		{"expiry before anchor", Terms{PerPeriod: 10, PeriodLength: day, ExpiresAt: 999}},
	}
	for _, c := range cases {
		if _, err := b.Open(alice, bob, 1000, c.terms); err != ErrInvalidTerms {
			t.Errorf("%s: got %v, want ErrInvalidTerms", c.name, err)
		}
	}
	// One past the anchor is the first acceptable expiry.
	ok := Terms{PerPeriod: 10, PeriodLength: day, ExpiresAt: 1001}
	if _, err := b.Open(alice, bob, 1000, ok); err != nil {
		t.Errorf("expiry one past the anchor: %v", err)
	}
}

func TestOpenAcceptsTotalBelowPerPeriod(t *testing.T) {
	// Not a contradiction: it is a narrower lifetime cap, and Spend is what
	// enforces the narrower of the two.
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, Total: 10})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if got := b.Remaining(id, 0); got != 10 {
		t.Errorf("Remaining: got %d, want 10 (the lifetime cap)", got)
	}
	refuse(t, b, id, 0, 11, ErrTotalExceeded)
	mustSpend(t, b, id, 0, 10)
}

func TestOpenEnforcesMaxLive(t *testing.T) {
	b := MustNew(2)
	terms := Terms{PerPeriod: 10, PeriodLength: day}
	id1, err := b.Open(alice, bob, 0, terms)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	if _, err := b.Open(alice, bob, 0, terms); err != nil {
		t.Fatalf("second Open: %v", err)
	}
	if _, err := b.Open(alice, bob, 0, terms); err != ErrBookFull {
		t.Fatalf("third Open: got %v, want ErrBookFull", err)
	}
	// Revoking frees a slot; the new id is NOT the revoked one.
	if err := b.Revoke(id1, alice); err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	id3, err := b.Open(alice, bob, 0, terms)
	if err != nil {
		t.Fatalf("Open after Revoke: %v", err)
	}
	if id3 == id1 {
		t.Errorf("id %d was reused after revocation", id3)
	}
}

func TestAFreedSlotDoesNotOverwriteALiveSibling(t *testing.T) {
	// Allocating the next id from the LIVE COUNT rather than a monotonic
	// counter looks right until a revocation in the middle: the count falls
	// back onto an id that is still in use, and the next Open silently
	// replaces that allowance instead of adding one. Count is what shows it,
	// which is why this asserts the population and not just the ids.
	b := MustNew(3)
	terms := Terms{PerPeriod: 10, PeriodLength: day}
	id1, _ := b.Open(alice, "s1", 0, terms)
	id2, _ := b.Open(alice, "s2", 0, terms)
	id3, _ := b.Open(alice, "s3", 0, terms)
	if err := b.Revoke(id2, alice); err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	id4, err := b.Open(alice, "s4", 0, terms)
	if err != nil {
		t.Fatalf("Open into the freed slot: %v", err)
	}
	if b.Count() != 3 {
		t.Errorf("Count: got %d, want 3 -- an Open replaced a live allowance",
			b.Count())
	}
	for _, c := range []struct {
		id      uint64
		spender string
	}{{id1, "s1"}, {id3, "s3"}, {id4, "s4"}} {
		a, err := b.Get(c.id)
		if err != nil {
			t.Errorf("Get(%d): %v", c.id, err)
			continue
		}
		if a.Spender != c.spender {
			t.Errorf("id %d: spender %q, want %q", c.id, a.Spender, c.spender)
		}
	}
	if _, err := b.Get(id2); err != ErrNotFound {
		t.Errorf("the revoked id came back: %v", err)
	}
}

func TestOpenAllocatesDistinctIDsForTheSamePair(t *testing.T) {
	// Two allowances for one (owner, spender) pair are independent, and the
	// id is what tells them apart. Drawing one down must not touch the other.
	b := MustNew(4)
	terms := Terms{PerPeriod: 50, PeriodLength: day}
	id1, _ := b.Open(alice, bob, 0, terms)
	id2, _ := b.Open(alice, bob, 0, terms)
	if id1 == id2 {
		t.Fatalf("duplicate id %d", id1)
	}
	mustSpend(t, b, id1, 0, 50)
	if got := b.Remaining(id1, 0); got != 0 {
		t.Errorf("drawn allowance: got %d, want 0", got)
	}
	if got := b.Remaining(id2, 0); got != 50 {
		t.Errorf("sibling allowance: got %d, want 50", got)
	}
}

// --- Get / Remaining lookups ---------------------------------------------

func TestGetUnknownID(t *testing.T) {
	b := MustNew(4)
	if _, err := b.Get(99); err != ErrNotFound {
		t.Errorf("Get: got %v, want ErrNotFound", err)
	}
	// Remaining cannot distinguish the two cases and documents that it
	// answers 0 for both; this pins the documented behavior.
	if got := b.Remaining(99, 0); got != 0 {
		t.Errorf("Remaining of unknown id: got %d, want 0", got)
	}
}

func TestGetReturnsACopy(t *testing.T) {
	b, id := openDefault(t, 0)
	a, err := b.Get(id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	a.Terms.PerPeriod = 1 << 40
	a.SpentWindow = -500
	again, _ := b.Get(id)
	if again.Terms.PerPeriod != 50 || again.SpentWindow != 0 {
		t.Errorf("mutating the returned value reached the book: %+v", again)
	}
}

// --- Spend: the per-window cap -------------------------------------------

func TestSpendWithinWindowCap(t *testing.T) {
	b, id := openDefault(t, 1000)
	mustSpend(t, b, id, 1000, 20)
	if got := b.Remaining(id, 1000); got != 30 {
		t.Errorf("Remaining: got %d, want 30", got)
	}
	mustSpend(t, b, id, 1050, 30)
	if got := b.Remaining(id, 1050); got != 0 {
		t.Errorf("Remaining after full draw: got %d, want 0", got)
	}
	refuse(t, b, id, 1050, 1, ErrPeriodExceeded)
}

func TestSpendRejectsBadArguments(t *testing.T) {
	b, id := openDefault(t, 1000)
	refuse(t, b, id, 1000, 0, ErrInvalidAmount)
	refuse(t, b, id, 1000, -5, ErrInvalidAmount)
	refuse(t, b, id, -1, 10, ErrInvalidNow)
	if err := b.Spend(99, bob, 1000, 10); err != ErrNotFound {
		t.Errorf("unknown id: got %v, want ErrNotFound", err)
	}
}

func TestSpendRejectsTheWrongSpender(t *testing.T) {
	b, id := openDefault(t, 1000)
	// Not the owner's either: owning an allowance does not mean drawing it.
	for _, who := range []string{carol, alice, ""} {
		if err := b.Spend(id, who, 1000, 10); err != ErrNotSpender {
			t.Errorf("Spend as %q: got %v, want ErrNotSpender", who, err)
		}
	}
}

func TestSpendBeforeTheAnchor(t *testing.T) {
	b, id := openDefault(t, 1000)
	refuse(t, b, id, 999, 10, ErrNotStarted)
	// The anchor instant itself is spendable.
	mustSpend(t, b, id, 1000, 10)
}

func TestRemainingBeforeTheAnchorIsZero(t *testing.T) {
	b, id := openDefault(t, 1000)
	if got := b.Remaining(id, 999); got != 0 {
		t.Errorf("got %d, want 0", got)
	}
}

func TestARefusedSpendConsumesNothing(t *testing.T) {
	b, id := openDefault(t, 1000)
	mustSpend(t, b, id, 1000, 40)
	before, _ := b.Get(id)

	// Every refusal path, in one book, each asserted to leave no trace.
	refuse(t, b, id, 1000, 11, ErrPeriodExceeded)
	refuse(t, b, id, 1000, 0, ErrInvalidAmount)
	refuse(t, b, id, -1, 5, ErrInvalidNow)
	if err := b.Spend(id, carol, 1000, 5); err != ErrNotSpender {
		t.Fatalf("wrong spender: %v", err)
	}
	refuse(t, b, id, 999, 5, ErrNotStarted)

	after, _ := b.Get(id)
	if after != before {
		t.Errorf("a refused Spend mutated the allowance:\n before %+v\n after  %+v",
			before, after)
	}
}

// --- Spend: anchored windows ---------------------------------------------

func TestWindowsAreAnchoredNotSliding(t *testing.T) {
	// Anchor 1000, period 100, so boundaries are 1100, 1200, ...
	b, id := openDefault(t, 1000)

	// Draw the whole cap at the very end of window 0.
	mustSpend(t, b, id, 1099, 50)
	refuse(t, b, id, 1099, 1, ErrPeriodExceeded)

	// One instant later is window 1, and the cap is whole again. Under a
	// SLIDING trailing window this draw would have to wait until 1199.
	mustSpend(t, b, id, 1100, 50)
	if got := b.Remaining(id, 1100); got != 0 {
		t.Errorf("window 1 after a full draw: got %d, want 0", got)
	}

	// The boundary is a property of the anchor, not of when anyone called:
	// window 1 ends at 1200 no matter that the first draw in it was at 1100.
	refuse(t, b, id, 1199, 1, ErrPeriodExceeded)
	mustSpend(t, b, id, 1200, 50)
}

func TestWindowRefillIsAResetNotACarry(t *testing.T) {
	b, id := openDefault(t, 0)
	// Spend nothing in windows 0 and 1, then everything available in 2.
	mustSpend(t, b, id, 200, 50)
	// If unused allowance carried, 150 would have been available and 50 more
	// would still be left. The cap bounds worst-case loss PER window, which a
	// carry would unbound.
	refuse(t, b, id, 200, 1, ErrPeriodExceeded)
	if got := b.Remaining(id, 200); got != 0 {
		t.Errorf("Remaining: got %d, want 0", got)
	}
}

func TestWindowIndexSkipsAheadCorrectly(t *testing.T) {
	b, id := openDefault(t, 1000)
	mustSpend(t, b, id, 1000, 50)
	// Jump many windows in one step; the index must land on the real one, not
	// merely increment.
	mustSpend(t, b, id, 1000+37*day+1, 50)
	a, _ := b.Get(id)
	if a.WindowIndex != 37 {
		t.Errorf("WindowIndex: got %d, want 37", a.WindowIndex)
	}
}

func TestLifetimeAllowanceNeverRolls(t *testing.T) {
	b := MustNew(4)
	// PeriodLength 0 == one window that never rolls.
	id, err := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: 0})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	mustSpend(t, b, id, 0, 50)
	for _, now := range []int64{1, 100, 1 << 40, maxInt64} {
		if got := b.Remaining(id, now); got != 0 {
			t.Errorf("Remaining at %d: got %d, want 0 (never refills)", now, got)
		}
		refuse(t, b, id, now, 1, ErrPeriodExceeded)
	}
}

// --- Spend: the lifetime cap and expiry ----------------------------------

func TestTotalCapSurvivesWindowRollover(t *testing.T) {
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, Total: 60})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	mustSpend(t, b, id, 0, 50)
	// Window 1 refills the per-window cap, but the lifetime cap does not
	// refill -- only 10 of the 60 is left.
	if got := b.Remaining(id, day); got != 10 {
		t.Errorf("Remaining in window 1: got %d, want 10", got)
	}
	refuse(t, b, id, day, 11, ErrTotalExceeded)
	mustSpend(t, b, id, day, 10)
	for _, now := range []int64{day, 2 * day, 99 * day} {
		if got := b.Remaining(id, now); got != 0 {
			t.Errorf("Remaining at %d: got %d, want 0 (lifetime spent)", now, got)
		}
	}
}

func TestExpiry(t *testing.T) {
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 250})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	a, _ := b.Get(id)
	if a.IsExpired(249) {
		t.Error("expired one instant early")
	}
	if !a.IsExpired(250) {
		t.Error("ExpiresAt is exclusive: 250 must be expired")
	}
	mustSpend(t, b, id, 249, 10)
	refuse(t, b, id, 250, 1, ErrExpired)
	if got := b.Remaining(id, 250); got != 0 {
		t.Errorf("Remaining when expired: got %d, want 0", got)
	}
}

func TestNoExpiryNeverExpires(t *testing.T) {
	b, id := openDefault(t, 0)
	a, _ := b.Get(id)
	if a.IsExpired(maxInt64) {
		t.Error("an allowance with ExpiresAt 0 reported expired")
	}
}

func TestOverflowGuardOnTheLifetimeAccumulator(t *testing.T) {
	// With Total == 0 (unlimited) SpentTotal is the one accumulation that can
	// genuinely reach the int64 ceiling, so it is the one that needs a guard.
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0, Terms{PerPeriod: maxInt64, PeriodLength: day})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	mustSpend(t, b, id, 0, maxInt64-5)
	a, _ := b.Get(id)
	if a.SpentTotal != maxInt64-5 {
		t.Fatalf("SpentTotal: got %d", a.SpentTotal)
	}
	// Next window: the per-window cap permits this draw, and only the
	// overflow guard stands between it and a wrapped SpentTotal.
	refuse(t, b, id, day, 10, ErrOverflow)
	mustSpend(t, b, id, day, 5)
	a, _ = b.Get(id)
	if a.SpentTotal != maxInt64 {
		t.Errorf("SpentTotal at the ceiling: got %d, want %d", a.SpentTotal, maxInt64)
	}
	refuse(t, b, id, 2*day, 1, ErrOverflow)
}

// --- Revoke ---------------------------------------------------------------

func TestRevoke(t *testing.T) {
	b, id := openDefault(t, 0)
	if err := b.Revoke(id, carol); err != ErrNotOwner {
		t.Errorf("Revoke as a stranger: got %v, want ErrNotOwner", err)
	}
	if err := b.Revoke(id, bob); err != ErrNotOwner {
		t.Errorf("Revoke as the spender: got %v, want ErrNotOwner", err)
	}
	if err := b.Revoke(99, alice); err != ErrNotFound {
		t.Errorf("Revoke unknown: got %v, want ErrNotFound", err)
	}
	if err := b.Revoke(id, alice); err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	if b.Count() != 0 {
		t.Errorf("Count after Revoke: got %d, want 0", b.Count())
	}
	// Revocation is immediate and permanent -- the id is never resurrected.
	refuse(t, b, id, 0, 1, ErrNotFound)
	if err := b.Revoke(id, alice); err != ErrNotFound {
		t.Errorf("second Revoke: got %v, want ErrNotFound", err)
	}
}

func TestRevokeIsImmediateNotDeferredToABoundary(t *testing.T) {
	// Revocation is the owner's remedy, and a remedy that waits for a window
	// boundary is not one.
	b, id := openDefault(t, 0)
	mustSpend(t, b, id, 0, 10)
	if err := b.Revoke(id, alice); err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	refuse(t, b, id, 0, 1, ErrNotFound)
}

// --- Reap -----------------------------------------------------------------

func TestReapOnlyTakesExpiredAllowances(t *testing.T) {
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 250})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := b.Reap(id, 249); err != ErrNotExpired {
		t.Errorf("Reap a live allowance: got %v, want ErrNotExpired", err)
	}
	if err := b.Reap(id, -1); err != ErrInvalidNow {
		t.Errorf("Reap with a negative clock: got %v, want ErrInvalidNow", err)
	}
	if err := b.Reap(99, 250); err != ErrNotFound {
		t.Errorf("Reap unknown: got %v, want ErrNotFound", err)
	}
	// Permissionless: carol is neither owner nor spender and there is no
	// caller argument at all, which is the point.
	if err := b.Reap(id, 250); err != nil {
		t.Fatalf("Reap an expired allowance: %v", err)
	}
	if b.Count() != 0 {
		t.Errorf("Count after Reap: got %d, want 0", b.Count())
	}
	if err := b.Reap(id, 250); err != ErrNotFound {
		t.Errorf("second Reap: got %v, want ErrNotFound", err)
	}
}

func TestReapNeverTakesAnAllowanceWithNoExpiry(t *testing.T) {
	b, id := openDefault(t, 0)
	if err := b.Reap(id, maxInt64); err != ErrNotExpired {
		t.Errorf("got %v, want ErrNotExpired", err)
	}
}

func TestReapReclaimsASlot(t *testing.T) {
	// The defect Reap exists for: without it an expired allowance refuses
	// every Spend forever while still holding a slot against maxLive.
	b := MustNew(1)
	id, err := b.Open(alice, bob, 0, Terms{PerPeriod: 10, PeriodLength: day, ExpiresAt: 50})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	live := Terms{PerPeriod: 10, PeriodLength: day}
	if _, err := b.Open(alice, carol, 50, live); err != ErrBookFull {
		t.Fatalf("Open over a corpse: got %v, want ErrBookFull", err)
	}
	if err := b.Reap(id, 50); err != nil {
		t.Fatalf("Reap: %v", err)
	}
	if _, err := b.Open(alice, carol, 50, live); err != nil {
		t.Fatalf("Open after Reap: %v", err)
	}
}

// --- Amend: tighter applies immediately ----------------------------------

func TestAmendTighterAppliesImmediately(t *testing.T) {
	b, id := openDefault(t, 0)
	mustSpend(t, b, id, 10, 20)

	now, err := b.Amend(id, alice, 10, Terms{PerPeriod: 30, PeriodLength: day})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !now {
		t.Fatal("a tightening was queued instead of applied")
	}
	// 30 cap, 20 already spent in this window.
	if got := b.Remaining(id, 10); got != 10 {
		t.Errorf("Remaining: got %d, want 10", got)
	}
	refuse(t, b, id, 10, 11, ErrPeriodExceeded)
	mustSpend(t, b, id, 10, 10)
}

func TestAmendTighteningBelowWhatIsSpentClampsToZero(t *testing.T) {
	// Reachable, and the allowance must read as drawn rather than negative.
	b, id := openDefault(t, 0)
	mustSpend(t, b, id, 0, 40)
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 10, PeriodLength: day})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !applied {
		t.Fatal("tightening was queued")
	}
	if got := b.Remaining(id, 0); got != 0 {
		t.Errorf("Remaining: got %d, want 0", got)
	}
	refuse(t, b, id, 0, 1, ErrPeriodExceeded)
	// The next window refills to the NEW, tighter cap.
	if got := b.Remaining(id, day); got != 10 {
		t.Errorf("Remaining in the next window: got %d, want 10", got)
	}
}

func TestAmendEqualTermsApplyImmediately(t *testing.T) {
	// "Tighter OR EQUAL": re-stating the same terms is not a loosening and
	// must not be deferred, or a no-op amendment would sit queued.
	b, id := openDefault(t, 0)
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 50, PeriodLength: day})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !applied {
		t.Error("identical terms were queued")
	}
}

// --- Amend: looser is deferred to the next boundary ----------------------

func TestAmendLooserIsPendingUntilTheNextBoundary(t *testing.T) {
	b, id := openDefault(t, 0)
	mustSpend(t, b, id, 0, 50)

	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 500, PeriodLength: day})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if applied {
		t.Fatal("a loosening took effect inside the live window")
	}
	// The live window is untouched: this is the drain-then-raise-terms
	// attack, and the whole point is that the raise cannot reach back.
	if got := b.Remaining(id, 0); got != 0 {
		t.Errorf("Remaining in the live window: got %d, want 0", got)
	}
	refuse(t, b, id, 99, 1, ErrPeriodExceeded)

	// At the boundary the pending terms are in force.
	if got := b.Remaining(id, day); got != 500 {
		t.Errorf("Remaining at the boundary: got %d, want 500", got)
	}
	mustSpend(t, b, id, day, 500)

	// And they are now the allowance's real terms, not a one-window grant.
	a, _ := b.Get(id)
	if a.HasPending {
		t.Error("the pending amendment was not consumed")
	}
	if a.Terms.PerPeriod != 500 {
		t.Errorf("Terms.PerPeriod: got %d, want 500", a.Terms.PerPeriod)
	}
	if got := b.Remaining(id, 2*day); got != 500 {
		t.Errorf("Remaining two windows on: got %d, want 500", got)
	}
}

func TestPendingAmendmentAppliesThroughRemainingWithoutASpend(t *testing.T) {
	// Remaining and Spend share one implementation of the rollover rule, so a
	// read must not report the old terms just because nobody has spent yet.
	b, id := openDefault(t, 0)
	if _, err := b.Amend(id, alice, 0, Terms{PerPeriod: 500, PeriodLength: day}); err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if got := b.Remaining(id, day); got != 500 {
		t.Errorf("Remaining: got %d, want 500", got)
	}
	// ... and what the read promised is what the write honors.
	mustSpend(t, b, id, day, 500)
}

func TestATighteningSupersedesAQueuedLoosening(t *testing.T) {
	// Otherwise the owner's tightening silently expires at the next boundary
	// and the looser terms they just replaced come back.
	b, id := openDefault(t, 0)
	if _, err := b.Amend(id, alice, 0, Terms{PerPeriod: 500, PeriodLength: day}); err != nil {
		t.Fatalf("loosening Amend: %v", err)
	}
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 20, PeriodLength: day})
	if err != nil {
		t.Fatalf("tightening Amend: %v", err)
	}
	if !applied {
		t.Fatal("the tightening was queued")
	}
	a, _ := b.Get(id)
	if a.HasPending {
		t.Error("the queued loosening survived the tightening")
	}
	if got := b.Remaining(id, 0); got != 20 {
		t.Errorf("Remaining now: got %d, want 20", got)
	}
	if got := b.Remaining(id, day); got != 20 {
		t.Errorf("Remaining after the boundary: got %d, want 20", got)
	}
	if got := b.Remaining(id, 99*day); got != 20 {
		t.Errorf("Remaining much later: got %d, want 20", got)
	}
}

func TestASecondLooseningReplacesTheQueuedOne(t *testing.T) {
	b, id := openDefault(t, 0)
	if _, err := b.Amend(id, alice, 0, Terms{PerPeriod: 500, PeriodLength: day}); err != nil {
		t.Fatalf("first: %v", err)
	}
	if _, err := b.Amend(id, alice, 0, Terms{PerPeriod: 300, PeriodLength: day}); err != nil {
		t.Fatalf("second: %v", err)
	}
	// 300 is looser than the live 50 (so still queued) but tighter than the
	// queued 500: the owner's latest word wins.
	if got := b.Remaining(id, day); got != 300 {
		t.Errorf("Remaining at the boundary: got %d, want 300", got)
	}
}

func TestAmendAfterAQuietStretchJudgesAgainstTheTermsInForce(t *testing.T) {
	// The clock has moved several windows past a pending amendment without a
	// Spend to roll the record. Amend must roll first, or it would compare
	// the new terms against stale ones.
	b, id := openDefault(t, 0)
	if _, err := b.Amend(id, alice, 0, Terms{PerPeriod: 500, PeriodLength: day}); err != nil {
		t.Fatalf("loosening: %v", err)
	}
	// Window 5. The pending 500 is in force here, so 200 is a TIGHTENING and
	// must apply immediately. Judged against the stale 50 it would look like
	// a loosening and be queued for a boundary that has already passed.
	applied, err := b.Amend(id, alice, 5*day, Terms{PerPeriod: 200, PeriodLength: day})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !applied {
		t.Fatal("judged against stale terms: a tightening was queued")
	}
	if got := b.Remaining(id, 5*day); got != 200 {
		t.Errorf("Remaining: got %d, want 200", got)
	}
}

func TestRollingThroughAmendResetsTheWindowSpend(t *testing.T) {
	b, id := openDefault(t, 0)
	mustSpend(t, b, id, 0, 50)
	// Amend in window 3 with equal terms; the roll it performs must reset the
	// in-window spend rather than carry window 0's 50 forward.
	if _, err := b.Amend(id, alice, 3*day, Terms{PerPeriod: 50, PeriodLength: day}); err != nil {
		t.Fatalf("Amend: %v", err)
	}
	a, _ := b.Get(id)
	if a.WindowIndex != 3 || a.SpentWindow != 0 {
		t.Errorf("WindowIndex=%d SpentWindow=%d, want 3 and 0", a.WindowIndex, a.SpentWindow)
	}
	if a.SpentTotal != 50 {
		t.Errorf("SpentTotal: got %d, want 50 (lifetime does not reset)", a.SpentTotal)
	}
	mustSpend(t, b, id, 3*day, 50)
}

// --- Amend: the zero-means-unlimited inversions --------------------------

func TestAmendTotalZeroIsLooserNotTighter(t *testing.T) {
	// Total 0 means NO lifetime cap, so replacing a positive Total with 0 is
	// removing a cap. Reading "smaller is tighter" would let an owner lift it
	// mid-window and call it a tightening.
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, Total: 100})
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 50, PeriodLength: day, Total: 0})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if applied {
		t.Error("removing the lifetime cap applied immediately")
	}
	if got := b.Remaining(id, 0); got != 50 {
		t.Errorf("Remaining: got %d, want 50 (still capped by the live 100)", got)
	}
}

func TestAmendTotalDownwardIsTighter(t *testing.T) {
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, Total: 100})
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 50, PeriodLength: day, Total: 40})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !applied {
		t.Error("lowering the lifetime cap was queued")
	}
	if got := b.Remaining(id, 0); got != 40 {
		t.Errorf("Remaining: got %d, want 40", got)
	}
}

func TestAmendAddingATotalToAnUncappedAllowanceIsTighter(t *testing.T) {
	b, id := openDefault(t, 0) // Total 0 == unlimited
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 50, PeriodLength: day, Total: 60})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !applied {
		t.Error("adding a lifetime cap was queued")
	}
	if got := b.Remaining(id, 0); got != 50 {
		t.Errorf("Remaining: got %d, want 50", got)
	}
	mustSpend(t, b, id, 0, 50)
	if got := b.Remaining(id, day); got != 10 {
		t.Errorf("Remaining in window 1: got %d, want 10", got)
	}
}

func TestAmendExpiresAtZeroIsLooserNotTighter(t *testing.T) {
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 10 * day})
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 0})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if applied {
		t.Error("removing the expiry applied immediately")
	}
	// The live expiry still bites until the boundary consumes the pending
	// terms, which here it does at day 1 -- well before the old expiry.
	a, _ := b.Get(id)
	if !a.HasPending {
		t.Fatal("no pending amendment recorded")
	}
	mustSpend(t, b, id, day, 50)
	a, _ = b.Get(id)
	if a.Terms.ExpiresAt != 0 {
		t.Errorf("ExpiresAt after the boundary: got %d, want 0", a.Terms.ExpiresAt)
	}
	if a.IsExpired(100 * day) {
		t.Error("still expiring on the old terms")
	}
}

func TestAmendShorteningTheExpiryIsTighter(t *testing.T) {
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 10 * day})
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 2 * day})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !applied {
		t.Fatal("shortening the expiry was queued")
	}
	mustSpend(t, b, id, day, 10)
	refuse(t, b, id, 2*day, 1, ErrExpired)
}

func TestAmendAddingAnExpiryToAnUnexpiringAllowanceIsTighter(t *testing.T) {
	b, id := openDefault(t, 0) // ExpiresAt 0 == never
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 2 * day})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !applied {
		t.Fatal("adding an expiry was queued")
	}
	refuse(t, b, id, 2*day, 1, ErrExpired)
}

func TestAmendMixedDirectionsIsLooser(t *testing.T) {
	// Tighter in one dimension and looser in another is NOT tighter: the
	// predicate is weakly tighter in EVERY dimension.
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, Total: 100})
	applied, err := b.Amend(id, alice, 0,
		Terms{PerPeriod: 10, PeriodLength: day, Total: 1000})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if applied {
		t.Error("a lower PerPeriod with a raised Total applied immediately")
	}
	if got := b.Remaining(id, 0); got != 50 {
		t.Errorf("Remaining: got %d, want 50 (live terms unchanged)", got)
	}
}

// --- Amend: PeriodLength is immutable ------------------------------------

func TestAmendCannotChangePeriodLength(t *testing.T) {
	// Moving every future boundary is an enlargement vector wearing a
	// different hat, so it is refused in BOTH directions rather than queued.
	b, id := openDefault(t, 0)
	for _, pl := range []int64{day - 1, day + 1, 0, 1} {
		_, err := b.Amend(id, alice, 0, Terms{PerPeriod: 50, PeriodLength: pl})
		if err != ErrInvalidTerms {
			t.Errorf("PeriodLength %d: got %v, want ErrInvalidTerms", pl, err)
		}
	}
	// And the tighter-or-equal predicate independently refuses it, so the
	// check in Amend is not the only thing standing in the way.
	a := Terms{PerPeriod: 1, PeriodLength: day}
	c := Terms{PerPeriod: 1, PeriodLength: day + 1}
	if a.tighterOrEqualTo(c) || c.tighterOrEqualTo(a) {
		t.Error("tighterOrEqualTo accepted a PeriodLength change")
	}
}

// --- Amend: no reachable boundary ----------------------------------------

func TestAmendLooserOnALifetimeAllowanceIsRefused(t *testing.T) {
	// PeriodLength 0 has no next boundary, so queueing would park the
	// amendment forever and report it as accepted.
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: 0})
	_, err := b.Amend(id, alice, 0, Terms{PerPeriod: 500, PeriodLength: 0})
	if err != ErrNoBoundary {
		t.Errorf("got %v, want ErrNoBoundary", err)
	}
	// A tightening on a lifetime allowance is still fine: it needs no window.
	applied, err := b.Amend(id, alice, 0, Terms{PerPeriod: 10, PeriodLength: 0})
	if err != nil {
		t.Fatalf("tightening a lifetime allowance: %v", err)
	}
	if !applied {
		t.Error("the tightening was queued")
	}
}

func TestAmendLooserIsRefusedWhenTheExpiryPrecedesTheNextBoundary(t *testing.T) {
	// The ordinary-use case: tightening ExpiresAt applies IMMEDIATELY, so an
	// owner can pull the expiry in below the next boundary and then try to
	// loosen PerPeriod. The boundary the loosening waits for never opens.
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 10 * day})
	applied, err := b.Amend(id, alice, 0,
		Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: day / 2})
	if err != nil {
		t.Fatalf("tightening the expiry: %v", err)
	}
	if !applied {
		t.Fatal("the tightening was queued")
	}
	// Next boundary is `day`; the allowance dies at day/2.
	_, err = b.Amend(id, alice, 0, Terms{PerPeriod: 500, PeriodLength: day, ExpiresAt: day / 2})
	if err != ErrNoBoundary {
		t.Errorf("got %v, want ErrNoBoundary", err)
	}
	// Pushing the expiry back out is itself a loosening, so it cannot be the
	// owner's way out: it is judged against the same dead window and refused
	// identically. The tightening is one-way without a reachable boundary,
	// and Revoke plus a fresh Open is the only route.
	if _, err := b.Amend(id, alice, 0,
		Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 5 * day}); err != ErrNoBoundary {
		t.Errorf("re-expanding the expiry: got %v, want ErrNoBoundary", err)
	}
	a, _ := b.Get(id)
	if a.Terms.ExpiresAt != day/2 {
		t.Errorf("a loosened expiry applied immediately: %d", a.Terms.ExpiresAt)
	}
}

func TestTheUnreachableBoundaryTestIsGreaterOrEqualNotGreater(t *testing.T) {
	// An expiry exactly AT the next boundary is unreachable, because the
	// window opens at `day` and IsExpired is already true at `day`. Off by
	// one in the comparison would queue an amendment into a window that
	// exists for zero instants.
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: day})
	looser := Terms{PerPeriod: 500, PeriodLength: day, ExpiresAt: day}
	if _, err := b.Amend(id, alice, 0, looser); err != ErrNoBoundary {
		t.Errorf("expiry at the boundary: got %v, want ErrNoBoundary", err)
	}

	// One instant later the boundary IS reachable, which is what keeps the
	// check above from being a tool that merely always refuses.
	b2 := MustNew(4)
	id2, _ := b2.Open(alice, bob, 0, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: day + 1})
	applied, err := b2.Amend(id2, alice, 0,
		Terms{PerPeriod: 500, PeriodLength: day, ExpiresAt: day + 1})
	if err != nil {
		t.Fatalf("expiry one past the boundary: %v", err)
	}
	if applied {
		t.Fatal("the loosening applied immediately")
	}
	// And the one instant it is alive for actually honors the new terms.
	mustSpend(t, b2, id2, day, 500)
}

func TestNextBoundaryRefusesUnrepresentableArithmetic(t *testing.T) {
	// An unguarded Anchor + (idx+1)*PeriodLength would wrap and report a
	// boundary in the PAST, which is the dangerous direction: Amend would
	// queue a loosening as though it were about to take effect.
	a := Allowance{Anchor: 0, Terms: Terms{PerPeriod: 1, PeriodLength: maxInt64}}
	if _, ok := a.nextBoundary(1); ok {
		t.Error("steps * PeriodLength overflow was not detected")
	}
	if nb, ok := a.nextBoundary(0); !ok || nb != maxInt64 {
		t.Errorf("the representable boundary: got %d/%v, want %d/true",
			nb, ok, maxInt64)
	}
	// Overflow in the Anchor + offset term rather than the product.
	a2 := Allowance{Anchor: maxInt64 - 5, Terms: Terms{PerPeriod: 1, PeriodLength: 10}}
	if _, ok := a2.nextBoundary(0); ok {
		t.Error("Anchor + offset overflow was not detected")
	}
	// A lifetime allowance has none by construction.
	a3 := Allowance{Terms: Terms{PerPeriod: 1, PeriodLength: 0}}
	if _, ok := a3.nextBoundary(0); ok {
		t.Error("a lifetime allowance reported a boundary")
	}
}

func TestAmendLooserIsRefusedWhenTheBoundaryIsUnrepresentable(t *testing.T) {
	b := MustNew(4)
	id, _ := b.Open(alice, bob, maxInt64-5, Terms{PerPeriod: 50, PeriodLength: 10})
	_, err := b.Amend(id, alice, maxInt64-5, Terms{PerPeriod: 500, PeriodLength: 10})
	if err != ErrNoBoundary {
		t.Errorf("got %v, want ErrNoBoundary", err)
	}
}

// --- Amend: authorization and argument checks ----------------------------

func TestAmendRejectsNonOwners(t *testing.T) {
	b, id := openDefault(t, 0)
	tighter := Terms{PerPeriod: 10, PeriodLength: day}
	for _, who := range []string{bob, carol, ""} {
		if _, err := b.Amend(id, who, 0, tighter); err != ErrNotOwner {
			t.Errorf("Amend as %q: got %v, want ErrNotOwner", who, err)
		}
	}
	if _, err := b.Amend(99, alice, 0, tighter); err != ErrNotFound {
		t.Errorf("unknown id: got %v, want ErrNotFound", err)
	}
}

func TestAmendRejectsBadArgumentsAndDeadAllowances(t *testing.T) {
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 1000, Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 2000})
	tighter := Terms{PerPeriod: 10, PeriodLength: day, ExpiresAt: 2000}

	if _, err := b.Amend(id, alice, -1, tighter); err != ErrInvalidNow {
		t.Errorf("negative now: got %v, want ErrInvalidNow", err)
	}
	if _, err := b.Amend(id, alice, 999, tighter); err != ErrNotStarted {
		t.Errorf("before the anchor: got %v, want ErrNotStarted", err)
	}
	if _, err := b.Amend(id, alice, 2000, tighter); err != ErrExpired {
		t.Errorf("expired: got %v, want ErrExpired", err)
	}
	if _, err := b.Amend(id, alice, 1000, Terms{PerPeriod: 0, PeriodLength: day}); err != ErrInvalidTerms {
		t.Errorf("invalid terms: got %v, want ErrInvalidTerms", err)
	}
}

func TestAmendIsValidatedAgainstTheAnchorNotNow(t *testing.T) {
	// Documented and deliberate: an expiry between the anchor and now is a
	// tightening to the point of death, which is the owner's prerogative.
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 1000, Terms{PerPeriod: 50, PeriodLength: day})
	applied, err := b.Amend(id, alice, 1050,
		Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 1001})
	if err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if !applied {
		t.Fatal("it was queued")
	}
	refuse(t, b, id, 1050, 1, ErrExpired)
	// And the slot is reclaimable, which is what keeps this from being a leak.
	if err := b.Reap(id, 1050); err != nil {
		t.Fatalf("Reap: %v", err)
	}
}

// --- Iterate --------------------------------------------------------------

func TestIterateVisitsEveryAllowanceInIDOrder(t *testing.T) {
	b := MustNew(16)
	terms := Terms{PerPeriod: 10, PeriodLength: day}
	// Enough entries that a lexical key order would diverge from numeric
	// order without the zero padding (9 then 10).
	var want []uint64
	for i := 0; i < 12; i++ {
		id, err := b.Open(alice, bob, 0, terms)
		if err != nil {
			t.Fatalf("Open %d: %v", i, err)
		}
		want = append(want, id)
	}
	var got []uint64
	b.Iterate(func(a Allowance) bool {
		got = append(got, a.ID)
		return false
	})
	if len(got) != len(want) {
		t.Fatalf("visited %d, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order diverged at %d: got %v, want %v", i, got, want)
		}
	}
}

func TestIterateStopsEarly(t *testing.T) {
	b := MustNew(8)
	terms := Terms{PerPeriod: 10, PeriodLength: day}
	for i := 0; i < 5; i++ {
		b.Open(alice, bob, 0, terms)
	}
	n := 0
	b.Iterate(func(a Allowance) bool {
		n++
		return n == 2
	})
	if n != 2 {
		t.Errorf("visited %d, want 2", n)
	}
}

func TestIteratePassesByValue(t *testing.T) {
	b, id := openDefault(t, 0)
	b.Iterate(func(a Allowance) bool {
		a.Terms.PerPeriod = 1 << 40
		a.SpentWindow = -1
		return false
	})
	after, _ := b.Get(id)
	if after.Terms.PerPeriod != 50 || after.SpentWindow != 0 {
		t.Errorf("fn mutated the book through its argument: %+v", after)
	}
}

func TestIterateOnAnEmptyBook(t *testing.T) {
	b := MustNew(4)
	b.Iterate(func(a Allowance) bool {
		t.Error("fn was called on an empty book")
		return false
	})
}

// --- the shared-implementation property ----------------------------------

func TestRemainingAgreesWithWhatSpendHonors(t *testing.T) {
	// Spend and Remaining share one `at`, so the read and the write cannot
	// disagree -- an allowance must never report more than it honors, nor
	// honor more than it reports. This walks a clock across boundaries,
	// amendments and caps, asserting both halves at every step.
	clocks := []int64{0, 10, 99, 100, 150, 199, 200, 201, 500, 501, 900, 1000}

	for _, c := range clocks {
		b := MustNew(4)
		id, err := b.Open(alice, bob, 0,
			Terms{PerPeriod: 50, PeriodLength: day, Total: 120, ExpiresAt: 1000})
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		// Some history, so the state at c is not pristine.
		if err := b.Spend(id, bob, 0, 30); err != nil {
			t.Fatalf("seed Spend: %v", err)
		}
		if _, err := b.Amend(id, alice, 0,
			Terms{PerPeriod: 500, PeriodLength: day, Total: 120, ExpiresAt: 1000}); err != nil {
			t.Fatalf("seed Amend: %v", err)
		}

		r := b.Remaining(id, c)
		if r < 0 {
			t.Fatalf("clock %d: Remaining is negative: %d", c, r)
		}
		if r > 0 {
			// Exactly what it promised must be spendable...
			if err := b.Spend(id, bob, c, r); err != nil {
				t.Errorf("clock %d: Remaining said %d but Spend refused it: %v",
					c, r, err)
			}
			// ...and nothing beyond it.
			if err := b.Spend(id, bob, c, 1); err == nil {
				t.Errorf("clock %d: honored 1 past the reported %d", c, r)
			}
		} else {
			if err := b.Spend(id, bob, c, 1); err == nil {
				t.Errorf("clock %d: Remaining said 0 but Spend honored a draw", c)
			}
		}
	}
}

// --- the last-written record vs the live view ------------------------------
//
// The three tests below were written AFTER the fact, from measurements taken
// on onyx-1 against the deployed bytes, and they are CHARACTERIZATION tests:
// they assert the behaviour this package actually has, not the behaviour it
// ought to have. They exist because that behaviour misled its own first
// consumer, and a hazard nothing asserts is a hazard that gets re-discovered.
//
// The hazard, stated once: Allowance's exported FIELDS are the last-WRITTEN
// record, while the only live-resolved view is behind the unexported at(),
// reachable from outside this package through Remaining alone. Between a
// window boundary and the next write there is no write to update the record,
// so Terms, Pending, HasPending, WindowIndex and SpentWindow all describe a
// window the clock has left -- and a consumer that reads them to DISPLAY
// state publishes figures that disagree with what Spend will honor.
//
// Nothing here is a correctness bug in enforcement. Spend and Remaining both
// route through at() and were correct in all ten live transactions; see
// onyx/DEPLOYMENT.md, Group 9. What is wrong is the shape of the API.

func TestExportedFieldsAreTheLastWrittenRecordNotTheLiveView(t *testing.T) {
	// This is the on-chain sequence of budgets grant #1, in miniature:
	// open, spend, tighten, queue a loosening, then let the window roll with
	// no write at all. Measured on onyx-1 at height 189411, 31 windows after
	// the grant was opened at 186267.
	b, id := openDefault(t, 0) // PerPeriod 50, PeriodLength 100
	mustSpend(t, b, id, 10, 30)

	// Tighter-or-equal applies now.
	applied, err := b.Amend(id, alice, 20, Terms{PerPeriod: 20, PeriodLength: day})
	if err != nil {
		t.Fatalf("tightening Amend: %v", err)
	}
	if !applied {
		t.Fatalf("a tightening amendment should apply immediately")
	}

	// Looser is queued for the next boundary.
	applied, err = b.Amend(id, alice, 30, Terms{PerPeriod: 80, PeriodLength: day})
	if err != nil {
		t.Fatalf("loosening Amend: %v", err)
	}
	if applied {
		t.Fatalf("a loosening amendment should be queued, not applied")
	}

	// Now cross several boundaries WITHOUT writing. now = 3150 is window 31,
	// matching the live measurement.
	const now = int64(3150)

	a, err := b.Get(id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}

	// The live view, through the only exported door that resolves it.
	if got := b.Remaining(id, now); got != 80 {
		t.Fatalf("Remaining: got %d, want 80 (the queued terms took effect "+
			"at the boundary and the window spend reset)", got)
	}
	// And enforcement agrees with the live view, which is the half that
	// matters: on chain this was a real 800000ugnot draw at height 189436
	// (tx f58bc91016b055bfdfeae5e60f7aea1f6652d0f9d45152c89f7a0bcc0bafbf64)
	// against a record still reporting a cap of 200000.
	if err := b.Spend(id, bob, now, 80); err != nil {
		t.Fatalf("Spend of the full live Remaining was refused: %v", err)
	}

	// The record, meanwhile, says three things that are all false at `now`.
	// Each is asserted individually so a future change breaks the specific
	// claim rather than a lump.
	if a.Terms.PerPeriod != 20 {
		t.Errorf("Allowance.Terms.PerPeriod: got %d, want the SUPERSEDED 20 "+
			"-- the field is the last-written record", a.Terms.PerPeriod)
	}
	if !a.HasPending {
		t.Errorf("Allowance.HasPending: got false, want true -- the pending " +
			"flag stays set after its boundary until the next write, so a " +
			"consumer reports an amendment as 'queued' that is already live")
	}
	if a.Pending.PerPeriod != 80 {
		t.Errorf("Allowance.Pending.PerPeriod: got %d, want 80",
			a.Pending.PerPeriod)
	}
	if a.WindowIndex != 0 {
		t.Errorf("Allowance.WindowIndex: got %d, want the LEFT window 0",
			a.WindowIndex)
	}
	if a.SpentWindow != 30 {
		t.Errorf("Allowance.SpentWindow: got %d, want the left window's 30",
			a.SpentWindow)
	}

	// The disagreement, stated as the one assertion a consumer cares about:
	// a display path reading the field publishes a cap of 20 over the very
	// window in which the enforcer just honored 80 -- a factor of four, and
	// in the dangerous direction (the owner is shown LESS authority than the
	// delegate actually holds).
	if a.Terms.PerPeriod >= 80 {
		t.Fatalf("Terms.PerPeriod is %d, which no longer understates the "+
			"honored cap of 80: this test is describing behaviour the "+
			"package has stopped having", a.Terms.PerPeriod)
	}
}

func TestTheStaleRecordSelfHealsOnTheNextWrite(t *testing.T) {
	// The hazard is bounded: it lasts from a boundary until the next write,
	// and any write ends it. Measured on chain -- after the draw at 189436,
	// GrantInfo reported 800000 and PendingTerms reported nothing queued.
	b, id := openDefault(t, 0)
	mustSpend(t, b, id, 10, 30)
	if _, err := b.Amend(id, alice, 30, Terms{PerPeriod: 80, PeriodLength: day}); err != nil {
		t.Fatalf("Amend: %v", err)
	}

	const now = int64(3150)
	mustSpend(t, b, id, now, 5)

	a, err := b.Get(id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if a.Terms.PerPeriod != 80 {
		t.Errorf("after a write, Terms.PerPeriod: got %d, want 80", a.Terms.PerPeriod)
	}
	if a.HasPending {
		t.Errorf("after a write, HasPending should be cleared")
	}
	if a.WindowIndex != 31 {
		t.Errorf("after a write, WindowIndex: got %d, want 31", a.WindowIndex)
	}
	if a.SpentWindow != 5 {
		t.Errorf("after a write, SpentWindow: got %d, want 5", a.SpentWindow)
	}
}

func TestRemainingIsTheOnlyExportedLiveView(t *testing.T) {
	// The remedy a future version wants is an exported live-resolved view --
	// Allowance.At(now), say -- so a consumer's display path cannot read a
	// stale field by accident.
	//
	// THIS TEST DOES NOT ENFORCE THAT ABSENCE, and the first draft of this
	// comment claimed it did ("it fails the moment such a method is added").
	// That was false: nothing below would fail if At were added, and Gno
	// offers no reflection over a method set to write the check with. The
	// claim is removed rather than reworded, because a test whose comment
	// promises a guard it does not have is worse than no test -- a reader
	// stops looking, which is the §7a/C11 failure in miniature.
	//
	// What it actually does: pin the two live-resolving doors that DO exist,
	// so a change to either breaks here. The deliberateness of At's absence
	// lives in prose (onyx/p/spendbook/MAINNET_ASSESSMENT.md) and nowhere
	// else; that is a documented gap, not an enforced one.
	b, id := openDefault(t, 0)
	mustSpend(t, b, id, 10, 30)

	// IsExpired resolves live. In v1 this comment read "IsExpired resolves
	// live, but expiry does not depend on the window, so it is not affected
	// by the hazard" -- and the second half was FALSE about the package it
	// was written in. Expiry DID depend on the window, because a pending
	// amendment can move ExpiresAt and v1's IsExpired read the stored field
	// rather than asking at(). That is Y2, stated in the affirmative, in a
	// test comment. It is corrected rather than deleted, because the
	// sentence is a record of how the defect stayed invisible: the claim
	// read like a reason not to look.
	//
	// This case is unaffected either way -- the allowance has no expiry and
	// no pending expiry -- which is exactly why it never caught anything.
	// The claim is enforced in the Y2 regression block at the bottom of
	// this file.
	if a, _ := b.Get(id); a.IsExpired(3150) {
		t.Errorf("an allowance with no expiry is never expired")
	}
	// Remaining resolves live and IS affected -- it is the whole remedy a
	// consumer has today.
	if got := b.Remaining(id, 3150); got != 50 {
		t.Errorf("Remaining across a boundary: got %d, want the refilled 50", got)
	}
	if a, _ := b.Get(id); a.Remaining(3150) != 50 {
		t.Errorf("Allowance.Remaining must agree with Book.Remaining")
	}
}

// --- Y2 regression: the expiry is resolved LIVE, in both directions -------
//
// EVERY case below carries its own "v1:" line saying whether it fails or passes
// against v1, and where it fails, v1's wrong answer is written out beside the
// assertion. The first draft of this header instead claimed "every case below
// FAILS against v1 unless it is marked otherwise" -- one blanket adjective over
// a whole subject set, which is the defect this repo keeps catching in its own
// prose. Measured, it was wrong about five of the fourteen: a preservation case
// (authorization unchanged, the zero value unchanged, the pre-anchor guard, the
// pending terms not promoted early) is SUPPOSED to pass against v1, and reading
// the header would have made a reader expect it to fail and distrust the suite.
//
// The split is not restated here; it is re-derivable, and the probe that
// derives it is the non-vacuity control for this whole block -- a regression
// test that passes against the source it was written to indict proves nothing:
//
//	mkdir /tmp/v1probe && cd /tmp/v1probe
//	cp <repo>/onyx/p/spendbook/spendbook.gno .          # the DEPLOYED bytes
//	cp <repo>/onyx/p/spendbook/v2/spendbook_test.gno .  # this file
//	cp <repo>/onyx/p/spendbook/v2/gnomod.toml .
//	gno test -v .      # expect exit 1; read WHICH names fail
//
// The block is organised by the two directions the stale read pointed:
//
//	UNDER-authorization  an extension or a removal of the expiry is accepted,
//	                     queued, comes into force at the boundary, and is then
//	                     ignored at the OLD expiry -- so the owner's own
//	                     amendment is discarded and a third party may Reap.
//	OVER-authorization   an amendment that RAISES PerPeriod and LOWERS
//	                     ExpiresAt queues as a whole, and past the boundary the
//	                     raised cap is honoured while the lowered expiry is
//	                     not -- a draw past an expiry the owner set.

// openExtendable opens the shape every extension case below needs: a window
// of 100 with a cap of 50, expiring at 300, so the next boundary (100) lands
// strictly before the expiry and a loosening is therefore queueable.
func openExtendable(t *testing.T) (*Book, uint64) {
	t.Helper()
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0,
		Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 3 * day})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return b, id
}

// queueExtension raises PerPeriod to 80 and pushes ExpiresAt out to 1000.
// Both moves are looser, so the whole amendment queues; raising PerPeriod
// alongside the expiry is what makes "the pending terms are not in force
// yet" observable before the boundary, where the expiry alone is not.
func queueExtension(t *testing.T, b *Book, id uint64, now int64) {
	t.Helper()
	applied, err := b.Amend(id, alice, now,
		Terms{PerPeriod: 80, PeriodLength: day, ExpiresAt: 10 * day})
	if err != nil {
		t.Fatalf("Amend(extend): %v", err)
	}
	if applied {
		t.Fatalf("an extension of the expiry applied immediately; it is " +
			"LOOSER and tighterOrEqualTo must queue it")
	}
}

func TestAnExtensionCanOnlyEverBeQueuedNotApplied(t *testing.T) {
	// The premise of the whole defect, asserted first because without it
	// there would be a workaround: there is NO way to extend an expiry
	// immediately. tighterOrEqualTo reads ExpiresAt 0 as unlimited, so a
	// later expiry is looser in that dimension and a later-or-removed expiry
	// is the only kind of expiry change that can be queued at all.
	//
	// v1: PASSES -- it is about tighterOrEqualTo, which the fix does not
	// touch. It is here so a reader cannot conclude the queueing path was
	// avoidable.
	live := Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 3 * day}
	for _, tc := range []struct {
		name string
		to   Terms
	}{
		{"pushed out", Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 4 * day}},
		{"removed", Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 0}},
	} {
		if tc.to.tighterOrEqualTo(live) {
			t.Errorf("%s: tighterOrEqualTo says an expiry %s is tighter; it is "+
				"looser, and treating it as tighter would let an owner undo an "+
				"expiry mid-window", tc.name, tc.name)
		}
	}
}

func TestTheOldExpiryIsNeverReachableWhileStillInForce(t *testing.T) {
	// A structural consequence of Amend's queueability guard, and the reason
	// the stale read had no legitimate window to be right in: a loosening is
	// only queued when the next boundary arrives STRICTLY before the current
	// expiry (nb >= ExpiresAt is refused). So by the time the clock reaches
	// the old expiry, the boundary has already passed and the pending terms
	// are already the terms in force. v1 consulted the old expiry at an
	// instant where it was, without exception, superseded.
	//
	// v1: PASSES -- it is Amend's guard, which the fix does not touch.
	b := MustNew(4)
	// Expiry at 50, inside window 0, so the next boundary (100) is past it.
	id, err := b.Open(alice, bob, 0,
		Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: day / 2})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := b.Amend(id, alice, 0,
		Terms{PerPeriod: 80, PeriodLength: day, ExpiresAt: 10 * day}); err != ErrNoBoundary {
		t.Fatalf("queueing against an expiry inside the current window: got %v, "+
			"want ErrNoBoundary", err)
	}
}

func TestPendingTermsAreNotInForceBeforeTheBoundary(t *testing.T) {
	// The other half of the fix's correctness: routing IsExpired through at()
	// must not promote a pending amendment EARLY. Window 0 still runs on the
	// old terms in every dimension.
	//
	// v1: PASSES -- and that is the point. This is a PRESERVATION case: it
	// pins the behaviour the fix must not disturb, so it is supposed to hold
	// on both sides. A reader who expects it to fail against v1 has misread
	// which half of the fix it covers.
	b, id := openExtendable(t)
	queueExtension(t, b, id, 10)

	if got := b.Remaining(id, 50); got != 50 {
		t.Errorf("Remaining inside window 0: got %d, want the OLD cap 50", got)
	}
	if got := b.Remaining(id, day-1); got != 50 {
		t.Errorf("Remaining at the last instant of window 0: got %d, want 50", got)
	}
	refuse(t, b, id, 50, 51, ErrPeriodExceeded)
	a, _ := b.Get(id)
	if a.Terms.ExpiresAt != 3*day {
		t.Errorf("the live expiry in window 0: got %d, want the OLD %d",
			a.Terms.ExpiresAt, 3*day)
	}
	if a.IsExpired(day - 1) {
		t.Error("not expired yet at the last instant of window 0")
	}
}

func TestPendingTermsTakeEffectExactlyAtTheBoundary(t *testing.T) {
	// Off by one here would either delay the extension by a whole window or
	// grant it a window early.
	//
	// v1: PASSES -- Remaining already resolved through at() in v1, so the
	// boundary arithmetic was never the broken part. IsExpired was.
	b, id := openExtendable(t)
	queueExtension(t, b, id, 10)

	if got := b.Remaining(id, day-1); got != 50 {
		t.Errorf("one instant before the boundary: got %d, want 50", got)
	}
	if got := b.Remaining(id, day); got != 80 {
		t.Errorf("AT the boundary: got %d, want the pending 80", got)
	}
}

func TestAQueuedExpiryExtensionSurvivesTheOldExpiry(t *testing.T) {
	// THE Y2 CASE. No write of any kind between queueing the amendment and
	// the old expiry -- that is the whole point, because any write promotes
	// the pending terms into the record and ends the hazard.
	//
	// v1: FAILS. At now=300: IsExpired reads the stored ExpiresAt of 300, reports
	// EXPIRED, Remaining answers 0 and Spend returns ErrExpired -- on an
	// allowance whose owner extended it to 1000 and was told "accepted".
	b, id := openExtendable(t)
	queueExtension(t, b, id, 10)

	const oldExpiry = 3 * day // 300
	const newExpiry = 10 * day

	a, _ := b.Get(id)
	if a.IsExpired(oldExpiry) {
		t.Fatalf("IsExpired(%d) is true: the extension to %d was accepted and "+
			"queued, took effect at the boundary, and has been discarded",
			oldExpiry, newExpiry)
	}
	if got := b.Remaining(id, oldExpiry); got != 80 {
		t.Errorf("Remaining(%d): got %d, want the extended terms' 80",
			oldExpiry, got)
	}
	// Enforcement must agree with the view, which is the half that moves value.
	if err := b.Spend(id, bob, oldExpiry, 80); err != nil {
		t.Fatalf("Spend at the old expiry was refused: %v", err)
	}
	// And the new expiry does bite, at exactly the right instant.
	if got := b.Remaining(id, newExpiry-1); got == 0 {
		t.Error("one instant before the new expiry the allowance must be alive")
	}
	if got := b.Remaining(id, newExpiry); got != 0 {
		t.Errorf("Remaining at the new expiry %d: got %d, want 0", newExpiry, got)
	}
	refuse(t, b, id, newExpiry, 1, ErrExpired)
}

func TestAThirdPartyCannotReapAnExtendedAllowance(t *testing.T) {
	// v1: FAILS.
	//
	// Reap is PERMISSIONLESS, which is sound only because an expired
	// allowance can authorize nothing. Under v1 the extended allowance read
	// as expired at 300, so the justification failed and any caller could
	// destroy a live grant -- the one place the defect let a third party act.
	b, id := openExtendable(t)
	queueExtension(t, b, id, 10)

	const oldExpiry = 3 * day
	if err := b.Reap(id, oldExpiry); err != ErrNotExpired {
		t.Fatalf("Reap at the old expiry: got %v, want ErrNotExpired -- a "+
			"third party just deleted a live allowance", err)
	}
	if b.Count() != 1 {
		t.Fatalf("live count after the refused Reap: got %d, want 1", b.Count())
	}
	// Once genuinely expired it is reapable, which is the behaviour Reap is
	// for and must not be lost by fixing the predicate.
	if err := b.Reap(id, 10*day); err != nil {
		t.Fatalf("Reap at the real expiry: %v", err)
	}
	if b.Count() != 0 {
		t.Errorf("live count after the Reap: got %d, want 0", b.Count())
	}
}

func TestExpiryRemovalSurvivesTheOldExpiryWithNoWrite(t *testing.T) {
	// ExpiresAt -> 0 is the same class as an extension by way of
	// tighterOrEqualTo's other arm: 0 means unlimited, so removing the expiry
	// is LOOSER and can only be queued.
	//
	// v1: FAILS. v1 covered this only on the WRITTEN path -- see
	// TestAmendExpiresAtZeroIsLooserNotTighter above, which spends at the
	// boundary and so promotes the pending terms before reading them. With no
	// write the removal was discarded at the old expiry exactly as an
	// extension was, and "no write" is the ordinary case for an allowance
	// nobody has drawn on yet.
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0,
		Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 3 * day})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	applied, err := b.Amend(id, alice, 10,
		Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 0})
	if err != nil {
		t.Fatalf("Amend(remove expiry): %v", err)
	}
	if applied {
		t.Fatal("removing the expiry applied immediately")
	}

	const oldExpiry = 3 * day
	a, _ := b.Get(id)
	if a.IsExpired(oldExpiry) {
		t.Fatalf("IsExpired(%d) is true after the expiry was REMOVED", oldExpiry)
	}
	if got := b.Remaining(id, oldExpiry); got != 50 {
		t.Errorf("Remaining(%d): got %d, want 50", oldExpiry, got)
	}
	if err := b.Reap(id, oldExpiry); err != ErrNotExpired {
		t.Errorf("Reap(%d): got %v, want ErrNotExpired", oldExpiry, err)
	}
	// "No expiry" means no expiry, at any instant, forever.
	if a.IsExpired(maxInt64) {
		t.Error("an allowance whose expiry was removed must never expire")
	}
	if err := b.Spend(id, bob, 1000*day, 50); err != nil {
		t.Fatalf("Spend long after the removed expiry: %v", err)
	}
	// The stored record is still stale -- the fix does not write, it stops
	// READING the stale field. Asserted so the mechanism is not mistaken for
	// a migration of stored state.
	a, _ = b.Get(id)
	if a.Terms.ExpiresAt != 0 {
		t.Errorf("after the spend promoted the terms, ExpiresAt: got %d, want 0",
			a.Terms.ExpiresAt)
	}
}

func TestAQueuedTighteningOfTheExpiryStopsAuthorizingDraws(t *testing.T) {
	// v1: FAILS -- THE MIRROR CASE, and the dangerous direction: v1
	// OVER-authorized here.
	//
	// tighterOrEqualTo is weakly-tighter in EVERY dimension, so an amendment
	// that raises PerPeriod and lowers ExpiresAt is looser as a whole and
	// queues as a whole. Past the boundary, v1's at() handed Spend the RAISED
	// cap while v1's IsExpired reported the allowance alive on the OLD, later
	// expiry -- so the spender could draw, at the new higher cap, past an
	// expiry the owner themselves had set. No bound in the package stopped
	// it: the bound had moved and the gate had not been told.
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0,
		Terms{PerPeriod: 100, PeriodLength: 1000, ExpiresAt: 5000})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	applied, err := b.Amend(id, alice, 0,
		Terms{PerPeriod: 200, PeriodLength: 1000, ExpiresAt: 3000})
	if err != nil {
		t.Fatalf("Amend(raise cap, pull expiry in): %v", err)
	}
	if applied {
		t.Fatal("a mixed-direction amendment applied immediately")
	}

	// Before the new expiry the owner's intent holds in full: raised cap.
	if got := b.Remaining(id, 1500); got != 200 {
		t.Errorf("Remaining(1500): got %d, want the raised 200", got)
	}

	// At and after the new expiry it is dead, even though the record still
	// says 5000.
	a, _ := b.Get(id)
	if a.Terms.ExpiresAt != 5000 {
		t.Fatalf("precondition: the stored expiry should still be the stale "+
			"5000, got %d", a.Terms.ExpiresAt)
	}
	for _, now := range []int64{3000, 3500, 4999} {
		if !a.IsExpired(now) {
			t.Errorf("IsExpired(%d) is false: the owner pulled the expiry in to "+
				"3000 and v1 would authorize a 200 draw here", now)
		}
		if got := b.Remaining(id, now); got != 0 {
			t.Errorf("Remaining(%d): got %d, want 0", now, got)
		}
	}
	refuse(t, b, id, 3500, 1, ErrExpired)
	refuse(t, b, id, 3500, 200, ErrExpired)

	// It is now genuinely dead, so Reap's permissionless justification holds
	// and the slot is reclaimable.
	if err := b.Reap(id, 3500); err != nil {
		t.Errorf("Reap on the correctly-expired allowance: %v", err)
	}
}

func TestRevokeStillWorksOnWhatTheFixDeclaresExpired(t *testing.T) {
	// The owner's fast remedy must not be taken away by making IsExpired
	// stricter. Revoke carries no IsExpired gate, deliberately, and the
	// mirror case is the first state in which the distinction is observable:
	// the allowance is expired on terms that are not in the record.
	//
	// v1: FAILS, on its SECOND half only. Revoke passes on both sides -- it has
	// no expiry gate to get wrong. The Amend assertion is what v1 misses: at
	// 3500 v1 reads the stored 5000, calls the allowance alive, and lets the
	// owner amend a grant that is dead on its own queued terms.
	b := MustNew(4)
	id, _ := b.Open(alice, bob, 0,
		Terms{PerPeriod: 100, PeriodLength: 1000, ExpiresAt: 5000})
	if _, err := b.Amend(id, alice, 0,
		Terms{PerPeriod: 200, PeriodLength: 1000, ExpiresAt: 3000}); err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if err := b.Revoke(id, alice); err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	if b.Count() != 0 {
		t.Errorf("live count after Revoke: got %d, want 0", b.Count())
	}
	// Amend, by contrast, IS gated on expiry and now correctly refuses --
	// the owner cannot amend a grant that is dead on its own queued terms.
	b2 := MustNew(4)
	id2, _ := b2.Open(alice, bob, 0,
		Terms{PerPeriod: 100, PeriodLength: 1000, ExpiresAt: 5000})
	if _, err := b2.Amend(id2, alice, 0,
		Terms{PerPeriod: 200, PeriodLength: 1000, ExpiresAt: 3000}); err != nil {
		t.Fatalf("Amend: %v", err)
	}
	if _, err := b2.Amend(id2, alice, 3500,
		Terms{PerPeriod: 10, PeriodLength: 1000, ExpiresAt: 3000}); err != ErrExpired {
		t.Errorf("Amend on a correctly-expired allowance: got %v, want ErrExpired",
			err)
	}
}

func TestTheFixGrantsNoAuthorityToAnyoneNew(t *testing.T) {
	// The extended window is a new state, so the authorization checks are
	// re-asserted inside it rather than assumed to carry.
	//
	// v1: PASSES -- a PRESERVATION case. The defect was never an authorization
	// defect for Spend, Amend or Revoke; it was a liveness defect that let a
	// permissionless Reap act (covered above) and let an authorized spender
	// draw past an expiry. Nobody new ever gained a right, on either side.
	b, id := openExtendable(t)
	queueExtension(t, b, id, 10)
	const oldExpiry = 3 * day

	if err := b.Spend(id, carol, oldExpiry, 1); err != ErrNotSpender {
		t.Errorf("Spend by a stranger: got %v, want ErrNotSpender", err)
	}
	if err := b.Spend(id, alice, oldExpiry, 1); err != ErrNotSpender {
		t.Errorf("Spend by the OWNER: got %v, want ErrNotSpender", err)
	}
	if _, err := b.Amend(id, carol, oldExpiry,
		Terms{PerPeriod: 999, PeriodLength: day}); err != ErrNotOwner {
		t.Errorf("Amend by a stranger: got %v, want ErrNotOwner", err)
	}
	if _, err := b.Amend(id, bob, oldExpiry,
		Terms{PerPeriod: 999, PeriodLength: day}); err != ErrNotOwner {
		t.Errorf("Amend by the SPENDER: got %v, want ErrNotOwner", err)
	}
	if err := b.Revoke(id, carol); err != ErrNotOwner {
		t.Errorf("Revoke by a stranger: got %v, want ErrNotOwner", err)
	}
	if err := b.Revoke(id, bob); err != ErrNotOwner {
		t.Errorf("Revoke by the SPENDER: got %v, want ErrNotOwner", err)
	}
	if b.Count() != 1 {
		t.Errorf("live count after six refused calls: got %d, want 1", b.Count())
	}
}

func TestAccountingIsUnchangedAcrossTheExtendedBoundary(t *testing.T) {
	// The fix must move the expiry gate and nothing else. The window reset,
	// the lifetime accumulator and the window index all behave exactly as the
	// package doc describes, measured across the boundary the extension made
	// reachable.
	//
	// v1: FAILS -- not on an accounting assertion, but on mustSpend at the old
	// expiry, which v1 refuses with ErrExpired. The accounting it was written
	// to pin is therefore UNREACHABLE on v1: there is no v1 state in which
	// these figures could be compared, which is itself the measurement.
	b := MustNew(4)
	id, err := b.Open(alice, bob, 0,
		Terms{PerPeriod: 50, PeriodLength: day, Total: 120, ExpiresAt: 3 * day})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	mustSpend(t, b, id, 10, 40) // window 0
	queueExtension(t, b, id, 20)

	// queueExtension keeps Total at 0 -- it names no Total, so the pending
	// terms REMOVE the lifetime cap. Assert that premise rather than relying
	// on it silently, since it is what makes the draw below permitted.
	a, _ := b.Get(id)
	if a.Pending.Total != 0 || a.Terms.Total != 120 {
		t.Fatalf("precondition: pending Total %d, live Total %d",
			a.Pending.Total, a.Terms.Total)
	}

	mustSpend(t, b, id, 3*day, 80) // past the old expiry, on the new terms

	a, _ = b.Get(id)
	if a.SpentTotal != 120 {
		t.Errorf("SpentTotal: got %d, want 40+80=120", a.SpentTotal)
	}
	if a.SpentWindow != 80 {
		t.Errorf("SpentWindow: got %d, want 80 (the window reset, it did not "+
			"carry the 40)", a.SpentWindow)
	}
	if a.WindowIndex != 3 {
		t.Errorf("WindowIndex: got %d, want 3", a.WindowIndex)
	}
	if a.HasPending {
		t.Error("HasPending must be cleared once the write promotes the terms")
	}
	if a.Terms.ExpiresAt != 10*day {
		t.Errorf("promoted ExpiresAt: got %d, want %d", a.Terms.ExpiresAt, 10*day)
	}
	// The window cap still bites at the new figure, not above it.
	refuse(t, b, id, 3*day, 1, ErrPeriodExceeded)
}

func TestRemainingAgreesWithSpendAcrossEveryQueuedExpiryChange(t *testing.T) {
	// The cross-check the package doc names as the reason everything routes
	// through at(): a view that disagrees with the enforcer is the defect,
	// whichever way it points. Each row gets a FRESH book, because Spend
	// writes and a write ends the hazard being measured.
	//
	// v1: FAILS. Note WHERE: v1 keeps Remaining and Spend in AGREEMENT on
	// every row -- both route through at() -- so the agreement invariant alone
	// would have passed against the defective package. What fails is the
	// `alive` column: v1 calls the three post-boundary live rows dead. Two
	// views agreeing is not the same as either being right, which is why the
	// expected liveness is spelled out per row instead of only cross-checked.
	for _, tc := range []struct {
		name  string
		now   int64
		alive bool
	}{
		{"extension: inside the original window", 50, true},
		{"extension: at the boundary", day, true},
		{"extension: at the old expiry", 3 * day, true},
		{"extension: one before the new expiry", 10*day - 1, true},
		{"extension: at the new expiry", 10 * day, false},
		{"extension: long after the new expiry", 100 * day, false},
	} {
		b, id := openExtendable(t)
		queueExtension(t, b, id, 10)

		remaining := b.Remaining(id, tc.now)
		err := b.Spend(id, bob, tc.now, 1)

		if tc.alive {
			if remaining <= 0 {
				t.Errorf("%s: Remaining=%d, want > 0", tc.name, remaining)
			}
			if err != nil {
				t.Errorf("%s: Spend=%v, want nil", tc.name, err)
			}
		} else {
			if remaining != 0 {
				t.Errorf("%s: Remaining=%d, want 0", tc.name, remaining)
			}
			if err != ErrExpired {
				t.Errorf("%s: Spend=%v, want ErrExpired", tc.name, err)
			}
		}
		if (remaining > 0) != (err == nil) {
			t.Errorf("%s: the view and the enforcer disagree (Remaining=%d, "+
				"Spend=%v)", tc.name, remaining, err)
		}
	}
}

func TestIsExpiredToleratesAPreAnchorNow(t *testing.T) {
	// IsExpired is EXPORTED and now routes through at(), so it is the one
	// place a caller-supplied now can reach windowIndex without an upstream
	// ErrNotStarted. Reap is the in-package caller with no anchor check of
	// its own.
	//
	// v1: PASSES -- and the agreement is the claim. v1 could not reach
	// windowIndex from IsExpired at all, so this case exists to prove the new
	// path did not introduce a divergence where v1 had no exposure. A FAIL
	// here would mean the fix had moved behaviour it was supposed to leave
	// alone, so "passes on both sides" is the only acceptable outcome.
	//
	// First, the hazard the guard exists for, measured rather than asserted:
	// a negative numerator folds roughly two windows into one, because Go
	// truncates toward zero.
	a := Allowance{Anchor: 500, Terms: Terms{PerPeriod: 1, PeriodLength: day}}
	if a.windowIndex(401) != a.windowIndex(599) {
		t.Fatalf("precondition: windowIndex(401)=%d windowIndex(599)=%d -- the "+
			"fold this guard avoids is not present, so the guard's stated "+
			"reason is wrong", a.windowIndex(401), a.windowIndex(599))
	}

	// Then the guard: every pre-anchor now answers false, which is also what
	// v1 answered for any allowance valid() would accept, since valid()
	// requires ExpiresAt > Anchor.
	e := Allowance{
		Anchor: 500,
		Terms:  Terms{PerPeriod: 1, PeriodLength: day, ExpiresAt: 1000},
	}
	for _, now := range []int64{-1, 0, 401, 499} {
		if e.IsExpired(now) {
			t.Errorf("IsExpired(%d) with Anchor 500: got true, want false", now)
		}
	}
	// Reach it through Reap, the caller that has no anchor check.
	b := MustNew(4)
	id, err := b.Open(alice, bob, 500,
		Terms{PerPeriod: 50, PeriodLength: day, ExpiresAt: 1000})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := b.Reap(id, 100); err != ErrNotExpired {
		t.Errorf("Reap before the anchor: got %v, want ErrNotExpired", err)
	}
	if err := b.Reap(id, -1); err != ErrInvalidNow {
		t.Errorf("Reap with a negative now: got %v, want ErrInvalidNow", err)
	}
	if err := b.Reap(id, 1000); err != nil {
		t.Errorf("Reap at the expiry: %v", err)
	}
}

func TestThePreAnchorGuardIsLoadBearingOnACallerBuiltAllowance(t *testing.T) {
	// The companion to the test above, and it exists because the sabotage
	// harness found the gap: deleting the `now < a.Anchor` guard outright was
	// UNCAUGHT by the whole suite. TestIsExpiredToleratesAPreAnchorNow could
	// not catch it, and that is a property of the DOMAIN rather than a
	// weakness in the test -- over allowances valid() accepts the guard is
	// genuinely inert, which is also what README.md claims, in a sentence
	// carefully scoped to "every allowance it would accept".
	//
	// Measured rather than reasoned: a sweep of 4,176 valid()-accepted
	// (anchor, PeriodLength, ExpiresAt, pending, now) combinations found ZERO
	// inputs distinguishing the guarded body from the unguarded one, counting
	// a panic as a difference. Widening past validity found 3,570.
	//
	// So the observable domain is exactly `0 != ExpiresAt <= now < Anchor`,
	// and valid() rejects every member of it (`ExpiresAt <= anchor` is one of
	// its refusals). It is reachable anyway, which is the whole reason this
	// test is here rather than a comment saying the term cannot be sabotaged:
	// Get returns an Allowance BY VALUE and Iterate passes one, IsExpired is
	// exported with a value receiver, so a consumer can hold a copy, mutate
	// its Terms, and call IsExpired on a shape the Book would never store.
	//
	// v1: PASSES. v1 read a.Terms.ExpiresAt directly and never reached
	// windowIndex from here, so it answered false too -- another PRESERVATION
	// case. The guard is what keeps v2 agreeing with it.
	//
	// What is NOT claimed: no authorization consequence. Reap resolves the
	// STORED allowance, which is always valid()-accepted, so a caller's
	// mutated copy cannot make Reap delete anything. This pins consistency of
	// an exported method, not a permission.
	a := Allowance{
		Owner: alice, Spender: bob, Anchor: 1000,
		Terms: Terms{PerPeriod: 10, PeriodLength: day, ExpiresAt: 5},
	}
	if a.Terms.valid(a.Anchor) {
		t.Fatalf("precondition: valid(1000) accepted ExpiresAt 5, so this case " +
			"is no longer about a shape the Book refuses to store")
	}
	// now sits at or after the expiry and strictly before the anchor: the
	// guard answers false, the unguarded body would answer true.
	for _, now := range []int64{5, 6, 100, 999} {
		if a.IsExpired(now) {
			t.Errorf("IsExpired(%d) with Anchor 1000 / ExpiresAt 5: got true, "+
				"want false -- the pre-anchor guard is not in force, so an "+
				"exported method disagrees with v1 on a caller-built shape", now)
		}
	}
	// The same with no window at all, so both of windowIndex's arms are
	// covered on this path and not just the folding one.
	lifetime := a
	lifetime.Terms.PeriodLength = 0
	if lifetime.IsExpired(100) {
		t.Errorf("IsExpired(100) on a lifetime allowance with Anchor 1000 / " +
			"ExpiresAt 5: got true, want false")
	}
	// The control: past the anchor the expiry IS honoured, so the guard is
	// proven to be a pre-anchor shortcut and not a blanket `return false`.
	// Without this, deleting the guard's condition and keeping `return false`
	// would pass everything above.
	if !a.IsExpired(1000) {
		t.Errorf("IsExpired(1000) at the anchor with ExpiresAt 5: got false, " +
			"want true -- the guard has become an unconditional false and " +
			"IsExpired no longer reports expiry at all")
	}
}

func TestTheZeroAllowanceIsUnchangedByTheFix(t *testing.T) {
	// A hand-built Allowance is reachable: Get returns one by value and
	// Iterate passes one. The zero value must answer exactly as it did in
	// v1, or the fix has changed a shape no consumer declared.
	//
	// v1: PASSES -- a PRESERVATION case, and the one with the least margin:
	// the zero value has Anchor 0 and PeriodLength 0, so it takes the guard's
	// false branch on now < 0 and windowIndex's PeriodLength == 0 branch
	// otherwise. Both arms are exercised below.
	var z Allowance
	for _, now := range []int64{-1, 0, 1, maxInt64} {
		if z.IsExpired(now) {
			t.Errorf("the zero Allowance has ExpiresAt 0 and must never expire; "+
				"IsExpired(%d) said true", now)
		}
	}
}
