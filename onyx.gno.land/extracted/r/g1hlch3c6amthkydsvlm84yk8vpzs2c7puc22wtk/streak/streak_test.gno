package streak

import (
	"strings"
	"testing"
	"time"

	"gno.land/p/g1hlch3c6amthkydsvlm84yk8vpzs2c7puc22wtk/streakcalc"
)

// Test addresses (valid bech32, taken from the gno examples).
var (
	alice = address("g1g3lsfxhvaqgdv4ccemwpnms4fv6t3aq3p5z6u7")
	bob   = address("g1juz2yxmdsa6audkp6ep9vfv80c8p5u76e03vvh")
	carol = address("g1sp8v98h2gadm5jggtzz9w5ksexqn68ympsd68h")
	dave  = address("g1vuch2um9wf047h6lta047h6lta047h6l2ewm6w")
)

// reset clears all realm state so each test starts empty.
func reset() {
	records = map[address]streakcalc.State{}
	members = nil
}

func wantStats(t *testing.T, addr address, current, longest, total, lastDay int64) {
	t.Helper()
	c, l, tot, last, found := GetStats(addr)
	if !found {
		t.Fatalf("no record for %s", addr)
	}
	if c != current || l != longest || tot != total || last != lastDay {
		t.Fatalf("%s: got (current %d, longest %d, total %d, last %d), want (%d, %d, %d, %d)",
			addr, c, l, tot, last, current, longest, total, lastDay)
	}
}

func TestFirstCheckIn(t *testing.T) {
	reset()
	st := checkIn(alice, 100)
	if st != (streakcalc.State{Current: 1, Longest: 1, Total: 1, LastDay: 100, Has: true}) {
		t.Fatalf("unexpected state: %+v", st)
	}
	wantStats(t, alice, 1, 1, 1, 100)
	if TotalUsers() != 1 {
		t.Fatalf("TotalUsers = %d, want 1", TotalUsers())
	}
}

func TestSameDayRepeat(t *testing.T) {
	reset()
	checkIn(alice, 100)
	checkIn(alice, 100)
	checkIn(alice, 100)
	wantStats(t, alice, 1, 1, 1, 100)
	if TotalUsers() != 1 {
		t.Fatalf("TotalUsers = %d, want 1", TotalUsers())
	}
}

func TestConsecutiveDays(t *testing.T) {
	reset()
	checkIn(alice, 100)
	checkIn(alice, 101)
	checkIn(alice, 102)
	wantStats(t, alice, 3, 3, 3, 102)
}

func TestGapResets(t *testing.T) {
	reset()
	checkIn(alice, 100)
	checkIn(alice, 101)
	checkIn(alice, 110) // 8 days missed
	wantStats(t, alice, 1, 2, 3, 110)
}

func TestLongestTracked(t *testing.T) {
	reset()
	for d := int64(0); d < 7; d++ {
		checkIn(alice, d)
	}
	checkIn(alice, 100) // reset after a gap
	checkIn(alice, 101)
	wantStats(t, alice, 2, 7, 9, 101)
}

func TestMultipleUsersIndependent(t *testing.T) {
	reset()
	checkIn(alice, 100)
	checkIn(alice, 101)
	checkIn(bob, 101)
	checkIn(carol, 99)
	checkIn(carol, 100)
	checkIn(carol, 101)
	wantStats(t, alice, 2, 2, 2, 101)
	wantStats(t, bob, 1, 1, 1, 101)
	wantStats(t, carol, 3, 3, 3, 101)
	if TotalUsers() != 3 {
		t.Fatalf("TotalUsers = %d, want 3", TotalUsers())
	}
	if _, _, _, _, found := GetStats(dave); found {
		t.Fatal("unknown address should have no record")
	}
}

// carol has the best streak (5); alice and bob tie on longest (3),
// and alice wins the tie on current streak (3 vs bob's 1 after a gap).
func seedLeaderboard() {
	reset()
	for d := int64(0); d < 5; d++ {
		checkIn(carol, d)
	}
	for d := int64(0); d < 3; d++ {
		checkIn(alice, d)
	}
	for d := int64(0); d < 3; d++ {
		checkIn(bob, d)
	}
	checkIn(bob, 50) // gap: bob's current drops to 1, longest stays 3
}

func TestLeaderboardOrder(t *testing.T) {
	seedLeaderboard()
	rows := top(10)
	if len(rows) != 3 {
		t.Fatalf("top(10) returned %d rows, want 3", len(rows))
	}
	if rows[0].addr != carol || rows[1].addr != alice || rows[2].addr != bob {
		t.Fatalf("order = %s, %s, %s; want carol, alice, bob",
			rows[0].addr, rows[1].addr, rows[2].addr)
	}
	if got := top(2); len(got) != 2 || got[1].addr != alice {
		t.Fatalf("top(2) wrong: %+v", got)
	}
}

func TestRenderLeaderboard(t *testing.T) {
	reset()
	if out := Render(""); !strings.Contains(out, "Nobody has checked in yet") {
		t.Fatalf("empty leaderboard render missing placeholder:\n%s", out)
	}
	seedLeaderboard()
	out := Render("")
	for _, want := range []string{
		"# Streak", carol.String(), alice.String(), bob.String(), "3 user(s)",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("leaderboard render missing %q:\n%s", want, out)
		}
	}
	// Carol (best streak) must appear before alice and bob.
	ci, ai, bi := strings.Index(out, carol.String()),
		strings.Index(out, alice.String()), strings.Index(out, bob.String())
	if !(ci < ai && ai < bi) {
		t.Errorf("leaderboard rows out of order:\n%s", out)
	}
}

func TestRenderUser(t *testing.T) {
	reset()
	checkIn(alice, 100)
	checkIn(alice, 101)
	out := Render(alice.String())
	for _, want := range []string{alice.String(), "**2**", "Last check-in day index: 101"} {
		if !strings.Contains(out, want) {
			t.Errorf("user render missing %q:\n%s", want, out)
		}
	}
	if out := Render(bob.String()); !strings.Contains(out, "No check-ins yet") {
		t.Errorf("unknown user render should say no check-ins:\n%s", out)
	}
}

// TestCheckInEndToEnd drives the real crossing entry point: the
// caller is a test user realm, and a second immediate call is a
// same-day no-op whatever the test clock says.
func TestCheckInEndToEnd(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	msg := CheckIn(cross(cur))
	if !strings.Contains(msg, "Checked in") {
		t.Fatalf("first CheckIn message: %q", msg)
	}
	wantStats(t, alice, 1, 1, 1, streakcalc.DayOf(time.Now().Unix()))
	msg = CheckIn(cross(cur))
	if !strings.Contains(msg, "Already checked in today") {
		t.Fatalf("second CheckIn message: %q", msg)
	}
	if _, _, total, _, _ := GetStats(alice); total != 1 {
		t.Fatalf("total after same-day repeat = %d, want 1", total)
	}
}
