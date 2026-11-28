package torchbeat

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/sys/users"
)

const (
	hubPath = "/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1" // deploy rewrites the namespace
	playURL = "https://torchbeat.vercel.app"

	topExplorersShown = 10
	newestShown       = 5
	hiddenShown       = 32 // hidden rooms listed on the home page; the rest are counted
)

// Render serves the hub's pages: "" (home and world map), "room/<id>" (a room
// with its best run replayed) and "player/<addr>". A query string is ignored.
// Every page is bounded: the map has at most 1089 cells, lists are capped, and
// a room page replays one run of at most sim.MaxBeats beats.
func Render(path string) string {
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "room/"):
		if v := rooms.Get(path[len("room/"):]); v != nil {
			return renderRoom(v.(*Room))
		}
	case strings.HasPrefix(path, "player/"):
		// bech32 is case-insensitive but every key here is lowercase, so an
		// uppercase address renders the canonical page.
		if a := strings.ToLower(path[len("player/"):]); address(a).IsValid() {
			return renderPlayer(a)
		}
	}
	return "# Not found\n\n" + playLine("") + "Nothing lives at this path. [Back to the world map](" + hubPath + ").\n"
}

// mdText escapes s for inline Markdown (headings, link text).
func mdText(s string) string { return sanitize.InlineText(s) }

// mdCell escapes s for a Markdown table cell.
func mdCell(s string) string { return sanitize.TableCell(s) }

// shortAddr shortens a bech32 address to g1abcd…wxyz.
func shortAddr(a string) string {
	if len(a) <= 10 {
		return a
	}
	return a[:6] + "…" + a[len(a)-4:]
}

func roomLink(r *Room) string {
	return "[" + mdText(r.Name) + "](" + hubPath + ":room/" + r.ID + ")"
}

// displayName is a's r/sys/users name as "@name", or the shortened address
// when it has none (or the user was deleted). Callers escape it.
func displayName(a string) string {
	if u := users.ResolveAddress(address(a)); u != nil {
		return "@" + u.Name()
	}
	return shortAddr(a)
}

// playerLink links a's player page by address, shown by displayName.
func playerLink(a string) string {
	return "[" + mdText(displayName(a)) + "](" + hubPath + ":player/" + a + ")"
}

// playLine is the primary Play link, plus extra links, as a paragraph.
func playLine(extra string) string {
	return "**[Play Torchbeat](" + playURL + ")**" + extra + "\n\n"
}

func image(alt string, svg []byte) string {
	return "![" + mdText(alt) + "](" + dataURI(svg) + ")\n\n"
}

// pageSlack is room for a page's text besides its one image: a Builder grows
// by recopying, so each page sizes it up front.
const pageSlack = 8 << 10

func bold(n int) string { return "**" + strconv.Itoa(n) + "**" }

var relicNames = [3]string{"", "Featherboots", "Ironheart"}

// ---- Home ----

type explorer struct {
	addr           string
	cleared, stars int
}

// topExplorers returns the first n entries of the explorers index.
func topExplorers(n int) []explorer {
	var out []explorer
	explorers.IterateByOffset(0, n, func(k string, _ any) bool {
		c, _ := strconv.Atoi(k[0:4])
		s, _ := strconv.Atoi(k[4:8])
		out = append(out, explorer{k[8:], 9999 - c, 9999 - s})
		return false
	})
	return out
}

// newestRooms returns up to n visible rooms, newest first.
func newestRooms(n int) []*Room {
	var out []*Room
	newest.ReverseIterate("", "", func(_ string, v any) bool {
		r := rooms.Get(v.(string)).(*Room)
		if !r.Hidden {
			out = append(out, r)
		}
		return len(out) >= n
	})
	return out
}

