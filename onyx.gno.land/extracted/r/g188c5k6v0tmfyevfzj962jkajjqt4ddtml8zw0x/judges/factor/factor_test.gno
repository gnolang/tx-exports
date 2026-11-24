package factor

import "testing"

func TestInputsInRange(t *testing.T) {
	ins := Inputs(1)
	if len(ins) != 6 {
		t.Fatalf("want 6 inputs, got %d", len(ins))
	}
	for _, in := range ins {
		if !Check(in, factorize(in)) {
			t.Fatalf("own factorization of %q rejected", in)
		}
	}
	if Inputs(2)[0] == ins[0] {
		t.Fatal("different seeds must give different inputs")
	}
}

func TestCheck(t *testing.T) {
	cases := []struct {
		in, out string
		want    bool
	}{
		{"84", "2*2*3*7", true},
		{"13", "13", true},
		{"84", "7*3*2*2", false},  // not ascending
		{"84", "2*2*21", false},   // 21 is not prime
		{"84", "2*2*3", false},    // product too small
		{"84", "2*2*3*7*1", false}, // 1 is not prime
		{"84", "84", false},       // 84 is not prime
		{"84", "", false},
		{"1", "1", false}, // out of range
	}
	for _, c := range cases {
		if got := Check(c.in, c.out); got != c.want {
			t.Fatalf("Check(%q, %q) = %v, want %v", c.in, c.out, got, c.want)
		}
	}
}

// factorize is only used by the test, to prove generated inputs are solvable.
func factorize(in string) string {
	n := uint64(0)
	for i := 0; i < len(in); i++ {
		n = n*10 + uint64(in[i]-'0')
	}
	out := ""
	for d := uint64(2); d*d <= n; d++ {
		for n%d == 0 {
			if out != "" {
				out += "*"
			}
			out += utoa(d)
			n /= d
		}
	}
	if n > 1 {
		if out != "" {
			out += "*"
		}
		out += utoa(n)
	}
	return out
}

func utoa(n uint64) string {
	if n == 0 {
		return "0"
	}
	s := ""
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	return s
}
