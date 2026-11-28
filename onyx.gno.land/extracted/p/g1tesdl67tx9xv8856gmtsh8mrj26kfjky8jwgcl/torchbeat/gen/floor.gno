// Package gen builds the Daily Descent: ten floors per UTC day, each made from
// (day, floor) alone, each with a witness route that proves it can be cleared.
//
// A floor is a chain of rooms on a small grid of cells (two to six cells, some
// merged into halls). The route runs room to room through one-tile doors; each
// room holds one pattern (a spike run, a dash gap, an archer gallery...) drawn
// in a canonical frame where the route enters from the west, then rotated and
// mirrored onto the room.
//
// Layout draws the floor without running the engine, cheaply enough for a
// realm to call on every reveal. Make adds the witness: the generator walks the
// plan the patterns left (waypoints, dashes, the beat to set off on) on the
// real engine, beat by beat, trying actions on a copy of the game and keeping
// the first that costs no HP. That walk costs a few times what replaying its
// log does, which is why the realm uses Layout and only clients and the range
// proof use Make.
package gen

import (
	"strconv"
	"strings"

	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"
)

// Floors is the number of floors in a day's descent.
const Floors = 10

// Floor is one generated floor: what sim.Parse takes, plus the witness log that
// clears it with zero damage under every relic (Make only; Layout leaves it
// empty), the floor's main pattern and whether it holds the day's chest.
type Floor struct {
	Grid, Props, Objective, Witness string
	Pattern                         uint8
	HasChest                        bool
}

// DayOf returns the UTC day number of a unix time (seconds since 1970-01-01).
// Times before 1970 map to day 0.
func DayOf(unix int64) uint32 {
	if unix < 0 {
		return 0
	}
	return uint32(unix / 86400)
}

// RoomID names one floor of one attempt for the commit-reveal helper:
// prefix:day:n:attempt in decimal. The commit preimage separates its fields
// with '|', so a prefix holding one panics.
func RoomID(prefix string, day uint32, n uint8, attempt uint32) string {
	if strings.Contains(prefix, "|") {
		panic("gen: RoomID prefix contains |")
	}
	return prefix + ":" + strconv.FormatUint(uint64(day), 10) + ":" +
		strconv.FormatUint(uint64(n), 10) + ":" + strconv.FormatUint(uint64(attempt), 10)
}

// A layout whose main pattern fits no room is drawn again, up to maxTries
// times; then up to maxFallbacks fallback layouts (the main pattern at its
// lightest, minors only as the band's monster floor needs).
const (
	maxTries     = 6
	maxFallbacks = 10
	walkTrials   = 40000000 // trial beats Make's walk may play: bounds its run time
)

// Layout builds floor n (1..Floors) of the given day without its witness. It
// is what a realm calls: it never runs the engine. It panics outside
// 1..Floors.
func Layout(day uint32, n uint8) Floor {
	f, _ := layout(day, n)
	return f
}

// Make is Layout plus the witness. Witness is empty if the walk fails, which
// the range proof rules out for every day it covers.
func Make(day uint32, n uint8) Floor {
	f, b := layout(day, n)
	m := b.simMap()
	k := &walker{limit: walkTrials}
	if w, ok := k.walk(b, &m); ok {
		f.Witness = w
	}
	return f
}

// ChestWitness returns a log that opens the floor's chest and still clears
// the floor with zero damage under every relic, or "" when the floor has no
// chest or the walk finds no such route. The range proof uses it to show no
// chest strands the hero; it is not the floor's witness.
func ChestWitness(day uint32, n uint8) string {
	f, b := layout(day, n)
	if !f.HasChest {
		return ""
	}
	m := b.simMap()
	k := &walker{limit: walkTrials, chest: b.roomAt(b.chestOut) + 1}
	w, ok := k.walk(b, &m)
	if !ok || !k.cur().Chest {
		return ""
	}
	return w
}

// roomAt returns the room whose interior or entry door holds tile i (0 if
// none does).
func (b *builder) roomAt(i int) int {
	x, y := i%b.w, i/b.w
	for ri := 0; ri < b.nrooms; ri++ {
		r := &b.rooms[ri]
		if x >= r.x0 && y >= r.y0 && x < r.x0+r.aw && y < r.y0+r.ah || ri > 0 && r.in == i {
			return ri
		}
	}
	return 0
}

