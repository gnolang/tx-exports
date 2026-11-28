package sim

// Monster and projectile rules. Facing is 0 N, 1 E, 2 S, 3 W.
//
// Gas (measured with gno test -print-runtime-metrics): a field selector or array
// index costs about 550 gas and a call about 2k, while locals are nearly free, so
// the per-beat loops below hoist fields into locals and stay flat. Game.Occ
// answers "who or what blocks this tile" in one read and is kept current on every
// move, death, collapse and gate toggle. Monsters that do not act this beat are
// skipped by the Tick/Sched bitmasks, and blocked idle archers cost nothing:
// seenArchers finds the ones with sight from solidRow/solidCol once per beat.
// TestWorstCaseBudget pins the worst case.

const (
	windBrute  = 2
	windArcher = 2
	cdArcher   = 2
)

// bitIndex maps (b * 0x077CB531) >> 27, for a single set bit b, to its position
// (de Bruijn), so loops visit only set bits.
var bitIndex = [32]uint8{
	0, 1, 28, 2, 29, 14, 24, 3, 30, 22, 20, 15, 25, 17, 4, 8,
	31, 27, 13, 23, 21, 19, 16, 7, 26, 12, 18, 6, 11, 5, 10, 9,
}

func faceVec(f uint8) (int, int) {
	switch f & 3 {
	case 0:
		return 0, -1
	case 1:
		return 1, 0
	case 2:
		return 0, 1
	}
	return -1, 0
}

// faceToward returns the facing from (x, y) toward a different tile in the same
// row or column.
func faceToward(x, y, tx, ty int) uint8 {
	switch {
	case tx > x:
		return 1
	case tx < x:
		return 3
	case ty > y:
		return 2
	}
	return 0
}

// kill removes monster i and credits the kill.
func (g *Game) kill(i int) {
	e := &g.Mons[i]
	e.Alive = false
	g.Live &^= 1 << uint(i)
	if e.Kind == KArcher {
		g.setIdle(int(e.X), int(e.Y), false)
	}
	x, y := int(e.X), int(e.Y)
	oi := (y+1)*int(g.PW) + x + 1
	if g.Tiles[y*int(g.M.W)+x] == TPit {
		g.Occ[oi] = OccPit
	} else {
		g.Occ[oi] = e.Under
		if e.Under != 0 {
			g.GateOcc &^= 1 << (e.Under & 7)
		}
	}
	if e.Kind != KGargoyle {
		g.Foes--
	}
	g.Kills++
	g.Ev |= EvKill
}

// dmgMon deals 1 damage to monster i, ignoring shields.
func (g *Game) dmgMon(i int) {
	e := &g.Mons[i]
	e.HP--
	g.Ev |= EvHit
	if e.HP <= 0 {
		g.kill(i)
	}
}

// hitMon deals 1 damage to monster i from the tile (fx, fy). Gargoyles are
// unkillable and a brute's shield blocks hits from the tile it faces. It reports
// whether the hit landed.
func (g *Game) hitMon(i, fx, fy int) bool {
	e := &g.Mons[i]
	switch e.Kind {
	case KGargoyle:
		return false
	case KBrute:
		dx, dy := faceVec(e.Facing)
		if int(e.X)+dx == fx && int(e.Y)+dy == fy {
			return false
		}
	}
	g.dmgMon(i)
	return true
}

// moveMon moves monster i to the open tile (x, y): free, or an open gate.
func (g *Game) moveMon(i, x, y int) {
	e := &g.Mons[i]
	pw := int(g.PW)
	to := (y+1)*pw + x + 1
	g.leaveEnter(i, e, (int(e.Y)+1)*pw+int(e.X)+1, to, g.Occ[to])
	e.X, e.Y = int8(x), int8(y)
}

