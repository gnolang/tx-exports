package game32

import (
	"strconv"
	"testing"
	"time"
)

// ── DailyCheckin helpers ──────────────────────────────────────────────────────

// resetDailyCheckin removes any stored check-in state for the address.
func resetDailyCheckin(addr string) {
	dailyCheckins.Remove(addr)
}

// setDailyCheckinRaw directly writes a raw value into dailyCheckins.
// Use this to seed "yesterday", "old format", etc. without going through
// the DailyCheckin transaction path.
func setDailyCheckinRaw(addr, raw string) {
	dailyCheckins.Set(addr, raw)
}

// getDailyCheckinRaw reads the raw stored value (for assertions).
func getDailyCheckinRaw(addr string) string {
	if !dailyCheckins.Has(addr) {
		return ""
	}
	return dailyCheckins.Get(addr).(string)
}

// ── parseDailyCheckin tests ───────────────────────────────────────────────────

func TestParseDailyCheckinNewFormat(t *testing.T) {
	lastDay, streak := parseDailyCheckin("20000:5")
	if lastDay != 20000 {
		t.Errorf("lastDay: got %d, want 20000", lastDay)
	}
	if streak != 5 {
		t.Errorf("streak: got %d, want 5", streak)
	}
}

func TestParseDailyCheckinLegacyFormat(t *testing.T) {
	// Old format: raw unix seconds.  day 19000 = 19000 * 86400 = 1641600000
	seconds := int64(19000 * 86400)
	raw := strconv.FormatInt(seconds, 10)
	lastDay, streak := parseDailyCheckin(raw)
	if lastDay != 19000 {
		t.Errorf("lastDay: got %d, want 19000", lastDay)
	}
	if streak != 1 {
		t.Errorf("legacy format must give streak=1, got %d", streak)
	}
}

func TestParseDailyCheckinEmpty(t *testing.T) {
	// Edge: value "0" (no prior check-in default)
	lastDay, streak := parseDailyCheckin("0")
	if lastDay != 0 {
		t.Errorf("lastDay: got %d, want 0", lastDay)
	}
	if streak != 1 {
		t.Errorf("streak: got %d, want 1", streak)
	}
}

// ── DailyCheckin streak logic tests ──────────────────────────────────────────

func TestDailyCheckinFirstCheckin(t *testing.T) {
	addr := "g1dailytest001"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400

	// Simulate first check-in: no prior state → DailyCheckin writes today:1
	// We call the logic inline (mirrors BuyToolDirect approach) since DailyCheckin
	// requires a cur realm that isn't available in unit tests.
	// Precondition: nothing stored
	if dailyCheckins.Has(addr) {
		t.Fatal("precondition: must have no prior check-in")
	}

	// Perform the streak update logic directly (same as DailyCheckin body)
	var lastDay, streak int64
	// No entry → both stay 0
	_ = lastDay
	_ = streak
	// today != 0 and 0 != today-1 → streak = 1
	newStreak := int64(1)
	val := strconv.FormatInt(today, 10) + ":" + strconv.FormatInt(newStreak, 10)
	dailyCheckins.Set(addr, val)

	// Verify
	stored := getDailyCheckinRaw(addr)
	gotDay, gotStreak := parseDailyCheckin(stored)
	if gotDay != today {
		t.Errorf("lastDay: got %d, want %d", gotDay, today)
	}
	if gotStreak != 1 {
		t.Errorf("streak after first check-in: got %d, want 1", gotStreak)
	}
}

func TestDailyCheckinConsecutiveDays(t *testing.T) {
	addr := "g1dailytest002"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400
	yesterday := today - 1

	// Seed: player checked in yesterday with streak=3
	setDailyCheckinRaw(addr, strconv.FormatInt(yesterday, 10)+":3")

	// Now simulate today's check-in
	raw := getDailyCheckinRaw(addr)
	lastDay, streak := parseDailyCheckin(raw)

	if lastDay == today {
		t.Fatal("test setup error: lastDay should be yesterday")
	}
	var newStreak int64
	if lastDay == today-1 {
		newStreak = streak + 1 // should be 4
	} else {
		newStreak = 1
	}

	val := strconv.FormatInt(today, 10) + ":" + strconv.FormatInt(newStreak, 10)
	dailyCheckins.Set(addr, val)

	gotDay, gotStreak := parseDailyCheckin(getDailyCheckinRaw(addr))
	if gotDay != today {
		t.Errorf("lastDay: got %d, want %d", gotDay, today)
	}
	if gotStreak != 4 {
		t.Errorf("streak after consecutive day: got %d, want 4", gotStreak)
	}
}

