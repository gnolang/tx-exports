package hex

import "math"

// Axial step of each direction on the flat-top grid (q east along the
// columns, r down a column), matching scripts/gen_board_data.py.
var dirStep = [6][2]int{{0, -1}, {1, -1}, {1, 0}, {0, 1}, {-1, 1}, {-1, 0}}

// Step returns the axial (q, r) offset of one hex in direction d.
func (d Dir) Step() (q, r int) { return dirStep[d][0], dirStep[d][1] }

// Coords returns the axial coordinates of a hex.
func (b *Board) Coords(id string) (q, r int, ok bool) {
	i := b.Index(id)
	if i < 0 {
		return 0, 0, false
	}
	return b.qr[i][0], b.qr[i][1], true
}

// Distance is the range between two hexes in hexes along the shortest route
// over the board (rule 13.51), or -1 when either hex is unknown.
func (b *Board) Distance(from, to string) int {
	src, dst := b.Index(from), b.Index(to)
	if src < 0 || dst < 0 {
		return -1
	}
	if src == dst {
		return 0
	}
	dist := make([]int, len(b.ids))
	for i := range dist {
		dist[i] = -1
	}
	dist[src] = 0
	queue := []int{src}
	for len(queue) > 0 {
		i := queue[0]
		queue = queue[1:]
		for _, j := range b.nbr[i] {
			if j < 0 || dist[j] >= 0 {
				continue
			}
			dist[j] = dist[i] + 1
			if j == dst {
				return dist[j]
			}
			queue = append(queue, j)
		}
	}
	return -1
}

// InAimZone reports whether target lies in the aim zone of a character at
// from facing f (rule 8.32): its own hex and every hex in or between its
// ahead-left and ahead-right rows, i.e. the 120° cone spanned by those two
// directions.
func (b *Board) InAimZone(from string, f Dir, target string) bool {
	q0, r0, ok := b.Coords(from)
	q1, r1, ok2 := b.Coords(target)
	if !ok || !ok2 || !f.Valid() {
		return false
	}
	dq, dr := q1-q0, r1-r0
	uq, ur := Dir((int(f) + 5) % 6).Step() // ahead left
	wq, wr := Dir((int(f) + 1) % 6).Step() // ahead right
	// Solve a*u + b*w = d; the step vectors 120° apart have determinant ±1.
	det := uq*wr - ur*wq
	a := (dq*wr - dr*wq) / det
	c := (uq*dr - ur*dq) / det
	return a >= 0 && c >= 0
}

// LongDir is the direction from target that continues the line drawn from
// shooter through target (rule 14.32): the "Long" hex of a direction card is
// the target's neighbour that way. When the line runs between two hexes the
// one closest to it wins, lowest direction first; in a shared hex it is the
// shooter's facing.
func (b *Board) LongDir(shooter, target string, shooterFacing Dir) Dir {
	q0, r0, ok := b.Coords(shooter)
	q1, r1, ok2 := b.Coords(target)
	if !ok || !ok2 || (q0 == q1 && r0 == r1) {
		return shooterFacing
	}
	x, y := planar(q1-q0, r1-r0)
	best, bestCos := Dir(0), -2.0
	for d := 0; d < 6; d++ {
		sq, sr := Dir(d).Step()
		sx, sy := planar(sq, sr)
		cos := (x*sx + y*sy) / (math.Sqrt(x*x+y*y) * math.Sqrt(sx*sx+sy*sy))
		if cos > bestCos+1e-9 {
			best, bestCos = Dir(d), cos
		}
	}
	return best
}

// planar maps an axial offset to flat-top pixel-like coordinates (x east, y south).
func planar(q, r int) (x, y float64) {
	return 1.5 * float64(q), math.Sqrt(3) * (float64(r) + float64(q)/2)
}
