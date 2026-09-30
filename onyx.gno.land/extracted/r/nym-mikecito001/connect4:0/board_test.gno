package connect4

import "testing"

func play(b *board, p byte, colsPlayed ...int) (int, int) {
	c, r := 0, 0
	for _, c = range colsPlayed {
		r = b.drop(c, p)
	}
	return c, r
}

func TestWins(t *testing.T) {
	cases := []struct {
		name  string
		setup func(b *board) (int, int)
		want  bool
	}{
		{"horizontal", func(b *board) (int, int) { return play(b, 1, 0, 1, 2, 3) }, true},
		{"vertical", func(b *board) (int, int) { return play(b, 1, 4, 4, 4, 4) }, true},
		{"three only", func(b *board) (int, int) { return play(b, 1, 0, 1, 2) }, false},
		{"diagonal up", func(b *board) (int, int) {
			play(b, 2, 1, 2, 2, 3, 3, 3)
			return play(b, 1, 0, 1, 2, 3)
		}, true},
		{"diagonal down", func(b *board) (int, int) {
			play(b, 2, 3, 3, 3, 2, 2, 1)
			return play(b, 1, 3, 2, 1, 0)
		}, true},
		{"gap breaks line", func(b *board) (int, int) { return play(b, 1, 0, 1, 3, 4) }, false},
	}
	for _, tc := range cases {
		var b board
		c, r := tc.setup(&b)
		if got := b.wins(c, r); got != tc.want {
			t.Errorf("%s: wins=%v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestDropFullColumn(t *testing.T) {
	var b board
	for i := 0; i < rows; i++ {
		if b.drop(0, 1) != i {
			t.Fatalf("drop %d landed on wrong row", i)
		}
	}
	if b.drop(0, 1) != -1 {
		t.Fatal("drop into full column should return -1")
	}
}

func TestWinLine(t *testing.T) {
	var b board
	if c, r := play(&b, 1, 0, 1, 2); b.winLine(c, r) != nil {
		t.Fatal("three in a row is not a win")
	}
	c, r := play(&b, 1, 3)
	line := b.winLine(c, r)
	if len(line) != 4 {
		t.Fatalf("want 4 winning cells, got %v", line)
	}
	for i, cell := range line {
		if cell != [2]int{i, 0} {
			t.Fatalf("cell %d = %v, want [%d 0]", i, cell, i)
		}
	}
}
