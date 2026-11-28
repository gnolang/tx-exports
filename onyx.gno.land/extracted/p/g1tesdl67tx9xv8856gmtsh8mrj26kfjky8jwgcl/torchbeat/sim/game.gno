package sim

// Event bits, reset at the start of every Step.
const (
	EvMove uint32 = 1 << iota
	EvBump
	EvDash
	EvShove
	EvHit
	EvKill
	EvHurt
	EvFall
	EvChest
	EvGate
	EvCrumble
	EvFire
	EvWin
	EvDie
)

// Occ codes above any monster index + 1.
const (
	OccGate uint8 = 0xF0 // OccGate+k: gate k, passable only while open
	OccPit  uint8 = 0xFE // blocks monsters, not projectiles
	OccWall uint8 = 0xFF // wall or out of bounds: blocks both
)

// Runtime-only tile states, never produced by Parse.
const (
	TGateOpen     uint8 = 'o'
	TCrumbleMark  uint8 = 'm' // crumble the hero has left; becomes a pit next beat
	invAfterHit   uint8 = 2
	relicDashMax1 uint8 = 3
	relicDashMax2 uint8 = 8
	defaultDash   uint8 = 5
)

// Ent is a live monster.
type Ent struct {
	Kind   uint8
	X, Y   int8
	HP     int8
	Facing uint8
	Phase  uint8
	Alive  bool
	Wind   uint8 // brute: windup beats left; archer: aim beats left
	Aim    bool  // archer: aim line shown, shot pending
	CD     uint8 // archer: beats before it may aim again
	Under  uint8 // Occ code of its tile without it: 0, or OccGate+k on a gate
}

// Proj is an arrow, or a gargoyle fireball when Fire is set.
type Proj struct {
	X, Y, DX, DY int8
	Alive        bool
	Fire         bool
	Src          uint8 // shooter index + 1 (0 none): a projectile never hits its shooter
}

// Game is the full simulation state. It contains no pointers except M, which is
// read-only after NewGame.
type Game struct {
	M         *Map
	Tiles     [MaxTiles]uint8
	HX, HY    int8
	HIdx      uint16 // hero tile index HY*W + HX
	HP, MaxHP int8
	Inv       uint8
	DashCD    uint8
	DashMax   uint8
	Beat      uint16
	Mons      [MaxMonsters]Ent
	NMons     uint8
	Foes      uint8 // living killable (non-gargoyle) monsters, for SLAY
	// Monster schedule bitmasks (bit i = monster i). A beat visits only
	// (Tick | Sched[beat%4] | idle archers that see the hero) & Live:
	//   Tick: busy monsters that act every beat (aiming or cooling archers,
	//     winding brutes);
	//   Sched[r]: slimes, brutes and gargoyles whose acting beat has beat%4 == r.
	Live  uint16
	Tick  uint16
	Sched [4]uint16
	// Idle archers by position: IdleX[y] has bit x and IdleY[x] has bit y for an
	// idle archer at (x, y). Blocked idle archers cost nothing per beat.
	IdleX [MaxH]uint32
	IdleY [MaxW]uint16
	// Occ is what blocks each tile for monsters and projectiles: 0 free, 1-16 a
	// living monster (index + 1), OccGate+k (gate k), OccPit or OccWall (wall,
	// or the border). It is padded with a 1-tile OccWall border (row stride PW = W+2,
	// tile (x, y) at (y+1)*PW + x+1), so one read answers "in bounds, and can a
	// monster step here or what does an arrow hit" with no bounds check.
	Occ           [MaxOcc]uint8
	PW            uint8
	Projs         [MaxProjs]Proj
	NProjs        uint8 // live projectiles
	Damage, Kills uint8
	Chest, Won    bool
	Dead          bool
	Route         uint32
	Ev            uint32
	FailWhy       string

	// Gate tile indices (Validate caps them at MaxGates; NewGame walls off any
	// extra gate of an unvalidated map). Gates share one plate signal, so their
	// state is O(1) to change: gate k is open when GatesUp (a plate was held at
	// the last hazards phase) or Stuck has bit k (held open by an occupant after
	// the plates were released). GateOcc has bit k while a monster stands on gate
	// k. Tiles keeps TGate for gates; Tile reports TGateOpen when open.
	Gates   [MaxGates]uint16
	NGates  uint16
	GatesUp bool
	Stuck   uint8
	GateOcc uint8
	// Mark is the crumble tile the hero left last beat (it becomes a pit this
	// beat), or -1.
	Mark int16
	// Occ indices of plate tiles (Validate caps them at MaxPlates).
	PlateOI [MaxTiles]uint16
	NPlates uint16
	// Static wall and gate bits per row (bit x) and per column (bit y), for
	// O(1) line of sight; see solidRow/solidCol for closed gates.
	RowWall, RowGate [MaxH]uint32
	ColWall, ColGate [MaxW]uint16
}