// layout draws layouts until one places its main pattern, and returns it with
// its builder (which holds the plan the walk follows).
func layout(day uint32, n uint8) (Floor, *builder) {
	if n < 1 || n > Floors {
		panic("gen: floor out of range")
	}
	pats, chest := dayPlan(day)
	r := newRng(day, n)
	var b *builder
	placed := false
	for try := 0; try < maxTries+maxFallbacks && !placed; try++ {
		b = &builder{}
		b.init(&r, n, pats[n-1], n == chest, try >= maxTries)
		placed = b.place()
	}
	if !placed {
		// Never seen in the proven range. Say so rather than name a main
		// pattern the floor does not hold: the range proof fails on it.
		b.pat = patPlain
	}
	obj := "EXIT"
	if b.slay {
		obj = "SLAY"
	}
	return Floor{
		Grid:      b.render(),
		Props:     b.props(),
		Objective: obj,
		Pattern:   b.pat,
		HasChest:  b.chest,
	}, b
}

// bandOf maps a floor to its band: 0 warmup (1-3), 1 combinations (4-7), 2 hard
// (8-9), 3 the SLAY finale (10).
func bandOf(n uint8) int {
	switch {
	case n <= 3:
		return 0
	case n <= 7:
		return 1
	case n <= 9:
		return 2
	}
	return 3
}

// numPairs is the number of unordered pattern pairs. A day leaves one pair out,
// so it plays NumPatterns-2 = Floors patterns, one per floor.
const numPairs = int(NumPatterns) * (int(NumPatterns) - 1) / 2

// dayPlan returns each floor's main pattern (index n-1) and the floor holding the
// chest. The left-out pair's index has the day's parity, so two consecutive days
// always leave out different pairs and play different pattern sets.
func dayPlan(day uint32) ([Floors]uint8, uint8) {
	r := newRng(day, 0)
	k := 2*r.intn(numPairs/2) + int(day%2)
	var used uint32
	for i := uint8(0); i < NumPatterns; i++ {
		for j := i + 1; j < NumPatterns; j++ {
			if k == 0 {
				used = uint32(1)<<i | uint32(1)<<j
			}
			k--
		}
	}
	var pats [Floors]uint8
	pats[Floors-1] = pickPattern(&r, &used, fSlay)
	for n := 0; n < 3; n++ {
		pats[n] = pickPattern(&r, &used, fWarm)
	}
	for n := 3; n < Floors-1; n++ {
		pats[n] = pickPattern(&r, &used, 0)
	}
	return pats, uint8(4 + r.intn(4))
}

// pickPattern draws an unused pattern carrying every bit of flag.
func pickPattern(r *rng, used *uint32, flag uint8) uint8 {
	var cand [NumPatterns]uint8
	nc := 0
	for p := uint8(0); p < NumPatterns; p++ {
		if *used&(uint32(1)<<p) == 0 && patFlags[p]&flag == flag {
			cand[nc] = p
			nc++
		}
	}
	p := cand[r.intn(nc)]
	*used |= uint32(1) << p
	return p
}

// bandCfg is a floor's cell grid: c x r cells with interiors cw x rh, and the
// walks the route may take through it. A walk starts in cell (0, 0) (before
// the floor is mirrored) and moves N/E/S/W; an upper-case move crosses a door,
// a lower-case move merges the next cell into the same room.
type bandCfg struct {
	c, r, wlo, whi, hlo, hhi int
	walks                    []string
}

var bands = [Floors]bandCfg{
	{2, 1, 5, 6, 5, 5, []string{"E"}},
	{3, 1, 4, 5, 5, 5, []string{"EE", "eE", "Ee"}},
	{2, 2, 5, 6, 3, 4, []string{"SE", "ES"}},
	{3, 2, 4, 5, 3, 4, []string{"EES", "ESE", "SEE", "SENE", "ESEN", "SEEN"}},
	{3, 2, 4, 5, 3, 4, []string{"EES", "ESE", "SEE", "SENE", "ESEN", "SEEN"}},
	{3, 2, 5, 5, 3, 4, []string{"SENE", "ESEN", "SEEN", "SENES", "eSE", "SEe"}},
	{3, 2, 5, 5, 3, 4, []string{"SENE", "ESEN", "SEEN", "SENES", "eSE", "SEe"}},
	{3, 2, 5, 6, 4, 5, []string{"SENES", "SENE", "ESEN", "SEEN", "eSEN"}},
	{3, 2, 5, 6, 4, 5, []string{"SENES", "SENE", "ESEN", "SEEN", "eSEN"}},
	{3, 2, 5, 6, 5, 6, []string{"SEe", "ESe", "EEs", "SENe"}},
}

