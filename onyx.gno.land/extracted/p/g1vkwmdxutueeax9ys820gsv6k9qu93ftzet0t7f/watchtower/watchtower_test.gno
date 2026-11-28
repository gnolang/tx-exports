package watchtower

import (
	"testing"
	"time"
)

func TestComputeStatus(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)

	cases := []struct {
		lastBeat int64
		interval int64
		manual   string
		want     string
	}{
		{0, 300, "", StatusUnknown},                    // never seen
		{now.Unix() - 100, 300, "", StatusOperational}, // fresh
		{now.Unix() - 600, 300, "", StatusDegraded},    // 2x interval
		{now.Unix() - 5000, 300, "", StatusDown},       // way stale
		{now.Unix() - 100, 300, ManualMaintenance, StatusMaintenance},
		{now.Unix() - 100, 300, ManualDown, StatusDown},
		{now.Unix() - 100, 0, "", StatusOperational}, // default interval
	}
	for i, c := range cases {
		if got := ComputeStatus(c.lastBeat, c.interval, c.manual, now); got != c.want {
			t.Fatalf("case %d: ComputeStatus(%d, %d, %q) = %q, want %q", i, c.lastBeat, c.interval, c.manual, got, c.want)
		}
	}
}

func TestFormatAge(t *testing.T) {
	cases := map[int64]string{
		0:     "0s",
		42:    "42s",
		180:   "3m",
		7200:  "2h",
		90000: "1d",
		-5:    "0s",
	}
	for in, want := range cases {
		if got := FormatAge(in); got != want {
			t.Fatalf("FormatAge(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestStatusMark(t *testing.T) {
	if StatusMark(StatusOperational) != "[OK]" {
		t.Fatalf("unexpected mark for operational: %q", StatusMark(StatusOperational))
	}
	if StatusMark("whatever") != "[UNKNOWN]" {
		t.Fatalf("unexpected mark for unknown input: %q", StatusMark("whatever"))
	}
}
