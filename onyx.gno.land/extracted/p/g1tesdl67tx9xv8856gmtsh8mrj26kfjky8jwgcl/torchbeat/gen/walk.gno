package gen

import "gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"

// The walker plays the witness on the engine itself. Every beat it tries
// actions in order of preference on a copy of the game (sim.Game holds no
// pointers but the map, so a copy is a full snapshot) and keeps the first that
// costs no HP: the planned step, then waiting, then striking, a side step or
// a dash. A room that cannot be crossed is replayed from its door with one
// more beat of waiting there first, which shifts every timed hazard by a beat.
// When no wait works, a beam search over the engine's states takes over: from
// the room's door, then from the doors of the rooms before it (a chaser picked
// up earlier can doom a room), then over the whole floor from the start.
//
// Walking with Ironheart, whose dash cooldown is the longest, makes every
// dash the witness takes wait out the 8-beat cooldown, so the log clears the
// same with any relic (the relics differ in nothing else a flawless log meets).
const (
	walkRelic = 2
	maxWaits  = 7   // extra beats of waiting tried at one door
	roomBeats = 60  // beats one plan step may take
	huntBeats = 120 // beats the finale's hunt may take
	huntStall = 30  // beats the hunt may go without a kill
)

type walker struct {
	b    *builder
	g    [2]sim.Game // the current game is g[ci]; the other is the trial
	ci   int
	log  [sim.MaxBeats]byte
	n    int
	side int    // side of the last move, tried first
	off  [4]int // tile offset of each side

	trials int // trial beats played
	limit  int // trial budget (see walkTrials)

	cp    sim.Game // a room's door, after the waits tried so far
	cpN   int
	doors [maxRooms]sim.Game // the game as the hero reached each room's door
	doorN [maxRooms]int

	// Distance fields: the one in use, and a small cache keyed by target and
	// box (target -1: not reusable).
	dist   *[sim.MaxTiles]uint8
	fields [3][sim.MaxTiles]uint8
	keys   [3][5]int
	nextF  int
	q      [sim.MaxTiles]int

	// The hunt's target, for rebuilding its field only when needed.
	hTile, hMon int
	hFoes       uint8

	// For the search: each room's distance field to its exit, and the room
	// each tile belongs to (a door belongs to the room it opens into).
	rdist  [maxRooms][sim.MaxTiles]uint8
	roomOf [sim.MaxTiles]int8
	rdone  bool
	// huntLight scores the finale's arena by the exit plus a little per foe
	// left, as cmd/solve does, instead of by foes and the nearest one.
	huntLight bool
	// chest is the room (index+1) whose door leads to the chest, when the walk
	// must take it (ChestWitness); 0 for the floor's own witness.
	chest int
}

const far = uint8(255)

func (k *walker) cur() *sim.Game {
	return &k.g[k.ci]
}

// walk plays the floor's plan room by room and returns the log and whether it
// cleared with zero damage.
func (k *walker) walk(b *builder, m *sim.Map) (string, bool) {
	k.b = b
	k.off = [4]int{-b.w, 1, b.w, -1}
	for i := 0; i < len(k.keys); i++ {
		k.keys[i][0] = -1
	}
	k.g[0] = sim.NewGame(m, walkRelic)
	ok := true
	for ri := 0; ri < b.nrooms && ok; ri++ {
		ok = k.room(ri)
	}
	if !ok {
		// Last resort: a wide search over the whole floor from the start,
		// then one that weighs foes as cmd/solve does, then a wider one.
		for pass := 0; pass < 3 && !ok; pass++ {
			k.g[k.ci] = k.doors[0]
			k.n = 0
			k.huntLight = pass >= 1
			width := beamFloor
			if pass == 2 {
				width = beamFloorWide
			}
			ok = k.search(0, b.nrooms-1, width)
		}
	}
	g := k.cur()
	return string(k.log[:k.n]), ok && g.Won && g.Damage == 0
}

// room crosses room ri, retrying from its door with one more beat of waiting
// each time a step of its plan fails. When every wait fails, it searches for a
// way to the room's exit from its door, then from the doors of the one or two
// rooms before it (a chaser picked up earlier can doom a room from its door).
func (k *walker) room(ri int) bool {
	r := &k.b.rooms[ri]
	k.save()
	k.doors[ri] = k.cp
	k.doorN[ri] = k.n
	for w := 0; ; w++ {
		if k.steps(r) {
			return true
		}
		if w == maxWaits || k.trials >= k.limit {
			break
		}
		k.restore()
		if !k.try(0, int(k.cur().HIdx)) {
			break
		}
		k.save()
	}
	for from := ri; from >= 0 && from >= ri-2; from-- {
		k.g[k.ci] = k.doors[from]
		k.n = k.doorN[from]
		if k.search(from, ri, beamWidth) {
			return true
		}
	}
	return false
}

