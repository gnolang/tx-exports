package tavern

import (
	"chain/markdown"
	"crypto/bech32"
	"strconv"
	"strings"
	"testing"
	"time"
)

// testAddr derives a deterministic test address from a short name,
// using the same bech32 trick as the official test utilities (stdlib
// only, so the suite runs without downloading any on-chain package).
func testAddr(name string) address {
	raw := []byte("____________________")
	copy(raw[:], name)
	converted, err := bech32.ConvertBits(raw, 8, 5, true)
	if err != nil {
		panic(err)
	}
	enc, err := bech32.Encode("g", converted)
	if err != nil {
		panic(err)
	}
	return address(enc)
}

var (
	alice = testAddr("alice")
	bob   = testAddr("bob")
	carol = testAddr("carol")
	dave  = testAddr("dave")
	erin  = testAddr("erin")
	frank = testAddr("frank")
	grace = testAddr("grace")
)

// setActor makes addr the acting user and moves the block clock to the
// given UTC day number (one hour into the day).
func setActor(addr address, day int64) {
	testing.SetRealm(testing.NewUserRealm(addr))
	ctx := testing.GetContext()
	ctx.CurrentRealm = testing.NewUserRealm(addr)
	ctx.OriginCaller = addr
	ctx.Time = time.Unix(day*secondsPerDay+3600, 0)
	testing.SetContext(ctx)
}

func resetState() {
	book = nil
	board = nil
	patrons = map[address]*patron{}
	totalSigns = 0
	totalCheckIns = 0
}

func TestSignGuestbook(cur realm, t *testing.T) {
	resetState()

	setActor(alice, 100)
	res := Sign(cross(cur), "First round is on me!")
	if !strings.Contains(res, "guest #1") {
		t.Fatalf("unexpected Sign reply: %q", res)
	}
	setActor(bob, 100)
	Sign(cross(cur), "Cozy place.")
	setActor(alice, 101)
	Sign(cross(cur), "Back again.")

	if totalSigns != 3 || GuestCount() != 3 {
		t.Fatalf("totalSigns = %d, want 3", totalSigns)
	}
	if len(book) != 3 {
		t.Fatalf("len(book) = %d, want 3", len(book))
	}
	if book[0].author != alice || book[0].msg != "First round is on me!" || book[0].day != 100 {
		t.Fatalf("book[0] = %+v", book[0])
	}
	if book[2].author != alice || book[2].day != 101 {
		t.Fatalf("book[2] = %+v", book[2])
	}
	// Signing the guestbook is not a check-in.
	if totalCheckIns != 0 {
		t.Fatalf("totalCheckIns = %d, want 0", totalCheckIns)
	}
}

func TestSignRingBound(cur realm, t *testing.T) {
	resetState()
	setActor(alice, 100)

	for i := 1; i <= 55; i++ {
		Sign(cross(cur), "msg-"+pad2(i))
	}
	if totalSigns != 55 {
		t.Fatalf("totalSigns = %d, want 55", totalSigns)
	}
	if len(book) != guestbookKeep {
		t.Fatalf("len(book) = %d, want %d", len(book), guestbookKeep)
	}
	if book[0].msg != "msg-06" {
		t.Fatalf("oldest kept entry = %q, want msg-06", book[0].msg)
	}
	if book[len(book)-1].msg != "msg-55" {
		t.Fatalf("newest entry = %q, want msg-55", book[len(book)-1].msg)
	}
	out := Render("")
	// Messages are markdown-escaped in the render, so compare the
	// escaped forms: the newest entry shows, the evicted one is gone.
	if !strings.Contains(out, markdown.EscapeInline("msg-55")) ||
		strings.Contains(out, markdown.EscapeInline("msg-05")) {
		t.Fatalf("render should show msg-55 and no longer show evicted msg-05")
	}
}

func pad2(i int) string {
	if i < 10 {
		return "0" + strconv.Itoa(i)
	}
	return strconv.Itoa(i)
}

// NOTE: a panic raised inside a crossing function (Sign, CheckIn) is
// not recoverable from Gno test code — it aborts the whole test run
// (on-chain it simply reverts the transaction). The guard rules are
// therefore tested at the validateMessage layer that Sign is wired to,
// and Sign itself is exercised live on the testnet, where a rejected
// call is observable as a reverted transaction.
func TestSignGuards(cur realm, t *testing.T) {
	resetState()

	rejected := map[string]string{
		"empty message":   "",
		"blank message":   "   ",
		"newline in text": "two\nlines",
		"tab in text":     "a\tb",
		"141 ascii chars": strings.Repeat("x", 141),
		"141 runes":       strings.Repeat("é", 141),
	}
	for what, msg := range rejected {
		if _, reason := validateMessage(msg); reason == "" {
			t.Fatalf("validateMessage accepted %s", what)
		}
	}

	// Exactly at the cap — including multibyte runes — is accepted.
	for _, msg := range []string{strings.Repeat("x", 140), strings.Repeat("é", 140), "hello"} {
		if _, reason := validateMessage(msg); reason != "" {
			t.Fatalf("validateMessage rejected a valid message: %s", reason)
		}
	}

	// Sign stores the trimmed message.
	setActor(alice, 100)
	Sign(cross(cur), "  padded with care  ")
	if len(book) != 1 || book[0].msg != "padded with care" {
		t.Fatalf("stored message = %+v, want trimmed text", book)
	}
}