// leaveEnter moves monster i's Occ entry from index from to index to, whose
// code was under, keeping Under and GateOcc. Only a gate code is remembered: a
// shove can also land a monster on a pit (OccPit), where kill restores OccPit.
func (g *Game) leaveEnter(i int, e *Ent, from, to int, under uint8) {
	g.Occ[from] = e.Under
	if e.Under != 0 {
		g.GateOcc &^= 1 << (e.Under & 7)
	}
	if under&0xF8 == OccGate {
		g.GateOcc |= 1 << (under & 7)
	} else {
		under = 0
	}
	e.Under = under
	g.Occ[to] = uint8(i + 1)
}

// setIdle marks or clears an idle archer at (x, y) in IdleX/IdleY.
func (g *Game) setIdle(x, y int, on bool) {
	if on {
		g.IdleX[y] |= 1 << uint(x)
		g.IdleY[x] |= 1 << uint(y)
	} else {
		g.IdleX[y] &^= 1 << uint(x)
		g.IdleY[x] &^= 1 << uint(y)
	}
}

// visible returns the positions q on a line from which no solid (mask s) lies
// strictly between q and p. Positions that are themselves solid or beyond the
// grid may be set; callers mask them with real archer positions.
func visible(s uint32, p uint) uint32 {
	low := uint32(1)<<p - 1 // positions below p
	b := s & low
	// Smear the highest solid below p downward: b covers every position up to it.
	b |= b >> 1
	b |= b >> 2
	b |= b >> 4
	b |= b >> 8
	b |= b >> 16
	high := ^(low | uint32(1)<<p) // positions above p
	if a := s & high; a != 0 {
		high &= (a & (^a + 1)) - 1 // below the lowest solid above p
	}
	return low&^b | high
}

// seenArchers returns the bits of idle archers in the hero's row or column with
// clear sight to the hero. Sight blockers (walls, closed gates) and archer
// positions cannot change during the monster phase, so this is exact for it.
func (g *Game) seenArchers(hx, hy int) uint16 {
	var seen uint16
	pw := int(g.PW)
	if r := g.IdleX[hy]; r != 0 {
		r &= visible(g.solidRow(hy), uint(hx))
		for x := 0; r != 0; x++ {
			if r&1 != 0 {
				seen |= 1 << uint(g.Occ[(hy+1)*pw+x+1]-1)
			}
			r >>= 1
		}
	}
	if c := uint32(g.IdleY[hx]); c != 0 {
		c &= visible(g.solidCol(hx), uint(hy))
		for y := 0; c != 0; y++ {
			if c&1 != 0 {
				seen |= 1 << uint(g.Occ[(y+1)*pw+hx+1]-1)
			}
			c >>= 1
		}
	}
	return seen
}

// spawnProj puts a projectile on monster i's tile heading in its facing. Live
// projectiles are kept packed in Projs[:NProjs]. It returns false when all slots
// are live.
func (g *Game) spawnProj(i int, fire bool) bool {
	if g.NProjs >= MaxProjs {
		return false
	}
	e := &g.Mons[i]
	dx, dy := faceVec(e.Facing)
	g.Projs[g.NProjs] = Proj{X: e.X, Y: e.Y, DX: int8(dx), DY: int8(dy), Alive: true, Fire: fire, Src: uint8(i + 1)}
	g.NProjs++
	return true
}

