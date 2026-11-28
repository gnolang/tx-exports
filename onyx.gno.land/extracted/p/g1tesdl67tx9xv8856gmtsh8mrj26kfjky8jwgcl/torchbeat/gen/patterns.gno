package gen

import "gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"

// Patterns. Each is drawn into one room in its canonical frame (entered from
// the west at A = (0, ay), left at B) and adds the plan steps the walk follows
// there. A pattern returns false when the room cannot hold it, leaving the room
// plain floor with no monsters or steps added. lv is 0 (light), 1 or 2 (full).
// The order of this list is part of the generator: reordering it changes every
// floor.
const (
	PatSpikes    uint8 = iota // spike run: spikes timed to the 4-beat wave
	PatGap                    // dash gap: a pit trench crossed with a dash
	PatCrumble                // crumble bridge over a chasm, a gargoyle across it
	PatGate                   // plate and gate: dash from the plate through the door before it shuts
	PatArchers                // archer gallery: aim lines across the room
	PatSlimes                 // slime pen: slimes close in, keep moving
	PatBrute                  // brute choke: brutes pace the far bank of a trench
	PatGargoyle               // gargoyle lanes: fireballs across the route
	PatFireRun                // fire run: a gargoyle fires down the corridor behind you
	PatShove                  // shove pit: slimes on a ledge path over a chasm
	PatChase                  // crumble chase: slimes follow you across a crumbling floor
	PatCrossfire              // crossfire: two archers face each other across your path
	NumPatterns

	patPlain uint8 = 255 // an empty room (minor rooms only)
)

var patNames = [NumPatterns]string{
	"spike run", "dash gap", "crumble bridge", "plate and gate", "archer gallery", "slime pen",
	"brute choke", "gargoyle lanes", "fire run", "shove pit", "crumble chase", "crossfire",
}

// PatternName returns a pattern's display name.
func PatternName(p uint8) string {
	if p >= NumPatterns {
		return "plain"
	}
	return patNames[p]
}

// Pattern flags: fWarm fits floors 1-3, fSlay holds foes for the SLAY finale.
const (
	fWarm uint8 = 1
	fSlay uint8 = 2
)

var patFlags = [NumPatterns]uint8{
	PatSpikes:    fWarm | fSlay, // the arena: stepping stones among spikes, slimes closing in
	PatGap:       fWarm,
	PatCrumble:   fWarm,
	PatGate:      fWarm,
	PatArchers:   fWarm | fSlay,
	PatSlimes:    fWarm | fSlay,
	PatBrute:     0,
	PatGargoyle:  fWarm | fSlay, // the arena's foes are its slimes; gargoyles never count for SLAY
	PatFireRun:   0,
	PatShove:     fWarm | fSlay,
	PatChase:     0, // a collapsing trail can strand a slime, so never a SLAY arena
	PatCrossfire: fSlay,
}

// Minor rooms per band: bit p set means pattern p may fill a room that is not
// the main one. The finale keeps its foes in the arena, so its minors hold
// none.
var minorPool = [4]uint32{
	uint32(1)<<PatSpikes | uint32(1)<<PatGap | uint32(1)<<PatCrumble | uint32(1)<<PatGargoyle,
	uint32(1)<<PatSpikes | uint32(1)<<PatGap | uint32(1)<<PatCrumble | uint32(1)<<PatGate | uint32(1)<<PatArchers | uint32(1)<<PatSlimes |
		uint32(1)<<PatGargoyle | uint32(1)<<PatFireRun | uint32(1)<<PatShove | uint32(1)<<PatChase | uint32(1)<<PatCrossfire,
	uint32(1)<<NumPatterns - 1,
	uint32(1)<<PatSpikes | uint32(1)<<PatGap | uint32(1)<<PatCrumble | uint32(1)<<PatGate | uint32(1)<<PatGargoyle | uint32(1)<<PatFireRun,
}

// finaleFoes is the fewest foes the SLAY arena holds; slimes make up the
// difference after its pattern.
const finaleFoes = 5

func (b *builder) foes() int {
	n := 0
	for i := 0; i < b.nmons; i++ {
		if b.mons[i].kind != sim.KGargoyle {
			n++
		}
	}
	return n
}

// inArcherLine reports whether an archer has a clear line to tile i.
func (b *builder) inArcherLine(i int) bool {
	for j := 0; j < b.nmons; j++ {
		if b.mons[j].kind == sim.KArcher && b.line(b.mons[j].at, i) {
			return true
		}
	}
	return false
}