// Sides and facings: 0 N, 1 E, 2 S, 3 W. A sim move action is side+1.
func sideVec(s int) (int, int) {
	switch s & 3 {
	case 0:
		return 0, -1
	case 1:
		return 1, 0
	case 2:
		return 0, 1
	}
	return -1, 0
}

func vecSide(dx, dy int) int {
	switch {
	case dy < 0:
		return 0
	case dx > 0:
		return 1
	case dy > 0:
		return 2
	}
	return 3
}

func sideOf(c byte) int {
	switch c {
	case 'N', 'n':
		return 0
	case 'E', 'e':
		return 1
	case 'S', 's':
		return 2
	}
	return 3
}

const (
	maxCells  = 6
	maxRooms  = 6
	maxSteps  = 8
	maxRoute  = 40
	tileFloor = byte('.')
	tileWall  = byte('#')
	tilePit   = byte('~')
	tileSpike = byte('^')
	tileCrum  = byte('%')
	tilePlate = byte('_')
	tileGate  = byte('|')
	tileChest = byte('C')
	tileStart = byte('@')
	tileExit  = byte('E')
)

// Plan step ops, run by the walker in order, room by room.
const (
	opGoto  uint8 = iota + 1 // walk to tile at
	opDash                   // dash toward side dir, landing on at
	opHunt                   // SLAY: kill every foe left
	opCross                  // dash over the trench toward side dir, from any tile of its near bank
)

type step struct {
	op  uint8
	at  int
	dir int
}

type mon struct {
	kind, facing, phase uint8
	at                  int
}

// builder holds one layout attempt.
type builder struct {
	r        *rng
	n        uint8
	lvl      int
	pat      uint8
	chest    bool
	fallback bool
	slay     bool

	w, h        int
	cols, rows  int
	cw, rh      [3]int
	xs, ys      [3]int
	tiles       [sim.MaxTiles]byte
	mons        [sim.MaxMonsters]mon
	nmons       int
	monCap      int
	gates       int
	start, exit int
	// The chest's tile and the tile outside its room's door (both the chest
	// tile when it sits in a room), for the chest route.
	chestAt, chestOut int
	chestBox          [4]int // the chest's side room and door: x0, y0, x1, y1

	cellC, cellR [maxCells]int
	cellRoom     [maxCells]int
	ncells       int
	used         [3][3]bool
	rooms        [maxRooms]room
	nrooms       int

	// The current room's route (canonical), and route marks: rmark[i] ==
	// stamp for its tiles.
	cur      *room
	rtx, rty [maxRoute]int
	rn       int
	rmark    [sim.MaxTiles]int
	stamp    int
}

func (b *builder) init(r *rng, n uint8, pat uint8, chest, fallback bool) {
	b.r, b.n, b.pat, b.chest, b.fallback = r, n, pat, chest, fallback
	b.lvl = bandOf(n)
	b.slay = n == Floors
	b.monCap = [4]int{3, 6, 7, 10}[b.lvl]
}

// place lays the floor out: cells, rooms, patterns and the chest. It reports
// false when the main pattern fits no room, or the floor would hold nothing
// the engine counts as a hazard or monster.
func (b *builder) place() bool {
	b.layout()
	if !b.placePatterns() {
		return false
	}
	// Patterns draw over whole rooms; the start stays the start.
	b.tiles[b.start] = tileStart
	if b.chest {
		b.placeChest()
	}
	if b.nmons > 0 {
		return true
	}
	for i := 0; i < b.w*b.h; i++ {
		switch b.tiles[i] {
		case tilePit, tileSpike, tileCrum, tilePlate, tileGate:
			return true
		}
	}
	return false
}

