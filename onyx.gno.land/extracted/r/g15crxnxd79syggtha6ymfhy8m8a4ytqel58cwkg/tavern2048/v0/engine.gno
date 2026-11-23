package tavern2048

// engine.gno — pure 2048 board logic for Tavern2048.
//
// No chain calls, no IO: a deterministic, fully unit-tested core that the
// realm functions in tavern2048.gno wrap. Same inputs, same board, always.

const N = 4

const DIR_UP = 0
const DIR_RIGHT = 1
const DIR_DOWN = 2
const DIR_LEFT = 3

// Board is one 4x4 game. Zero is an empty cell.
type Board struct {
	Cells [N][N]int `json:"cells"`
	Score int       `json:"score"`
	Moves int       `json:"moves"`
	Over  bool      `json:"over"`
}

// NewBoard returns a fresh board with the two starting tiles.
func NewBoard() Board {
	var b Board
	b.Cells[1][1] = 2
	b.Cells[0][2] = 2
	return b
}

// NewBoardSeeded returns a fresh board whose two starting tiles are placed
// from seed, so every game starts differently but reproducibly.
func NewBoardSeeded(seed int) Board {
	var b Board
	a := lcg(seed) % (N * N)
	c := lcg(seed+1) % (N*N - 1)
	if c >= a {
		c++
	}
	b.Cells[a/N][a%N] = 2
	v := 2
	if lcg(seed+2)%8 == 0 {
		v = 4
	}
	b.Cells[c/N][c%N] = v
	return b
}

// slideRowLeft collapses a row to the left, merging equal neighbours once.
// Returns the new row and the points added by the merges.
func slideRowLeft(row [N]int) (out [N]int, gained int) {
	// 1. strip zeros
	nz := [N]int{}
	cnt := 0
	for i := 0; i < N; i++ {
		if row[i] != 0 {
			nz[cnt] = row[i]
			cnt++
		}
	}
	// 2. single pass: merge only original adjacent pairs (each tile at most
	//    once per move) — the canonical 2048 rule.
	merged := [N]int{}
	m := 0
	i := 0
	for i < cnt {
		if i+1 < cnt && nz[i] == nz[i+1] {
			merged[m] = nz[i] * 2
			gained += nz[i] * 2
			m++
			i += 2
		} else {
			merged[m] = nz[i]
			m++
			i++
		}
	}
	for j := 0; j < N; j++ {
		out[j] = merged[j]
	}
	return out, gained
}

// applyDir runs a full-board move. It returns the new board, the gained
// score and whether the board changed at all.
func applyDir(b [N][N]int, dir int) (nb [N][N]int, gained int, moved bool) {
	nb = b
	for i := 0; i < N; i++ {
		row := [N]int{}
		for j := 0; j < N; j++ {
			switch dir {
			case DIR_UP:
				row[j] = b[j][i]
			case DIR_DOWN:
				row[j] = b[N-1-j][i]
			case DIR_LEFT:
				row[j] = b[i][j]
			case DIR_RIGHT:
				row[j] = b[i][N-1-j]
			}
		}
		slid, g := slideRowLeft(row)
		gained += g
		for j := 0; j < N; j++ {
			switch dir {
			case DIR_UP:
				nb[j][i] = slid[j]
			case DIR_DOWN:
				nb[N-1-j][i] = slid[j]
			case DIR_LEFT:
				nb[i][j] = slid[j]
			case DIR_RIGHT:
				nb[i][N-1-j] = slid[j]
			}
		}
	}
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			if nb[i][j] != b[i][j] {
				moved = true
			}
		}
	}
	return nb, gained, moved
}

// HasMove reports whether any move is still possible.
func HasMove(b [N][N]int) bool {
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			if b[i][j] == 0 {
				return true
			}
			if j+1 < N && b[i][j] == b[i][j+1] {
				return true
			}
			if i+1 < N && b[i][j] == b[i+1][j] {
				return true
			}
		}
	}
	return false
}

// lcg advances a deterministic PRNG from a seed; value in [0,1024).
func lcg(seed int) int {
	x := seed*1103515245 + 12345
	x &= 0x7fffffff
	return x % 1024
}

// Itoa is a dependency-free int->string for realm Render.
func Itoa(x int) string {
	if x == 0 {
		return "0"
	}
	neg := x < 0
	if neg {
		x = -x
	}
	var b []byte
	for x > 0 {
		b = append(b, byte('0'+x%10))
		x /= 10
	}
	if neg {
		b = append(b, '-')
	}
	s := ""
	for i := len(b) - 1; i >= 0; i-- {
		s += string(b[i])
	}
	return s
}

// Move applies a direction (0=up,1=right,2=down,3=left) to the board,
// awards merge points and spawns one new tile from the block-height seed.
// spawnSeed makes the spawn reproducible: pass blockheight() on chain.
// Returns the updated board and a human-readable outcome.
func (b *Board) Move(dir int, spawnSeed int) (ok bool, msg string) {
	if b.Over {
		return false, "game over"
	}
	if dir < DIR_UP || dir > DIR_LEFT {
		return false, "invalid dir"
	}
	nb, gained, moved := applyDir(b.Cells, dir)
	if !moved {
		return false, "no change"
	}
	b.Cells = nb
	b.Score += gained
	b.Moves++
	if !HasMove(b.Cells) {
		b.Over = true
		return true, "game over"
	}
	// spawn: 2 with 87.5% chance, 4 with 12.5%, cell picked deterministically
	v := lcg(spawnSeed*7919 + b.Score*2654435761 + b.Moves*97)
	val := 2
	if v%8 == 0 {
		val = 4
	}
	var empty [][2]int
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			if b.Cells[i][j] == 0 {
				empty = append(empty, [2]int{i, j})
			}
		}
	}
	if len(empty) > 0 {
		cell := empty[lcg(v+1)%len(empty)]
		b.Cells[cell[0]][cell[1]] = val
	}
	return true, "score " + Itoa(b.Score)
}