// chaserPool holds the patterns with slimes or brutes, which chase the hero.
const chaserPool uint32 = uint32(1)<<PatSlimes | uint32(1)<<PatBrute | uint32(1)<<PatShove |
	uint32(1)<<PatChase | uint32(1)<<PatCrossfire

// minMons is the fewest monsters a floor of each band should hold.
var minMons = [4]int{0, 1, 3, 3}

// monsterPool holds the patterns that always place a monster.
const monsterPool uint32 = uint32(1)<<PatArchers | uint32(1)<<PatSlimes | uint32(1)<<PatBrute | uint32(1)<<PatGargoyle |
	uint32(1)<<PatFireRun | uint32(1)<<PatShove | uint32(1)<<PatChase | uint32(1)<<PatCrossfire

// placePatterns puts the main pattern in the first room that holds it (the
// arena, the last room, on the finale; otherwise the largest rooms first) and
// fills the other rooms with minors. It reports false when no room holds the
// main pattern.
func (b *builder) placePatterns() bool {
	lv := b.lvl
	if lv > 2 {
		lv = 2
	}
	if b.fallback {
		lv = 0
	}
	var order [maxRooms]int
	no := 0
	if b.slay {
		order[0] = b.nrooms - 1
		no = 1
	} else {
		for k := 0; k < b.nrooms; k++ {
			order[no] = k
			no++
		}
		// Largest first, ties in random order.
		for i := no - 1; i > 0; i-- {
			j := b.r.intn(i + 1)
			order[i], order[j] = order[j], order[i]
		}
		for i := 1; i < no; i++ {
			for j := i; j > 0 && b.area(order[j]) > b.area(order[j-1]); j-- {
				order[j], order[j-1] = order[j-1], order[j]
			}
		}
	}
	b.rooms[b.nrooms-1].last = true
	b.rooms[0].cp = b.start
	main := -1
	for i := 0; i < no && main < 0; i++ {
		if b.runPattern(&b.rooms[order[i]], b.pat, lv) {
			main = order[i]
		}
	}
	if main < 0 {
		return false
	}
	if b.slay {
		// The exit opens once every foe is dead: walk the pattern's route,
		// then hunt down what is left, then take the exit.
		r := &b.rooms[main]
		b.cur = r
		// The hunt starts where the pattern's route ends, short of its walk to
		// the exit: crossing the arena first only to come back for the foes
		// wastes beats.
		if l := &r.steps[r.ns-1]; l.op == opGoto && l.at == r.out {
			r.ns--
		}
		// Every arena tile, from a random one on, until the arena has its foes.
		n := r.w * r.h
		o := b.r.intn(n)
		for k := 0; k < n && b.foes() < finaleFoes; k++ {
			x, y := (o+k)%n%r.w, (o+k)%n/r.w
			i := r.at(b, x, y)
			if r.fromA(x, y) < 4 || b.inArcherLine(i) {
				continue
			}
			// A spike arena has little plain floor: a slime may start on a
			// spike tile off the route, which becomes floor under it.
			spiked := b.tiles[i] == tileSpike && !b.onRoute(x, y)
			if spiked {
				b.tiles[i] = tileFloor
			}
			if !b.monL(r, sim.KSlime, x, y, 3, uint8(b.r.intn(4))) && spiked {
				b.tiles[i] = tileSpike
			}
		}
		r.addStep(opHunt, 0, 0)
		b.gotoOut(r)
	}
	mlv := b.lvl - 1
	if mlv < 0 {
		mlv = 0
	}
	if mlv > 1 {
		mlv = 1
	}
	pool := minorPool[b.lvl] &^ (uint32(1) << b.pat)
	// Floor 1 is one pattern, or two half the time (its layouts are few, and
	// a second pattern keeps them from repeating).
	if b.n == 1 && b.r.coin() {
		pool = 0
	}
	if b.fallback {
		// Plain rooms, except what the band's monster floor needs.
		pool &= monsterPool
		mlv = 0
	}
	for k := 0; k < b.nrooms; k++ {
		if k == main {
			continue
		}
		r := &b.rooms[k]
		placed := false
		// The finale's arena door: the room before the arena ends in a plate
		// and gate with a pit before it, so the arena's foes cannot come out;
		// the hero dashes in from the plate.
		if b.slay && k == main-1 {
			if !b.runPattern(r, PatGate, 1) {
				return false
			}
			continue
		}
		// Below the band's monster floor, minors must bring monsters.
		use := pool
		// Chasers in two rooms side by side on the route pile up on the hero.
		if k > 0 && chaserPool&(uint32(1)<<b.rooms[k-1].pat) != 0 ||
			k+1 < b.nrooms && chaserPool&(uint32(1)<<b.rooms[k+1].pat) != 0 {
			use &^= chaserPool
		}
		if b.nmons < minMons[b.lvl] {
			use = pool & monsterPool
		} else if b.fallback {
			use = 0
		}
		if !placed && use != 0 && !(b.lvl == 1 && use == pool && b.r.intn(6) == 0) {
			var cand [NumPatterns]uint8
			nc := 0
			for p := uint8(0); p < NumPatterns; p++ {
				if use&(uint32(1)<<p) != 0 {
					cand[nc] = p
					nc++
				}
			}
			for nc > 0 && !placed {
				j := b.r.intn(nc)
				if b.runPattern(r, cand[j], mlv) {
					placed = true
				}
				nc--
				cand[j] = cand[nc]
			}
		}
		if !placed {
			b.runPattern(r, patPlain, 0)
		}
	}
	return true
}