// layout sizes the cell grid, picks and mirrors a walk, carves the rooms and
// doors and places the start and the exit.
func (b *builder) layout() {
	cfg := &bands[b.n-1]
	b.cols, b.rows = cfg.c, cfg.r
	sumW, sumH := 0, 0
	for i := 0; i < b.cols; i++ {
		b.cw[i] = b.r.span(cfg.wlo, cfg.whi)
		sumW += b.cw[i]
	}
	for i := 0; i < b.rows; i++ {
		b.rh[i] = b.r.span(cfg.hlo, cfg.hhi)
		sumH += b.rh[i]
	}
	// Trim to the engine's 20 x 14.
	for sumW+b.cols+1 > sim.MaxW {
		i := b.r.intn(b.cols)
		if b.cw[i] > cfg.wlo {
			b.cw[i]--
			sumW--
		}
	}
	for sumH+b.rows+1 > sim.MaxH {
		i := b.r.intn(b.rows)
		if b.rh[i] > cfg.hlo {
			b.rh[i]--
			sumH--
		}
	}
	b.w, b.h = sumW+b.cols+1, sumH+b.rows+1
	b.xs[0], b.ys[0] = 1, 1
	for i := 1; i < b.cols; i++ {
		b.xs[i] = b.xs[i-1] + b.cw[i-1] + 1
	}
	for i := 1; i < b.rows; i++ {
		b.ys[i] = b.ys[i-1] + b.rh[i-1] + 1
	}
	for i := 0; i < b.w*b.h; i++ {
		b.tiles[i] = tileWall
	}

	walk := b.pickWalk(cfg)
	mx, my := b.r.coin(), b.rows > 1 && b.r.coin()
	c, rr := 0, 0
	if mx {
		c = b.cols - 1
	}
	if my {
		rr = b.rows - 1
	}
	var moves [maxCells]int
	var doors [maxCells]bool
	b.ncells = 0
	b.addCell(c, rr, 0)
	for i := 0; i < len(walk); i++ {
		s := sideOf(walk[i])
		if (s == 1 || s == 3) && mx || (s == 0 || s == 2) && my {
			s ^= 2
		}
		dx, dy := sideVec(s)
		c, rr = c+dx, rr+dy
		room := b.cellRoom[b.ncells-1]
		upper := walk[i] < 'a'
		if upper {
			room++
		}
		moves[b.ncells] = s
		doors[b.ncells] = upper
		b.addCell(c, rr, room)
	}
	b.nrooms = b.cellRoom[b.ncells-1] + 1

	// Room rectangles: the union of their cells, walls between merged cells
	// included.
	for k := 0; k < b.nrooms; k++ {
		rm := &b.rooms[k]
		x0, y0, x1, y1 := 99, 99, -1, -1
		for i := 0; i < b.ncells; i++ {
			if b.cellRoom[i] != k {
				continue
			}
			cx0, cy0 := b.xs[b.cellC[i]], b.ys[b.cellR[i]]
			cx1, cy1 := cx0+b.cw[b.cellC[i]]-1, cy0+b.rh[b.cellR[i]]-1
			if cx0 < x0 {
				x0 = cx0
			}
			if cy0 < y0 {
				y0 = cy0
			}
			if cx1 > x1 {
				x1 = cx1
			}
			if cy1 > y1 {
				y1 = cy1
			}
		}
		rm.x0, rm.y0, rm.aw, rm.ah = x0, y0, x1-x0+1, y1-y0+1
		for y := y0; y <= y1; y++ {
			for x := x0; x <= x1; x++ {
				b.tiles[y*b.w+x] = tileFloor
			}
		}
	}

	// Doors, the start and the exit. Room k is entered on side in and left on
	// side out; in/out hold the wall tile on that side (a door, the wall behind
	// the start, or the exit).
	var sIn, sOut [maxRooms]int
	var tIn, tOut [maxRooms]int
	first := (moves[1] + 2) & 3
	sIn[0], tIn[0] = first, b.wallTile(0, first)
	for i := 1; i < b.ncells; i++ {
		if !doors[i] {
			continue
		}
		k := b.cellRoom[i]
		t := b.wallTile(i-1, moves[i])
		b.tiles[t] = tileFloor
		sOut[k-1], tOut[k-1] = moves[i], t
		sIn[k], tIn[k] = (moves[i]+2)&3, t
	}
	lastCell := b.ncells - 1
	last := b.nrooms - 1
	exitSide := moves[lastCell]
	if !b.onBorder(lastCell, exitSide) {
		for s := 0; s < 4; s++ {
			if s != sIn[last] && b.onBorder(lastCell, s) {
				exitSide = s
				break
			}
		}
	}
	sOut[last], tOut[last] = exitSide, b.wallTile(lastCell, exitSide)
	b.exit = tOut[last]
	b.tiles[b.exit] = tileExit
	dx, dy := sideVec(first)
	b.start = tIn[0] - dx - dy*b.w
	b.tiles[b.start] = tileStart

	for k := 0; k < b.nrooms; k++ {
		b.rooms[k].orient(b, sIn[k], sOut[k], tIn[k], tOut[k], b.r.coin())
	}
}

