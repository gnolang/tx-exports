package sim

func fnvBool(h uint32, b bool) uint32 {
	if b {
		return fnvByte(h, 1)
	}
	return fnvByte(h, 0)
}

// StateHash is FNV-1a 32 over the observable game state: Beat, hero position, HP,
// invulnerability and dash cooldown, gate state, Chest, Damage, Kills, every
// current tile (crumble marks, pits, picked-up chest), every live monster in index
// order, every live projectile in slot order, then Won and Dead. Both builds of
// the sim must produce the same value on every beat (the parity vectors check it).
func (g *Game) StateHash() uint32 {
	h := uint32(2166136261)
	h = fnvByte(h, uint8(g.Beat))
	h = fnvByte(h, uint8(g.Beat>>8))
	h = fnvByte(h, uint8(g.HX))
	h = fnvByte(h, uint8(g.HY))
	h = fnvByte(h, uint8(g.HP))
	h = fnvByte(h, g.Inv)
	h = fnvByte(h, g.DashCD)
	h = fnvBool(h, g.GatesUp)
	h = fnvByte(h, g.Stuck)
	h = fnvBool(h, g.Chest)
	h = fnvByte(h, g.Damage)
	h = fnvByte(h, g.Kills)
	for i, n := 0, int(g.M.W)*int(g.M.H); i < n; i++ {
		h = fnvByte(h, g.Tiles[i])
	}
	for i := 0; i < MaxMonsters; i++ {
		e := &g.Mons[i]
		if !e.Alive {
			continue
		}
		h = fnvByte(h, uint8(i))
		h = fnvByte(h, uint8(e.X))
		h = fnvByte(h, uint8(e.Y))
		h = fnvByte(h, uint8(e.HP))
		h = fnvByte(h, e.Wind)
		h = fnvBool(h, e.Aim)
		h = fnvByte(h, e.CD)
		h = fnvByte(h, e.Facing)
	}
	for i := 0; i < MaxProjs; i++ {
		p := &g.Projs[i]
		if !p.Alive {
			continue
		}
		h = fnvByte(h, uint8(p.X))
		h = fnvByte(h, uint8(p.Y))
		h = fnvByte(h, uint8(p.DX))
		h = fnvByte(h, uint8(p.DY))
		h = fnvBool(h, p.Fire)
	}
	h = fnvBool(h, g.Won)
	return fnvBool(h, g.Dead)
}
