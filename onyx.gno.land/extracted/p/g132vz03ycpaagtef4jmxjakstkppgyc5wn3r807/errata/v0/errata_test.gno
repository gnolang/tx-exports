package errata

import (
	"strings"
	"testing"
)

func TestFormatUgnot(t *testing.T) {
	tests := []struct {
		amount int64
		want   string
	}{
		{0, "0 GNOT (0 ugnot)"},
		{1, "0.000001 GNOT (1 ugnot)"},
		{2560000, "2.56 GNOT (2560000 ugnot)"},
		{2000000, "2 GNOT (2000000 ugnot)"},
		{-1, "-0.000001 GNOT (-1 ugnot)"},
		{-9223372036854775808, "-9223372036854.775808 GNOT (-9223372036854775808 ugnot)"},
	}
	for _, test := range tests {
		if got := FormatUgnot(test.amount); got != test.want {
			t.Errorf("FormatUgnot(%d) = %q, want %q", test.amount, got, test.want)
		}
	}
}

func TestShortAddr(t *testing.T) {
	if got := ShortAddr("g1abcdefghijklmnopqrstuvwxy"); got != "g1abcd…vwxy" {
		t.Errorf("unexpected abbreviated address: %q", got)
	}
	if got := ShortAddr("g1abcd"); got != "g1abcd" {
		t.Errorf("short address changed: %q", got)
	}
}

func TestRenderSection(t *testing.T) {
	if got := RenderSection("", nil); got != "## Errata\n\nNo errata yet.\n" {
		t.Errorf("unexpected empty section: %q", got)
	}
	entries := []Entry{
		{
			Location: "p. 42 | 43", Text: "*fix*\n[x](javascript:boom) <img>",
			Finder: "[reader]|test", FoundAt: 12, Paid: 2560000, Link: "javascript:boom",
		},
		{Location: "p. 50", Text: "Fix the example.", Finder: "reader",
			FoundAt: 13, Link: "/r/reader/errata/v0:finder/1"},
	}
	got := RenderSection("Errata\n# <unsafe>", entries)
	for _, want := range []string{"p\\. 42 \\| 43", "\\*fix\\*", "\\<img\\>",
		"2.56 GNOT (2560000 ugnot)", "[reader](/r/reader/errata/v0:finder/1)"} {
		if !strings.Contains(got, want) {
			t.Errorf("table missing %q in %q", want, got)
		}
	}
	for _, unwanted := range []string{"\n# <unsafe>", "[x](javascript:", "](javascript:", "<img>"} {
		if strings.Contains(got, unwanted) {
			t.Errorf("unsafe content %q in %q", unwanted, got)
		}
	}
	if lines := strings.Count(got, "\n"); lines != 6 {
		t.Errorf("expected one line per table row, got %d lines in %q", lines, got)
	}
}
