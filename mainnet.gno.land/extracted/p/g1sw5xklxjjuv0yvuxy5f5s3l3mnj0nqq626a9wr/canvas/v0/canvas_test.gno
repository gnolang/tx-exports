package canvas

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestNewRejectsBadSizes(t *testing.T) {
	for _, tc := range []struct{ w, h int }{{0, 1}, {1, 0}, {-1, 1}, {MaxSide + 1, 1}, {1, MaxSide + 1}} {
		func() {
			defer func() {
				if r := recover(); r == nil {
					t.Errorf("New(%d, %d) did not panic", tc.w, tc.h)
				}
			}()
			New(tc.w, tc.h)
		}()
	}
}

func TestSetGet(t *testing.T) {
	c := New(4, 3)
	uassert.Equal(t, 4, c.Width())
	uassert.Equal(t, 3, c.Height())
	uassert.Equal(t, 0, c.Painted())
	uassert.Equal(t, Blank, c.Get(3, 2))

	c.Set(Pixel{X: 3, Y: 2, Color: 6})
	uassert.Equal(t, byte(6), c.Get(3, 2))
	uassert.Equal(t, 1, c.Painted())

	// Repainting the same pixel does not count twice.
	c.Set(Pixel{X: 3, Y: 2, Color: 7})
	uassert.Equal(t, byte(7), c.Get(3, 2))
	uassert.Equal(t, 1, c.Painted())

	// Other rows stay unallocated and blank.
	uassert.Equal(t, Blank, c.Get(0, 0))
	uassert.True(t, c.rows[0] == nil, "row 0 should stay nil")
}

func TestCheck(t *testing.T) {
	c := New(2, 2)
	tests := []struct {
		name string
		p    Pixel
		err  error
	}{
		{"ok", Pixel{0, 0, 1}, nil},
		{"ok max", Pixel{1, 1, MaxColor}, nil},
		{"x negative", Pixel{-1, 0, 1}, ErrOutOfRange},
		{"y negative", Pixel{0, -1, 1}, ErrOutOfRange},
		{"x too big", Pixel{2, 0, 1}, ErrOutOfRange},
		{"y too big", Pixel{0, 2, 1}, ErrOutOfRange},
		{"blank color", Pixel{0, 0, Blank}, ErrInvalidColor},
		{"color too big", Pixel{0, 0, MaxColor + 1}, ErrInvalidColor},
	}
	for _, tc := range tests {
		got := c.Check(tc.p)
		if got != tc.err {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.err)
		}
	}
}

func TestRows(t *testing.T) {
	c := New(3, 3)
	uassert.Equal(t, "000000000", c.Rows(0, 3))
	c.Set(Pixel{X: 1, Y: 1, Color: 15})
	c.Set(Pixel{X: 2, Y: 2, Color: 10})
	uassert.Equal(t, "000", c.Rows(0, 1))
	uassert.Equal(t, "0f0", c.Rows(1, 2))
	uassert.Equal(t, "0f000a", c.Rows(1, 3))
	uassert.Equal(t, "", c.Rows(2, 2))

	for _, r := range [][2]int{{-1, 1}, {0, 4}, {2, 1}} {
		func() {
			defer func() {
				if rec := recover(); rec == nil {
					t.Errorf("Rows(%d, %d) did not panic", r[0], r[1])
				}
			}()
			c.Rows(r[0], r[1])
		}()
	}
}

func TestParsePixels(t *testing.T) {
	px, err := ParsePixels("0,0,1;5,7,15;")
	uassert.NoError(t, err)
	uassert.Equal(t, 2, len(px))
	if px[0] != (Pixel{0, 0, 1}) || px[1] != (Pixel{5, 7, 15}) {
		t.Errorf("unexpected pixels: %v", px)
	}

	for _, bad := range []string{"", ";", "1,2", "1,2,3,4", "a,2,3", "1,b,3", "1,2,c", "1,2,0", "1,2,16", "1,2,-1"} {
		if _, err := ParsePixels(bad); err == nil {
			t.Errorf("ParsePixels(%q) accepted invalid input", bad)
		}
	}
}

func TestEncodeRoundTrip(t *testing.T) {
	in := []Pixel{{0, 0, 1}, {999, 999, 15}, {3, 4, 8}}
	s := Encode(in)
	uassert.Equal(t, "0,0,1;999,999,15;3,4,8", s)
	out, err := ParsePixels(s)
	uassert.NoError(t, err)
	uassert.Equal(t, len(in), len(out))
	for i := range in {
		if in[i] != out[i] {
			t.Errorf("pixel %d: got %v, want %v", i, out[i], in[i])
		}
	}
}