func (b *builder) area(k int) int {
	return b.rooms[k].aw * b.rooms[k].ah
}

func (b *builder) runPattern(r *room, p uint8, lv int) bool {
	// Nothing chases the hero from the start: the first room holds no slimes
	// or brutes.
	if r.cp == b.start && p < NumPatterns && chaserPool&(uint32(1)<<p) != 0 {
		return false
	}
	b.cur = r
	ok := true
	switch p {
	case PatSpikes:
		ok = b.patSpikes(r, lv)
	case PatGap:
		ok = b.patGap(r, lv)
	case PatCrumble:
		ok = b.patCrumble(r, lv)
	case PatGate:
		ok = b.patGate(r, lv)
	case PatArchers:
		ok = b.patArchers(r, lv)
	case PatSlimes:
		ok = b.patSlimes(r, lv)
	case PatBrute:
		ok = b.patBrute(r, lv)
	case PatGargoyle:
		ok = b.patGargoyle(r, lv)
	case PatFireRun:
		ok = b.patFireRun(r, lv)
	case PatShove:
		ok = b.patShove(r, lv)
	case PatChase:
		ok = b.patChase(r, lv)
	case PatCrossfire:
		ok = b.patCrossfire(r, lv)
	default:
		b.gotoOut(r)
	}
	if ok {
		r.pat = p
	}
	return ok
}

// spare reports how many more monsters the floor's budget allows.
func (b *builder) spare() int {
	return b.monCap - b.nmons
}

// patSpikes: spikes timed to the 4-beat wave. Spikes are up when
// (beat + x + y) % 4 >= 2. A step west or north lowers x + y as the beat
// rises, so it keeps pace with the wave: a run of spikes walked that way is
// down all along once it is down underfoot. A step east or south does not, so
// two spikes walked that way in a row can never both be down. The route's
// spikes follow that rule, and every stretch of them starts from a floor tile
// where the walk can stand and wait for the wave; whatever beat the walk
// arrives on, it can cross. Light: a one-wide corridor. Full: the rest of the
// room is spikes too.
func (b *builder) patSpikes(r *room, lv int) bool {
	if r.w*r.h < 6 {
		return false
	}
	b.wroute(r)
	if lv == 0 {
		b.fill(r, tileWall)
		for i := 0; i < b.rn; i++ {
			b.put(r, b.rtx[i], b.rty[i], tileFloor)
		}
	} else {
		for y := 0; y < r.h; y++ {
			for x := 0; x < r.w; x++ {
				if !b.onRoute(x, y) {
					b.put(r, x, y, tileSpike)
				}
			}
		}
	}
	prev := false // tile i-1 is spikes
	stones := b.r.intn(2)
	for i := 1; i < b.rn; i++ {
		j := r.at(b, b.rtx[i], b.rty[i])
		d := j - r.at(b, b.rtx[i-1], b.rty[i-1])
		withWave := d == -1 || d == -b.w
		spike := !prev || withWave
		if spike && !withWave {
			// Across the wave: every other tile, from a random first one.
			spike = (i+stones)%2 == 0
		}
		if spike {
			b.tiles[j] = tileSpike
		}
		prev = spike
	}
	b.cornerSteps(r)
	b.gotoOut(r)
	return true
}