// pickWalk draws a walk; the chest floor needs one that leaves a cell spare.
func (b *builder) pickWalk(cfg *bandCfg) string {
	for {
		w := cfg.walks[b.r.intn(len(cfg.walks))]
		if !b.chest || len(w)+1 < cfg.c*cfg.r {
			return w
		}
	}
}

func (b *builder) addCell(c, r, room int) {
	b.cellC[b.ncells], b.cellR[b.ncells] = c, r
	b.cellRoom[b.ncells] = room
	b.used[c][r] = true
	b.ncells++
}

func (b *builder) onBorder(cell, side int) bool {
	c, r := b.cellC[cell], b.cellR[cell]
	switch side {
	case 0:
		return r == 0
	case 1:
		return c == b.cols-1
	case 2:
		return r == b.rows-1
	}
	return c == 0
}

// wallTile picks a tile of the wall on side s of cell i, at a random offset along
// the cell.
func (b *builder) wallTile(cell, s int) int {
	return b.wallTileAt(b.cellC[cell], b.cellR[cell], s, -1)
}

// wallTileAt is wallTile for cell (c, r); off < 0 draws the offset.
func (b *builder) wallTileAt(c, r, s, off int) int {
	x0, y0, cw, ch := b.xs[c], b.ys[r], b.cw[c], b.rh[r]
	if off < 0 {
		if s == 0 || s == 2 {
			off = b.r.intn(cw)
		} else {
			off = b.r.intn(ch)
		}
	}
	switch s {
	case 0:
		return (y0-1)*b.w + x0 + off
	case 1:
		return (y0+off)*b.w + x0 + cw
	case 2:
		return (y0+ch)*b.w + x0 + off
	}
	return (y0+off)*b.w + x0 - 1
}

// monHP is each monster kind's spawn HP, as sim.Parse gives it.
var monHP = [5]int8{0, 1, 1, 2, 0}

// simMap builds the map sim.Parse makes of the floor's grid, props and
// objective, without rendering and parsing it. TestSimMapMatchesParse checks
// it against Parse.
func (b *builder) simMap() sim.Map {
	var m sim.Map
	m.W, m.H = uint8(b.w), uint8(b.h)
	n := b.w * b.h
	for i := 0; i < n; i++ {
		m.Tiles[i] = b.tiles[i]
	}
	m.StartX, m.StartY = int8(b.start%b.w), int8(b.start/b.w)
	for i := 0; i < b.nmons; i++ {
		e := b.mons[i]
		m.Mons[i] = sim.Mon{Kind: e.kind, X: int8(e.at % b.w), Y: int8(e.at / b.w),
			HP: monHP[e.kind], Facing: e.facing, Phase: e.phase}
	}
	m.NMons = uint8(b.nmons)
	if b.slay {
		m.Obj = sim.ObjSlay
	}
	m.HasChest = b.chest
	return m
}

// render draws the grid with monsters and the start.
func (b *builder) render() string {
	out := make([]byte, 0, b.h*(b.w+1))
	mi := 0
	for y := 0; y < b.h; y++ {
		if y > 0 {
			out = append(out, '\n')
		}
		for x := 0; x < b.w; x++ {
			i := y*b.w + x
			c := b.tiles[i]
			if mi < b.nmons && b.mons[mi].at == i {
				c = " sabg"[b.mons[mi].kind]
				mi++
			}
			out = append(out, c)
		}
	}
	return string(out)
}

// props returns one hex digit per monster in row-major order: facing<<2 | phase.
// Monsters are kept sorted by tile, which is Parse's spawn order.
func (b *builder) props() string {
	out := make([]byte, b.nmons)
	for i := 0; i < b.nmons; i++ {
		out[i] = "0123456789abcdef"[b.mons[i].facing<<2|b.mons[i].phase&3]
	}
	return string(out)
}

// startClear is how far from the start a slime or brute must begin.
const startClear = 6

// addMon places a monster on floor tile i unless the floor's monster budget is
// spent, the tile is taken or it is too near the start. Monsters stay sorted
// by tile.
func (b *builder) addMon(kind uint8, i int, facing, phase uint8) bool {
	if b.nmons >= b.monCap || b.tiles[i] != tileFloor || b.monAt(i) {
		return false
	}
	// No monster starts within two tiles (Chebyshev) of the start, and nothing
	// that chases within startClear steps of it.
	dx, dy := abs(i%b.w-b.start%b.w), abs(i/b.w-b.start/b.w)
	if dx <= 2 && dy <= 2 || (kind == sim.KSlime || kind == sim.KBrute) && dx+dy < startClear {
		return false
	}
	j := b.nmons
	for j > 0 && b.mons[j-1].at > i {
		b.mons[j] = b.mons[j-1]
		j--
	}
	b.mons[j] = mon{kind: kind, facing: facing & 3, phase: phase & 3, at: i}
	b.nmons++
	return true
}

