package torchbeat

import (
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"
)

// The SVG here is written straight into a data URI (see dataURI), so svgW
// output is "URI-ready": every '#' is written pre-encoded as %23 and a '%'
// from text as %25. Gas shapes the rest: GnoVM charges per operation, so the
// writers append whole strings into a buffer sized up front (growing a slice
// recopies it), format small numbers by hand (strconv.Itoa costs ~25k gas),
// and precompute the strings a replay repeats.

const sharp = "%23" // '#'

// Palette: every color the pages draw with.
const (
	colBG        = sharp + "14110f"
	colFloor     = sharp + "2a2420"
	colWall      = sharp + "4a3f36"
	colWallFace  = sharp + "352d27" // the south face of a wall above a lower tile
	colPit       = sharp + "000000"
	colSpikes    = sharp + "8a8378"
	colCrumble   = sharp + "6b5a48"
	colPlate     = sharp + "3d6b5a"
	colGate      = sharp + "b08d57"
	colGateOpen  = sharp + "5a4a30"
	colChest     = sharp + "d9a441"
	colExit      = sharp + "5fbf77"
	colHub       = sharp + "e8b04a"
	colHero      = sharp + "f2e3c6"
	colSlime     = sharp + "7bc96f"
	colArcher    = sharp + "d07a6a"
	colBrute     = sharp + "9a7bd0"
	colGargoyle  = sharp + "6f93c9"
	colFireball  = sharp + "ff8a3d"
	colArrow     = sharp + "e0d4b0"
	colCleared   = colExit          // player map: a room the player cleared
	colUncharted = sharp + "2e2723" // player map: a room the player has not cleared
)

// shade is a world-map room color for clear-count step 0-3 (see shadeStep).
func shade(step int) string {
	switch step {
	case 0:
		return sharp + "3b322b"
	case 1:
		return sharp + "5e4b37"
	case 2:
		return sharp + "8c6a40"
	}
	return sharp + "bd8d47"
}

// shadeStep buckets a room's clears: 0, 1-9, 10-49, 50 and more.
func shadeStep(clears int) int {
	switch {
	case clears == 0:
		return 0
	case clears < 10:
		return 1
	case clears < 50:
		return 2
	}
	return 3
}

// svgW builds URI-ready SVG. raw writes trusted markup; text and attr escape
// & < > " ' as XML entities (and # % for the URI), so no value can end the
// attribute or element it sits in. Every room name and address goes through
// text or attr.
type svgW struct{ b []byte }

func newSVG(capacity int) *svgW { return &svgW{b: make([]byte, 0, capacity)} }

func (w *svgW) raw(s string) { w.b = append(w.b, s...) }

func (w *svgW) int(n int) { w.b = appendInt(w.b, n) }

func (w *svgW) text(s string) {
	start := 0
	for i := 0; i < len(s); i++ {
		var rep string
		switch s[i] {
		case '&':
			rep = "&amp;"
		case '<':
			rep = "&lt;"
		case '>':
			rep = "&gt;"
		case '"':
			rep = "&quot;"
		case '\'':
			rep = "&apos;"
		case '#':
			rep = sharp
		case '%':
			rep = "%25"
		default:
			continue
		}
		w.b = append(w.b, s[start:i]...)
		w.b = append(w.b, rep...)
		start = i + 1
	}
	w.b = append(w.b, s[start:]...)
}

// attr writes ` name="value"` with value escaped.
func (w *svgW) attr(name, value string) {
	w.raw(" " + name + `="`)
	w.text(value)
	w.b = append(w.b, '"')
}

// num writes ` name="n"`.
func (w *svgW) num(name string, n int) {
	w.raw(" " + name + `="`)
	w.b = append(appendInt(w.b, n), '"')
}

// rect writes a rect; fill is trusted (a palette color or url(...)).
func (w *svgW) rect(x, y, width, height int, fill string) {
	w.raw(`<rect x="`)
	w.int(x)
	w.raw(`" y="`)
	w.int(y)
	w.raw(`" width="`)
	w.int(width)
	w.raw(`" height="`)
	w.int(height)
	w.raw(`" fill="` + fill + `"/>`)
}

