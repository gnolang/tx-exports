package streakcalc

import "testing"

func check(t *testing.T, got, want State) {
	t.Helper()
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestDayOf(t *testing.T) {
	if DayOf(0) != 0 {
		t.Errorf("DayOf(0) = %d, want 0", DayOf(0))
	}
	if DayOf(86399) != 0 {
		t.Errorf("DayOf(86399) = %d, want 0", DayOf(86399))
	}
	if DayOf(86400) != 1 {
		t.Errorf("DayOf(86400) = %d, want 1", DayOf(86400))
	}
	// 2026-11-28 00:00:00 UTC = unix 1796102400 = day 20788.
	if DayOf(1796102400) != 20788 {
		t.Errorf("DayOf(1796102400) = %d, want 20788", DayOf(1796102400))
	}
}

func TestFirstCheckIn(t *testing.T) {
	got := Apply(State{}, 100)
	check(t, got, State{Current: 1, Longest: 1, Total: 1, LastDay: 100, Has: true})
}

func TestSameDayRepeatIsNoOp(t *testing.T) {
	s := Apply(State{}, 100)
	got := Apply(s, 100)
	check(t, got, State{Current: 1, Longest: 1, Total: 1, LastDay: 100, Has: true})
}

func TestConsecutiveDay(t *testing.T) {
	s := State{}
	s = Apply(s, 100)
	s = Apply(s, 101)
	s = Apply(s, 102)
	check(t, s, State{Current: 3, Longest: 3, Total: 3, LastDay: 102, Has: true})
}

func TestGapResetsCurrent(t *testing.T) {
	s := State{}
	s = Apply(s, 100)
	s = Apply(s, 101)
	s = Apply(s, 105) // three days missed
	check(t, s, State{Current: 1, Longest: 2, Total: 3, LastDay: 105, Has: true})
}

func TestLongestSurvivesReset(t *testing.T) {
	s := State{}
	for d := int64(200); d < 210; d++ { // 10-day streak
		s = Apply(s, d)
	}
	s = Apply(s, 300) // long gap: reset
	check(t, s, State{Current: 1, Longest: 10, Total: 11, LastDay: 300, Has: true})
	s = Apply(s, 301)
	s = Apply(s, 302)
	check(t, s, State{Current: 3, Longest: 10, Total: 13, LastDay: 302, Has: true})
}

func TestOutOfOrderDayIsNoOp(t *testing.T) {
	s := Apply(State{}, 100)
	s = Apply(s, 101)
	got := Apply(s, 50)
	check(t, got, State{Current: 2, Longest: 2, Total: 2, LastDay: 101, Has: true})
}