// NewGame starts a game on m with the given relic (0 none, 1 glass, 2 bulwark)
// at full HP.
func NewGame(m *Map, relic uint8) Game {
	return NewGameFrom(m, relic, 0)
}

// NewGameFrom is NewGame with a starting hp carried in from an earlier floor.
// hp outside 1..MaxHP for the relic starts at MaxHP.
func NewGameFrom(m *Map, relic uint8, hp int8) Game {
	var g Game
	g.M = m
	g.Tiles = m.Tiles
	g.HX, g.HY = m.StartX, m.StartY
	g.HIdx = uint16(int(m.StartY)*int(m.W) + int(m.StartX))
	g.Tiles[g.HIdx] = TFloor
	w, h := int(m.W), int(m.H)
	pw := w + 2
	g.PW = uint8(pw)
	for x := 0; x < pw; x++ {
		g.Occ[x] = OccWall
		g.Occ[(h+1)*pw+x] = OccWall
	}
	for y := 0; y < h; y++ {
		g.Occ[(y+1)*pw] = OccWall
		g.Occ[(y+1)*pw+w+1] = OccWall
		for x := 0; x < w; x++ {
			i := y*w + x
			switch g.Tiles[i] {
			case TPit:
				g.Occ[(y+1)*pw+x+1] = OccPit
				continue
			case TPlate:
				g.PlateOI[g.NPlates] = uint16((y+1)*pw + x + 1)
				g.NPlates++
				continue
			case TGate:
				if g.NGates < MaxGates {
					g.Occ[(y+1)*pw+x+1] = OccGate + uint8(g.NGates)
					g.Gates[g.NGates] = uint16(i)
					g.NGates++
					g.RowGate[y] |= 1 << uint(x)
					g.ColGate[x] |= 1 << uint(y)
					continue
				}
				g.RowWall[y] |= 1 << uint(x)
				g.ColWall[x] |= 1 << uint(y)
			case TWall:
				g.RowWall[y] |= 1 << uint(x)
				g.ColWall[x] |= 1 << uint(y)
			default:
				continue
			}
			g.Occ[(y+1)*pw+x+1] = OccWall
		}
	}
	for i := 0; i < int(m.NMons) && i < MaxMonsters; i++ {
		s := m.Mons[i]
		g.Mons[i] = Ent{Kind: s.Kind, X: s.X, Y: s.Y, HP: s.HP, Facing: s.Facing, Phase: s.Phase, Alive: true}
		g.Occ[(int(s.Y)+1)*pw+int(s.X)+1] = uint8(i + 1)
		if s.Kind != KGargoyle {
			g.Foes++
		}
		bit := uint16(1) << uint(i)
		g.Live |= bit
		if s.Kind == KArcher {
			g.setIdle(int(s.X), int(s.Y), true)
		}
		for r := 0; r < 4; r++ {
			switch s.Kind {
			case KArcher:
			case KGargoyle:
				if (r+int(s.Phase))%4 == 0 {
					g.Sched[r] |= bit
				}
			default:
				if (r+int(s.Phase))%2 == 0 {
					g.Sched[r] |= bit
				}
			}
		}
		g.NMons++
	}
	g.Mark = -1
	g.MaxHP, g.DashMax = 3, defaultDash
	switch relic {
	case 1:
		g.MaxHP, g.DashMax = 2, relicDashMax1
	case 2:
		g.MaxHP, g.DashMax = 4, relicDashMax2
	}
	g.HP = g.MaxHP
	if hp >= 1 && hp <= g.MaxHP {
		g.HP = hp
	}
	g.Route = 2166136261
	return g
}

// monsterAt returns the index of a living monster on (x, y), or -1.
func (g *Game) monsterAt(x, y int) int {
	if x < 0 || y < 0 || x >= int(g.M.W) || y >= int(g.M.H) {
		return -1
	}
	o := int(g.Occ[(y+1)*int(g.PW)+x+1])
	if o == 0 || o > MaxMonsters || !g.Mons[o-1].Alive {
		return -1
	}
	return o - 1
}

// Tile returns tile i's current state: Tiles, except TGateOpen for an open gate.
// Clients read gates through it.
func (g *Game) Tile(i int) uint8 {
	t := g.Tiles[i]
	if t != TGate {
		return t
	}
	w := int(g.M.W)
	o := g.Occ[(i/w+1)*int(g.PW)+i%w+1]
	if o != 0 && o <= MaxMonsters {
		return TGateOpen // occupied, so open
	}
	if o&0xF8 == OccGate && g.gateOpen(o) {
		return TGateOpen
	}
	return TGate
}