// timeRoute lays spikes on the current route's tiles from index from on: those
// the walk is on while they are down, if it sets off from r's checkpoint on a
// beat that is q mod 4 and reaches route tile i i beats later (i-1 from the
// start, which is A itself), for the q among those in mask (bit c: q == c)
// that lays the most.
func (b *builder) timeRoute(r *room, from, mask int) {
	off := 0
	if r.cp == b.start {
		off = -1
	}
	q, best := 0, -1
	for c := 0; c < 4; c++ {
		if mask&(1<<uint(c)) == 0 {
			continue
		}
		n := 0
		for i := from; i < b.rn; i++ {
			j := r.at(b, b.rtx[i], b.rty[i])
			if (c+i+off+j%b.w+j/b.w)%4 < 2 {
				n++
			}
		}
		if n > best {
			best, q = n, c
		}
	}
	for i := from; i < b.rn; i++ {
		j := r.at(b, b.rtx[i], b.rty[i])
		if (q+i+off+j%b.w+j/b.w)%4 < 2 {
			b.tiles[j] = tileSpike
		}
	}
}

// cornerSteps adds a goto to every bend of the current route, so the walk
// follows it exactly (in a spike field the straight runs between bends are the
// only shortest paths).
func (b *builder) cornerSteps(r *room) {
	for i := 1; i+1 < b.rn; i++ {
		dx0, dy0 := b.rtx[i]-b.rtx[i-1], b.rty[i]-b.rty[i-1]
		dx1, dy1 := b.rtx[i+1]-b.rtx[i], b.rty[i+1]-b.rty[i]
		// Leave room for the exit goto and the finale's hunt and goto.
		if (dx0 != dx1 || dy0 != dy1) && r.ns < maxSteps-3 {
			b.gotoL(r, b.rtx[i], b.rty[i])
		}
	}
}

// patGap: a trench of pits across the room, crossed with a dash. Full: the
// trench is two wide except at two rows, where the dash must cross. Monsters
// cannot cross pits, so anything chasing stays behind.
func (b *builder) patGap(r *room, lv int) bool {
	endx := r.w - 1
	if r.turn {
		endx = r.bx
	}
	if endx < 2 {
		return false
	}
	gx := 1 + b.r.intn(endx-1)
	wide := lv >= 1 && gx+2 <= endx && r.h >= 3
	cr := b.r.intn(r.h)
	// The wide trench narrows at two rows, so one monster on the far bank
	// cannot hold the only landing.
	cr2 := (cr + 1 + b.r.intn(r.h-1)) % r.h
	for y := 0; y < r.h; y++ {
		b.put(r, gx, y, tilePit)
		if wide && y != cr && y != cr2 {
			b.put(r, gx+1, y, tilePit)
		}
	}
	b.gotoL(r, gx-1, cr)
	r.addStep(opCross, r.out, r.face(1))
	b.gotoOut(r)
	return true
}

// patCrumble: a chasm with a crumble bridge along the route; each tile falls
// the beat after you leave it. Full: a gargoyle at the chasm's edge fires
// across the bridge.
func (b *builder) patCrumble(r *room, lv int) bool {
	if r.w < 3 || r.w*r.h < 8 {
		return false
	}
	b.wroute(r)
	b.fill(r, tilePit)
	for i := 0; i < b.rn; i++ {
		b.put(r, b.rtx[i], b.rty[i], tileCrum)
	}
	b.put(r, 0, r.ay, tileFloor)
	b.put(r, b.rtx[b.rn-1], b.rty[b.rn-1], tileFloor)
	if lv >= 1 {
		n := 1
		if lv >= 2 && b.r.coin() {
			n = 2
		}
		b.laneGargoyles(r, n, true)
	}
	b.gotoOut(r)
	return true
}

