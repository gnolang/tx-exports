package gen

// room is one room of the chain, with the canonical frame its pattern is drawn
// in: w x h tiles, entered from the west at A = (0, ay) through a door at
// (-1, ay), left at B, the tile before the exit door: (w-1, by) through (w, by)
// when the room runs straight, (bx, 0) through (bx, -1) when it turns. The
// frame maps onto the room's real rectangle by an optional transpose (tr) and
// mirrors (fx, fy), chosen so that canonical west is the side the route enters.
type room struct {
	x0, y0, aw, ah int // interior rectangle on the floor
	tr, fx, fy     bool
	w, h           int
	ay             int
	turn           bool
	bx, by         int
	base, sx, sy   int // tile index of canonical (lx, ly) is base + lx*sx + ly*sy
	in, out        int // wall tiles the route enters and leaves by
	cp             int // where the walk waits before the room: its entry door, or the start
	last           bool
	pat            uint8
	steps          [maxSteps]step
	ns             int
}

// orient sets the frame from the entry side sIn and exit side sOut (0 N, 1 E,
// 2 S, 3 W) and the entry and exit wall tiles; flip picks the free mirror of a
// straight room.
func (r *room) orient(b *builder, sIn, sOut, tIn, tOut int, flip bool) {
	switch sIn {
	case 3:
		r.tr, r.fx, r.fy = false, false, flip
	case 1:
		r.tr, r.fx, r.fy = false, true, flip
	case 0:
		r.tr, r.fx, r.fy = true, flip, false
	default:
		r.tr, r.fx, r.fy = true, flip, true
	}
	r.turn = sOut != (sIn+2)&3
	if r.turn {
		// Canonical north must land on sOut.
		if r.tr {
			r.fx = sOut == 1
		} else {
			r.fy = sOut == 2
		}
	}
	r.w, r.h = r.aw, r.ah
	if r.tr {
		r.w, r.h = r.ah, r.aw
	}
	// at() as strides: a step in canonical x or y is a fixed index step.
	du, dv := 1, b.w
	r.base = r.y0*b.w + r.x0
	if r.fx {
		du = -1
		r.base += r.aw - 1
	}
	if r.fy {
		dv = -b.w
		r.base += (r.ah - 1) * b.w
	}
	r.sx, r.sy = du, dv
	if r.tr {
		r.sx, r.sy = dv, du
	}
	r.in, r.out, r.cp = tIn, tOut, tIn
	_, r.ay = r.local(b, tIn)
	ex, ey := r.local(b, tOut)
	if r.turn {
		r.bx, r.by = ex, 0
	} else {
		r.bx, r.by = r.w-1, ey
	}
}

// at maps canonical (lx, ly) to a tile index; -1 and w/h reach the walls.
func (r *room) at(b *builder, lx, ly int) int {
	return r.base + lx*r.sx + ly*r.sy
}

// local is the inverse of at.
func (r *room) local(b *builder, i int) (int, int) {
	u, v := i%b.w-r.x0, i/b.w-r.y0
	if r.fx {
		u = r.aw - 1 - u
	}
	if r.fy {
		v = r.ah - 1 - v
	}
	if r.tr {
		return v, u
	}
	return u, v
}

// face maps a canonical side or facing (0 N, 1 E, 2 S, 3 W) onto the floor.
func (r *room) face(s int) int {
	dx, dy := sideVec(s)
	if r.tr {
		dx, dy = dy, dx
	}
	if r.fx {
		dx = -dx
	}
	if r.fy {
		dy = -dy
	}
	return vecSide(dx, dy)
}

func (r *room) in2(lx, ly int) bool {
	return lx >= 0 && ly >= 0 && lx < r.w && ly < r.h
}

// fromA is the walking distance from A ignoring obstacles.
func (r *room) fromA(lx, ly int) int {
	d := ly - r.ay
	if d < 0 {
		d = -d
	}
	return lx + d
}

// addStep appends a plan step. More than maxSteps is a pattern bug: it panics.
func (r *room) addStep(op uint8, at, dir int) {
	if r.ns >= maxSteps {
		panic("gen: more than maxSteps plan steps in a room")
	}
	r.steps[r.ns] = step{op: op, at: at, dir: dir}
	r.ns++
}

// Canonical drawing helpers. Each takes the room by pointer and works in its
// frame.

func (b *builder) put(r *room, lx, ly int, c byte) {
	i := r.at(b, lx, ly)
	b.tiles[i] = c
}

