package duebook

import "testing"

const (
	alice = "g1alice"
	bob   = "g1bob"
)

// newBook is the default fixture: delay in [10, 1000], 8 open slots.
func newBook(t *testing.T) *Book {
	t.Helper()
	b, err := New(10, 1000, 8)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return b
}

// --- construction ---------------------------------------------------------

func TestNewRejectsBadConfig(t *testing.T) {
	cases := []struct {
		name                string
		min, max            int64
		maxOpen             int
	}{
		{"negative min", -1, 100, 4},
		{"max below min", 100, 99, 4},
		{"zero maxOpen", 0, 100, 0},
		{"negative maxOpen", 0, 100, -1},
		{"maxOpen over limit", 0, 100, MaxOpenLimit + 1},
	}
	for _, c := range cases {
		if _, err := New(c.min, c.max, c.maxOpen); err != ErrInvalidConfig {
			t.Errorf("%s: got %v, want ErrInvalidConfig", c.name, err)
		}
	}
}

func TestNewAcceptsZeroMinDelay(t *testing.T) {
	b, err := New(0, 0, 1)
	if err != nil {
		t.Fatalf("New(0,0,1): %v", err)
	}
	id, err := b.Schedule(alice, "", 100, 0, 0)
	if err != nil {
		t.Fatalf("Schedule: %v", err)
	}
	// min == max == 0 means due immediately.
	if _, err := b.Claim(id, 100); err != nil {
		t.Fatalf("Claim at due instant: %v", err)
	}
}

// --- scheduling -----------------------------------------------------------

func TestScheduleComputesWindow(t *testing.T) {
	b := newBook(t)
	id, err := b.Schedule(alice, "payload", 1000, 50, 200)
	if err != nil {
		t.Fatalf("Schedule: %v", err)
	}
	d, ok := b.Get(id)
	if !ok {
		t.Fatal("Get: not found")
	}
	if d.CreatedAt != 1000 || d.DueAt != 1050 || d.ExpiresAt != 1250 {
		t.Errorf("window = (%d,%d,%d), want (1000,1050,1250)", d.CreatedAt, d.DueAt, d.ExpiresAt)
	}
	if d.Owner != alice || d.Payload != "payload" {
		t.Errorf("owner/payload = %q/%q", d.Owner, d.Payload)
	}
}

func TestScheduleZeroTTLNeverExpires(t *testing.T) {
	b := newBook(t)
	id := b.MustSchedule(alice, "", 0, 10, 0)
	d, _ := b.Get(id)
	if d.ExpiresAt != 0 {
		t.Fatalf("ExpiresAt = %d, want 0", d.ExpiresAt)
	}
	if d.IsExpired(1 << 62) {
		t.Error("ttl==0 deferral reported expired")
	}
	// Still claimable in the far future.
	if _, err := b.Claim(id, 1<<62); err != nil {
		t.Fatalf("Claim far future: %v", err)
	}
}