// patGate: the exit door is a gate, opened while a plate is held. The plate is
// two tiles before the door: stand on it, then dash, landing on the gate before
// it shuts (walking off the plate shuts it at once). Full: the tile between is
// a pit.
func (b *builder) patGate(r *room, lv int) bool {
	if b.gates > 0 || r.last {
		return false
	}
	var px, py, qx, qy, side int
	if r.turn {
		// The plate and the tile beyond it must not be A, the way in.
		if r.h < 3 || r.bx == 0 && r.ay <= 1 {
			return false
		}
		px, py, qx, qy, side = r.bx, 1, r.bx, 0, 0
	} else {
		if r.w < 3 {
			return false
		}
		px, py, qx, qy, side = r.w-2, r.by, r.w-1, r.by, 1
	}
	b.put(r, px, py, tilePlate)
	if lv >= 1 {
		b.put(r, qx, qy, tilePit)
	}
	b.tiles[r.out] = tileGate
	b.gates++
	b.gotoL(r, px, py)
	b.dashL(r, side, qx+(qx-px), qy+(qy-py))
	return true
}

// patArchers: archers whose rows and columns cross the route; never stand in
// a line. Full: pillars break some lines and give cover.
func (b *builder) patArchers(r *room, lv int) bool {
	if r.w < 3 || r.h < 3 || b.spare() < 1 {
		return false
	}
	b.zroute(r, b.r.intn(r.w))
	if lv >= 1 {
		b.pillars(r, lv)
	}
	n := 1 + lv
	if b.slay {
		n++
	}
	// Every tile, from a random one on, until the gallery has its archers.
	placed, cells := 0, r.w*r.h
	o := b.r.intn(cells)
	for k := 0; k < cells && placed < n; k++ {
		x, y := (o+k)%cells%r.w, (o+k)%cells/r.w
		i := r.at(b, x, y)
		if y == r.ay || r.fromA(x, y) < 2 || b.onRoute(x, y) || !b.seesRoute(i) ||
			b.line(i, r.cp) || b.line(i, r.out) || b.nearArcher(i) {
			continue
		}
		if b.monL(r, sim.KArcher, x, y, 3, 0) {
			placed++
		}
	}
	if placed == 0 {
		b.unplace(r)
		return false
	}
	b.gotoOut(r)
	return true
}

// patSlimes: slimes that close in from the far side. A slime only strikes a
// hero who stands still next to it, so keep moving and bump the ones in the
// way. Full: holes in the floor to shove them into.
func (b *builder) patSlimes(r *room, lv int) bool {
	if r.w*r.h < 9 || b.spare() < 1 {
		return false
	}
	b.zroute(r, b.r.intn(r.w))
	if lv >= 1 {
		for k := 0; k < lv+1; k++ {
			x, y := b.r.intn(r.w), b.r.intn(r.h)
			if !b.nearRoute(x, y) && r.fromA(x, y) >= 2 {
				b.put(r, x, y, tilePit)
			}
		}
	}
	n := 2 + lv
	if b.slay {
		n += 2
	}
	if b.lvl == 0 {
		n = 2
	}
	placed := 0
	for k := 0; k < n; k++ {
		if b.farMon(r, sim.KSlime, 3) {
			placed++
		}
	}
	if placed == 0 {
		b.unplace(r)
		return false
	}
	b.gotoOut(r)
	return true
}

// patBrute: a trench splits the room and a brute paces the far bank. It
// cannot cross pits, so it keeps opposite the hero; walk along the near bank to
// draw it off the landing, then dash across and keep moving while it winds up
// (two beats) before its blow. Full: a second brute on the far bank (not in
// the finale's arena).
func (b *builder) patBrute(r *room, lv int) bool {
	gx, ok := b.trench(r, 2)
	if !ok || r.h < 3 || b.spare() < 1 {
		return false
	}
	// The brute starts on the far bank, away from the entry row.
	by := r.h - 1
	if r.ay >= r.h/2 {
		by = 0
	}
	if !b.monL(r, sim.KBrute, gx+1, by, 3, uint8(b.r.intn(2))) {
		return false
	}
	for y := 0; y < r.h; y++ {
		b.put(r, gx, y, tilePit)
	}
	// Full: a second brute. Not in the finale's arena, where every brute must
	// be killed; slimes fill it instead.
	if lv >= 1 && !b.slay {
		b.monL(r, sim.KBrute, r.w-1, r.h-1-by, 3, uint8(b.r.intn(2)))
	}
	b.gotoL(r, gx-1, r.ay)
	r.addStep(opCross, r.out, r.face(1))
	b.gotoOut(r)
	return true
}