func (k *walker) save() {
	k.cp = k.g[k.ci]
	k.cpN = k.n
}

func (k *walker) restore() {
	k.g[k.ci] = k.cp
	k.n = k.cpN
}

func (k *walker) steps(r *room) bool {
	// The chest detour: into the chest room and back out, then the plan.
	if k.chest > 0 && r == &k.b.rooms[k.chest-1] && !k.cur().Chest {
		b := k.b
		if !k.goToBox(0, 0, b.w-1, b.h-1, b.chestAt) || !k.goToBox(0, 0, b.w-1, b.h-1, b.chestOut) {
			return false
		}
	}
	for i := 0; i < r.ns; i++ {
		s := r.steps[i]
		ok := false
		switch s.op {
		case opGoto:
			ok = k.goTo(r, s.at)
		case opDash:
			ok = k.dash(s.dir, s.at)
		case opHunt:
			ok = k.hunt(r)
		case opCross:
			ok = k.cross(r, s.dir, s.at)

		}
		if !ok {
			return false
		}
	}
	return true
}

// trial plays action a on a copy of the current game and returns the copy.
// Once the walk's trial budget is spent every trial comes back dead, which
// fails the walk at once.
func (k *walker) trial(a uint8) *sim.Game {
	t := &k.g[1-k.ci]
	*t = k.g[k.ci]
	if k.trials >= k.limit {
		t.Dead = true
		return t
	}
	t.Step(a)
	k.trials++
	return t
}

func clean(t *sim.Game) bool {
	return !t.Dead && t.Damage == 0
}

// commit makes the last trial (action a) current.
func (k *walker) commit(a uint8) {
	k.ci = 1 - k.ci
	k.log[k.n] = '0' + a
	k.n++
	if a >= 1 && a <= 8 {
		k.side = int(a-1) & 3
	}
}

// viable reports whether game t (a trial's result) leaves the hero some
// action next beat that looks safe: a step or a wait, a bump that kills the
// monster it hits, or a dash (a dash beat cannot be hurt). Rejecting moves
// into a dead end, such as the gap between two fireball lanes, spares the walk
// replaying a whole room.
func (k *walker) viable(t *sim.Game) bool {
	// The dead ends it guards against come from projectiles, and only one in
	// the hero's row or column can reach him next beat.
	hx, hy := t.HX, t.HY
	near := false
	for j := 0; j < int(t.NProjs) && !near; j++ {
		near = t.Projs[j].X == hx || t.Projs[j].Y == hy
	}
	if !near {
		return true
	}
	for a := uint8(0); a <= 4; a++ {
		skip := -1
		j := -1
		if a > 0 {
			j = k.neighbor(int(t.HIdx), int(a-1))
		}
		if j >= 0 {
			o := int(t.Occ[k.oi(j)])
			if o >= 1 && o <= sim.MaxMonsters && t.Mons[o-1].Alive && t.Mons[o-1].HP == 1 {
				skip = o - 1
			}
		}
		if k.safeOn(t, a, skip) {
			return true
		}
	}
	return t.DashCD == 0
}