func TestCheckInStreaks(cur realm, t *testing.T) {
	resetState()

	setActor(alice, 200)
	res := CheckIn(cross(cur))
	if !strings.Contains(res, "First check-in") {
		t.Fatalf("unexpected first CheckIn reply: %q", res)
	}
	streak, best, total, ok := PatronStats(alice)
	if !ok || streak != 1 || best != 1 || total != 1 {
		t.Fatalf("after first check-in: streak=%d best=%d total=%d ok=%v", streak, best, total, ok)
	}

	// Same day again: a no-op that reports the standing.
	res = CheckIn(cross(cur))
	if !strings.Contains(res, "Already checked in") {
		t.Fatalf("unexpected same-day reply: %q", res)
	}
	if totalCheckIns != 1 {
		t.Fatalf("totalCheckIns = %d after same-day repeat, want 1", totalCheckIns)
	}

	setActor(alice, 201)
	CheckIn(cross(cur))
	setActor(alice, 202)
	CheckIn(cross(cur))
	streak, best, total, _ = PatronStats(alice)
	if streak != 3 || best != 3 || total != 3 {
		t.Fatalf("after 3 consecutive days: streak=%d best=%d total=%d", streak, best, total)
	}

	// Skip day 203: the streak restarts, the best is remembered.
	setActor(alice, 204)
	CheckIn(cross(cur))
	streak, best, total, _ = PatronStats(alice)
	if streak != 1 || best != 3 || total != 4 {
		t.Fatalf("after missed day: streak=%d best=%d total=%d", streak, best, total)
	}
	if totalCheckIns != 4 || CheckInCount() != 4 {
		t.Fatalf("totalCheckIns = %d, want 4", totalCheckIns)
	}

	if _, _, _, ok := PatronStats(bob); ok {
		t.Fatalf("bob never checked in but has stats")
	}
}

// checkInOn checks addr in on each of the given days. It is a
// top-level helper on purpose: a realm value must be threaded through
// explicit parameters — calling a crossing function through a closure
// that captures cur makes cur.Previous() resolve to the wrong realm.
func checkInOn(cur realm, addr address, days ...int64) {
	for _, d := range days {
		setActor(addr, d)
		CheckIn(cross(cur))
	}
}

func TestRegularsBoard(cur realm, t *testing.T) {
	resetState()

	checkInOn(cur, carol, 300, 301, 302, 303, 304) // streak 5, total 5
	checkInOn(cur, erin, 300, 301, 302, 303)       // streak 4, total 4
	checkInOn(cur, dave, 300, 301, 302)            // streak 3, total 3
	checkInOn(cur, grace, 300, 301, 303)           // streak 1, total 3
	checkInOn(cur, frank, 300)                     // streak 1, total 1

	want := []address{carol, erin, dave, grace, frank}
	if len(board) != len(want) {
		t.Fatalf("len(board) = %d, want %d (%v)", len(board), len(want), board)
	}
	for i, a := range want {
		if board[i] != a {
			t.Fatalf("board[%d] = %s, want %s (board: %v)", i, board[i], a, board)
		}
	}

	// The board is capped at boardSize even with many more patrons.
	for i := 0; i < 8; i++ {
		setActor(testAddr("guest"+strconv.Itoa(i)), 300)
		CheckIn(cross(cur))
	}
	if len(board) != boardSize {
		t.Fatalf("len(board) = %d, want cap %d", len(board), boardSize)
	}
	if board[0] != carol || board[1] != erin {
		t.Fatalf("top of board changed unexpectedly: %v", board[:2])
	}
}

func TestRender(cur realm, t *testing.T) {
	resetState()

	empty := Render("")
	if !strings.Contains(empty, "# 🍺 Tavern Guestbook") ||
		!strings.Contains(empty, "No regulars yet") ||
		!strings.Contains(empty, "first page is still blank") {
		t.Fatalf("empty render missing expected sections:\n%s", empty)
	}

	setActor(alice, 20785) // 2026-11-28
	Sign(cross(cur), "Best stew in gno.land!")
	CheckIn(cross(cur))
	setActor(alice, 20786)
	CheckIn(cross(cur))

	out := Render("")
	for _, want := range []string{
		"# 🍺 Tavern Guestbook",
		"## 🏆 Regulars Board",
		"## 📖 Latest in the Guestbook",
		markdown.EscapeInline("Best stew in gno.land!"),
		"Guestbook signatures:** 1",
		"Check-ins poured:** 2",
		"2026-11-28", // the signature's rendered ISO date
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("render missing %q:\n%s", want, out)
		}
	}
}

func TestRenderEscapesMessages(cur realm, t *testing.T) {
	resetState()
	setActor(alice, 200)

	msg := "# not-a-heading *not-bold*"
	Sign(cross(cur), msg)
	out := Render("")
	if !strings.Contains(out, markdown.EscapeInline(msg)) {
		t.Fatalf("render does not contain the escaped message:\n%s", out)
	}
	if strings.Contains(out, "\n# not-a-heading") {
		t.Fatalf("raw message leaked into render as a heading:\n%s", out)
	}
}
