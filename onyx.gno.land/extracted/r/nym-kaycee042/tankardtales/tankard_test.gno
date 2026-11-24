package tankardtales

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
	dave  = testutils.TestAddress("dave")
)

// expectPanic fails the test unless fn aborts with a message containing
// substr. The realm's public functions are entered via cross(cur), so
// their panics cross a realm boundary and surface as aborts — a plain
// recover() cannot catch them; uassert.AbortsContains wraps the VM's
// revive mechanism, which can.
func expectPanic(t *testing.T, rlm realm, substr string, fn func()) {
	t.Helper()
	uassert.AbortsContains(t, rlm, substr, fn)
}

func TestSignGuestbook(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))

	// Delta-based assertions: realm state may be shared across the
	// package's tests in one run, so never assume a blank tavern.
	_, _, signs0, _ := GetGuest(alice)
	_, _, _, guestSigns0, _ := GetRegular(alice)
	before := GuestCount()
	_, _, _, hadEntry := GetGuest(alice)

	SignGuestbook(cross(cur), "Alice", "First round is on me.")
	name, message, signs, ok := GetGuest(alice)
	uassert.Equal(t, ok, true)
	uassert.Equal(t, name, "Alice")
	uassert.Equal(t, message, "First round is on me.")
	uassert.Equal(t, signs, signs0+1)
	if !hadEntry {
		uassert.Equal(t, GuestCount(), before+1)
	}
	countAfterFirst := GuestCount()

	// Signing again updates the entry and counts a return visit,
	// but does not create a second guest.
	SignGuestbook(cross(cur), "Alice A.", "Back again!")
	name, message, signs, _ = GetGuest(alice)
	uassert.Equal(t, name, "Alice A.")
	uassert.Equal(t, message, "Back again!")
	uassert.Equal(t, signs, signs0+2)
	uassert.Equal(t, GuestCount(), countAfterFirst)

	// The regulars tally noticed both visits.
	_, _, _, guestSigns, ok := GetRegular(alice)
	uassert.Equal(t, ok, true)
	uassert.Equal(t, guestSigns, guestSigns0+2)
}

func TestGuestbookMultipleGuests(cur realm, t *testing.T) {
	before := GuestCount()

	testing.SetRealm(testing.NewUserRealm(bob))
	SignGuestbook(cross(cur), "Bob", "Questing for hire.")
	testing.SetRealm(testing.NewUserRealm(carol))
	SignGuestbook(cross(cur), "Carol", "Just here for the songs.")

	uassert.Equal(t, GuestCount(), before+2)

	_, msg, _, _ := GetGuest(bob)
	uassert.Equal(t, msg, "Questing for hire.")
	_, msg, _, _ = GetGuest(carol)
	uassert.Equal(t, msg, "Just here for the songs.")
}

func TestGuestbookRejectsBadInput(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(dave))

	expectPanic(t, cur, "display name must be 1-32 characters", func() {
		SignGuestbook(cross(cur), "  ", "hello")
	})
	expectPanic(t, cur, "display name must be 1-32 characters", func() {
		SignGuestbook(cross(cur), strings.Repeat("x", MaxNameLen+1), "hello")
	})
	expectPanic(t, cur, "message must be 1-280 characters", func() {
		SignGuestbook(cross(cur), "Dave", " ")
	})
	expectPanic(t, cur, "message must be 1-280 characters", func() {
		SignGuestbook(cross(cur), "Dave", strings.Repeat("x", MaxMessageLen+1))
	})

	// None of the failed attempts left a signature behind.
	_, _, _, ok := GetGuest(dave)
	uassert.Equal(t, ok, false)
}