// projectilesPhase moves every live projectile one tile. A projectile hits the
// hero when he stands on its next tile or on its current tile. Live projectiles stay
// packed in Projs[:NProjs]: a dead one is replaced by the last (not yet moved)
// one. It reports whether the hero was hit.
//
// A projectile never hits its shooter (Src). The ruling only exempts the first
// move, but the two are equivalent: shooters move only by shove (dash cooldown
// at least 3 beats), so after its first move a projectile is always ahead of its
// shooter and pulls away 1 tile per beat.
func (g *Game) projectilesPhase() bool {
	hit := false
	n := int(g.NProjs)
	pw := int(g.PW)
	hx, hy := g.HX, g.HY
	for k := 0; k < n; {
		p := &g.Projs[k]
		px, py := p.X, p.Y
		nx, ny := px+p.DX, py+p.DY
		// The hero is hit on the projectile's next tile, or on its current one if
		// he stepped into it (no passing through).
		if (nx == hx && ny == hy) || (px == hx && py == hy) {
			hit = true
		} else if o := g.Occ[(int(ny)+1)*pw+int(nx)+1]; o == 0 || o == OccPit || o == p.Src ||
			(o <= MaxMonsters && !g.Mons[o-1].Alive) || (o&0xF8 == OccGate && g.gateOpen(o)) {
			p.X, p.Y = nx, ny
			k++
			continue
		} else if o <= MaxMonsters { // else a wall, closed gate or out of bounds
			g.hitMon(int(o-1), int(px), int(py))
		}
		// The projectile is spent: move the last live one into its slot.
		n--
		g.Projs[k] = g.Projs[n]
		g.Projs[n] = Proj{}
	}
	g.NProjs = uint8(n)
	return hit
}

// monstersPhase lets the monsters scheduled this beat act in spawn order:
// slimes and brutes when (beat+phase)%2 == 0, gargoyles when (beat+phase)%4 == 0,
// busy archers and winding brutes every beat, idle archers when they see the
// hero. moved says the hero changed tile this beat. It reports whether the hero
// was hit.
func (g *Game) monstersPhase(moved bool) bool {
	hit := false
	hx, hy := int(g.HX), int(g.HY)
	pw := int(g.PW)
	// No monster stands on a gate, so a walker leaving its tile leaves 0. Safe
	// to hoist: only a monster that steps onto a gate this phase changes it, and
	// it has already acted.
	offGates := g.GateOcc == 0
	m := g.Tick | g.Sched[g.Beat&3]
	if g.IdleX[hy] != 0 || g.IdleY[hx] != 0 {
		m |= g.seenArchers(hx, hy)
	}
	m &= g.Live
	for m != 0 {
		low := m & (^m + 1)
		m ^= low
		i := int(bitIndex[(uint32(low)*0x077CB531)>>27])
		e := &g.Mons[i]
		switch e.Kind {
		case KSlime, KBrute:
			if e.Wind != 0 { // brute winding up
				e.Wind--
				if e.Wind == 0 {
					g.Tick &^= 1 << uint(i)
					if g.strike(i) {
						hit = true
					}
					m &= g.Live // the strike may have killed a later monster
				}
				continue
			}
			x, y := int(e.X), int(e.Y)
			dx, dy := hx-x, hy-y
			hf, adx, hs := uint8(1), dx, 1
			if dx < 0 {
				hf, adx, hs = 3, -dx, -1
			}
			vf, ady, vs := uint8(2), dy, 1
			if dy < 0 {
				vf, ady, vs = 0, -dy, -1
			}
			if adx+ady == 1 { // adjacent: attack or wind up
				if adx == 1 {
					e.Facing = hf
				} else {
					e.Facing = vf
				}
				if e.Kind == KBrute {
					e.Wind = windBrute
					g.Tick |= 1 << uint(i)
				} else if !moved {
					// A slime attacks only a hero who was already next to it
					// when the beat began (a hero who moved this beat cannot
					// have been: one step or dash never keeps him adjacent).
					// One who just stepped up is only faced.
					hit = true
				}
				continue
			}
			// Step along the larger axis (ties horizontal), else the other one. A
			// tile is open when its Occ is 0 (in bounds, no wall, closed gate, pit
			// or monster); the hero is not adjacent, so never the target. The
			// primary axis always has a nonzero distance. The move is inlined
			// (see moveMon): walkers can move on every acting beat.
			// An open gate (OccGate+k) is open too. Walls and pits (>= OccPit)
			// and monsters (< OccGate) settle in one or two compares.
			oi := (y+1)*pw + x + 1
			to, o, f := 0, uint8(0), uint8(0)
			if adx >= ady {
				to, f = oi+hs, hf
				if o = g.Occ[to]; o != 0 && (o >= OccPit || o < OccGate || !g.gateOpen(o)) {
					if dy == 0 {
						continue
					}
					to, f = oi+vs*pw, vf
					if o = g.Occ[to]; o != 0 && (o >= OccPit || o < OccGate || !g.gateOpen(o)) {
						continue
					}
				}
			} else {
				to, f = oi+vs*pw, vf
				if o = g.Occ[to]; o != 0 && (o >= OccPit || o < OccGate || !g.gateOpen(o)) {
					if dx == 0 {
						continue
					}
					to, f = oi+hs, hf
					if o = g.Occ[to]; o != 0 && (o >= OccPit || o < OccGate || !g.gateOpen(o)) {
						continue
					}
				}
			}
			if o == 0 && offGates {
				g.Occ[oi] = 0
				g.Occ[to] = uint8(i + 1)
			} else {
				g.leaveEnter(i, e, oi, to, o)
			}
			if f == hf {
				e.X = int8(x + hs)
			} else {
				e.Y = int8(y + vs)
			}
			e.Facing = f
		case KArcher:
			if e.CD != 0 {
				e.CD--
				if e.CD == 0 { // idle again
					g.Tick &^= 1 << uint(i)
					g.setIdle(int(e.X), int(e.Y), true)
				}
				continue
			}
			if e.Aim {
				e.Wind--
				if e.Wind == 0 {
					e.Aim = false
					e.CD = cdArcher
					if g.spawnProj(i, false) {
						g.Ev |= EvFire
					}
				}
				continue
			}
			// Idle archers are visited only when seenArchers found clear sight
			// to the hero on a shared row or column: turn and aim.
			x, y := int(e.X), int(e.Y)
			e.Facing = faceToward(x, y, hx, hy)
			e.Aim = true
			e.Wind = windArcher
			g.Tick |= 1 << uint(i)
			g.setIdle(x, y, false)
		case KGargoyle:
			if g.spawnProj(i, true) {
				g.Ev |= EvFire
			}
		}
	}
	return hit
}

