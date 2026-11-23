package tavern2048

import "testing"

func TestSlideRowLeft(t *testing.T) {
	out, g := slideRowLeft([N]int{2, 2, 4, 4})
	if out != [N]int{4, 8, 0, 0} || g != 12 {
		t.Fatalf("got %v g=%d", out, g)
	}
	// [2,2,2,2] -> [4,4,0,0] (each tile merges at most once)
	out, g = slideRowLeft([N]int{2, 2, 2, 2})
	if out != [N]int{4, 4, 0, 0} || g != 8 {
		t.Fatalf("got %v g=%d", out, g)
	}
	// no merge
	out, g = slideRowLeft([N]int{0, 0, 2, 4})
	if out != [N]int{2, 4, 0, 0} || g != 0 {
		t.Fatalf("got %v g=%d", out, g)
	}
	// a just-merged tile must not merge again: [4,2,2,0] -> [4,4,0,0]
	out, g = slideRowLeft([N]int{4, 2, 2, 0})
	if out != [N]int{4, 4, 0, 0} || g != 4 {
		t.Fatalf("got %v g=%d", out, g)
	}
	// 4 must not merge across 2: [4,2,4,0] -> [4,2,4,0]
	out, g = slideRowLeft([N]int{4, 2, 4, 0})
	if out != [N]int{4, 2, 4, 0} || g != 0 {
		t.Fatalf("got %v g=%d", out, g)
	}
}

func TestApplyDirAllDirections(t *testing.T) {
	b := [N][N]int{{2, 0, 0, 0}, {2, 4, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}}
	nb, g, moved := applyDir(b, DIR_UP)
	if !moved || nb[0][0] != 4 || g != 4 {
		t.Fatalf("up: %v g=%d", nb, g)
	}
	b = [N][N]int{{2, 2, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}}
	nb, g, moved = applyDir(b, DIR_LEFT)
	if !moved || nb[0][0] != 4 || g != 4 {
		t.Fatalf("left: %v g=%d", nb, g)
	}
	b = [N][N]int{{2, 0, 2, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}}
	nb, g, moved = applyDir(b, DIR_RIGHT)
	if !moved || nb[0][3] != 4 || g != 4 {
		t.Fatalf("right: %v g=%d", nb, g)
	}
	b = [N][N]int{{0, 2, 0, 0}, {0, 2, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}}
	nb, g, moved = applyDir(b, DIR_DOWN)
	if !moved || nb[3][1] != 4 || g != 4 {
		t.Fatalf("down: %v g=%d", nb, g)
	}
}

func TestNoChangeDetection(t *testing.T) {
	// full board, no merges: every direction is a no-op
	b := [N][N]int{{2, 4, 8, 16}, {32, 64, 128, 256}, {512, 1024, 2, 4}, {8, 16, 32, 64}}
	for d := 0; d < 4; d++ {
		_, _, moved := applyDir(b, d)
		if moved {
			t.Fatalf("dir %d should be a no-op", d)
		}
	}
	// left moves, up is a no-op for a lone tile in a column
	b = [N][N]int{{0, 2, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}}
	_, _, moved := applyDir(b, DIR_LEFT)
	if !moved {
		t.Fatal("left should move")
	}
	_, _, moved = applyDir(b, DIR_UP)
	if moved {
		t.Fatal("up should be a no-op")
	}
}

func TestHasMove(t *testing.T) {
	b := [N][N]int{{2, 4, 8, 16}, {32, 64, 128, 256}, {512, 1024, 2, 4}, {8, 16, 32, 64}}
	if HasMove(b) {
		t.Fatal("full board, no merges -> no move")
	}
	b[0][0] = 0
	if !HasMove(b) {
		t.Fatal("a zero cell means a move")
	}
	b = [N][N]int{{2, 2, 8, 16}, {32, 64, 128, 256}, {512, 1024, 4, 8}, {16, 32, 64, 128}}
	if !HasMove(b) {
		t.Fatal("equal neighbours means a move")
	}
}

func TestLcgBounds(t *testing.T) {
	for s := 0; s < 1000; s += 7 {
		v := lcg(s)
		if v < 0 || v >= 1024 {
			t.Fatalf("lcg out of range: %d", v)
		}
	}
}

func TestItoa(t *testing.T) {
	cases := map[int]string{0: "0", 42: "42", 123456: "123456", -7: "-7"}
	for in, want := range cases {
		if got := Itoa(in); got != want {
			t.Fatalf("Itoa(%d)=%s want %s", in, got, want)
		}
	}
}

func isPow2(v int) bool {
	return v >= 2 && (v&(v-1)) == 0
}

func TestGameSim(t *testing.T) {
	b := NewBoard()
	if b.Cells[1][1] != 2 || b.Cells[0][2] != 2 {
		t.Fatalf("start tiles wrong: %v", b)
	}
	moves := 0
	for i := 0; i < 500 && !b.Over; i++ {
		ok, _ := b.Move(i%4, 1000+i)
		if ok {
			moves++
			if b.Score < 0 {
				t.Fatal("negative score")
			}
			for r := 0; r < N; r++ {
				for c := 0; c < N; c++ {
					v := b.Cells[r][c]
					if v != 0 && !isPow2(v) {
						t.Fatalf("bad cell value %d at %d,%d", v, r, c)
					}
				}
			}
		}
	}
	if moves < 20 {
		t.Fatalf("too few moves in sim: %d", moves)
	}
	t.Logf("sim done: moves=%d score=%d over=%v", moves, b.Score, b.Over)
}

func TestSpawnIsReproducible(t *testing.T) {
	a := NewBoard()
	b := NewBoard()
	// same seeds => identical boards
	for i := 0; i < 50; i++ {
		ao, _ := a.Move(i%4, 777+i)
		bo, _ := b.Move(i%4, 777+i)
		if ao != bo {
			t.Fatal("moves diverged unexpectedly")
		}
	}
	if a.Cells != b.Cells || a.Score != b.Score || a.Moves != b.Moves {
		t.Fatal("same seeds must give identical state")
	}
}

func TestNewBoardSeeded(t *testing.T) {
	for s := 0; s < 200; s++ {
		b := NewBoardSeeded(s)
		tiles := 0
		for i := 0; i < N; i++ {
			for j := 0; j < N; j++ {
				if b.Cells[i][j] != 0 {
					tiles++
				}
			}
		}
		if tiles != 2 {
			t.Fatalf("seed %d: want 2 start tiles, got %d", s, tiles)
		}
	}
	if NewBoardSeeded(42).Cells != NewBoardSeeded(42).Cells {
		t.Fatal("same seed must give same start board")
	}
}
