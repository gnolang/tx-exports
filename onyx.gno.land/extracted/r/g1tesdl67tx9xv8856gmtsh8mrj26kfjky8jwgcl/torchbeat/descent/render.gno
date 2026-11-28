package descent

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/gen"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"
	"gno.land/r/sys/users"
)

const (
	selfPath = "/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/descent" // deploy rewrites the namespace
	hubPath  = "/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
	playURL  = "https://torchbeat.vercel.app"
)

// Render serves "" (today's board, yesterday's winner and a map of today's
// floor 10) and "player/<addr>". A query string is ignored. Every page is
// bounded: the board shows at most 50 rows, a player page at most 8 days,
// and the map draws one floor without replaying anything.
func Render(path string) string {
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "player/"):
		if a := strings.ToLower(path[len("player/"):]); address(a).IsValid() {
			return renderPlayer(a)
		}
	}
	return "# Not found\n\n" + playLine() + "Nothing lives at this path. [Back to the descent](" + selfPath + ").\n"
}

func renderHome() string {
	t := today()
	var b strings.Builder
	b.WriteString("# Torchbeat: Daily Descent\n\n")
	b.WriteString(playLine())
	b.WriteString("Ten floors a day, drawn from the date alone. Every floor counted below was replayed on chain. Today is **" + dateOf(t) + "** (day " + u32(t) + ").\n\n")

	b.WriteString("## Today's board\n\n")
	rows := ""
	if bd := boardOf(t, false); bd != nil {
		rows = bd.Rows
	}
	for i, k := 0, 1; i < len(rows); k++ {
		if i == 0 {
			b.WriteString("| # | Player | Floors | Beats | Damage |\n|---|---|---|---|---|\n")
		}
		var r Row
		r, i = unpackRow(rows, i)
		b.WriteString("| " + strconv.Itoa(k) + " | " + playerLink(r.Owner.String()) + " | " +
			strconv.Itoa(int(r.Floors)) + " | " + strconv.Itoa(int(r.Beats)) + " | " + strconv.Itoa(int(r.Damage)) + " |\n")
	}
	if len(rows) == 0 {
		b.WriteString("No one has cleared a floor today yet.\n")
	}
	b.WriteString("\n## Yesterday's winner\n\n")
	if bd := boardOf(t-1, false); bd != nil && bd.Rows != "" {
		w, _ := unpackRow(bd.Rows, 0)
		b.WriteString(playerLink(w.Owner.String()) + " cleared " + count(int(w.Floors), "floor") + " in " +
			count(int(w.Beats), "beat") + " on " + dateOf(t-1) + ".\n")
	} else {
		b.WriteString("No one cleared a floor on " + dateOf(t-1) + ".\n")
	}
	b.WriteString("\n## Today's floor 10\n\n")
	b.WriteString("![Floor 10 of " + dateOf(t) + "](" + dataURI(floorSVG(t, gen.Floors)) + ")\n")
	return b.String()
}

func renderPlayer(a string) string {
	var p Record
	if v := recordOf(a, false); v != nil {
		p = *v
	}
	t := today()
	var b strings.Builder
	b.WriteString("# " + mdText(displayName(a)) + "\n\n")
	b.WriteString(playLine())
	b.WriteString("Deepest: " + count(int(p.Deepest), "floor") + " in one attempt. Streak: " + count(int(liveStreak(&p, t)), "day") +
		" in a row reaching floor 3 (longest " + strconv.Itoa(int(p.Longest)) + "). All time: " +
		count(int(p.Total), "floor") + " over " + count(int(p.Played), "day") + ".\n\n")

	b.WriteString("## Current attempt\n\n")
	if at := attemptOf(a); at != nil {
		state := "on floor " + strconv.Itoa(int(at.Floor)) + " with " + strconv.Itoa(int(at.HP)) + " HP"
		switch at.Ended {
		case "dead":
			state = "fell on floor " + strconv.Itoa(int(at.Floor))
		case "cleared":
			state = "cleared all " + strconv.Itoa(gen.Floors) + " floors"
		}
		b.WriteString("Attempt " + u32(at.N) + " of " + dateOf(at.Day) + ": " + state + ", " + relicName(at.Relic) + ", " +
			count(int(at.Beats), "beat") + ", " + strconv.Itoa(int(at.Damage)) + " damage so far.\n\n")
	} else {
		b.WriteString("No attempt yet.\n\n")
	}

	b.WriteString("## Recent days\n\n")
	n := 0
	for d := t; ; d-- {
		if r, ok := ringGet(p.Days, d); ok {
			if n == 0 {
				b.WriteString("| Day | Floors | Beats | Damage |\n|---|---|---|---|\n")
			}
			n++
			b.WriteString("| " + dateOf(d) + " | " + strconv.Itoa(int(r.Floors)) + " | " + strconv.Itoa(int(r.Beats)) +
				" | " + strconv.Itoa(int(r.Damage)) + " |\n")
		}
		if d == cutoff(t) {
			break
		}
	}
	if n == 0 {
		b.WriteString("No floors cleared in the last " + strconv.Itoa(keepDays+1) + " days.\n")
	}
	return b.String()
}

