package bloom_test

import (
	"strconv"
	"testing"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/bloom/v0"
)

func TestNewWithMK(t *testing.T) {
	cases := []struct {
		name  string
		m, k  uint64
		value []byte
	}{
		{name: "small filter", m: 64, k: 3, value: []byte("x")},
		{name: "single bit single hash", m: 1, k: 1, value: []byte("y")},
		{name: "clamped to minimums", m: 0, k: 0, value: []byte("z")},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			b := bloom.NewWithMK(tc.m, tc.k)

			// Act
			b.Add(tc.value)

			// Assert
			if !b.Contains(tc.value) {
				t.Error("expected Contains to be true")
			}
		})
	}
}

func TestNew(t *testing.T) {
	cases := []struct {
		name     string
		maxItems uint64
		rate     float64
	}{
		{name: "zero items", maxItems: 0, rate: 0.01},
		{name: "rate zero", maxItems: 10, rate: 0},
		{name: "rate one", maxItems: 10, rate: 1},
		{name: "negative rate", maxItems: 10, rate: -0.5},
		{name: "valid", maxItems: 1000, rate: 0.01},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			b := bloom.New(tc.maxItems, tc.rate)

			// Act: must not panic and must yield a usable filter.
			b.Add([]byte("value"))

			// Assert
			if !b.Contains([]byte("value")) {
				t.Error("expected Contains to be true for an added value")
			}
		})
	}
}

func TestContains(t *testing.T) {
	cases := []struct {
		name  string
		items []string
		value string
		want  bool
	}{
		{
			name:  "empty filter",
			items: nil,
			value: "alice",
			want:  false,
		},
		{
			name:  "single item",
			items: []string{"alice"},
			value: "alice",
			want:  true,
		},
		{
			name:  "multiple items",
			items: []string{"alice", "bob", "carol"},
			value: "bob",
			want:  true,
		},
		{
			name:  "empty string",
			items: []string{"alice", "", "carol"},
			value: "",
			want:  true,
		},
		{
			name:  "long string",
			items: []string{"alice", "a long string", "carol"},
			value: "a long string",
			want:  true,
		},
		{
			name:  "absent empty string",
			items: []string{"alice", "bob", "carol"},
			value: "",
			want:  false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			b := bloom.New(100, 0.01)
			for _, s := range tc.items {
				b.AddString(s)
			}

			// Act
			got := b.ContainsString(tc.value)

			// Assert
			if got != tc.want {
				t.Errorf("expected value to be %s", strconv.FormatBool(tc.want))
			}
		})
	}
}

func TestReset(t *testing.T) {
	// Arrange
	b := bloom.New(100, 0.01)
	b.AddString("alice").AddString("bob")
	m := b.Capacity()
	k := b.HashFunctions()

	// Act
	b.Reset()

	// Assert: previously added items are gone
	if b.ContainsString("alice") {
		t.Error("expected Contains to be false after Reset")
	}

	if b.ContainsString("bob") {
		t.Error("expected Contains to be false after Reset")
	}

	// Assert: capacity and hash count are unchanged
	if got := b.Capacity(); got != m {
		t.Errorf("expected capacity %d after Reset, got %d", m, got)
	}

	if got := b.HashFunctions(); got != k {
		t.Errorf("expected %d hash functions after Reset, got %d", k, got)
	}

	// Assert: the filter is still usable
	b.AddString("carol")
	if !b.ContainsString("carol") {
		t.Error("expected Contains to be true for an item added after Reset")
	}
}
