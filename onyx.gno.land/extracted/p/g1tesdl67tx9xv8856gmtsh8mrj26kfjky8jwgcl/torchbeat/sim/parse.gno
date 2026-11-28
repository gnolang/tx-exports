package sim

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// normalize converts CRLF to LF, drops one leading newline and one trailing newline.
// Without a CR it only slices (no copy).
func normalize(s string) string {
	cr := false
	for i := 0; i < len(s); i++ {
		if s[i] == '\r' {
			cr = true
			break
		}
	}
	if !cr {
		if len(s) > 0 && s[0] == '\n' {
			s = s[1:]
		}
		if len(s) > 0 && s[len(s)-1] == '\n' {
			s = s[:len(s)-1]
		}
		return s
	}
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '\r' && i+1 < len(s) && s[i+1] == '\n' {
			continue
		}
		b = append(b, s[i])
	}
	if len(b) > 0 && b[0] == '\n' {
		b = b[1:]
	}
	if len(b) > 0 && b[len(b)-1] == '\n' {
		b = b[:len(b)-1]
	}
	return string(b)
}

// Parse builds a Map from a grid, per-monster props (one hex char each, row-major
// spawn order: bits 3-2 facing, bits 1-0 phase) and an objective ("EXIT" or "SLAY").
// The second result is "" on success, otherwise a reason code.
func Parse(grid, props, objective string) (Map, string) {
	var m Map
	g := normalize(grid)

	w := 0
	for w < len(g) && g[w] != '\n' {
		w++
	}
	// Count rows; their widths must all match (one pass).
	h, rowStart := 1, 0
	for i := w; i < len(g); i++ {
		if g[i] == '\n' {
			if i-rowStart != w {
				return Map{}, "ragged"
			}
			h++
			rowStart = i + 1
		}
	}
	if len(g)-rowStart != w {
		return Map{}, "ragged"
	}
	if w < MinW || w > MaxW || h < MinH || h > MaxH {
		return Map{}, "size"
	}
	switch objective {
	case "EXIT":
		m.Obj = ObjExit
	case "SLAY":
		m.Obj = ObjSlay
	default:
		return Map{}, "objective"
	}
	m.W = uint8(w)
	m.H = uint8(h)

	nmons := 0
	var cnt tileCounts
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := g[y*(w+1)+x]
			cl := glyphClass[c]
			if k := cl & cKind; k != 0 {
				if nmons < MaxMonsters {
					m.Mons[nmons] = Mon{Kind: k, X: int8(x), Y: int8(y), HP: hpForKind(k)}
				}
				nmons++
				m.Tiles[y*w+x] = TFloor
				continue
			}
			if cl&cTile == 0 {
				return Map{}, "glyph"
			}
			m.Tiles[y*w+x] = c
			if c == TFloor || c == TWall {
				continue
			}
			if c == TStart {
				m.StartX, m.StartY = int8(x), int8(y)
			}
			cnt.add(c, cl)
		}
	}
	if nmons > MaxMonsters {
		return Map{}, "monsters"
	}
	if len(props) != nmons {
		return Map{}, "props"
	}
	for i := 0; i < nmons; i++ {
		v := hexVal(props[i])
		if v < 0 {
			return Map{}, "props"
		}
		m.Mons[i].Facing = uint8(v>>2) & 3
		m.Mons[i].Phase = uint8(v) & 3
	}
	m.NMons = uint8(nmons)

	// The same checks as Validate, on the counts gathered above (no second pass).
	if reason := m.checkHeader(); reason != "" {
		return Map{}, reason
	}
	if reason := cnt.check(m.NMons); reason != "" {
		return Map{}, reason
	}
	m.HasChest = cnt.chests == 1
	return m, ""
}

// tileCounts tallies the special tiles Validate checks.
type tileCounts struct {
	starts, exits, chests, hazards, gates, plates int
}

// add counts tile c of glyph class cl; floor and wall need not be added.
func (n *tileCounts) add(c, cl uint8) {
	switch c {
	case TStart:
		n.starts++
	case TExit:
		n.exits++
	case TChest:
		n.chests++
	case TGate:
		n.gates++
	case TPlate:
		n.plates++
	}
	if cl&cHazard != 0 {
		n.hazards++
	}
}

// check applies the per-tile rules in Validate's order.
func (n *tileCounts) check(nmons uint8) string {
	switch {
	case n.starts != 1:
		return "start"
	case n.exits < 1:
		return "exit"
	case n.chests > 1:
		return "chest"
	case n.gates > MaxGates || n.plates > MaxPlates:
		return "gates"
	case nmons == 0 && n.hazards == 0:
		return "dull"
	}
	return ""
}

// checkHeader checks size, monster count and objective.
func (m *Map) checkHeader() string {
	w, h := int(m.W), int(m.H)
	switch {
	case w < MinW || w > MaxW || h < MinH || h > MaxH:
		return "size"
	case m.NMons > MaxMonsters:
		return "monsters"
	case m.Obj != ObjExit && m.Obj != ObjSlay:
		return "objective"
	}
	return ""
}

// Validate checks caps, exactly one start, at least one exit, at most one chest,
// at most MaxGates gates and MaxPlates plates ("gates"), at least one monster or
// hazard tile, and that every monster can be placed: in bounds on its own floor
// tile, of kind 1-4 with that kind's HP ("monsters"). It returns "" or a reason
// code.
func Validate(m *Map) string {
	if reason := m.checkHeader(); reason != "" {
		return reason
	}
	var cnt tileCounts
	for i := 0; i < int(m.W)*int(m.H); i++ {
		t := m.Tiles[i]
		cl := glyphClass[t]
		if cl&cTile == 0 {
			return "glyph"
		}
		if t != TFloor && t != TWall {
			cnt.add(t, cl)
		}
	}
	if reason := m.checkMons(); reason != "" {
		return reason
	}
	return cnt.check(m.NMons)
}

// checkMons rejects monsters NewGame cannot place. Parse only builds valid ones
// (each on the floor tile its glyph became), so only Validate runs it.
func (m *Map) checkMons() string {
	w, h := int(m.W), int(m.H)
	for i := 0; i < int(m.NMons); i++ {
		s := m.Mons[i]
		x, y := int(s.X), int(s.Y)
		if s.Kind < KSlime || s.Kind > KGargoyle || s.HP != hpForKind(s.Kind) ||
			x < 0 || y < 0 || x >= w || y >= h || m.Tiles[y*w+x] != TFloor {
			return "monsters"
		}
		for j := 0; j < i; j++ {
			if m.Mons[j].X == s.X && m.Mons[j].Y == s.Y {
				return "monsters"
			}
		}
	}
	return ""
}

func fnvByte(h uint32, b uint8) uint32 {
	h ^= uint32(b)
	return h * 16777619
}

// CanonHash is FNV-1a over W, H, tiles, monsters and objective.
func CanonHash(m *Map) uint32 {
	h := uint32(2166136261)
	h = fnvByte(h, m.W)
	h = fnvByte(h, m.H)
	for i := 0; i < int(m.W)*int(m.H); i++ {
		h = fnvByte(h, m.Tiles[i])
	}
	for i := 0; i < int(m.NMons); i++ {
		mon := m.Mons[i]
		h = fnvByte(h, mon.Kind)
		h = fnvByte(h, uint8(mon.X))
		h = fnvByte(h, uint8(mon.Y))
		h = fnvByte(h, mon.Facing)
		h = fnvByte(h, mon.Phase)
	}
	return fnvByte(h, m.Obj)
}
