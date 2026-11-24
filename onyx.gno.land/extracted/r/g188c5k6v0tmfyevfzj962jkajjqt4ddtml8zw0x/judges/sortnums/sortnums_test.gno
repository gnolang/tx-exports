package sortnums

import "testing"

func TestInputsAreDeterministicPerSeed(t *testing.T) {
	a, b := Inputs(42), Inputs(42)
	if len(a) != 8 {
		t.Fatalf("want 8 inputs, got %d", len(a))
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatal("same seed must give the same inputs")
		}
	}
	if Inputs(43)[0] == a[0] {
		t.Fatal("different seeds must give different inputs")
	}
}

func TestInputsAreValidLists(t *testing.T) {
	for _, in := range Inputs(7) {
		nums, ok := parse(in)
		if !ok || len(nums) == 0 || len(nums) > 40 {
			t.Fatalf("bad generated input %q", in)
		}
	}
}

func TestCheck(t *testing.T) {
	cases := []struct {
		in, out string
		want    bool
	}{
		{"3,1,2", "1,2,3", true},
		{"5", "5", true},
		{"-1,0,1", "-1,0,1", true},
		{"3,1,2", "3,2,1", false},      // wrong order
		{"3,1,2", "1,2", false},        // dropped a number
		{"3,1,2", "1,2,4", false},      // invented a number
		{"3,1,1", "1,1,3", true},       // duplicates kept
		{"3,1,1", "1,3,3", false},      // duplicates changed
		{"3,1,2", "", false},           // empty answer
		{"3,1,2", "1, 2, 3", true},     // spaces tolerated
		{"3,1,2", "one,two,three", false},
	}
	for _, c := range cases {
		if got := Check(c.in, c.out); got != c.want {
			t.Fatalf("Check(%q, %q) = %v, want %v", c.in, c.out, got, c.want)
		}
	}
}