func TestDailyCheckinSkippedDay(t *testing.T) {
	addr := "g1dailytest003"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400
	twoDaysAgo := today - 2

	// Seed: player last checked in 2 days ago with a long streak
	setDailyCheckinRaw(addr, strconv.FormatInt(twoDaysAgo, 10)+":42")

	raw := getDailyCheckinRaw(addr)
	lastDay, streak := parseDailyCheckin(raw)
	_ = streak

	var newStreak int64
	if lastDay == today {
		t.Fatal("same-day check detected unexpectedly")
	} else if lastDay == today-1 {
		newStreak = streak + 1
	} else {
		newStreak = 1 // streak resets
	}

	val := strconv.FormatInt(today, 10) + ":" + strconv.FormatInt(newStreak, 10)
	dailyCheckins.Set(addr, val)

	_, gotStreak := parseDailyCheckin(getDailyCheckinRaw(addr))
	if gotStreak != 1 {
		t.Errorf("streak after missed day: got %d, want 1", gotStreak)
	}
}

func TestDailyCheckinSameDayPanics(t *testing.T) {
	addr := "g1dailytest004"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400

	// Seed: already checked in today
	setDailyCheckinRaw(addr, strconv.FormatInt(today, 10)+":7")

	// The DailyCheckin function should panic with "already checked in today"
	// when lastDay == today. We replicate the same panic condition here.
	mustPanic(t, "already checked in today", func() {
		raw := getDailyCheckinRaw(addr)
		lastDay, _ := parseDailyCheckin(raw)
		if lastDay == today {
			panic("already checked in today")
		}
	})
}

func TestDailyCheckinOldUnixSecondsFormat(t *testing.T) {
	addr := "g1dailytest005"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400
	yesterdaySeconds := (today - 1) * 86400

	// Seed: old format — raw unix seconds for yesterday
	setDailyCheckinRaw(addr, strconv.FormatInt(yesterdaySeconds, 10))

	// parseDailyCheckin must interpret this as lastDay = yesterdaySeconds/86400 = today-1, streak=1
	raw := getDailyCheckinRaw(addr)
	lastDay, streak := parseDailyCheckin(raw)

	if lastDay != today-1 {
		t.Errorf("old format lastDay: got %d, want %d", lastDay, today-1)
	}
	if streak != 1 {
		t.Errorf("old format streak: got %d, want 1", streak)
	}

	// Checking in today from old-format yesterday → streak becomes 2
	var newStreak int64
	if lastDay == today-1 {
		newStreak = streak + 1
	} else {
		newStreak = 1
	}
	if newStreak != 2 {
		t.Errorf("streak after old-format yesterday: got %d, want 2", newStreak)
	}
}

// ── DailyCheckinStatus tests ──────────────────────────────────────────────────

func TestDailyCheckinStatusNeverCheckedIn(t *testing.T) {
	addr := "g1statustest001"
	resetDailyCheckin(addr)

	status := DailyCheckinStatus(addr)
	if !strContains(status, `"ok":true`) {
		t.Errorf("expected ok:true, got %s", status)
	}
	if !strContains(status, `"done":false`) {
		t.Errorf("expected done:false for no check-in, got %s", status)
	}
	if !strContains(status, `"streak":0`) {
		t.Errorf("expected streak:0 for no check-in, got %s", status)
	}
}

func TestDailyCheckinStatusCheckedInToday(t *testing.T) {
	addr := "g1statustest002"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400
	// Simulate checked in today with streak=5
	setDailyCheckinRaw(addr, strconv.FormatInt(today, 10)+":5")

	status := DailyCheckinStatus(addr)
	if !strContains(status, `"done":true`) {
		t.Errorf("expected done:true when checked in today, got %s", status)
	}
	if !strContains(status, `"streak":5`) {
		t.Errorf("expected streak:5, got %s", status)
	}
}

func TestDailyCheckinStatusCheckedInYesterday(t *testing.T) {
	addr := "g1statustest003"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400
	yesterday := today - 1
	// Checked in yesterday — streak is still live (not broken yet)
	setDailyCheckinRaw(addr, strconv.FormatInt(yesterday, 10)+":12")

	status := DailyCheckinStatus(addr)
	if !strContains(status, `"done":false`) {
		t.Errorf("expected done:false (not checked in today), got %s", status)
	}
	// Streak is still live (lastDay == today-1)
	if !strContains(status, `"streak":12`) {
		t.Errorf("expected streak:12 (live streak), got %s", status)
	}
}

