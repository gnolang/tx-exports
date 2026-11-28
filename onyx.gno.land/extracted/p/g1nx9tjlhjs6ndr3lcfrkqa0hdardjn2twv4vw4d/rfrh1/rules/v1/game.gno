package rules

// Game is a game in progress. It is a plain value owned by whoever created
// it; bots never get a reference to it, only Views.
type Game struct {
	m      Map
	cells  []uint8
	head   [2]Point
	turn   int
	moves  []byte
	winner int
	death  [2]int
	facing [2]Dir

	// scratch space for View.Reach, reused to avoid allocations per call
	mark  []uint32
	gen   uint32
	queue []int
}

// NewGame starts a game on m.
func NewGame(m Map) *Game {
	g := &Game{m: m, cells: make([]uint8, m.w*m.h), winner: going, mark: make([]uint32, m.w*m.h), queue: make([]int, 0, m.w*m.h)}
	for i, w := range m.wall {
		if w {
			g.cells[i] = Wall
		}
	}
	for side := 0; side < 2; side++ {
		p, f := m.Start(side)
		g.head[side] = p
		g.facing[side] = f
		g.cells[p.Y*m.w+p.X] = uint8(TrailA + side)
	}
	return g
}

// Over reports whether the game has ended.
func (g *Game) Over() bool { return g.winner != going }

// Turn is the number of turns played.
func (g *Game) Turn() int { return g.turn }

// Map returns the game's map.
func (g *Game) Map() Map { return g.m }

// Head returns a side's head in board coordinates.
func (g *Game) Head(side int) Point { return g.head[side] }

// Cell returns Empty, Wall, TrailA or TrailB. Outside the board is Wall.
func (g *Game) Cell(x, y int) int {
	if x < 0 || y < 0 || x >= g.m.w || y >= g.m.h {
		return Wall
	}
	return int(g.cells[y*g.m.w+x])
}

// View returns the read-only view a side's bot sees.
func (g *Game) View(side int) View { return View{g: g, side: side} }

// Apply resolves one turn from two move symbols (0-3 a direction in BOARD
// coordinates, 4 crashed). It is the only place the rules live; Play and
// Replay both go through it.
func (g *Game) Apply(symA, symB int) {
	if g.Over() {
		panic("rules: game is over")
	}
	sym := [2]int{symA, symB}
	var next [2]Point
	for s := 0; s < 2; s++ {
		if sym[s] < 0 || sym[s] > crashed {
			panic("rules: bad move symbol")
		}
		if sym[s] == crashed {
			g.death[s] = Crashed
			continue
		}
		next[s] = g.head[s].Step(Dir(sym[s]))
		switch g.Cell(next[s].X, next[s].Y) {
		case Empty:
		case Wall:
			g.death[s] = HitWall
		default:
			g.death[s] = HitTrail
		}
	}
	if g.death[0] == Alive && g.death[1] == Alive && next[0] == next[1] {
		g.death[0], g.death[1] = HitHead, HitHead
	}
	g.moves = append(g.moves, byte('a'+5*symA+symB))
	g.turn++
	deadA, deadB := g.death[0] != Alive, g.death[1] != Alive
	switch {
	case deadA && deadB:
		g.winner = Draw
		return
	case deadA:
		g.winner = WinB
		return
	case deadB:
		g.winner = WinA
		return
	}
	for s := 0; s < 2; s++ {
		g.head[s] = next[s]
		g.facing[s] = Dir(sym[s])
		g.cells[next[s].Y*g.m.w+next[s].X] = uint8(TrailA + s)
	}
}

// Result returns the outcome so far.
func (g *Game) Result() Result {
	return Result{Winner: g.winner, Turns: g.turn, DeathA: g.death[0], DeathB: g.death[1], Match: g.String()}
}

// String is the canonical match string: "v1.<mapkey>.<moves>".
func (g *Game) String() string { return "v1." + g.m.Key() + "." + string(g.moves) }

// Result is the outcome of a finished (or abandoned) game.
type Result struct {
	Winner int // Draw, WinA or WinB; -1 while the game is still going
	Turns  int
	DeathA int
	DeathB int
	Match  string
}

// Play runs a full game between two bots. A bot that panics or returns an
// invalid direction crashes that turn. A panic in a bot declared in an /r/
// realm aborts the whole transaction instead (Gno semantics); callers that
// need to survive that must not run untrusted realm code.
func Play(a, b Bot, m Map) Result {
	g := NewGame(m)
	g.Advance(a, b, -1)
	return g.Result()
}

// Advance plays up to n more turns (all remaining turns if n < 0) and
// returns how many were played. Together with ReplayTo it lets a long game
// be played across several transactions.
func (g *Game) Advance(a, b Bot, n int) int {
	played := 0
	for !g.Over() && (n < 0 || played < n) {
		symA := ask(a, g.View(SideA))
		symB := ask(b, g.View(SideB))
		if symB != crashed {
			symB = int(Dir(symB).Opposite()) // B answered in its rotated frame
		}
		g.Apply(symA, symB)
		played++
	}
	return played
}

// ask calls a bot and converts a panic or invalid answer into a crash.
func ask(bot Bot, v View) (sym int) {
	defer func() {
		if r := recover(); r != nil {
			sym = crashed
		}
	}()
	if bot == nil {
		return crashed
	}
	d := bot(v)
	if !d.Valid() {
		return crashed
	}
	return int(d)
}

// reach counts empty cells reachable from board cell (x, y), including it,
// stopping at limit. A non-empty start counts 0. It works on flat indexes
// with local slices because every call and field access costs gas.
func (g *Game) reach(x, y, limit int) int {
	w, h := g.m.w, g.m.h
	cells := g.cells
	if x < 0 || y < 0 || x >= w || y >= h || cells[y*w+x] != Empty || limit <= 0 {
		return 0
	}
	g.gen++
	gen := g.gen
	mark := g.mark
	q := g.queue[:0]
	c := y*w + x
	mark[c] = gen
	q = append(q, c)
	last := w*h - w
	for i := 0; i < len(q) && len(q) < limit; i++ {
		c = q[i]
		cx := c % w
		if cx > 0 {
			if n := c - 1; cells[n] == Empty && mark[n] != gen {
				mark[n] = gen
				q = append(q, n)
			}
		}
		if cx < w-1 {
			if n := c + 1; cells[n] == Empty && mark[n] != gen {
				mark[n] = gen
				q = append(q, n)
			}
		}
		if c >= w {
			if n := c - w; cells[n] == Empty && mark[n] != gen {
				mark[n] = gen
				q = append(q, n)
			}
		}
		if c < last {
			if n := c + w; cells[n] == Empty && mark[n] != gen {
				mark[n] = gen
				q = append(q, n)
			}
		}
	}
	g.queue = q
	if len(q) > limit {
		return limit
	}
	return len(q)
}