// path writes a path with a trusted fill, skipping an empty d.
func (w *svgW) path(d []byte, fill string) {
	if len(d) == 0 {
		return
	}
	w.raw(`<path fill="` + fill + `" d="`)
	w.b = append(w.b, d...)
	w.raw(`"/>`)
}

// open writes <svg ...> showing a vw x vh viewBox at width x height.
func (w *svgW) open(width, height, vw, vh int) {
	w.raw(`<svg xmlns="http://www.w3.org/2000/svg" width="`)
	w.int(width)
	w.raw(`" height="`)
	w.int(height)
	w.raw(`" viewBox="0 0 `)
	w.int(vw)
	w.raw(" ")
	w.int(vh)
	w.raw(`">`)
}

const svgURIPrefix = "data:image/svg+xml;charset=utf-8,"

// dataURI turns URI-ready SVG into an image destination through
// sanitize.ImageURL (native percent-encoding): gnoweb accepts any
// data:image/svg+xml destination (markdown/ext_imgvalidator.go, v1.8.0-rc.1)
// and goldmark needs the ';' after the media type. Spaces, quotes, < > and
// the like are encoded; '#' and '%' never reach it raw (svgW pre-encodes
// them), so the data cannot be cut at a fragment or decoded wrongly.
func dataURI(svg []byte) string {
	return sanitize.ImageURL(svgURIPrefix + string(svg))
}

// ---- World map ----

const (
	cellPx  = 20 // world-map cell
	mapSide = 2*maxCoord + 1
)

// worldSVG draws the world map: the hub, every room and corridors between
// orthogonal neighbours, over the bounding box of the used cells plus a 1-cell
// margin (at most 33x33 cells). On the home map (player false) rooms are
// shaded by clears and the newest visible room pulses; on a player's map the
// rooms in cleared are highlighted. Hidden rooms are hatched either way.
func worldSVG(player bool, cleared map[string]bool) []byte {
	newestID := ""
	if !player {
		if nr := newestRooms(1); len(nr) == 1 {
			newestID = nr[0].ID
		}
	}

	// One pass over the rooms: each used cell gets a look (0 empty, 1 the
	// hub, else an index into looks) and the bounding box grows to fit.
	var cell [mapSide * mapSide]uint8
	const hub, hatched, clearedLook, uncharted, shade0 = 1, 2, 3, 4, 5
	cell[maxCoord*mapSide+maxCoord] = hub
	pulse := -1
	minX, maxX, minY, maxY := 0, 0, 0, 0
	rooms.Iterate("", "", func(_ string, v any) bool {
		r := v.(*Room)
		x, y := int(r.X), int(r.Y)
		if x < minX {
			minX = x
		}
		if x > maxX {
			maxX = x
		}
		if y < minY {
			minY = y
		}
		if y > maxY {
			maxY = y
		}
		i := (y+maxCoord)*mapSide + x + maxCoord
		switch {
		case r.Hidden:
			cell[i] = hatched
		case !player:
			cell[i] = uint8(shade0 + shadeStep(r.Clears))
		case cleared[r.ID]:
			cell[i] = clearedLook
		default:
			cell[i] = uncharted
		}
		if r.ID == newestID {
			pulse = i
		}
		return false
	})
	looks := [shade0 + 4]string{"", colHub, "url(" + sharp + "hatch)", colCleared, colUncharted, shade(0), shade(1), shade(2), shade(3)}
	minX, minY = clampCoord(minX-1), clampCoord(minY-1)
	maxX, maxY = clampCoord(maxX+1), clampCoord(maxY+1)
	cols, rows := maxX-minX+1, maxY-minY+1
	vw, vh := cols*cellPx, rows*cellPx
	n := rooms.Size()

	w := newSVG(2048 + 96*n)
	scale := 1 // small maps show at 2x so a young world is not a speck
	if vw*2 <= 640 {
		scale = 2
	}
	w.open(vw*scale, vh*scale, vw, vh)
	w.raw(`<defs><pattern id="dots" width="20" height="20" patternUnits="userSpaceOnUse">`)
	w.rect(9, 9, 2, 2, colFloor)
	w.raw(`</pattern><pattern id="hatch" width="4" height="4" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">`)
	w.rect(0, 0, 4, 4, colBG)
	w.rect(0, 0, 2, 4, colWall)
	w.raw(`</pattern></defs>`)
	w.rect(0, 0, vw, vh, colBG)
	w.rect(0, 0, vw, vh, "url("+sharp+"dots)")

	// Corridors: a short link from each used cell to its east and south
	// neighbours.
	links := make([]byte, 0, 32*(n+1))
	for y := minY; y <= maxY; y++ {
		for x := minX; x <= maxX; x++ {
			i := (y+maxCoord)*mapSide + x + maxCoord
			if cell[i] == 0 {
				continue
			}
			px, py := (x-minX)*cellPx, (y-minY)*cellPx
			if x < maxX && cell[i+1] != 0 {
				links = appendBox(links, px+17, py+8, "h4v4h-4z")
			}
			if y < maxY && cell[i+mapSide] != 0 {
				links = appendBox(links, px+8, py+17, "h4v4h-4z")
			}
		}
	}
	w.path(links, colWall)

	// The hub: a gold cell with a flickering torch.
	hx, hy := -minX*cellPx, -minY*cellPx
	w.raw(`<g id="hub"><rect x="`)
	w.int(hx + 2)
	w.raw(`" y="`)
	w.int(hy + 2)
	w.raw(`" width="16" height="16" rx="2" fill="` + colHub + `"/>`)
	w.rect(hx+9, hy+10, 2, 6, colBG)
	w.raw(`<path fill="` + colBG + `" d="M`)
	w.int(hx + 10)
	w.raw(" ")
	w.int(hy + 4)
	w.raw(`q3 3 0 6q-3-3 0-6z"><animate attributeName="opacity" values="1;0.6;1" dur="0.9s" repeatCount="indefinite"/></path></g>`)

	// Rooms, one rect each, row by row.
	w.raw(`<g id="rooms">`)
	for y := minY; y <= maxY; y++ {
		for x := minX; x <= maxX; x++ {
			i := (y+maxCoord)*mapSide + x + maxCoord
			if cell[i] <= hub {
				continue
			}
			w.raw(`<rect x="`)
			w.int((x-minX)*cellPx + 2)
			w.raw(`" y="`)
			w.int((y-minY)*cellPx + 2)
			w.raw(`" width="16" height="16" rx="2" fill="` + looks[cell[i]])
			if i == pulse {
				w.raw(`"><animate attributeName="opacity" values="1;0.55;1" dur="1.6s" repeatCount="indefinite"/></rect>`)
			} else {
				w.raw(`"/>`)
			}
		}
	}
	w.raw("</g></svg>")
	return w.b
}