// strike resolves brute i's blow on the tile it faces. It reports a hero hit.
func (g *Game) strike(i int) bool {
	e := &g.Mons[i]
	x, y := int(e.X), int(e.Y)
	dx, dy := faceVec(e.Facing)
	tx, ty := x+dx, y+dy
	if tx == int(g.HX) && ty == int(g.HY) {
		return true
	}
	if j := g.monsterAt(tx, ty); j >= 0 {
		g.hitMon(j, x, y)
	}
	return false
}

// shove resolves a dash whose first tile (x1, y1) holds monster i. It reports
// whether the dash happened (and so grants dash invulnerability).
func (g *Game) shove(i, x1, y1, dx, dy int) bool {
	if g.Mons[i].Kind == KGargoyle {
		g.Ev |= EvBump
		return false
	}
	tx, ty := x1+dx, y1+dy
	if g.closedAt(tx, ty) || g.monsterAt(tx, ty) >= 0 {
		g.Ev |= EvBump
		return false
	}
	if e := &g.Mons[i]; e.Kind == KArcher && e.CD == 0 && !e.Aim {
		g.setIdle(x1, y1, false)
		g.setIdle(tx, ty, true)
	}
	t := g.Tiles[ty*int(g.M.W)+tx]
	g.moveMon(i, tx, ty)
	g.HX, g.HY = int8(x1), int8(y1)
	g.HIdx = uint16(y1*int(g.M.W) + x1)
	g.DashCD = g.DashMax
	g.Ev |= EvShove | EvDash
	switch {
	case t == TPit:
		g.kill(i) // leaves OccPit
		g.Ev |= EvFall
	case t == TSpikes && (int(g.Beat)+tx+ty)%4 >= 2:
		g.dmgMon(i)
	}
	return true
}