// safeOn screens action a on game g without playing it: it reports false
// when the beat surely costs HP or a life (spikes up under the hero's step, a
// pit, a crumble that falls this beat, a projectile on or entering his tile,
// an acting slime next to a hero who stays put, a brute's blow landing on his
// tile). It never rejects a safe action, as it reads the same state the engine
// will. Monster skip is ignored (the action kills it before it acts). Dashes
// are left to a trial: a dash beat cannot be hurt.
func (k *walker) safeOn(g *sim.Game, a uint8, skip int) bool {
	if a >= 5 {
		return true
	}
	pw := int(g.PW)
	i := int(g.HIdx)
	moved := false
	j := -1
	if a >= 1 {
		j = k.neighbor(i, int(a-1))
	}
	if j >= 0 {
		o := g.Occ[k.oi(j)]
		if o == 0 || o == sim.OccPit || o&0xF8 == sim.OccGate && (g.GatesUp || g.Stuck&(1<<(o&7)) != 0) ||
			o >= 1 && o <= sim.MaxMonsters && !g.Mons[o-1].Alive {
			i, moved = j, true
		}
	}
	t := g.Tiles[i]
	if t == sim.TPit || int(g.Mark) == i {
		return false
	}
	if g.Inv != 0 {
		return true
	}
	x, y := i%k.b.w, i/k.b.w
	if t == sim.TSpikes && (int(g.Beat)+x+y)%4 >= 2 {
		return false
	}
	for j := 0; j < int(g.NProjs); j++ {
		p := &g.Projs[j]
		px, py := int(p.X), int(p.Y)
		if px == x && py == y || px+int(p.DX) == x && py+int(p.DY) == y {
			return false
		}
	}
	// Melee comes only from the four tiles around the hero: a slime acting
	// this beat strikes a hero who stays put, a brute ending its wind-up
	// strikes the tile it faces.
	acting := g.Tick | g.Sched[g.Beat&3]
	oc := (y+1)*pw + x + 1
	for s := 0; s < 4; s++ {
		var o int
		switch s {
		case 0:
			o = int(g.Occ[oc-pw])
		case 1:
			o = int(g.Occ[oc+1])
		case 2:
			o = int(g.Occ[oc+pw])
		default:
			o = int(g.Occ[oc-1])
		}
		if o < 1 || o > sim.MaxMonsters || o-1 == skip || acting&(1<<uint(o-1)) == 0 {
			continue
		}
		e := &g.Mons[o-1]
		if !e.Alive {
			continue
		}
		switch e.Kind {
		case sim.KSlime:
			if !moved {
				return false
			}
		case sim.KBrute:
			// The brute is on side s of the hero and must face him: its
			// facing is the opposite side.
			if e.Wind == 1 && int(e.Facing) == (s+2)&3 {
				return false
			}
		}
	}
	return true
}

// oi is the Occ index of tile i (Occ has a one-tile border).
func (k *walker) oi(i int) int {
	return i + 2*(i/k.b.w) + k.b.w + 3
}

// dashLanding returns the tile a dash toward side s would land on, as the
// engine resolves it, or -1 when it would not happen (cooldown, a wall in the
// way) or would shove a monster, or would end in a pit or a falling crumble.
func (k *walker) dashLanding(s int) int {
	g := k.cur()
	if g.DashCD != 0 {
		return -1
	}
	pw := int(g.PW)
	dx, dy := sideVec(s)
	x1, y1 := int(g.HX)+dx, int(g.HY)+dy
	blocks := func(x, y int) (bool, bool) { // closed, monster
		o := g.Occ[(y+1)*pw+x+1]
		closed := o == sim.OccWall || o&0xF8 == sim.OccGate && !(g.GatesUp || g.Stuck&(1<<(o&7)) != 0)
		mon := o >= 1 && o <= sim.MaxMonsters && g.Mons[o-1].Alive
		return closed, mon
	}
	if c, m := blocks(x1, y1); c || m {
		return -1
	}
	x2, y2 := x1+dx, y1+dy
	if c, m := blocks(x2, y2); c || m {
		x2, y2 = x1, y1
	}
	i := y2*k.b.w + x2
	if g.Tiles[i] == sim.TPit || int(g.Mark) == i {
		return -1
	}
	return i
}

// try plays a and keeps it when it is clean and the hero ends on tile want.
func (k *walker) try(a uint8, want int) bool {
	if k.n >= sim.MaxBeats {
		return false
	}
	t := k.trial(a)
	if !clean(t) || int(t.HIdx) != want || t.Ev&sim.EvShove != 0 || !t.Won && !k.viable(t) {
		return false
	}
	k.commit(a)
	return true
}

// monAt returns the index of a live monster on tile i, or -1.
func (k *walker) monAt(g *sim.Game, i int) int {
	o := int(g.Occ[k.oi(i)])
	if o >= 1 && o <= sim.MaxMonsters && g.Mons[o-1].Alive {
		return o - 1
	}
	return -1
}

// neighbor returns the tile next to i on side s, or -1 past the floor's edge
// (the walk can stand on the exit, which is in the border wall).
func (k *walker) neighbor(i, s int) int {
	w := k.b.w
	switch s {
	case 0:
		if i < w {
			return -1
		}
	case 1:
		if i%w == w-1 {
			return -1
		}
	case 2:
		if i >= w*(k.b.h-1) {
			return -1
		}
	default:
		if i%w == 0 {
			return -1
		}
	}
	return i + k.off[s]
}

// strike attacks the monster on the tile toward side s: a dash that shoves it
// into a pit when one lies behind it, else a bump. It reports whether a clean
// blow landed (a bump on a brute's shield does not count).
func (k *walker) strike(s int) bool {
	if k.n >= sim.MaxBeats {
		return false
	}
	g := k.cur()
	nb := k.neighbor(int(g.HIdx), s)
	if nb < 0 {
		return false
	}
	mi := k.monAt(g, nb)
	if mi < 0 || g.Mons[mi].Kind == sim.KGargoyle {
		return false
	}
	if g.DashCD == 0 {
		if pb := k.neighbor(nb, s); pb >= 0 && g.Tiles[pb] == sim.TPit {
			t := k.trial(uint8(s + 5))
			if clean(t) && t.Ev&sim.EvFall != 0 {
				k.commit(uint8(s + 5))
				return true
			}
		}
	}
	t := k.trial(uint8(s + 1))
	if clean(t) && t.Ev&sim.EvHit != 0 {
		k.commit(uint8(s + 1))
		return true
	}
	return false
}