func clampCoord(v int) int {
	if v < -maxCoord {
		return -maxCoord
	}
	if v > maxCoord {
		return maxCoord
	}
	return v
}

// appendBox appends "M x y" and a relative shape.
func appendBox(d []byte, x, y int, shape string) []byte {
	d = appendInt(append(d, 'M'), x)
	d = appendInt(append(d, ' '), y)
	return append(d, shape...)
}

// ---- Room and ghost ----

const (
	tilePx    = 16
	holdBeats = 6 // the replay holds its last frame this many beats
)

// glyphDefs: monster glyphs drawn at the origin of a 16x16 tile and placed
// with <use>, the floor tiling, and the hero's torchlight.
const glyphDefs = `<g id="k1"><path fill="` + colSlime + `" d="M2 14c0-6 3-9 6-9s6 3 6 9z"/>` +
	`<rect x="5" y="9" width="2" height="2" fill="` + colBG + `"/><rect x="9" y="9" width="2" height="2" fill="` + colBG + `"/></g>` +
	`<g id="k2"><path fill="` + colArcher + `" d="M7 3l5 11H2z"/><path fill="none" stroke="` + colArrow + `" d="M11 3q4 5 0 10M11 3v10"/></g>` +
	`<g id="k3"><rect x="2" y="3" width="12" height="11" rx="2" fill="` + colBrute + `"/><rect x="4" y="6" width="8" height="2" fill="` + colBG + `"/></g>` +
	`<g id="k4"><path fill="` + colGargoyle + `" d="M8 4l3 3 4-4-1 11H2L1 3l4 4z"/>` +
	`<rect x="6" y="8" width="1" height="1" fill="` + colFireball + `"/><rect x="9" y="8" width="1" height="1" fill="` + colFireball + `"/></g>` +
	`<pattern id="fl" width="16" height="16" patternUnits="userSpaceOnUse"><rect width="16" height="16" fill="` + colBG + `"/>` +
	`<rect width="15" height="15" fill="` + colFloor + `"/></pattern>` +
	`<radialGradient id="glow"><stop offset="0" stop-color="` + colFireball + `" stop-opacity="0.35"/>` +
	`<stop offset="1" stop-color="` + colFireball + `" stop-opacity="0"/></radialGradient>`