// gateOpen reports whether gate code o (OccGate+k) is open.
func (g *Game) gateOpen(o uint8) bool {
	return g.GatesUp || g.Stuck&(1<<(o&7)) != 0
}

// closedAt reports whether (x, y), at most one tile outside the grid, is a wall,
// a closed gate or out of bounds.
func (g *Game) closedAt(x, y int) bool {
	o := g.Occ[(y+1)*int(g.PW)+x+1]
	return o == OccWall || (o&0xF8 == OccGate && !g.gateOpen(o))
}

// dirVec maps 1-4 (and 5-8) to N/E/S/W unit vectors.
func dirVec(d uint8) (int, int) {
	switch (d - 1) & 3 {
	case 0:
		return 0, -1
	case 1:
		return 1, 0
	case 2:
		return 0, 1
	}
	return -1, 0
}

// exitOpen reports whether standing on the exit wins.
func (g *Game) exitOpen() bool {
	return g.M.Obj == ObjExit || g.Foes == 0
}

// heroAct resolves the hero's action. It returns true if this beat's damage
// phase is skipped (dash invulnerability).
func (g *Game) heroAct(a uint8) bool {
	switch {
	case a >= 1 && a <= 4:
		// Flat on purpose: a step can happen every beat. Occ already says wall or
		// closed gate (OccWall) and which monster stands there.
		x, y := int(g.HX), int(g.HY)
		nx, ny := x, y
		switch a {
		case 1:
			ny--
		case 2:
			nx++
		case 3:
			ny++
		default:
			nx--
		}
		if o := g.Occ[(ny+1)*int(g.PW)+nx+1]; o == OccWall || (o&0xF8 == OccGate && !g.gateOpen(o)) {
			g.Ev |= EvBump // wall, closed gate or out of bounds
			return false
		} else if o != 0 && o <= MaxMonsters && g.Mons[o-1].Alive {
			// Bump-attack: the hero stays put.
			if !g.hitMon(int(o-1), x, y) {
				g.Ev |= EvBump
			}
			return false
		}
		g.HX, g.HY = int8(nx), int8(ny)
		g.HIdx = uint16(ny*int(g.M.W) + nx)
		g.Ev |= EvMove
	case a >= 5 && a <= 8:
		if g.DashCD != 0 {
			g.Ev |= EvBump
			return false
		}
		dx, dy := dirVec(a)
		x1, y1 := int(g.HX)+dx, int(g.HY)+dy
		if g.closedAt(x1, y1) {
			g.Ev |= EvBump
			return false
		}
		if i := g.monsterAt(x1, y1); i >= 0 {
			return g.shove(i, x1, y1, dx, dy)
		}
		x2, y2 := x1+dx, y1+dy
		if g.closedAt(x2, y2) || g.monsterAt(x2, y2) >= 0 {
			x2, y2 = x1, y1
		}
		g.HX, g.HY = int8(x2), int8(y2)
		g.HIdx = uint16(y2*int(g.M.W) + x2)
		g.DashCD = g.DashMax
		g.Ev |= EvDash
		return true
	}
	return false
}

// Step executes one beat. Order: hero, tile effects, projectiles, monsters,
// hazards, damage, death, timers.
func (g *Game) Step(a uint8) {
	g.Ev = 0
	if g.Won || g.Dead {
		return
	}
	hIdx := int(g.HIdx)
	dashInv, markIdx, moved := false, -1, false
	if a != 0 {
		pIdx := hIdx
		dashInv = g.heroAct(a)
		hIdx = int(g.HIdx)
		moved = hIdx != pIdx
		// Leaving a crumble marks it.
		if moved && g.Tiles[pIdx] == TCrumble {
			g.Tiles[pIdx] = TCrumbleMark
			markIdx = pIdx
		}
	}

	// Tile effects under the hero. The hero is always in bounds.
	switch g.Tiles[hIdx] {
	case TChest:
		g.Tiles[hIdx] = TFloor
		g.Chest = true
		g.Ev |= EvChest
	case TExit:
		if g.exitOpen() {
			g.Won = true
			g.Ev |= EvWin
			g.endBeat()
			return
		}
	}

	struck := false
	if g.NProjs != 0 {
		struck = g.projectilesPhase()
	}
	if g.Live != 0 && g.monstersPhase(moved) {
		struck = true
	}
	if markIdx >= 0 || g.Mark >= 0 || g.NGates > 0 {
		g.hazardsPhase(markIdx)
	}

	// Damage: at most one per beat, from spikes or a monster or projectile hit.
	// Read the hero's tile again: hazards may have turned it into a pit.
	ht := g.Tiles[hIdx]
	if (struck || (ht == TSpikes && (int(g.Beat)+int(g.HX)+int(g.HY))%4 >= 2)) && g.Inv == 0 && !dashInv {
		g.HP--
		g.Damage++
		g.Inv = invAfterHit + 1 // the decrement below leaves invAfterHit
		g.Ev |= EvHurt
	}

	// Death.
	if g.HP <= 0 || ht == TPit {
		g.Dead = true
		if g.HP <= 0 {
			g.Ev |= EvDie
		}
		if ht == TPit {
			g.Ev |= EvFall
		}
	}

	if g.Inv > 0 {
		g.Inv--
	}
	g.endBeat()
}