// goTo walks to tile target along r's distance field.
func (k *walker) goTo(r *room, target int) bool {
	x0, y0 := r.x0-1, r.y0-1
	return k.goToBox(x0, y0, x0+r.aw+1, y0+r.ah+1, target)
}

// goToBox is goTo over the box [x0, x1] x [y0, y1].
func (k *walker) goToBox(x0, y0, x1, y1, target int) bool {
	k.bfs(x0, y0, x1, y1, target, nil)
	best, stall := far, 0
	for beat := 0; beat < roomBeats; beat++ {
		h := int(k.cur().HIdx)
		if h == target {
			return true
		}
		if d := k.dist[h]; d < best {
			best, stall = d, 0
		} else if stall++; stall > maxStall {
			return false // replay the room from its door, a beat later
		}
		if stall >= 4 && k.dashCloser() {
			continue
		}
		if stall == 0 && k.stepFast(h) {
			continue
		}
		if !k.advance() {
			return false
		}
	}
	return false
}

// stepFast is advance's common case, kept lean because Gno charges for every
// operation: one step to a free tile one closer (the last direction first),
// kept if the beat is clean. It reports false, having committed nothing, when
// that does not work out.
func (k *walker) stepFast(h int) bool {
	d := k.dist[h] - 1
	s := k.side
	nb := k.neighbor(h, s)
	if nb < 0 || k.dist[nb] != d {
		for s = 0; s < 4; s++ {
			if nb = k.neighbor(h, s); nb >= 0 && k.dist[nb] == d {
				break
			}
		}
		if s == 4 {
			return false
		}
	}
	g := &k.g[k.ci]
	if g.Occ[nb+2*(nb/k.b.w)+k.b.w+3] != 0 || k.n >= sim.MaxBeats {
		return false
	}
	t := k.trial(uint8(s + 1))
	if t.Dead || t.Damage != 0 || int(t.HIdx) != nb || t.NProjs != 0 && !t.Won && !k.viable(t) {
		return false
	}
	k.commit(uint8(s + 1))
	return true
}

// maxStall is how many beats goTo may go without getting closer.
const maxStall = 12

// dashCloser dashes to a tile closer to the goal when one is in reach and the
// dash is clean: the way past a hazard that walking cannot time (two fireball
// lanes side by side), since a dash beat cannot be hurt.
func (k *walker) dashCloser() bool {
	if k.n >= sim.MaxBeats {
		return false
	}
	d := k.dist[k.cur().HIdx]
	for s := 0; s < 4; s++ {
		l := k.dashLanding(s)
		if l < 0 || k.dist[l] >= d {
			continue
		}
		t := k.trial(uint8(s + 5))
		if clean(t) && t.Ev&sim.EvShove == 0 && k.viable(t) {
			k.commit(uint8(s + 5))
			return true
		}
	}
	return false
}

// advance plays one beat toward lower distance: a step that gets closer (or a
// blow on the monster in the way), else waiting, else a side step, a step
// back or a dash that gets closer. Off the distance field (in an archer's line
// while hunting) it steps back onto it. It reports false when every one of
// them costs HP.
func (k *walker) advance() bool {
	g := k.cur()
	h := int(g.HIdx)
	d := k.dist[h]
	if d == far {
		return k.escape()
	}
	blocked := false
	for o := 0; o < 4; o++ {
		s := (k.side + o) & 3
		nb := k.neighbor(h, s)
		if nb < 0 || k.dist[nb] != d-1 {
			continue
		}
		if k.monAt(g, nb) >= 0 {
			if k.strike(s) {
				return true
			}
			blocked = true
			continue
		}
		if k.try(uint8(s+1), nb) {
			return true
		}
	}
	// A monster that cannot be struck (a brute's shield, a gargoyle) stands
	// in the way: go round it before it winds up.
	if blocked && k.sidestep(d) {
		return true
	}
	return k.dodge(d)
}