// monKey is a monster keyframe: its tile at a beat.
type monKey struct {
	beat int
	x, y int8
}

// ghost is a replayed run, recorded beat by beat.
type ghost struct {
	beats      int                    // steps run
	hx, hy     [sim.MaxBeats + 1]int8 // hero tile after each beat
	keys       [sim.MaxMonsters][]monKey
	died       [sim.MaxMonsters]int // beat a monster died, 0 alive
	gates      [sim.MaxGates][]int  // beats a gate toggled
	gateOpen0  [sim.MaxGates]bool
	crumbles   []monKey // a crumble tile (x, y) fell at beat
	chestTaken int      // beat the chest was opened, 0 never
}

// replayRun runs log on m with relic, recording what the SVG animates:
// monsters only on beats where they move or die, gates when they toggle.
func replayRun(m *sim.Map, relic uint8, log string) *ghost {
	gh := &ghost{}
	g := sim.NewGame(m, relic)
	gh.hx[0], gh.hy[0] = g.HX, g.HY
	nm := int(g.NMons)
	var lx, ly [sim.MaxMonsters]int8
	for j := 0; j < nm; j++ {
		lx[j], ly[j] = g.Mons[j].X, g.Mons[j].Y
	}
	ng := int(g.NGates)
	var open [sim.MaxGates]bool
	for k := 0; k < ng; k++ {
		open[k] = g.Tile(int(g.Gates[k])) == sim.TGateOpen
		gh.gateOpen0[k] = open[k]
	}
	w := int(m.W)
	for i := 0; i < len(log) && !g.Won && !g.Dead; i++ {
		mark := int(g.Mark)
		g.Step(log[i] - '0')
		b := int(g.Beat)
		gh.beats = b
		gh.hx[b], gh.hy[b] = g.HX, g.HY
		for j := 0; j < nm; j++ {
			if gh.died[j] != 0 {
				continue
			}
			e := &g.Mons[j]
			if e.X != lx[j] || e.Y != ly[j] {
				gh.keys[j] = append(gh.keys[j], monKey{b, e.X, e.Y})
				lx[j], ly[j] = e.X, e.Y
			}
			if !e.Alive {
				gh.died[j] = b
			}
		}
		if g.Ev&sim.EvCrumble != 0 && mark >= 0 {
			gh.crumbles = append(gh.crumbles, monKey{b, int8(mark % w), int8(mark / w)})
		}
		if g.Ev&sim.EvChest != 0 {
			gh.chestTaken = b
		}
		for k := 0; k < ng; k++ {
			if o := g.Tile(int(g.Gates[k])) == sim.TGateOpen; o != open[k] {
				open[k] = o
				gh.gates[k] = append(gh.gates[k], b)
			}
		}
	}
	return gh
}

// keyTimes holds the keyTimes entry for every beat of a replay, each with a
// leading ';' (beat/total with 4 decimals; 0 and 1 exact).
func keyTimes(total int) []string {
	kt := make([]string, total+1)
	kt[0] = ";0"
	for b := 1; b < total; b++ {
		q := b * 10000 / total
		kt[b] = string([]byte{';', '0', '.', byte('0' + q/1000), byte('0' + q/100%10), byte('0' + q/10%10), byte('0' + q%10)})
	}
	kt[total] = ";1"
	return kt
}

// animHead opens an animation of attr with the keyTimes list kt (each entry
// with a leading ';') and starts its values.
func (w *svgW) animHead(attr, mode string, kt []byte) {
	w.raw(`<animate attributeName="` + attr + `" calcMode="` + mode + `" keyTimes="`)
	w.b = append(w.b, kt[1:]...)
	w.raw(`" values="`)
}