// endBeat decrements the dash cooldown, advances the beat and folds the route.
func (g *Game) endBeat() {
	if g.DashCD > 0 {
		g.DashCD--
	}
	g.Beat++
	h := g.Route
	h = (h ^ uint32(uint8(g.HX))) * 16777619
	h = (h ^ uint32(uint8(g.HY))) * 16777619
	g.Route = h
}

// hazardsPhase turns last beat's crumble mark into a pit, dropping any monster
// standing there, records this beat's mark (markIdx, or -1), and opens or closes
// gates from plate occupancy.
func (g *Game) hazardsPhase(markIdx int) {
	w := int(g.M.W)
	if g.Mark >= 0 {
		i := int(g.Mark)
		g.Tiles[i] = TPit
		g.Ev |= EvCrumble
		if o := g.monsterAt(i%w, i/w); o >= 0 {
			g.kill(o) // leaves OccPit
			g.Ev |= EvFall
		} else {
			g.Occ[(i/w+1)*int(g.PW)+i%w+1] = OccPit
		}
	}
	g.Mark = int16(markIdx)

	if g.NGates == 0 {
		return
	}
	pw := int(g.PW)
	held := g.Tiles[g.HIdx] == TPlate
	for k := 0; k < int(g.NPlates) && !held; k++ {
		held = g.Occ[g.PlateOI[k]] != 0 // only a monster can stand on a plate
	}
	if held {
		// Every gate opens; one was closed unless all were already open.
		if !g.GatesUp {
			if g.Stuck != g.allGates() {
				g.Ev |= EvGate
			}
			g.GatesUp, g.Stuck = true, 0
		}
		return
	}
	if !g.GatesUp && g.Stuck == 0 {
		return // all closed already
	}
	// Open gates close unless the hero or a monster stands on them.
	occ := g.GateOcc
	if o := g.Occ[(int(g.HY)+1)*pw+int(g.HX)+1]; o&0xF8 == OccGate {
		occ |= 1 << (o & 7)
	}
	open := g.Stuck
	if g.GatesUp {
		open = g.allGates()
	}
	if open&occ != open {
		g.Ev |= EvGate
	}
	g.GatesUp, g.Stuck = false, open&occ
}

func (g *Game) allGates() uint8 {
	return uint8(uint16(1)<<g.NGates - 1)
}

// stuckBits returns the row (byRow) or column bits of the gates held open by an
// occupant in row or column n.
func (g *Game) stuckBits(n int, byRow bool) uint32 {
	var s uint32
	w := int(g.M.W)
	for k := 0; k < int(g.NGates); k++ {
		if g.Stuck&(1<<uint(k)) == 0 {
			continue
		}
		i := int(g.Gates[k])
		if byRow && i/w == n {
			s |= 1 << uint(i%w)
		} else if !byRow && i%w == n {
			s |= 1 << uint(i/w)
		}
	}
	return s
}

// solidRow returns the wall and closed-gate bits of row y. Only gates held open
// by an occupant (rare) need the gate list.
func (g *Game) solidRow(y int) uint32 {
	switch {
	case g.GatesUp:
		return g.RowWall[y]
	case g.Stuck == 0:
		return g.RowWall[y] | g.RowGate[y]
	}
	return g.RowWall[y] | g.RowGate[y]&^g.stuckBits(y, true)
}

// solidCol is solidRow for column x (bit y).
func (g *Game) solidCol(x int) uint32 {
	switch {
	case g.GatesUp:
		return uint32(g.ColWall[x])
	case g.Stuck == 0:
		return uint32(g.ColWall[x] | g.ColGate[x])
	}
	return uint32(g.ColWall[x]|g.ColGate[x]) &^ g.stuckBits(x, false)
}
