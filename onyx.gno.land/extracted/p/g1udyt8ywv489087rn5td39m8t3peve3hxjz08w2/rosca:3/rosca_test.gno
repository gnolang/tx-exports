package rosca

import (
	"strings"
	"testing"
)





func TestSplitSumsExactly(t *testing.T) {
	cases := []struct {
		amount int64
		n      int
	}{
		{1000, 3},
		{1001, 3},
		{1, 4},
		{999999, 7},
		{0, 5},
	}
	for _, c := range cases {
		parts := Split(c.amount, c.n)
		if len(parts) != c.n {
			t.Fatalf("expected %d parts, got %d", c.n, len(parts))
		}
		sum := int64(0)
		for _, p := range parts {
			sum += p
		}
		if sum != c.amount {
			t.Fatalf("split of %d into %d gave %d", c.amount, c.n, sum)
		}
	}
}

func TestParamsValidate(t *testing.T) {
	good := Params{Contribution: 1000000, Collateral: 1000000, Size: 3, RoundSpan: 60}
	if err := good.Validate(); err != nil {
		t.Fatalf("valid params rejected: %v", err)
	}

	bad := []Params{
		{Contribution: 1000000, Collateral: 1000000, Size: 2, RoundSpan: 60},
		{Contribution: 1000000, Collateral: 1000000, Size: 51, RoundSpan: 60},
		{Contribution: 10, Collateral: 10, Size: 3, RoundSpan: 60},
		{Contribution: 1000000, Collateral: 2000000, Size: 3, RoundSpan: 60},
		{Contribution: 1000000, Collateral: 1000000, Size: 3, RoundSpan: 5},
		{Contribution: 1000000, Collateral: 1000000, Size: 3, RoundSpan: 99999999},
	}
	for i, p := range bad {
		if err := p.Validate(); err == nil {
			t.Fatalf("case %d: invalid params accepted", i)
		}
	}
}

func TestEconomicsBalance(t *testing.T) {
	p := Params{Contribution: 2000000, Collateral: 2000000, Size: 5, RoundSpan: 3600}
	if p.Pot() != 10000000 {
		t.Fatalf("pot should be 10 GNOT, got %d", p.Pot())
	}
	if p.Locked() != 10000000 {
		t.Fatalf("locked should be 10 GNOT, got %d", p.Locked())
	}
	if p.NetPerMember() != 0 {
		t.Fatalf("an ideal circle must net to zero per member, got %d", p.NetPerMember())
	}
}

func TestGnotFormatting(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0"},
		{1000, "0.001"},
		{1000000, "1"},
		{1500000, "1.5"},
		{1234567, "1.234567"},
		{1001000, "1.001"},
		{-2000000, "-2"},
	}
	for _, c := range cases {
		if got := Gnot(c.in); got != c.want {
			t.Fatalf("Gnot(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestBarWidth(t *testing.T) {
	b := Bar(1, 4, 8)
	if len(b) != 10 {
		t.Fatalf("bar should be 10 chars incl. brackets, got %q", b)
	}
	if !strings.HasPrefix(b, "[#") {
		t.Fatalf("expected some fill, got %q", b)
	}
	if got := Bar(0, 4, 4); got != "[----]" {
		t.Fatalf("empty bar wrong: %q", got)
	}
	if got := Bar(4, 4, 4); got != "[####]" {
		t.Fatalf("full bar wrong: %q", got)
	}
}

func TestHumanDuration(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{45, "45s"},
		{60, "1m"},
		{3600, "1h"},
		{90061, "1d 1h"},
		{0, "now"},
	}
	for _, c := range cases {
		if got := HumanDuration(c.in); got != c.want {
			t.Fatalf("HumanDuration(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestShortAddr(t *testing.T) {
	got := ShortAddr("g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2")
	if got != "g1udyt8...08w2" {
		t.Fatalf("short addr wrong: %q", got)
	}
	if ShortAddr("g1abc") != "g1abc" {
		t.Fatalf("short input should pass through")
	}
}
