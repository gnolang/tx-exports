package receipts

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
)

const (
	call1 = "GNOT trades above $1 before June 1, 2027"
	salt1 = "q7Zp-4tLx9"
)

func TestCommitKnownVector(t *testing.T) {
	// printf '%s|%s' 'saltsalt' 'hello' | sha256sum
	got := Commit("hello", "saltsalt")
	uassert.Equal(t, "ae4bd9fb4bcccb6edaed2ac2f1bdbd189efef96f98aa12ca78f4ae44a6fbd832", got)
	uassert.Equal(t, 64, len(got))
	uassert.Equal(t, got, Commit("hello", "saltsalt"))
	uassert.NotEqual(t, got, Commit("hello ", "saltsalt"))
}

func TestFullLifecycle(cur realm, t *testing.T) {
	commitment := Commit(call1, salt1)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := Seal(cross(cur), "GNOT price by mid 2027", commitment, 30)
	uassert.Equal(t, 1, id)
	uassert.Equal(t, StatusSealed, StatusOf(id))

	// The prediction is not on-chain yet.
	page := Render("call/1")
	uassert.False(t, strings.Contains(page, "GNOT trades above"))
	uassert.True(t, strings.Contains(page, commitment))

	// Bob cannot reveal Alice's call.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "only the author can reveal this call", func() {
		Reveal(cross(cur), id, call1, salt1)
	})

	// Wrong text is refused.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "prediction and salt do not match the sealed commitment", func() {
		Reveal(cross(cur), id, "GNOT trades above $2 before June 1, 2027", salt1)
	})

	// Verdicts are refused while sealed.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "call is still sealed", func() {
		Verdict(cross(cur), id, "held")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, call1, salt1)
	uassert.Equal(t, StatusRevealed, StatusOf(id))

	// Author cannot judge own call.
	uassert.AbortsWithMessage(t, cur, "authors cannot judge their own call", func() {
		Verdict(cross(cur), id, "held")
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	Verdict(cross(cur), id, "held")
	testing.SetRealm(testing.NewUserRealm(carol))
	Verdict(cross(cur), id, "missed")
	// Carol changes her mind; counts move, no double vote.
	testing.SetRealm(testing.NewUserRealm(carol))
	Verdict(cross(cur), id, "held")

	_, _, _, status, prediction, _, _, held, missed := GetCall(id)
	uassert.Equal(t, StatusRevealed, status)
	uassert.Equal(t, call1, prediction)
	uassert.Equal(t, 2, held)
	uassert.Equal(t, 0, missed)

	r := TrackRecord(alice)
	uassert.Equal(t, 1, r.Sealed)
	uassert.Equal(t, 1, r.OnTime)
	uassert.Equal(t, 1, r.Held)
	uassert.Equal(t, 100, r.KeptWord())

	page = Render("call/1")
	uassert.True(t, strings.Contains(page, "Verified on-chain"))
	// "$" from user text is escaped so gnoweb does not render math.
	uassert.True(t, strings.Contains(page, "\\$1"))
}

func TestValidation(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "commitment must be 64 hex characters (sha256)", func() {
		Seal(cross(cur), "topic", "abc", 3)
	})
	uassert.AbortsWithMessage(t, cur, "topic is required", func() {
		Seal(cross(cur), "   ", Commit("x", "12345678"), 3)
	})
	uassert.AbortsWithMessage(t, cur, "revealByDays must be between 1 and 3650", func() {
		Seal(cross(cur), "topic", Commit("x", "12345678"), 0)
	})
	id := Seal(cross(cur), "short salt", Commit("yes", "abc"), 3)
	uassert.AbortsWithMessage(t, cur, "salt must be 8 to 64 bytes", func() {
		Reveal(cross(cur), id, "yes", "abc")
	})
	uassert.AbortsWithMessage(t, cur, `verdict must be "held" or "missed"`, func() {
		testing.SetRealm(testing.NewUserRealm(carol))
		Verdict(cross(cur), 1, "maybe")
	})
}

func TestDuckedAfterDeadline(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(carol))
	id := Seal(cross(cur), "will be ducked", Commit("rain tomorrow", "saltysalt"), 1)
	uassert.Equal(t, StatusSealed, StatusOf(id))
	// ~5s blocks: skip well past one day.
	testing.SkipHeights(30000)
	uassert.Equal(t, StatusDucked, StatusOf(id))
	r := TrackRecord(carol)
	uassert.Equal(t, 1, r.Ducked)
	uassert.Equal(t, 0, r.KeptWord())

	// A late reveal is accepted but stays marked late.
	testing.SetRealm(testing.NewUserRealm(carol))
	Reveal(cross(cur), id, "rain tomorrow", "saltysalt")
	uassert.Equal(t, StatusLate, StatusOf(id))
	uassert.True(t, strings.Contains(Render("board"), "Track records"))
	uassert.True(t, strings.Contains(Render(""), "will be ducked"))
	uassert.True(t, strings.Contains(Render("u/"+carol.String()), "revealed late"))
}

func TestRenderUnknown(t *testing.T) {
	uassert.True(t, strings.Contains(Render("call/9999"), "Call not found"))
	uassert.True(t, strings.Contains(Render("u/notanaddress"), "not a valid address"))
	uassert.True(t, strings.Contains(Render("how"), "How it works"))
	uassert.True(t, strings.Contains(Render("nope/nope"), "Not found"))
}