// animTail closes an animation's values and adds the shared timing.
func (w *svgW) animTail(dur string) {
	w.raw(`"` + dur + "/>")
}

// durAttr is the shared timing of a replay of total beats at 0.16 s each.
func durAttr(total int) string {
	cs := total * 16
	b := appendInt([]byte(` dur="`), cs/100)
	b = append(b, '.', byte('0'+cs%100/10), byte('0'+cs%10), 's', '"')
	return string(b) + ` repeatCount="indefinite"`
}

// roomSVG draws a room from its stored map at 16 px per tile and, when run is
// set, replays it: the hero is keyframed on every beat, monsters only when
// they move or die, gates when they toggle, a crumble when it falls and the
// chest when it is opened. Every animation shares one duration (the run plus a
// short hold) and loops.
func roomSVG(r *Room, run *Run) []byte {
	m := &r.Static.Map
	mw, mh := int(m.W), int(m.H)
	vw, vh := mw*tilePx, mh*tilePx

	var gh *ghost
	var kt []string
	dur := ""
	total := 0
	if run != nil {
		gh = replayRun(m, run.Relic, run.Log)
		total = gh.beats + holdBeats
		kt = keyTimes(total)
		dur = durAttr(total)
	}

	w := newSVG(160 << 10)
	w.open(vw*2, vh*2, vw, vh)
	w.raw("<title>")
	w.text(r.Name)
	w.raw("</title><defs>" + glyphDefs + "</defs>")
	w.rect(0, 0, vw, vh, "url("+sharp+"fl)")

	// Static tiles, one path per kind; walls, faces and pits merge runs.
	// Path buffers fit MaxTiles of their kind (appending past capacity
	// recopies the buffer, which costs gas, not correctness).
	const tiles = sim.MaxTiles
	walls, faces, pits := make([]byte, 0, 24*tiles), make([]byte, 0, 24*tiles), make([]byte, 0, 24*tiles)
	crumble, spikes, plates := make([]byte, 0, 20*tiles), make([]byte, 0, 48*tiles), make([]byte, 0, 20*sim.MaxPlates)
	exits, steps, bars := make([]byte, 0, 20*tiles), make([]byte, 0, 24*tiles), make([]byte, 0, 56*sim.MaxGates)
	var gates [sim.MaxGates]int
	ng := 0
	chest := -1
	for y := 0; y < mh; y++ {
		row := y * mw
		py := y * tilePx
		for x := 0; x < mw; x++ {
			px := x * tilePx
			switch m.Tiles[row+x] {
			case sim.TWall:
				if x == 0 || m.Tiles[row+x-1] != sim.TWall {
					n := 1
					for x+n < mw && m.Tiles[row+x+n] == sim.TWall {
						n++
					}
					walls = appendRun(walls, px, py, n, 16)
				}
				if y+1 < mh && m.Tiles[row+mw+x] != sim.TWall {
					faces = appendRun(faces, px, py+11, 1, 5)
				}
			case sim.TPit:
				if x == 0 || m.Tiles[row+x-1] != sim.TPit {
					n := 1
					for x+n < mw && m.Tiles[row+x+n] == sim.TPit {
						n++
					}
					pits = appendRun(pits, px, py, n, 16)
				}
			case sim.TCrumble:
				crumble = appendBox(crumble, px, py, "h15v15h-15z")
			case sim.TSpikes:
				spikes = appendBox(spikes, px+2, py+13, "l2-7 2 7zm4 0l2-7 2 7zm4 0l2-7 2 7z")
			case sim.TPlate:
				plates = appendBox(plates, px+3, py+3, "h9v9h-9z")
			case sim.TExit:
				exits = appendBox(exits, px, py, "h15v15h-15z")
				steps = appendBox(steps, px+3, py+12, "h9v-3h-6v-3h-3z")
			case sim.TGate:
				if ng < sim.MaxGates {
					gates[ng] = row + x
					ng++
				}
				bars = appendBox(bars, px+3, py, "h1v16h-1zm4 0h1v16h-1zm4 0h1v16h-1zm4 0h1v16h-1z")
			case sim.TChest:
				chest = row + x
			}
		}
	}
	w.raw(`<g shape-rendering="crispEdges">`)
	w.path(walls, colWall)
	w.path(faces, colWallFace)
	w.path(pits, colPit)
	w.path(crumble, colCrumble)
	w.path(spikes, colSpikes)
	w.path(plates, colPlate)
	w.path(exits, colExit)
	w.path(steps, colFloor)

	// Gates, each with its own fill so the replay can toggle it (NewGame
	// numbers gates in row-major order, as collected above).
	for k := 0; k < ng; k++ {
		fill := colGate
		if gh != nil && gh.gateOpen0[k] {
			fill = colGateOpen
		}
		w.raw(`<rect x="`)
		w.int(gates[k] % mw * tilePx)
		w.raw(`" y="`)
		w.int(gates[k] / mw * tilePx)
		w.raw(`" width="16" height="16" fill="` + fill)
		if gh == nil || len(gh.gates[k]) == 0 {
			w.raw(`"/>`)
			continue
		}
		w.raw(`"><animate attributeName="fill" calcMode="discrete" keyTimes="0`)
		for _, b := range gh.gates[k] {
			w.raw(kt[b])
		}
		w.raw(`" values="` + fill)
		for t := len(gh.gates[k]); t > 0; t-- {
			if fill == colGate {
				fill = colGateOpen
			} else {
				fill = colGate
			}
			w.raw(";" + fill)
		}
		w.raw(`"` + dur + "/></rect>")
	}
	w.path(bars, colBG)

	// A crumble that falls during the replay becomes a pit.
	if gh != nil {
		for _, c := range gh.crumbles {
			w.raw(`<rect x="`)
			w.int(int(c.x) * tilePx)
			w.raw(`" y="`)
			w.int(int(c.y) * tilePx)
			w.raw(`" width="16" height="16" fill="` + colPit + `" opacity="0"><animate attributeName="opacity" calcMode="discrete" keyTimes="0`)
			w.raw(kt[c.beat])
			w.raw(`" values="0;1"` + dur + "/></rect>")
		}
	}
	w.raw("</g>")

	if chest >= 0 {
		cx, cy := chest%mw*tilePx, chest/mw*tilePx
		w.raw(`<g id="chest">`)
		w.rect(cx+3, cy+5, 10, 8, colChest)
		w.rect(cx+3, cy+8, 10, 1, colBG)
		if gh != nil && gh.chestTaken != 0 {
			w.raw(`<animate attributeName="opacity" calcMode="discrete" keyTimes="0`)
			w.raw(kt[gh.chestTaken])
			w.raw(`" values="1;0"` + dur + "/>")
		}
		w.raw("</g>")
	}

	w.raw(`<g id="mons">`)
	for j := 0; j < int(m.NMons); j++ {
		s := m.Mons[j]
		w.raw(`<use href="` + sharp + `k`)
		w.int(int(s.Kind))
		w.raw(`" transform="translate(`)
		w.b = appendXY(w.b, s.X, s.Y)
		w.raw(`)"`)
		if gh == nil || (len(gh.keys[j]) == 0 && gh.died[j] == 0) {
			w.raw("/>")
			continue
		}
		w.raw(">")
		if len(gh.keys[j]) > 0 {
			w.monsterMoves(s, gh.keys[j], kt, dur)
		}
		if d := gh.died[j]; d != 0 {
			w.raw(`<animate attributeName="opacity" calcMode="linear" keyTimes="0`)
			w.raw(kt[d-1])
			w.raw(kt[d])
			w.raw(`;1" values="1;1;0;0"` + dur + "/>")
		}
		w.raw("</use>")
	}
	w.raw("</g>")

	w.raw(`<g id="hero">`)
	if gh == nil {
		sx, sy := int(m.StartX)*tilePx, int(m.StartY)*tilePx
		w.raw(`<circle r="28" fill="url(` + sharp + `glow)" cx="`)
		w.int(sx + 8)
		w.raw(`" cy="`)
		w.int(sy + 8)
		w.raw(`"/><rect x="`)
		w.int(sx + 3)
		w.raw(`" y="`)
		w.int(sy + 3)
		w.raw(`" width="10" height="10" rx="3" fill="` + colHero + `"/>`)
	} else {
		n := gh.beats
		hkt := make([]byte, 0, 8*(n+2))
		for b := 0; b <= n; b++ {
			hkt = append(hkt, kt[b]...)
		}
		hkt = append(hkt, kt[total]...)
		// Coordinates for tile t at offset off, each with a leading ';'.
		var c3, c8 [sim.MaxW]string
		for t := 0; t < sim.MaxW; t++ {
			c3[t] = string(appendInt([]byte{';'}, t*tilePx+3))
			c8[t] = string(appendInt([]byte{';'}, t*tilePx+8))
		}
		w.raw(`<circle r="28" fill="url(` + sharp + `glow)" cx="`)
		w.raw(c8[gh.hx[0]][1:])
		w.raw(`" cy="`)
		w.raw(c8[gh.hy[0]][1:])
		w.raw(`">`)
		w.heroAnim("cx", hkt, &c8, gh.hx[:n+1], dur)
		w.heroAnim("cy", hkt, &c8, gh.hy[:n+1], dur)
		w.raw(`</circle><rect x="`)
		w.raw(c3[gh.hx[0]][1:])
		w.raw(`" y="`)
		w.raw(c3[gh.hy[0]][1:])
		w.raw(`" width="10" height="10" rx="3" fill="` + colHero + `">`)
		w.heroAnim("x", hkt, &c3, gh.hx[:n+1], dur)
		w.heroAnim("y", hkt, &c3, gh.hy[:n+1], dur)
		w.raw("</rect>")
	}
	w.raw("</g></svg>")
	return w.b
}