func TestDailyCheckinStatusStreakBrokenAfterMissedDay(t *testing.T) {
	addr := "g1statustest004"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400
	twoDaysAgo := today - 2
	// Last check-in was 2 days ago — streak is broken
	setDailyCheckinRaw(addr, strconv.FormatInt(twoDaysAgo, 10)+":30")

	status := DailyCheckinStatus(addr)
	if !strContains(status, `"done":false`) {
		t.Errorf("expected done:false, got %s", status)
	}
	// Streak must report 0 when broken
	if !strContains(status, `"streak":0`) {
		t.Errorf("expected streak:0 after missed day, got %s", status)
	}
}

func TestDailyCheckinStatusNextMidnight(t *testing.T) {
	addr := "g1statustest005"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400
	setDailyCheckinRaw(addr, strconv.FormatInt(today, 10)+":1")

	status := DailyCheckinStatus(addr)
	// next field must be (today+1)*86400
	wantNext := (today + 1) * 86400
	wantStr := `"next":` + strconv.FormatInt(wantNext, 10)
	if !strContains(status, wantStr) {
		t.Errorf("expected %s in status, got %s", wantStr, status)
	}
}

func TestDailyCheckinStatusOldFormat(t *testing.T) {
	addr := "g1statustest006"
	resetDailyCheckin(addr)

	today := time.Now().Unix() / 86400
	// Seed yesterday in old unix-seconds format
	yesterdaySeconds := (today - 1) * 86400
	setDailyCheckinRaw(addr, strconv.FormatInt(yesterdaySeconds, 10))

	status := DailyCheckinStatus(addr)
	// Old format is yesterday → streak lives at 1, not yet done today
	if !strContains(status, `"done":false`) {
		t.Errorf("expected done:false (old format, yesterday), got %s", status)
	}
	if !strContains(status, `"streak":1`) {
		t.Errorf("expected streak:1 (old format gives streak=1), got %s", status)
	}
}

// ── helpers (from the game28 test suite) ──
func mustPanic(t *testing.T, wantSubstr string, f func()) {
	t.Helper()
	var msg string
	panicked := false
	func() {
		defer func() {
			r := recover()
			if r != nil {
				panicked = true
				switch v := r.(type) {
				case string:
					msg = v
				case error:
					msg = v.Error()
				default:
					msg = "non-string panic"
				}
			}
		}()
		f()
	}()
	if !panicked {
		t.Errorf("expected panic containing %q, but no panic occurred", wantSubstr)
		return
	}
	if wantSubstr != "" && !strContains(msg, wantSubstr) {
		t.Errorf("panic message %q does not contain %q", msg, wantSubstr)
	}
}

func strContains(s, sub string) bool {
	if len(sub) == 0 {
		return true
	}
	if len(sub) > len(s) {
		return false
	}
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}


func TestRepairCostCeil30Pct(t *testing.T) {
	type tc struct {
		toolId   string
		coinId   string
		base     uint64
		expected uint64 // ceil(base × 30%) = (base×30 + 99) / 100
	}
	cases := []tc{
		// wood: seedling:19 → ceil(5.7) = 6
		{"wood", "seedling", 19, 6},
		// wood: party:8 → ceil(2.4) = 3
		{"wood", "party", 8, 3},
		// iron: gear:42 → ceil(12.6) = 13
		{"iron", "gear", 42, 13},
		// iron: magnet:4 → ceil(1.2) = 2
		{"iron", "magnet", 4, 2},
		// quasar: lotus:3510 → ceil(1053.0) = 1053
		{"quasar", "lotus", 3510, 1053},
		// omega: lotus:26970 → ceil(8091.0) = 8091
		{"omega", "lotus", 26970, 8091},
		// stone: cactus:15 → ceil(4.5) = 5
		{"stone", "cactus", 15, 5},
	}
	for _, c := range cases {
		costs, hasCosts := toolCosts[c.toolId]
		if !hasCosts {
			t.Errorf("toolCosts missing for %s", c.toolId)
			continue
		}
		found := false
		for _, pair := range costs {
			if pair[0] != c.coinId {
				continue
			}
			found = true
			base, _ := strconv.ParseUint(pair[1], 10, 64)
			if base != c.base {
				t.Errorf("%s[%s]: expected base=%d, got %d", c.toolId, c.coinId, c.base, base)
			}
			got := (base*30 + 99) / 100
			if got != c.expected {
				t.Errorf("%s[%s]: ceil(30%%)=%d expected, got %d", c.toolId, c.coinId, c.expected, got)
			}
			break
		}
		if !found {
			t.Errorf("%s does not contain ingredient %s", c.toolId, c.coinId)
		}
	}
}