func renderHome() string {
	img := image("World map: the hub in gold, rooms brighter with more clears, the newest pulsing", worldSVG(false, nil))
	var b strings.Builder
	b.Grow(len(img) + pageSlack)
	b.WriteString("# Torchbeat\n\n*A dungeon the gno.land community digs together.*\n\n")
	b.WriteString(playLine(""))
	b.WriteString(img)

	b.WriteString(bold(rooms.Size()) + " rooms · " + bold(explorers.Size()) + " explorers · " + bold(totalClears) + " clears\n\n")

	b.WriteString("## Top explorers\n\n")
	if top := topExplorers(topExplorersShown); len(top) == 0 {
		b.WriteString("No clears yet. Be the first.\n\n")
	} else {
		b.WriteString("| # | Explorer | Rooms | Stars |\n| ---: | --- | ---: | ---: |\n")
		for i, e := range top {
			b.WriteString("| " + strconv.Itoa(i+1) + " | " + playerLink(e.addr) + " | " +
				strconv.Itoa(e.cleared) + " | " + strconv.Itoa(e.stars) + " |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## Newest rooms\n\n")
	if nr := newestRooms(newestShown); len(nr) == 0 {
		b.WriteString("No rooms yet.\n")
	} else {
		for _, r := range nr {
			b.WriteString("- " + roomLink(r) + " by " + playerLink(r.Author.String()) +
				" at (" + strconv.Itoa(int(r.X)) + ", " + strconv.Itoa(int(r.Y)) + ")\n")
		}
	}

	b.WriteString("\n## Hidden rooms\n\n")
	writeHiddenRooms(&b)

	b.WriteString("\n## How to play\n\n")
	b.WriteString("1. [Open the game](" + playURL + "): hold a direction to glide tile to tile on the beat, Shift or Space to dash.\n")
	b.WriteString("2. Clear a room next to one you have cleared (the hub counts) to open it on your map.\n")
	b.WriteString("3. Sign in to keep a clear: the chain replays your inputs beat by beat, and only a replayed clear counts.\n")

	b.WriteString("\n## Build a room\n\n")
	b.WriteString("1. Paint and test-play a room in the [Forge](" + playURL + "); your clear becomes its proof and par.\n")
	b.WriteString("2. Deploy the exported `room.gno` to your own namespace with `gnokey maketx addpkg`.\n")
	b.WriteString("3. Call its `Publish` with `gnokey maketx call` and it opens on this map, next to a room that is already here.\n")
	return b.String()
}

// writeHiddenRooms lists the first hiddenShown hidden rooms by ID, each linked
// to its room page, and counts the rest.
func writeHiddenRooms(b *strings.Builder) {
	n := hiddenRooms.Size()
	if n == 0 {
		b.WriteString("No room is hidden.\n")
		return
	}
	noun := " rooms"
	if n == 1 {
		noun = " room"
	}
	b.WriteString("The admin has hidden " + bold(n) + noun + ". A hidden room keeps its cell but cannot be cleared.\n\n")
	hiddenRooms.IterateByOffset(0, hiddenShown, func(id string, _ any) bool {
		b.WriteString("- [" + mdText(id) + "](" + hubPath + ":room/" + id + "), hidden by the admin\n")
		return false
	})
	if n > hiddenShown {
		b.WriteString("\n...and " + strconv.Itoa(n-hiddenShown) + " more (`World()` lists every room with its hidden flag).\n")
	}
}

// ---- Room ----

func renderRoom(r *Room) string {
	cell := "(" + strconv.Itoa(int(r.X)) + ", " + strconv.Itoa(int(r.Y)) + ")"
	if r.Hidden {
		return "# Hidden room\n\n" + playLine(" · [World map]("+hubPath+")") +
			"The hub admin hid this room. It keeps its cell " + cell + " on the map.\n"
	}
	s := r.Static
	var board []Run
	if v := boards.Get(r.ID); v != nil {
		board = v.([]Run)
	}

	var img string
	if len(board) == 0 {
		img = image(r.Name, roomSVG(r, nil))
	} else {
		top := board[0]
		img = image(r.Name+", its best run replayed by the chain", roomSVG(r, &top))
	}
	var b strings.Builder
	b.Grow(len(img) + pageSlack)
	b.WriteString("# " + mdText(r.Name) + "\n\n")
	extra := ""
	if len(board) > 0 {
		// The relic rides along: a log replays only with the relic it was played with.
		extra = " · [Race this run](" + playURL + "/#/dare/" + r.ID + "/" + strconv.Itoa(int(board[0].Relic)) + "/" + board[0].Log + ")"
	}
	b.WriteString(playLine(extra + " · [World map](" + hubPath + ")"))

	objective := "reach the exit"
	if s.Objective == "SLAY" {
		objective = "slay every foe"
	}
	b.WriteString("By " + playerLink(r.Author.String()) + " · cell " + cell + " · " + objective +
		" · par " + bold(int(s.Par)) + " beats · " + bold(r.Clears) + " clears · " + bold(r.Uniques) + " explorers")
	if s.Chest != 0 {
		b.WriteString(" · chest: " + relicNames[s.Chest])
	}
	b.WriteString("\n\n")

	if len(board) == 0 {
		b.WriteString(img)
		b.WriteString("No clears yet. [Be the first](" + playURL + ").\n\n")
	} else {
		top := board[0]
		b.WriteString(img)
		b.WriteString("*The best run, replayed by the chain: " + strconv.Itoa(int(top.Beats)) + " beats by " + playerLink(top.Owner.String()))
		if top.Relic != 0 {
			b.WriteString(" with " + relicNames[top.Relic])
		}
		b.WriteString(".*\n\n## Board\n\n| # | Player | Beats | Damage | Route |\n| ---: | --- | ---: | ---: | --- |\n")
		for i, e := range board {
			b.WriteString("| " + strconv.Itoa(i+1) + " | " + playerLink(e.Owner.String()) + " | " +
				strconv.Itoa(int(e.Beats)) + " | " + strconv.Itoa(int(e.Damage)) + " | `" + routeHex(e.Route) + "` |\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("Room realm: [" + mdText(r.ID) + "](" + strings.TrimPrefix(r.ID, "gno.land") + ")\n")
	return b.String()
}

// ---- Player ----

func renderPlayer(a string) string {
	var p Player
	if v := playerOf(a, false); v != nil {
		p = *v
	}

	cleared := map[string]bool{}
	var rows strings.Builder
	if p.Cleared > 0 {
		rows.Grow(p.Cleared * 160)
		prefix := progressKey(a, "")
		// '}' is the byte after '|', so the range holds exactly this prefix.
		progress.Iterate(prefix, a+"}", func(k string, v any) bool {
			id := k[len(prefix):]
			cleared[id] = true
			pr := v.(*Progress)
			name := "*hidden room*"
			if rv := rooms.Get(id); rv != nil && !rv.(*Room).Hidden {
				name = roomLink(rv.(*Room))
			}
			rows.WriteString("| " + name + " | " + strconv.Itoa(int(pr.Best)) + " | " +
				strconv.Itoa(int(pr.Damage)) + " | " + starGlyphs(pr.Stars) + " |\n")
			return false
		})
	}
	img := image("World map with the rooms this explorer cleared in green", worldSVG(true, cleared))

	var b strings.Builder
	b.Grow(len(img) + rows.Len() + pageSlack)
	b.WriteString("# Explorer " + mdText(displayName(a)) + "\n\n")
	b.WriteString(playLine(" · [World map](" + hubPath + ")"))
	b.WriteString(mdText(a) + "\n\n")
	b.WriteString(bold(p.Renown) + " renown · " + bold(p.Cleared) + " rooms cleared · " + bold(p.Stars) + " stars · relics: ")
	held := ""
	for i := 1; i < len(relicNames); i++ {
		if p.Relics&(1<<uint(i)) != 0 {
			if held != "" {
				held += ", "
			}
			held += relicNames[i]
		}
	}
	if held == "" {
		held = "none"
	}
	b.WriteString(held + "\n\n")
	b.WriteString(img)
	b.WriteString("## Cleared rooms\n\n")
	if rows.Len() == 0 {
		b.WriteString("No clears yet. [Start in the hub](" + playURL + ").\n")
	} else {
		b.WriteString("| Room | Best beats | Damage | Stars |\n| --- | ---: | ---: | --- |\n")
		b.WriteString(rows.String())
	}
	return b.String()
}

// starGlyphs shows a room's star bits (clear, flawless, par) as three stars.
func starGlyphs(bits uint8) string {
	s := ""
	for _, bit := range []uint8{starCleared, starFlawless, starPar} {
		if bits&bit != 0 {
			s += "★"
		} else {
			s += "☆"
		}
	}
	return s
}