func TestScheduleValidation(t *testing.T) {
	b := newBook(t)
	big := make([]byte, MaxPayloadLen+1)
	cases := []struct {
		name    string
		owner   string
		payload string
		now     int64
		delay   int64
		ttl     int64
		want    error
	}{
		{"empty owner", "", "", 0, 10, 0, ErrEmptyOwner},
		{"payload too big", alice, string(big), 0, 10, 0, ErrPayloadTooBig},
		{"negative now", alice, "", -1, 10, 0, ErrInvalidNow},
		{"delay below min", alice, "", 0, 9, 0, ErrInvalidDelay},
		{"delay above max", alice, "", 0, 1001, 0, ErrInvalidDelay},
		{"negative delay", alice, "", 0, -5, 0, ErrInvalidDelay},
		{"negative ttl", alice, "", 0, 10, -1, ErrInvalidTTL},
	}
	for _, c := range cases {
		if _, err := b.Schedule(c.owner, c.payload, c.now, c.delay, c.ttl); err != c.want {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
	if b.OpenCount() != 0 {
		t.Errorf("failed Schedules mutated the book: OpenCount = %d", b.OpenCount())
	}
	if b.NextID() != 1 {
		t.Errorf("failed Schedules consumed IDs: NextID = %d", b.NextID())
	}
}

func TestScheduleOverflowGuard(t *testing.T) {
	b, err := New(0, 1<<62, 4)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	const huge = int64(1<<63 - 1)
	// now + delay overflows.
	if _, err := b.Schedule(alice, "", huge-10, 1<<62, 0); err != ErrOverflow {
		t.Errorf("dueAt overflow: got %v, want ErrOverflow", err)
	}
	// dueAt + ttl overflows.
	if _, err := b.Schedule(alice, "", huge-1<<62, 1<<62, huge); err != ErrOverflow {
		t.Errorf("expiresAt overflow: got %v, want ErrOverflow", err)
	}
	if b.OpenCount() != 0 {
		t.Errorf("overflow left state behind: OpenCount = %d", b.OpenCount())
	}
}

func TestScheduleRespectsCap(t *testing.T) {
	b, _ := New(0, 100, 2)
	b.MustSchedule(alice, "", 0, 10, 0)
	b.MustSchedule(alice, "", 0, 10, 0)
	if _, err := b.Schedule(alice, "", 0, 10, 0); err != ErrBookFull {
		t.Fatalf("third Schedule: got %v, want ErrBookFull", err)
	}
	// Consuming one frees exactly one slot.
	b.MustClaim(1, 10)
	if _, err := b.Schedule(alice, "", 0, 10, 0); err != nil {
		t.Fatalf("Schedule after Claim: %v", err)
	}
	if _, err := b.Schedule(alice, "", 0, 10, 0); err != ErrBookFull {
		t.Fatalf("cap not re-applied: got %v, want ErrBookFull", err)
	}
}

// --- the central claim: exactly-once ---------------------------------------

func TestClaimSucceedsExactlyOnce(t *testing.T) {
	b := newBook(t)
	id := b.MustSchedule(alice, "do-the-thing", 0, 10, 0)

	d, err := b.Claim(id, 10)
	if err != nil {
		t.Fatalf("first Claim: %v", err)
	}
	if d.Payload != "do-the-thing" {
		t.Errorf("payload = %q", d.Payload)
	}
	for i := 0; i < 5; i++ {
		if _, err := b.Claim(id, 10); err != ErrNotFound {
			t.Fatalf("replay %d: got %v, want ErrNotFound", i, err)
		}
	}
}

func TestIDsAreNeverReused(t *testing.T) {
	b := newBook(t)
	id1 := b.MustSchedule(alice, "", 0, 10, 0)
	b.MustClaim(id1, 10)
	if b.OpenCount() != 0 {
		t.Fatalf("OpenCount = %d after claim", b.OpenCount())
	}
	// The book is empty again, but the next ID must still move forward.
	id2 := b.MustSchedule(alice, "", 0, 10, 0)
	if id2 == id1 {
		t.Fatalf("ID %d reused after the book emptied", id2)
	}
	// So the old ID stays permanently unclaimable.
	if _, err := b.Claim(id1, 10); err != ErrNotFound {
		t.Errorf("old ID claimable again: %v", err)
	}
}

func TestConsumedByAnyPathStaysConsumed(t *testing.T) {
	// Every terminal path must close the ID to all three transitions.
	paths := []struct {
		name    string
		consume func(b *Book, id uint64)
	}{
		{"claim", func(b *Book, id uint64) { b.MustClaim(id, 10) }},
		{"cancel", func(b *Book, id uint64) { b.MustCancel(id, alice) }},
		{"expire", func(b *Book, id uint64) { b.MustExpire(id, 100) }},
	}
	for _, p := range paths {
		b := newBook(t)
		id := b.MustSchedule(alice, "", 0, 10, 50) // due 10, expires 60
		p.consume(b, id)

		if _, err := b.Claim(id, 10); err != ErrNotFound {
			t.Errorf("%s then Claim: got %v, want ErrNotFound", p.name, err)
		}
		if _, err := b.Cancel(id, alice); err != ErrNotFound {
			t.Errorf("%s then Cancel: got %v, want ErrNotFound", p.name, err)
		}
		if _, err := b.Expire(id, 100); err != ErrNotFound {
			t.Errorf("%s then Expire: got %v, want ErrNotFound", p.name, err)
		}
		if _, ok := b.Get(id); ok {
			t.Errorf("%s: deferral still visible", p.name)
		}
	}
}

// --- the claim window -----------------------------------------------------

func TestClaimWindowIsHalfOpen(t *testing.T) {
	// Schedule at 0, delay 10, ttl 5 => claimable on [10, 15).
	cases := []struct {
		now  int64
		want error
	}{
		{0, ErrNotDue},
		{9, ErrNotDue},
		{10, nil}, // due instant is claimable
		{14, nil},
		{15, ErrExpired}, // expiry instant is NOT claimable
		{16, ErrExpired},
	}
	for _, c := range cases {
		b := newBook(t)
		id := b.MustSchedule(alice, "", 0, 10, 5)
		_, err := b.Claim(id, c.now)
		if err != c.want {
			t.Errorf("Claim at now=%d: got %v, want %v", c.now, err, c.want)
		}
		// A refused Claim must not consume the deferral.
		if c.want != nil {
			if _, ok := b.Get(id); !ok {
				t.Errorf("refused Claim at now=%d consumed the deferral", c.now)
			}
		}
	}
}

func TestClaimRejectsNegativeNow(t *testing.T) {
	b := newBook(t)
	id := b.MustSchedule(alice, "", 0, 10, 0)
	if _, err := b.Claim(id, -1); err != ErrInvalidNow {
		t.Fatalf("got %v, want ErrInvalidNow", err)
	}
	if _, ok := b.Get(id); !ok {
		t.Error("negative now consumed the deferral")
	}
}

func TestClaimUnknownID(t *testing.T) {
	b := newBook(t)
	if _, err := b.Claim(999, 10); err != ErrNotFound {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

// --- cancellation ---------------------------------------------------------

func TestCancelOwnerOnly(t *testing.T) {
	b := newBook(t)
	id := b.MustSchedule(alice, "", 0, 10, 0)

	if _, err := b.Cancel(id, bob); err != ErrNotOwner {
		t.Fatalf("bob cancelling alice's deferral: got %v, want ErrNotOwner", err)
	}
	if _, ok := b.Get(id); !ok {
		t.Fatal("refused Cancel consumed the deferral")
	}
	if _, err := b.Cancel(id, ""); err != ErrEmptyOwner {
		t.Errorf("empty owner: got %v, want ErrEmptyOwner", err)
	}
	if _, err := b.Cancel(id, alice); err != nil {
		t.Fatalf("owner cancel: %v", err)
	}
}

func TestCancelWorksAfterDue(t *testing.T) {
	// Cancellation is allowed while OPEN, not only while pending — an owner
	// can still pull a deferral back after it became claimable, as long as
	// nobody claimed it first.
	b := newBook(t)
	id := b.MustSchedule(alice, "", 0, 10, 0)
	if _, err := b.Cancel(id, alice); err != nil {
		t.Fatalf("cancel after due: %v", err)
	}
}

func TestCancelLosesRaceToClaim(t *testing.T) {
	b := newBook(t)
	id := b.MustSchedule(alice, "", 0, 10, 0)
	b.MustClaim(id, 10)
	if _, err := b.Cancel(id, alice); err != ErrNotFound {
		t.Fatalf("cancel after claim: got %v, want ErrNotFound", err)
	}
}

// --- expiry ---------------------------------------------------------------

func TestExpireRequiresExpiry(t *testing.T) {
	b := newBook(t)
	// Not yet expired.
	id := b.MustSchedule(alice, "", 0, 10, 5) // expires 15
	if _, err := b.Expire(id, 14); err != ErrNotExpired {
		t.Errorf("at 14: got %v, want ErrNotExpired", err)
	}
	if _, err := b.Expire(id, 15); err != nil {
		t.Errorf("at 15: %v", err)
	}

	// ttl == 0 can never be expired away.
	never := b.MustSchedule(alice, "", 0, 10, 0)
	if _, err := b.Expire(never, 1<<62); err != ErrNotExpired {
		t.Errorf("no-expiry deferral: got %v, want ErrNotExpired", err)
	}
}

func TestExpireIsPermissionless(t *testing.T) {
	b := newBook(t)
	id := b.MustSchedule(alice, "", 0, 10, 5)
	// No owner argument at all — anyone may clear a dead entry.
	if _, err := b.Expire(id, 20); err != nil {
		t.Fatalf("Expire: %v", err)
	}
}

func TestExpiredDeferralCannotBeClaimedOrGriefTheCap(t *testing.T) {
	b, _ := New(0, 100, 1)
	id := b.MustSchedule(alice, "", 0, 10, 5) // expires 15
	// Cap is full and the entry is dead.
	if _, err := b.Schedule(bob, "", 20, 10, 0); err != ErrBookFull {
		t.Fatalf("got %v, want ErrBookFull", err)
	}
	if _, err := b.Claim(id, 20); err != ErrExpired {
		t.Fatalf("got %v, want ErrExpired", err)
	}
	// Anyone can unstick it.
	b.MustExpire(id, 20)
	if _, err := b.Schedule(bob, "", 20, 10, 0); err != nil {
		t.Fatalf("Schedule after Expire: %v", err)
	}
}

// --- queries --------------------------------------------------------------

func TestDueReturnsOnlyClaimableInIDOrder(t *testing.T) {
	b := newBook(t)
	b.MustSchedule(alice, "a", 0, 10, 0)  // 1: due 10
	b.MustSchedule(alice, "b", 0, 500, 0) // 2: due 500, not yet
	b.MustSchedule(alice, "c", 0, 10, 5)  // 3: due 10, expired at 15
	b.MustSchedule(alice, "d", 0, 20, 0)  // 4: due 20

	got := b.Due(20, 10)
	if len(got) != 2 {
		t.Fatalf("Due returned %d entries, want 2", len(got))
	}
	if got[0].ID != 1 || got[1].ID != 4 {
		t.Errorf("IDs = %d,%d; want 1,4", got[0].ID, got[1].ID)
	}
}

func TestDueRespectsLimit(t *testing.T) {
	b := newBook(t)
	for i := 0; i < 5; i++ {
		b.MustSchedule(alice, "", 0, 10, 0)
	}
	if got := b.Due(10, 2); len(got) != 2 {
		t.Errorf("limit 2 returned %d", len(got))
	}
	if got := b.Due(10, 0); len(got) != 0 {
		t.Errorf("limit 0 returned %d", len(got))
	}
	if got := b.Due(10, -1); len(got) != 0 {
		t.Errorf("limit -1 returned %d", len(got))
	}
}

func TestExpirable(t *testing.T) {
	b := newBook(t)
	b.MustSchedule(alice, "", 0, 10, 5) // 1: expires 15
	b.MustSchedule(alice, "", 0, 10, 0) // 2: never expires
	b.MustSchedule(alice, "", 0, 10, 5) // 3: expires 15

	got := b.Expirable(15, 10)
	if len(got) != 2 || got[0].ID != 1 || got[1].ID != 3 {
		t.Fatalf("Expirable = %v", got)
	}
	if len(b.Expirable(14, 10)) != 0 {
		t.Error("Expirable before expiry returned entries")
	}
}

func TestIterateOpenIsIDOrdered(t *testing.T) {
	b, _ := New(0, 100, 32)
	// Schedule enough to cross the 1->2 digit boundary, where naive string
	// keys would order "10" before "9".
	for i := 0; i < 12; i++ {
		b.MustSchedule(alice, "", 0, 1, 0)
	}
	prev := uint64(0)
	n := 0
	b.IterateOpen(func(d Deferral) bool {
		if d.ID <= prev {
			t.Fatalf("out of order: %d after %d", d.ID, prev)
		}
		prev = d.ID
		n++
		return false
	})
	if n != 12 {
		t.Errorf("iterated %d, want 12", n)
	}
}

func TestGetReturnsACopy(t *testing.T) {
	b := newBook(t)
	id := b.MustSchedule(alice, "original", 0, 10, 0)
	d, _ := b.Get(id)
	d.Payload = "tampered"
	d.Owner = bob

	again, _ := b.Get(id)
	if again.Payload != "original" || again.Owner != alice {
		t.Fatalf("mutating a returned Deferral changed the book: %+v", again)
	}
}

// --- helpers --------------------------------------------------------------

func TestIDKeyOrdering(t *testing.T) {
	if idKey(9) >= idKey(10) {
		t.Errorf("idKey(9)=%q not < idKey(10)=%q", idKey(9), idKey(10))
	}
	if len(idKey(1)) != 20 {
		t.Errorf("idKey(1) width = %d, want 20", len(idKey(1)))
	}
	// Largest uint64 is exactly 20 digits and must not be truncated.
	const maxU64 = ^uint64(0)
	if got := idKey(maxU64); got != "18446744073709551615" {
		t.Errorf("idKey(max) = %q", got)
	}
	if idKey(maxU64-1) >= idKey(maxU64) {
		t.Error("ordering breaks at the top of the range")
	}
}

func TestCheckedAdd(t *testing.T) {
	const max = int64(1<<63 - 1)
	const min = int64(-1 << 63)
	if _, ok := checkedAdd(max, 1); ok {
		t.Error("max+1 reported ok")
	}
	if _, ok := checkedAdd(min, -1); ok {
		t.Error("min-1 reported ok")
	}
	if v, ok := checkedAdd(5, 7); !ok || v != 12 {
		t.Errorf("5+7 = %d,%v", v, ok)
	}
}

func TestDeferralPredicates(t *testing.T) {
	d := Deferral{DueAt: 10, ExpiresAt: 20}
	if d.IsDue(9) || !d.IsDue(10) {
		t.Error("IsDue boundary")
	}
	if d.IsExpired(19) || !d.IsExpired(20) {
		t.Error("IsExpired boundary")
	}
	if d.IsClaimable(9) || !d.IsClaimable(10) || !d.IsClaimable(19) || d.IsClaimable(20) {
		t.Error("IsClaimable window")
	}
}