// trench picks a column gx for a full-height trench with the entry on its
// near side and at least far columns, B included, beyond it.
func (b *builder) trench(r *room, far int) (int, bool) {
	hi := r.w - 1 - far
	if r.turn && r.bx-1 < hi {
		hi = r.bx - 1
	}
	if hi < 1 {
		return 0, false
	}
	return 1 + b.r.intn(hi), true
}

// patGargoyle: gargoyles at the room's edge fire across the route every four
// beats; cross each lane between fireballs.
func (b *builder) patGargoyle(r *room, lv int) bool {
	if r.h < 3 || b.spare() < 1 {
		return false
	}
	b.zroute(r, b.r.intn(r.w))
	if b.laneGargoyles(r, 1+lv, false) == 0 {
		return false
	}
	b.gotoOut(r)
	return true
}

// patFireRun: a corridor with a gargoyle at its mouth firing down it. Enter
// just behind a fireball and keep moving: the next one follows four tiles back.
// Full: the corridor is spikes, laid for the walk's beat, so stopping is never
// free.
func (b *builder) patFireRun(r *room, lv int) bool {
	if b.spare() < 1 {
		return false
	}
	end := r.w - 1
	if r.turn {
		end = r.bx
	}
	if end < 4 || r.h < 2 {
		return false
	}
	var rows [16]int
	nr := 0
	for y := 0; y < r.h; y++ {
		if y == r.ay || !r.turn && y == r.by || r.turn && y == 0 {
			continue
		}
		rows[nr] = y
		nr++
	}
	if nr == 0 {
		return false
	}
	lane := rows[b.r.intn(nr)]
	b.fill(r, tileWall)
	b.put(r, 0, r.ay, tileFloor)
	b.vline(r, 1, r.ay, lane)
	for x := 0; x <= end; x++ {
		b.put(r, x, lane, tileFloor)
	}
	if r.turn {
		b.vline(r, end, lane, 0)
	} else {
		b.vline(r, end, lane, r.by)
	}
	phase := b.r.intn(4)
	b.monL(r, sim.KGargoyle, 0, lane, 1, uint8(phase))
	// The route, for timing: A, the column down to the lane, the lane.
	b.cur, b.rn = r, 0
	b.rpush(0, r.ay)
	for y, d := r.ay, 1; ; y += d {
		if lane < r.ay {
			d = -1
		}
		b.rpush(1, y)
		if y == lane {
			break
		}
	}
	for x := 2; x <= end; x++ {
		b.rpush(x, lane)
	}
	// The gargoyle fires on beats f = -phase mod 4. A fireball fired on beat f
	// is on lane tile x on beat f+x; the walk is on it on beat te+x-1, where te
	// is the beat it steps into the lane at x = 1. It is safe when te is f or
	// f+3 mod 4: it then keeps pace one tile behind a fireball, or ahead of
	// one. Spikes (Full) are laid for the better of the two, so one beat to
	// set off on clears both the fire and the spikes.
	f := (4 - phase) % 4
	safe := 1<<uint((f)%4) | 1<<uint((f+3)%4)
	// timeRoute counts in start beats; te is route index 1+|lane-ay| later.
	k := 1 + abs(lane-r.ay)
	off := 0
	if r.cp == b.start {
		off = -1
	}
	mask := 0
	for c := 0; c < 4; c++ {
		if safe&(1<<uint((c+k+off+4)%4)) != 0 {
			mask |= 1 << uint(c)
		}
	}
	// The walk finds the beat by waiting at the door (see walker.room).
	if lv >= 1 {
		b.timeRoute(r, k+1, mask)
	}
	b.gotoOut(r)
	return true
}

// patShove: a one-wide ledge path over a chasm with slimes coming along it.
// Bump them, or dash into one at a bend and shove it into the drop.
func (b *builder) patShove(r *room, lv int) bool {
	if r.w < 4 || r.h < 2 || b.spare() < 1 {
		return false
	}
	b.wroute(r)
	b.fill(r, tilePit)
	for i := 0; i < b.rn; i++ {
		b.put(r, b.rtx[i], b.rty[i], tileFloor)
	}
	n := 1
	if lv >= 1 {
		n = 2
	}
	if b.slay {
		n++
	}
	placed := 0
	for k := b.rn - 1; k > 0 && placed < n; k-- {
		if r.fromA(b.rtx[k], b.rty[k]) >= 4 && b.monL(r, sim.KSlime, b.rtx[k], b.rty[k], 3, uint8(b.r.intn(2))) {
			placed++
			k -= 2
		}
	}
	if placed == 0 {
		b.unplace(r)
		return false
	}
	b.gotoOut(r)
	return true
}

