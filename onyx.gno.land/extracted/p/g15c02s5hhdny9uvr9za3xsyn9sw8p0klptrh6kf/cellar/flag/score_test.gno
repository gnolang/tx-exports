package flag

import "testing"

func TestValueCurve(t *testing.T) {
	cases := []struct {
		d      Difficulty
		solves int
		want   int
	}{
		{Easy, 0, 100},
		{Easy, 1, 100},
		{Easy, 2, 100 - 60*1/400},
		{Medium, 11, 250 - 150*100/400},
		{Hard, 21, 200},
		{Hard, 500, 200},
	}
	for _, tc := range cases {
		if got := Value(tc.d, tc.solves); got != tc.want {
			t.Errorf("Value(%s, %d) = %d, want %d", tc.d, tc.solves, got, tc.want)
		}
	}
}

func TestValueMonotonic(t *testing.T) {
	for _, d := range []Difficulty{Easy, Medium, Hard} {
		prev := Value(d, 0)
		for n := 1; n <= 40; n++ {
			v := Value(d, n)
			if v > prev || v < d.Floor() {
				t.Fatalf("%s: value %d at %d solves breaks the curve", d, v, n)
			}
			prev = v
		}
	}
}

func TestFirstBlood(t *testing.T) {
	if Hard.FirstBloodBonus() != 50 || Easy.FirstBloodBonus() != 10 {
		t.Fatal("first blood bonus should be a tenth of the initial value")
	}
}

func TestCard(t *testing.T) {
	l := NewLedger()
	l.Record(ash)
	out := Card(Info{Slug: "label", Title: "The Forged Label", Difficulty: Easy, Category: "render", Brief: "Brief."}, l)
	want := "# The Forged Label\n\n**Easy** · render · 1 captured · worth 100 points\n\nBrief.\n"
	if out != want {
		t.Fatalf("Card =\n%q\nwant\n%q", out, want)
	}
}

func TestCaptures(t *testing.T) {
	l := NewLedger()
	if Captures(l, 3) != "*Nobody has broken it yet.*\n" {
		t.Fatal("empty ledger should say so")
	}
	l.Record(ash)
	out := Captures(l, 3)
	if out != "- `"+ash.String()+"` at block 123 (first)\n" {
		t.Fatalf("Captures = %q", out)
	}
}