// escape steps onto the tile of the distance field nearest the goal, or waits.
func (k *walker) escape() bool {
	g := k.cur()
	h := int(g.HIdx)
	for best := uint8(0); best < far; {
		bs, bd := -1, far
		for s := 0; s < 4; s++ {
			nb := k.neighbor(h, s)
			if nb >= 0 && k.dist[nb] >= best && k.dist[nb] < bd && k.monAt(g, nb) < 0 {
				bs, bd = s, k.dist[nb]
			}
		}
		if bs < 0 {
			break
		}
		if k.try(uint8(bs+1), k.neighbor(h, bs)) {
			return true
		}
		best = bd + 1
	}
	// Boxed in by closed tiles: any clean step, else the usual fallbacks.
	for s := 0; s < 4; s++ {
		nb := k.neighbor(h, s)
		if nb < 0 || k.monAt(g, nb) >= 0 {
			continue
		}
		if c := k.b.tiles[nb]; c == tileWall || c == tilePit || nb == k.b.exit {
			continue
		}
		if k.try(uint8(s+1), nb) {
			return true
		}
	}
	return k.dodge(far)
}

// sidestep steps to a free tile no farther from the goal than d+1.
func (k *walker) sidestep(d uint8) bool {
	g := k.cur()
	h := int(g.HIdx)
	if g.Tiles[h] == sim.TCrumble {
		return false
	}
	for s := 0; s < 4; s++ {
		nb := k.neighbor(h, s)
		if nb < 0 || k.dist[nb] == far || k.dist[nb] < d || k.dist[nb] > d+1 || k.monAt(g, nb) >= 0 {
			continue
		}
		if k.try(uint8(s+1), nb) {
			return true
		}
	}
	return false
}

// dodge is advance's fallback: wait, fight what is adjacent, step aside or
// back, or dash closer. In the hunt (d == far) any clean step will do.
func (k *walker) dodge(d uint8) bool {
	g := k.cur()
	h := int(g.HIdx)
	if k.try(0, h) {
		return true
	}
	for s := 0; s < 4; s++ {
		if k.strike(s) {
			return true
		}
	}
	// Leaving a crumble tile drops it: on one, only ever move closer.
	onCrumble := g.Tiles[h] == sim.TCrumble
	for s := 0; s < 4 && !onCrumble; s++ {
		nb := k.neighbor(h, s)
		if nb < 0 || k.monAt(g, nb) >= 0 || d != far && (k.dist[nb] == far || k.dist[nb] < d) {
			continue
		}
		if c := k.b.tiles[nb]; c == tileWall || c == tilePit {
			continue
		}
		if k.try(uint8(s+1), nb) {
			return true
		}
	}
	if g.DashCD == 0 && k.n < sim.MaxBeats {
		for s := 0; s < 4; s++ {
			l := k.dashLanding(s)
			if l < 0 || d != far && k.dist[l] >= d {
				continue
			}
			t := k.trial(uint8(s + 5))
			if clean(t) && t.Ev&sim.EvShove == 0 {
				k.commit(uint8(s + 5))
				return true
			}
		}
	}
	return false
}

// cross gets over a trench toward side s: dash across when the far bank is
// free and the beat is clean, else walk along the near bank away from the
// nearest monster across (a brute mirrors the hero at half speed, so this
// draws it off the landing), else wait. The far side is what the distance
// field to the exit (tile out) reaches without crossing a pit.
func (k *walker) cross(r *room, s, out int) bool {
	x0, y0 := r.x0-1, r.y0-1
	k.bfs(x0, y0, x0+r.aw+1, y0+r.ah+1, out, nil)
	along := (s + 1) & 3
	for beat := 0; beat < roomBeats && k.n < sim.MaxBeats; beat++ {
		g := k.cur()
		h := int(g.HIdx)
		if k.dist[h] != far {
			return true
		}
		if l := k.dashLanding(s); l >= 0 && k.dist[l] != far {
			t := k.trial(uint8(s + 5))
			if clean(t) && t.Ev&sim.EvShove == 0 {
				k.commit(uint8(s + 5))
				return true
			}
		}
		// Walk the bank: keep the current direction while the bank goes on.
		moved := false
		for o := 0; o < 2 && !moved; o++ {
			a := along
			if o == 1 {
				a = (along + 2) & 3
			}
			nb := k.neighbor(h, a)
			if nb < 0 || k.monAt(g, nb) >= 0 {
				continue
			}
			if c := k.b.tiles[nb]; c == tileWall || c == tilePit {
				continue
			}
			if pb := k.neighbor(nb, s); pb < 0 || k.b.tiles[pb] != tilePit {
				continue // not the bank
			}
			if k.try(uint8(a+1), nb) {
				along, moved = a, true
			}
		}
		if moved {
			continue
		}
		along = (along + 2) & 3
		if !k.dodge(far) {
			return false
		}
	}
	return false
}