// patChase: a crumbling floor with slimes behind it. The tiles you leave fall,
// and a slime following on them falls with them.
func (b *builder) patChase(r *room, lv int) bool {
	if r.w*r.h < 12 || b.spare() < 1 {
		return false
	}
	b.zroute(r, b.r.intn(r.w))
	n := 2
	if lv >= 2 || b.slay {
		n = 3
	}
	placed := 0
	for k := 0; k < n; k++ {
		if b.farMon(r, sim.KSlime, 3) {
			placed++
		}
	}
	if placed == 0 {
		return false
	}
	for y := 0; y < r.h; y++ {
		for x := 0; x < r.w; x++ {
			i := r.at(b, x, y)
			if b.tiles[i] == tileFloor && !b.monAt(i) && !(x == 0 && y == r.ay) {
				b.tiles[i] = tileCrum
			}
		}
	}
	b.put(r, b.rtx[b.rn-1], b.rty[b.rn-1], tileFloor)
	b.gotoOut(r)
	return true
}

// patCrossfire: two archers face each other along a row the route crosses.
// Step into the row and out again: both draw on you, and their arrows cross
// the empty row into each other.
func (b *builder) patCrossfire(r *room, lv int) bool {
	if r.w < 3 || b.spare() < 2 {
		return false
	}
	var cx, ylo, yhi int
	if r.turn {
		if r.bx < 1 || r.bx > r.w-2 || r.ay < 2 {
			return false
		}
		cx, ylo, yhi = r.bx, 0, r.ay
	} else {
		ylo, yhi = r.ay, r.by
		if ylo > yhi {
			ylo, yhi = yhi, ylo
		}
		if yhi-ylo < 2 {
			return false
		}
		cx = 1 + b.r.intn(r.w-2)
	}
	b.zroute(r, cx)
	row := ylo + 1 + b.r.intn(yhi-ylo-1)
	b.monL(r, sim.KArcher, 0, row, 1, 0)
	b.monL(r, sim.KArcher, r.w-1, row, 3, 0)
	// Shield each archer's column from the route's runs where there is room.
	b.shield(r, 0, row)
	b.shield(r, r.w-1, row)
	// Slimes to keep the crossing honest, off the archers' row so the arrows
	// still meet.
	n := 0
	if lv >= 2 {
		n = 1
	}
	if b.slay {
		n += 2
	}
	for try := 0; try < 16 && n > 0 && b.spare() > 0; try++ {
		x, y := r.w-1-b.r.intn((r.w+1)/2), b.r.intn(r.h)
		if y != row && r.fromA(x, y) >= 4 && b.monL(r, sim.KSlime, x, y, 3, uint8(b.r.intn(4))) {
			n--
		}
	}
	b.gotoOut(r)
	return true
}

// nearArcher reports whether an archer already placed shares a row or column
// with tile i (they would only shoot each other, and their lines would cover
// each other's approach), or touches it.
func (b *builder) nearArcher(i int) bool {
	x, y := i%b.w, i/b.w
	for j := 0; j < b.nmons; j++ {
		if b.mons[j].kind != sim.KArcher {
			continue
		}
		ax, ay := b.mons[j].at%b.w, b.mons[j].at/b.w
		if ax == x || ay == y || abs(ax-x) <= 1 && abs(ay-y) <= 1 {
			return true
		}
	}
	return false
}

// shield walls the tiles next to (x, y) in its column, toward each route run,
// where that leaves the route whole, so the archer there sees only its row.
func (b *builder) shield(r *room, x, y int) {
	for _, d := range []int{-1, 1} {
		for yy := y + d; yy >= 0 && yy < r.h; yy += d {
			if b.onRoute(x, yy) {
				if yy != y+d {
					b.put(r, x, y+d, tileWall)
				}
				break
			}
		}
	}
}