// count is "**n** noun", with an s unless n is 1.
func count(n int, noun string) string {
	if n != 1 {
		noun += "s"
	}
	return "**" + strconv.Itoa(n) + "** " + noun
}

func relicName(r uint8) string {
	switch r {
	case 1:
		return "Featherboots"
	case 2:
		return "Ironheart"
	}
	return "no relic"
}

func dateOf(day uint32) string {
	return time.Unix(int64(day)*86400, 0).UTC().Format("2006-01-02")
}

func playLine() string {
	return "**[Play Torchbeat](" + playURL + ")** · [Torchbeat world](" + hubPath + ")\n\n"
}

func mdText(s string) string { return sanitize.InlineText(s) }

// displayName is a's r/sys/users name as "@name", else the shortened address.
func displayName(a string) string {
	if u := users.ResolveAddress(address(a)); u != nil {
		return "@" + u.Name()
	}
	if len(a) <= 10 {
		return a
	}
	return a[:6] + "…" + a[len(a)-4:]
}

func playerLink(a string) string {
	return "[" + mdText(displayName(a)) + "](" + selfPath + ":player/" + a + ")"
}

// ---- Floor map ----

// The SVG goes straight into a data URI, so every '#' is written as %23.
const (
	sharp    = "%23"
	tilePx   = 16
	colFloor = sharp + "2a2420"
	colWall  = sharp + "4a3f36"
	colPit   = sharp + "000000"
	colSpike = sharp + "8a8378"
	colCrumb = sharp + "6b5a48"
	colPlate = sharp + "3d6b5a"
	colGate  = sharp + "b08d57"
	colChest = sharp + "d9a441"
	colExit  = sharp + "5fbf77"
	colHero  = sharp + "f2e3c6"
)

var monCol = [5]string{"", sharp + "7bc96f", sharp + "d07a6a", sharp + "9a7bd0", sharp + "6f93c9"}

// floorSVG draws floor n of day as it starts: tiles, monsters and the hero.
func floorSVG(day uint32, n uint8) []byte {
	f := gen.Layout(day, n)
	m, why := sim.Parse(f.Grid, f.Props, f.Objective)
	if why != "" {
		return nil
	}
	w, h := int(m.W), int(m.H)
	b := make([]byte, 0, 24<<10)
	b = append(b, `<svg xmlns="http://www.w3.org/2000/svg" width="`...)
	b = appendInt(b, w*tilePx*2)
	b = append(b, `" height="`...)
	b = appendInt(b, h*tilePx*2)
	b = append(b, `" viewBox="0 0 `...)
	b = appendInt(b, w*tilePx)
	b = append(b, ' ')
	b = appendInt(b, h*tilePx)
	b = append(b, `" shape-rendering="crispEdges">`...)
	b = appendRect(b, 0, 0, w*tilePx, h*tilePx, colFloor)
	for y := 0; y < h; y++ {
		for x := 0; x < w; {
			c := m.Tiles[y*w+x]
			run := 1
			if c == sim.TWall || c == sim.TPit {
				for x+run < w && m.Tiles[y*w+x+run] == c {
					run++
				}
			}
			if col := tileCol(c); col != "" {
				b = appendRect(b, x*tilePx, y*tilePx, run*tilePx, tilePx, col)
			}
			x += run
		}
	}
	for i := 0; i < int(m.NMons); i++ {
		mon := m.Mons[i]
		if mon.Kind < 1 || mon.Kind > 4 {
			continue
		}
		b = append(b, `<circle cx="`...)
		b = appendInt(b, int(mon.X)*tilePx+tilePx/2)
		b = append(b, `" cy="`...)
		b = appendInt(b, int(mon.Y)*tilePx+tilePx/2)
		b = append(b, `" r="6" fill="`...)
		b = append(b, monCol[mon.Kind]...)
		b = append(b, `"/>`...)
	}
	b = appendRect(b, int(m.StartX)*tilePx+3, int(m.StartY)*tilePx+3, tilePx-6, tilePx-6, colHero)
	return append(b, "</svg>"...)
}

func tileCol(c uint8) string {
	switch c {
	case sim.TWall:
		return colWall
	case sim.TPit:
		return colPit
	case sim.TSpikes:
		return colSpike
	case sim.TCrumble:
		return colCrumb
	case sim.TPlate:
		return colPlate
	case sim.TGate:
		return colGate
	case sim.TChest:
		return colChest
	case sim.TExit:
		return colExit
	}
	return ""
}

func appendRect(b []byte, x, y, w, h int, fill string) []byte {
	b = append(b, `<rect x="`...)
	b = appendInt(b, x)
	b = append(b, `" y="`...)
	b = appendInt(b, y)
	b = append(b, `" width="`...)
	b = appendInt(b, w)
	b = append(b, `" height="`...)
	b = appendInt(b, h)
	b = append(b, `" fill="`...)
	b = append(b, fill...)
	return append(b, `"/>`...)
}

// dataURI turns URI-ready SVG into an image destination, as the hub does:
// sanitize.ImageURL percent-encodes the rest.
func dataURI(svg []byte) string {
	return sanitize.ImageURL("data:image/svg+xml;charset=utf-8," + string(svg))
}