// dash waits for the cooldown, then dashes toward side s and must land on
// tile at.
func (k *walker) dash(s, at int) bool {
	for beat := 0; beat < roomBeats && k.n < sim.MaxBeats; beat++ {
		g := k.cur()
		if k.dashLanding(s) == at {
			t := k.trial(uint8(s + 5))
			if clean(t) && int(t.HIdx) == at && t.Ev&sim.EvShove == 0 {
				k.commit(uint8(s + 5))
				return true
			}
		}
		if k.try(0, int(g.HIdx)) {
			continue
		}
		hit := false
		for o := 0; o < 4 && !hit; o++ {
			hit = k.strike(o)
		}
		if !hit {
			return false
		}
	}
	return false
}

// hunt kills every foe left (the SLAY finale). Foes next to the hero are
// struck; slimes and brutes come to the hero, so the walk waits for them, and
// walks to an archer, or to a foe that has stopped coming, by a distance field
// over the arena that keeps out of the archers' lines until the last step.
func (k *walker) hunt(r *room) bool {
	k.hMon = -1
	idle, since, foes := 0, 0, k.cur().Foes
	for beat := 0; beat < huntBeats; beat++ {
		g := k.cur()
		if g.Foes == 0 {
			return true
		}
		if g.Foes < foes {
			foes, since = g.Foes, 0
		} else if since++; since > huntStall {
			return false // replay the room from its door, a beat later
		}
		struck := false
		h := int(g.HIdx)
		for s := 0; s < 4 && !struck; s++ {
			if nb := k.neighbor(h, s); nb >= 0 && k.monAt(g, nb) >= 0 && g.Mons[k.monAt(g, nb)].Kind != sim.KGargoyle {
				struck = k.strike(s)
			}
		}
		if struck {
			idle = 0
			continue
		}
		t := k.nearestFoe(g)
		if t < 0 {
			return false
		}
		e := g.Mons[t]
		ti := int(e.Y)*k.b.w + int(e.X)
		if e.Kind == sim.KArcher || idle >= 4 {
			// The field is the arena's; rebuild it for a new target or after a
			// kill (an archer's lines may be gone). A walking target is chased
			// to where it was: it is coming this way anyway.
			if t != k.hMon || k.hFoes != g.Foes {
				k.hMon, k.hTile, k.hFoes = t, ti, g.Foes
				x0, y0 := r.x0-1, r.y0-1
				k.bfs(x0, y0, x0+r.aw+1, y0+r.ah+1, ti, g)
			}
			if !k.advance() {
				return false
			}
		} else if !k.dodge(far) {
			return false
		}
		idle++
	}
	return false
}

// nearestFoe returns the live killable monster nearest the hero, or -1.
func (k *walker) nearestFoe(g *sim.Game) int {
	best, bd := -1, 1<<30
	for i := 0; i < int(g.NMons); i++ {
		e := &g.Mons[i]
		if !e.Alive || e.Kind == sim.KGargoyle {
			continue
		}
		dx, dy := int(e.X)-int(g.HX), int(e.Y)-int(g.HY)
		if dx < 0 {
			dx = -dx
		}
		if dy < 0 {
			dy = -dy
		}
		if dx+dy < bd {
			best, bd = i, dx+dy
		}
	}
	return best
}