// laneGargoyles puts up to n gargoyles on the room's top or bottom edge, each
// firing down a column the route crosses at least two tiles away. On a chasm
// (onPit) the gargoyle's tile is raised from the pit. It returns how many it
// placed.
func (b *builder) laneGargoyles(r *room, n int, onPit bool) int {
	placed := 0
	var lanes [4]int
	for try := 0; try < 16 && placed < n && b.spare() > 0; try++ {
		x := 1 + b.r.intn(r.w-1)
		if r.turn && x == r.bx {
			continue
		}
		// A tile between lanes, or they are one wall of fire.
		apart := true
		for k := 0; k < placed; k++ {
			apart = apart && abs(x-lanes[k]) >= 2
		}
		if !apart {
			continue
		}
		// The lane must cross the route at exactly one tile: a lane running
		// along the route would fire straight down it.
		ry, on := -1, 0
		for y := 0; y < r.h; y++ {
			if b.onRoute(x, y) {
				ry = y
				on++
			}
		}
		if on != 1 {
			continue
		}
		gy, face := 0, 2
		if ry < r.h/2 {
			gy, face = r.h-1, 0
		}
		if b.onRoute(x, gy) || gy-ry < 2 && ry-gy < 2 || b.gargoyleNear(r.at(b, x, gy)) {
			continue
		}
		if onPit {
			b.put(r, x, gy, tileFloor)
		}
		if b.monL(r, sim.KGargoyle, x, gy, face, uint8(b.r.intn(4))) {
			lanes[placed] = x
			placed++
		} else if onPit {
			b.put(r, x, gy, tilePit)
		}
	}
	return placed
}

// gargoyleNear reports a gargoyle on a tile touching tile i (diagonals too).
func (b *builder) gargoyleNear(i int) bool {
	for j := 0; j < b.nmons; j++ {
		g := b.mons[j]
		if g.kind == sim.KGargoyle && abs(g.at%b.w-i%b.w) <= 1 && abs(g.at/b.w-i/b.w) <= 1 {
			return true
		}
	}
	return false
}

// pillars walls a few tiles off the route, away from the doors.
func (b *builder) pillars(r *room, n int) {
	for k := 0; k < n*3 && n > 0; k++ {
		x, y := b.r.intn(r.w), b.r.intn(r.h)
		if b.nearRoute(x, y) || b.get(r, x, y) != tileFloor || b.monAt(r.at(b, x, y)) {
			continue
		}
		b.put(r, x, y, tileWall)
		n--
	}
}

// farMon places a monster on a free floor tile at least minD from A, trying
// the far tiles first. It reports whether it placed one.
func (b *builder) farMon(r *room, kind uint8, minD int) bool {
	for try := 0; try < 12; try++ {
		x, y := r.w-1-b.r.intn((r.w+1)/2), b.r.intn(r.h)
		if r.fromA(x, y) >= minD && b.monL(r, kind, x, y, 3, uint8(b.r.intn(4))) {
			return true
		}
	}
	return false
}

// unplace undoes walls a pattern drew into r before finding it could not
// place its monsters: the room goes back to plain floor.
func (b *builder) unplace(r *room) {
	b.fill(r, tileFloor)
}

func (b *builder) vline(r *room, x, y0, y1 int) {
	if y0 > y1 {
		y0, y1 = y1, y0
	}
	for y := y0; y <= y1; y++ {
		b.put(r, x, y, tileFloor)
	}
}

// line reports a clear row or column line between tiles i and j (no wall or
// gate strictly between).
func (b *builder) line(i, j int) bool {
	xi, yi, xj, yj := i%b.w, i/b.w, j%b.w, j/b.w
	st := 0
	switch {
	case yi == yj && xi < xj:
		st = 1
	case yi == yj && xi > xj:
		st = -1
	case xi == xj && yi < yj:
		st = b.w
	case xi == xj && yi > yj:
		st = -b.w
	default:
		return false
	}
	for k := i + st; k != j; k += st {
		if c := b.tiles[k]; c == tileWall || c == tileGate {
			return false
		}
	}
	return true
}

// seesRoute reports whether tile i has a clear row or column line to a tile of
// the current route.
func (b *builder) seesRoute(i int) bool {
	x0, y0 := i%b.w, i/b.w
	for s := 0; s < 4; s++ {
		dx, dy := sideVec(s)
		for x, y := x0+dx, y0+dy; x >= 0 && y >= 0 && x < b.w && y < b.h; x, y = x+dx, y+dy {
			k := y*b.w + x
			if c := b.tiles[k]; c == tileWall || c == tileGate {
				break
			}
			if b.rmark[k] == b.stamp {
				return true
			}
		}
	}
	return false
}