func (b *builder) get(r *room, lx, ly int) byte {
	return b.tiles[r.at(b, lx, ly)]
}

// fill sets every interior tile of r to c.
func (b *builder) fill(r *room, c byte) {
	for y := r.y0; y < r.y0+r.ah; y++ {
		for i := y*b.w + r.x0; i < y*b.w+r.x0+r.aw; i++ {
			b.tiles[i] = c
		}
	}
}

func (b *builder) monL(r *room, kind uint8, lx, ly, facing int, phase uint8) bool {
	return b.addMon(kind, r.at(b, lx, ly), uint8(r.face(facing)), phase)
}

func (b *builder) gotoL(r *room, lx, ly int) {
	r.addStep(opGoto, r.at(b, lx, ly), 0)
}

// dashL dashes toward canonical side s, landing on canonical (lx, ly).
func (b *builder) dashL(r *room, s, lx, ly int) {
	r.addStep(opDash, r.at(b, lx, ly), r.face(s))
}

func (b *builder) gotoOut(r *room) {
	r.addStep(opGoto, r.out, 0)
}

// zroute lays the default route from A to B in b.rtx/b.rty: east along the
// entry row to column cx, then along column cx to B's row, then east to B. A
// turning room goes east to bx, then north to B.
func (b *builder) zroute(r *room, cx int) {
	b.cur = r
	b.rn = 0
	if r.turn {
		for x := 0; x <= r.bx; x++ {
			b.rpush(x, r.ay)
		}
		for y := r.ay - 1; y >= 0; y-- {
			b.rpush(r.bx, y)
		}
		return
	}
	for x := 0; x <= cx; x++ {
		b.rpush(x, r.ay)
	}
	for y := r.ay + 1; y <= r.by; y++ {
		b.rpush(cx, y)
	}
	for y := r.ay - 1; y >= r.by; y-- {
		b.rpush(cx, y)
	}
	for x := cx + 1; x < r.w; x++ {
		b.rpush(x, r.by)
	}
}

// wroute lays a winding route from A to B: east along the entry row, a jog to
// a random middle row, east again, then a jog to B's row (a turning room ends
// with its climb to B). Each jog sits on its own column, so the route bends up
// to four times. Rooms too narrow for two jogs get the plain zroute.
func (b *builder) wroute(r *room) {
	end := r.w - 1
	if r.turn {
		end = r.bx
	}
	if end < 3 || r.h < 3 {
		b.zroute(r, b.r.intn(r.w))
		return
	}
	b.cur = r
	b.rn = 0
	c1 := b.r.intn(end - 1)
	c2 := c1 + 2 + b.r.intn(end-c1-1)
	if c2 > end {
		c2 = end
	}
	mid := b.r.intn(r.h)
	if r.turn && mid == 0 {
		mid = r.h - 1
	}
	if mid == r.ay {
		mid = (mid + 1 + b.r.intn(r.h-1)) % r.h
		if r.turn && mid == 0 {
			mid = 1
		}
	}
	y := r.ay
	b.rpush(0, y)
	for x := 0; x <= end; x++ {
		if x > 0 {
			b.rpush(x, y)
		}
		to := -1
		switch {
		case x == c1:
			to = mid
		case x == c2 && !r.turn:
			to = r.by
		case x == end && r.turn:
			to = 0
		}
		for to >= 0 && y != to {
			if y < to {
				y++
			} else {
				y--
			}
			b.rpush(x, y)
		}
	}
}

func (b *builder) rpush(x, y int) {
	if b.rn == 0 {
		b.stamp++
	}
	b.rtx[b.rn], b.rty[b.rn] = x, y
	b.rn++
	b.rmark[b.cur.at(b, x, y)] = b.stamp
}

// onRoute reports whether canonical (x, y) of the current room is on its route.
func (b *builder) onRoute(x, y int) bool {
	return b.cur.in2(x, y) && b.rmark[b.cur.at(b, x, y)] == b.stamp
}

// nearRoute reports whether (x, y) is on the route or next to it. Route marks
// sit on tile indices, and the room's walls are never marked, so the four
// neighbors need no bounds check.
func (b *builder) nearRoute(x, y int) bool {
	i := b.cur.at(b, x, y)
	st := b.stamp
	return b.rmark[i] == st || b.rmark[i-1] == st || b.rmark[i+1] == st ||
		b.rmark[i-b.w] == st || b.rmark[i+b.w] == st
}