// bfs fills dist with the walking distance to tile target over the box
// [x0, x1] x [y0, y1] (clipped to the floor), through any tile but walls and
// pits; everything else is far. With g set (the hunt), the lines of every live
// archer are closed (an archer sees along its row and column until a wall),
// and when the target is itself an archer the distance is to the tiles next to
// it, so the walk steps into an archer's line only to strike it.
func (k *walker) bfs(x0, y0, x1, y1, target int, g *sim.Game) {
	b := k.b
	if x0 < 0 {
		x0 = 0
	}
	if y0 < 0 {
		y0 = 0
	}
	if x1 >= b.w {
		x1 = b.w - 1
	}
	if y1 >= b.h {
		y1 = b.h - 1
	}
	// A field over the static floor depends only on its target and box, so a
	// room replayed from its door reuses the fields it built before.
	key := [5]int{target, x0, y0, x1, y1}
	if g == nil {
		for i := 0; i < len(k.keys); i++ {
			if k.keys[i] == key {
				k.dist = &k.fields[i]
				return
			}
		}
	}
	slot := k.nextF
	k.nextF = (k.nextF + 1) % len(k.fields)
	k.keys[slot] = key
	if g != nil {
		k.keys[slot][0] = -1 // a hunt field depends on the game too
	}
	k.dist = &k.fields[slot]
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			k.dist[y*b.w+x] = far
		}
	}
	const closed = far - 1
	// Gargoyles never move and cannot be struck or shoved: walls to a walk.
	for i := 0; i < b.nmons; i++ {
		if b.mons[i].kind == sim.KGargoyle && b.mons[i].at != target {
			k.dist[b.mons[i].at] = closed
		}
	}
	head, tail := 0, 0
	tm := -1
	if g != nil {
		tm = k.monAt(g, target)
		for i := 0; i < int(g.NMons); i++ {
			e := &g.Mons[i]
			if !e.Alive || e.Kind != sim.KArcher {
				continue
			}
			for s := 0; s < 4; s++ {
				dx, dy := sideVec(s)
				x, y := int(e.X)+dx, int(e.Y)+dy
				for n := 0; x >= x0 && y >= y0 && x <= x1 && y <= y1; n++ {
					j := y*b.w + x
					if c := b.tiles[j]; c == tileWall || c == tileGate {
						break
					}
					if n > 0 || i != tm {
						k.dist[j] = closed
					}
					x, y = x+dx, y+dy
				}
			}
			k.dist[int(e.Y)*b.w+int(e.X)] = closed
		}
	}
	if tm >= 0 && g.Mons[tm].Kind == sim.KArcher {
		for s := 0; s < 4; s++ {
			if j := k.neighbor(target, s); j >= 0 && k.dist[j] == far {
				if c := b.tiles[j]; c != tileWall && c != tilePit {
					k.dist[j] = 0
					k.q[tail] = j
					tail++
				}
			}
		}
	} else {
		k.dist[target] = 0
		k.q[tail] = target
		tail++
	}
	// The neighbor loop is unrolled: in Gno a call or an array read costs far
	// more than arithmetic, and this loop is the walk's hottest.
	w := b.w
	for head < tail {
		i := k.q[head]
		head++
		d := k.dist[i] + 1
		x, y := i%w, i/w
		if y > y0 {
			if j := i - w; k.dist[j] == far {
				if c := b.tiles[j]; c != tileWall && c != tilePit {
					k.dist[j] = d
					k.q[tail] = j
					tail++
				}
			}
		}
		if x < x1 {
			if j := i + 1; k.dist[j] == far {
				if c := b.tiles[j]; c != tileWall && c != tilePit {
					k.dist[j] = d
					k.q[tail] = j
					tail++
				}
			}
		}
		if y < y1 {
			if j := i + w; k.dist[j] == far {
				if c := b.tiles[j]; c != tileWall && c != tilePit {
					k.dist[j] = d
					k.q[tail] = j
					tail++
				}
			}
		}
		if x > x0 {
			if j := i - 1; k.dist[j] == far {
				if c := b.tiles[j]; c != tileWall && c != tilePit {
					k.dist[j] = d
					k.q[tail] = j
					tail++
				}
			}
		}
	}
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			if k.dist[y*b.w+x] == closed {
				k.dist[y*b.w+x] = far
			}
		}
	}
}

// Beam search bounds: states kept per beat (rooms, then the whole floor), and
// beats searched per room.
const (
	beamWidth     = 48
	beamFloor     = 2000 // the whole floor from the start, when all else fails
	beamFloorWide = 8000 // and once more, wider
	beamDepth     = 64
)

// node is one state of the search: game, the node it came from (index into
// the search's history) and the action that led here.
type node struct {
	g      sim.Game
	parent int
	act    uint8
	cost   int
}

// search is the fallback: a beam search over the engine's states from room
// from's door to room to's exit (or the floor won). Every action is tried each
// beat; states that cost HP are dropped, so are states seen before (state hash
// with the beat mod 4), and the width states with the least way left (rooms
// to go, then the distance to the current room's exit) are kept. On success
// the path is committed.
func (k *walker) search(from, to, width int) bool {
	b := k.b
	k.fields4Search()
	goal := b.rooms[to].out
	last := b.rooms[to].last
	var past []trace
	seen := map[uint32]bool{}
	layer := []node{{g: k.g[k.ci], parent: -1}}
	depth := beamDepth * (to - from + 1)
	if last || depth > sim.MaxBeats {
		depth = sim.MaxBeats // the finale's hunt can run long
	}
	for d := 0; d < depth && len(layer) > 0 && k.n+d < sim.MaxBeats; d++ {
		var next []node
		for li := range layer {
			for a := uint8(0); a <= 8; a++ {
				if k.trials >= k.limit {
					return false
				}
				t := layer[li].g
				t.Step(a)
				k.trials++
				if t.Dead || t.Damage != 0 {
					continue
				}
				done := (t.Won || int(t.HIdx) == goal && !last) && (k.chest == 0 || to < k.chest-1 || t.Chest)
				c := t
				c.Beat &= 3
				hsh := c.StateHash()
				if seen[hsh] && !done {
					continue
				}
				seen[hsh] = true
				past = append(past, trace{parent: layer[li].parent, act: a})
				if done {
					return k.replay(past, len(past)-1)
				}
				next = append(next, node{g: t, parent: len(past) - 1, cost: k.wayLeft(&t, to)})
			}
		}
		layer = cheapest(next, width)
	}
	return false
}