// heroAnim writes a linear animation of attr over the hero's tiles, one value
// per beat plus the last one again for the hold.
func (w *svgW) heroAnim(attr string, kt []byte, coord *[sim.MaxW]string, tiles []int8, dur string) {
	w.animHead(attr, "linear", kt)
	w.raw(coord[tiles[0]][1:])
	for _, t := range tiles[1:] {
		w.raw(coord[t])
	}
	w.raw(coord[tiles[len(tiles)-1]])
	w.animTail(dur)
}

// monsterMoves writes a monster's translate keyframes: it holds each tile
// until the beat before a move, slides during the move's beat, and holds its
// last tile to the end.
func (w *svgW) monsterMoves(s sim.Mon, keys []monKey, kt []string, dur string) {
	total := len(kt) - 1
	ktb := make([]byte, 0, 16*len(keys)+8)
	vals := make([]byte, 0, 20*len(keys)+16)
	ktb = append(ktb, kt[0]...)
	vals = appendXY(vals, s.X, s.Y)
	last, lx, ly := 0, s.X, s.Y
	for _, k := range keys {
		if k.beat-1 > last {
			ktb = append(ktb, kt[k.beat-1]...)
			vals = appendXY(append(vals, ';'), lx, ly)
		}
		ktb = append(ktb, kt[k.beat]...)
		vals = appendXY(append(vals, ';'), k.x, k.y)
		last, lx, ly = k.beat, k.x, k.y
	}
	if last < total {
		ktb = append(ktb, kt[total]...)
		vals = appendXY(append(vals, ';'), lx, ly)
	}
	w.raw(`<animateTransform attributeName="transform" type="translate" calcMode="linear" keyTimes="`)
	w.b = append(w.b, ktb[1:]...)
	w.raw(`" values="`)
	w.b = append(w.b, vals...)
	w.animTail(dur)
}

func appendXY(b []byte, x, y int8) []byte {
	return appendInt(append(appendInt(b, int(x)*tilePx), ','), int(y)*tilePx)
}

// appendRun appends an n-tile-wide strip of height h at (x, y).
func appendRun(d []byte, x, y, n, h int) []byte {
	d = appendInt(append(d, 'M'), x)
	d = appendInt(append(d, ' '), y)
	d = appendInt(append(d, 'h'), n*tilePx)
	d = appendInt(append(d, 'v'), h)
	d = appendInt(append(d, 'h', '-'), n*tilePx)
	return append(d, 'z')
}
