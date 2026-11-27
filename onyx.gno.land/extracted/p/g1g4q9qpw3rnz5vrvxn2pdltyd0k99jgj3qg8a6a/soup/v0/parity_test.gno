package soup

import "testing"

// Same answers as the reference filter on every case (parity_expected_test.gno).
func parity(t *testing.T, from, to int) {
	for _, c := range parityCases[from:min(to, len(parityCases))] {
		if got := Toxic(c[0]); got != c[1] {
			t.Errorf("toxic %q: got %q, want %q", c[0], got, c[1])
		}
		if got := Secret(c[0]); got != c[2] {
			t.Errorf("secret %q: got %q, want %q", c[0], got, c[2])
		}
	}
}

func TestParity1(t *testing.T) { parity(t, 0, 140) }
func TestParity2(t *testing.T) { parity(t, 140, 280) }
func TestParity3(t *testing.T) { parity(t, 280, 420) }
func TestParity4(t *testing.T) { parity(t, 420, 600) }