// maxCost caps a node's cost for cheapest's histogram.
const maxCost = 2047

// cheapest keeps the width cheapest nodes, ties in the order they came: a
// counting selection, linear in the layer, where a sort would cost its square.
func cheapest(next []node, width int) []node {
	if len(next) <= width {
		return next
	}
	var hist [maxCost + 1]int
	for i := range next {
		if next[i].cost > maxCost {
			next[i].cost = maxCost
		}
		hist[next[i].cost]++
	}
	cut, n := 0, 0
	for ; cut <= maxCost && n+hist[cut] < width; cut++ {
		n += hist[cut]
	}
	room := width - n // nodes of cost cut that still fit
	keep := next[:0]
	for i := range next {
		c := next[i].cost
		if c < cut || c == cut && room > 0 {
			if c == cut {
				room--
			}
			keep = append(keep, next[i])
		}
	}
	return keep
}

// wayLeft scores how far game t is from room to's exit: rooms still to cross,
// then the distance to the exit of the room the hero is in (a trench's near
// side, off the field, counts as a little more than its far edge). In the
// finale's arena, while foes are left, it is the foes left, then the distance
// to the nearest one: the exit stays shut until they are dead.
func (k *walker) wayLeft(t *sim.Game, to int) int {
	h := int(t.HIdx)
	ri := int(k.roomOf[h])
	if ri == to && t.Foes > 0 && t.M.Obj == sim.ObjSlay && !k.huntLight {
		near := 99
		for i := 0; i < int(t.NMons); i++ {
			e := &t.Mons[i]
			if e.Alive && e.Kind != sim.KGargoyle {
				if d := abs(int(e.X)-int(t.HX)) + abs(int(e.Y)-int(t.HY)); d < near {
					near = d
				}
			}
		}
		return 100*int(t.Foes) + near
	}
	// On the chest route, from the chest's room on and until it is taken, the
	// way left is the way to the chest.
	if k.chest > 0 && !t.Chest && ri >= k.chest-1 {
		c := k.b.chestAt
		return (to-k.chest+1)*200 + 100 + abs(h%k.b.w-c%k.b.w) + abs(h/k.b.w-c/k.b.w)
	}
	d := int(k.rdist[ri][h])
	if d == int(far) {
		d = 40
	}
	return (to-ri)*200 + d + 4*int(t.Foes)
}

// fields4Search fills rdist and roomOf once per walk.
func (k *walker) fields4Search() {
	if k.rdone {
		return
	}
	k.rdone = true
	b := k.b
	for i := range k.roomOf {
		k.roomOf[i] = 0
	}
	for ri := 0; ri < b.nrooms; ri++ {
		r := &b.rooms[ri]
		for y := r.y0; y < r.y0+r.ah; y++ {
			for x := r.x0; x < r.x0+r.aw; x++ {
				k.roomOf[y*b.w+x] = int8(ri)
			}
		}
		if ri > 0 {
			k.roomOf[r.in] = int8(ri)
		}
		x0, y0 := r.x0-1, r.y0-1
		k.bfs(x0, y0, x0+r.aw+1, y0+r.ah+1, r.out, nil)
		k.rdist[ri] = *k.dist
	}
	// The chest's side room belongs to the room its door opens from.
	if k.chest > 0 {
		x0, y0, x1, y1 := b.chestBox[0], b.chestBox[1], b.chestBox[2], b.chestBox[3]
		for y := y0; y <= y1; y++ {
			for x := x0; x <= x1; x++ {
				k.roomOf[y*b.w+x] = int8(k.chest - 1)
			}
		}
	}
}

// trace is one step of the search's history: the step it came from and the
// action taken.
type trace struct {
	parent int
	act    uint8
}

// replay commits the actions on the search's history path ending at i.
func (k *walker) replay(past []trace, i int) bool {
	var acts []uint8
	for ; i >= 0; i = past[i].parent {
		acts = append(acts, past[i].act)
	}
	for j := len(acts) - 1; j >= 0; j-- {
		t := k.trial(acts[j])
		if !clean(t) {
			return false
		}
		k.commit(acts[j])
	}
	return true
}