func (b *builder) monAt(i int) bool {
	for j := 0; j < b.nmons; j++ {
		if b.mons[j].at == i {
			return true
		}
	}
	return false
}

// placeChest opens a spare cell next to the route as a side room with the
// chest in its far corner, behind one spike tile in the doorway. Every spare
// cell and side is tried, from a random start, for a door whose outer tile is
// plain floor with another open, non-crumble tile beside it: the way in must
// still be there on the way out (a crumble there falls once crossed). If no
// spare cell can take such a door, the chest goes on a free floor tile of a
// room with the most walls around it; if there is none, the floor holds no
// chest and says so.
func (b *builder) placeChest() {
	n := b.cols * b.rows * 4
	o0 := b.r.intn(n)
	for o := 0; o < n; o++ {
		v := (o0 + o) % n
		c, r, s := v/4%b.cols, v/4/b.cols, v%4
		if b.used[c][r] {
			continue
		}
		dx, dy := sideVec(s)
		nc, nr := c+dx, r+dy
		if nc < 0 || nr < 0 || nc >= b.cols || nr >= b.rows || !b.used[nc][nr] {
			continue
		}
		span := b.rh[r]
		if s == 0 || s == 2 {
			span = b.cw[c]
		}
		off0 := b.r.intn(span)
		for k := 0; k < span; k++ {
			door := b.wallTileAt(c, r, s, (off0+k)%span)
			out := door + dx + dy*b.w
			if b.tiles[out] != tileFloor || b.monAt(out) || !b.firmNeighbor(out, door) {
				continue
			}
			best, bd := -1, -1
			for y := b.ys[r]; y < b.ys[r]+b.rh[r]; y++ {
				for x := b.xs[c]; x < b.xs[c]+b.cw[c]; x++ {
					b.tiles[y*b.w+x] = tileFloor
					d := abs(x-door%b.w) + abs(y-door/b.w)
					if d > bd {
						best, bd = y*b.w+x, d
					}
				}
			}
			b.tiles[door] = tileSpike
			b.tiles[best] = tileChest
			b.chestAt, b.chestOut = best, out
			// The side room and its door, for the chest route's search.
			b.chestBox = [4]int{b.xs[c], b.ys[r], b.xs[c] + b.cw[c] - 1, b.ys[r] + b.rh[r] - 1}
			if dx < 0 || dy < 0 {
				b.chestBox[0], b.chestBox[1] = door%b.w, door/b.w
				if dy < 0 {
					b.chestBox[0] = b.xs[c]
				} else {
					b.chestBox[1] = b.ys[r]
				}
			} else {
				b.chestBox[2], b.chestBox[3] = door%b.w, door/b.w
				if dy > 0 {
					b.chestBox[2] = b.xs[c] + b.cw[c] - 1
				} else {
					b.chestBox[3] = b.ys[r] + b.rh[r] - 1
				}
			}
			return
		}
	}
	best, bw := -1, -1
	for i := b.w; i < b.w*(b.h-1); i++ {
		if b.tiles[i] != tileFloor || b.monAt(i) || i == b.start {
			continue
		}
		walls := 0
		for s := 0; s < 4; s++ {
			dx, dy := sideVec(s)
			if b.tiles[i+dx+dy*b.w] == tileWall {
				walls++
			}
		}
		if walls > bw && walls < 3 {
			best, bw = i, walls
		}
	}
	if best < 0 {
		b.chest = false
		return
	}
	b.tiles[best] = tileChest
	b.chestAt, b.chestOut = best, best
	b.chestBox = [4]int{best % b.w, best / b.w, best % b.w, best / b.w}
}

// firmNeighbor reports whether tile i has an open tile beside it, other than
// tile from, that is not a pit, wall or crumble.
func (b *builder) firmNeighbor(i, from int) bool {
	for s := 0; s < 4; s++ {
		dx, dy := sideVec(s)
		j := i + dx + dy*b.w
		if j == from || j < 0 || j >= b.w*b.h {
			continue
		}
		switch b.tiles[j] {
		case tileWall, tilePit, tileCrum, tileGate:
		default:
			return true
		}
	}
	return false
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
