package verdict_counter

import (
	"strconv"
	"testing"
)

func TestCounter(cur realm, t *testing.T) {
	defer func() { counter = 0 }()

	if got := Count(); got != 0 {
		t.Fatalf("initial count %d", got)
	}

	Increment(cross(cur))
	if got := Count(); got != 1 {
		t.Fatalf("count after one increment %d", got)
	}

	Increment(cross(cur))
	if got := Count(); got != 2 {
		t.Fatalf("count after repeated increments %d", got)
	}

	if got := Count(); got != 2 {
		t.Fatalf("count changed on read %d", got)
	}
	if got := Render(""); got != "Verdict counter: 2" {
		t.Fatalf("render %q", got)
	}
	if got := Count(); got != 2 {
		t.Fatalf("count changed on render %d", got)
	}
	if strconv.FormatInt(Count(), 10) != "2" {
		t.Fatal("count is not numeric")
	}
}

func TestCounterOverflow(cur realm, t *testing.T) {
	const maxInt64 = int64(1<<63 - 1)
	counter = maxInt64 - 1
	defer func() { counter = 0 }()

	Increment(cross(cur))
	if got := Count(); got != maxInt64 {
		t.Fatalf("count after last valid increment %d, want %d", got, maxInt64)
	}

	gotPanic := revive(func() {
		Increment(cross(cur))
	})
	if gotPanic != "counter overflow" {
		t.Fatalf("panic %v, want %q", gotPanic, "counter overflow")
	}

	if got := Count(); got != maxInt64 {
		t.Fatalf("count after overflow %d, want %d", got, maxInt64)
	}
}
