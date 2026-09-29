package gno4

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/moul/gno4/v0"
	"gno.land/p/moul/md/v0"
	"gno.land/p/moul/txlink/v0"
)

// self is this realm's own gnoweb prefix, read from the package path it is
// running under.
//
// Not a constant, on purpose. The same source is deployed twice: once at
// r/moul/gno4 and once at r/moul/gno4/preview, the redeployable twin. A
// hardcoded "/r/moul/gno4" would send every link on the preview back to
// production, which reads as working and is the most confusing possible bug.
// txlink already does exactly this for the transaction links; this is the same
// rule applied to the page links.
func self() string {
	return strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), runtime.ChainDomain())
}

// Render is the product, not a debug view.
//
// Everything this realm knows is reachable from gnoweb with no wallet, no
// JavaScript and no front-end: the board is an inline SVG, every move is an
// ordinary link, and a game is a URL you can paste to somebody. The web app in
// web/ is a nicer way to do the same thing, never the only way.
//
// It is also deterministic. Nothing here reads the current height or the
// current time, only heights already recorded in state, which is what lets
// render_example_test.gno pin the output and turn a rendering regression into
// a red build instead of a permanently broken page.
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case path == "about":
		return renderAbout()
	case strings.HasPrefix(path, "g/"):
		return renderGame(strings.TrimPrefix(path, "g/"))
	case strings.HasPrefix(path, "u/"):
		return renderPlayer(strings.TrimPrefix(path, "u/"))
	}
	return "# Not found\n\nNo page at `" + md.EscapeText(path) + "`. [Back to the lobby](" + self() + ").\n"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Connect Four\n\n")
	b.WriteString("**The chain is the referee.** The rules live in a pure package that has never heard of a chain; ")
	b.WriteString("this realm owns the only three things that package cannot decide: who may move, when, and what everyone else gets to see.\n\n")
	b.WriteString(md.Link("Open a table", txlink.Call("Open")) + " and wait for someone, or join one below.\n\n")

	b.WriteString(section("Open tables", renderOpen()))
	b.WriteString(section("In play", renderLive()))
	b.WriteString(section("Finished", renderDone()))
	b.WriteString(section("Standings", renderStandings()))

	b.WriteString(md.HorizontalRule())
	b.WriteString(md.CollapsibleSection("How to play from a terminal", howTo()))
	b.WriteString("\n" + md.Link("What this realm is exploring", self()+":about") + "\n")
	return b.String()
}

func section(title, body string) string {
	if body == "" {
		return ""
	}
	return md.H2(title) + body + "\n"
}

func renderOpen() string {
	if len(open) == 0 {
		return ""
	}
	rows := "| table | opened by | at height | |\n|---|---|---|---|\n"
	for _, id := range open {
		g := mustGame(id)
		rows += "| " + gameLink(id) + " | " + player(g.Red) + " | " + itoa64(g.Opened) + " | " +
			md.Link("join", txlink.Call("Join", "id", itoa(id))) + " |\n"
	}
	return rows
}

func renderLive() string {
	if len(live) == 0 {
		return ""
	}
	rows := "| table | red | yellow | to move | moves |\n|---|---|---|---|---|\n"
	for _, id := range live {
		g := mustGame(id)
		board := g.Board()
		turn := g.Red
		if board.Turn() == gno4.Yellow {
			turn = g.Yellow
		}
		rows += "| " + gameLink(id) + " | " + player(g.Red) + " | " + player(g.Yellow) + " | " +
			disc(board.Turn()) + " " + player(turn) + " | " + itoa(board.MoveCount()) + " |\n"
	}
	return rows
}

func renderDone() string {
	if len(done) == 0 {
		return ""
	}
	rows := "| table | red | yellow | result |\n|---|---|---|---|\n"
	for _, id := range done {
		g := mustGame(id)
		rows += "| " + gameLink(id) + " | " + player(g.Red) + " | " + player(g.Yellow) + " | " + result(g) + " |\n"
	}
	return rows
}

func renderStandings() string {
	if records.Size() == 0 {
		return ""
	}
	rows := "| player | won | lost | drawn |\n|---|---|---|---|\n"
	records.Iterate("", "", func(k string, v any) bool {
		r := v.(*Record)
		rows += "| " + player(address(k)) + " | " + itoa(r.Wins) + " | " + itoa(r.Losses) + " | " + itoa(r.Draws) + " |\n"
		return false
	})
	return rows
}

func renderGame(raw string) string {
	id, ok := atoi(raw)
	if !ok || !games.Has(key(id)) {
		return "# Not found\n\nNo table numbered `" + md.EscapeText(raw) + "`. [Back to the lobby](" + self() + ").\n"
	}
	g := mustGame(id)
	board := g.Board()

	var b strings.Builder
	b.WriteString("# Table " + itoa(id) + "\n\n")
	b.WriteString(board.Image("Connect Four, table "+itoa(id)) + "\n\n")
	b.WriteString(status(g, board) + "\n\n")

	if !g.Over() && g.Yellow != "" {
		b.WriteString(moveRow(id, board) + "\n\n")
		b.WriteString(md.Italic("Anyone may click, but the chain only accepts the player whose turn it is.") + "\n\n")
	}
	if g.Yellow == "" && g.Quit == "" {
		b.WriteString(md.Link("Take the yellow seat", txlink.Call("Join", "id", itoa(id))) + "\n\n")
	}

	b.WriteString(md.H2("Seats"))
	b.WriteString("| | player | record |\n|---|---|---|\n")
	b.WriteString("| 🔴 red | " + player(g.Red) + " | " + recordLine(g.Red) + " |\n")
	if g.Yellow == "" {
		b.WriteString("| 🟡 yellow | _open_ | |\n")
	} else {
		b.WriteString("| 🟡 yellow | " + player(g.Yellow) + " | " + recordLine(g.Yellow) + " |\n")
	}
	b.WriteString("\n")

	b.WriteString(md.H2("The game, in full"))
	b.WriteString("The whole match is its move list, one digit per move. ")
	b.WriteString("Replaying it reproduces this position exactly, which is why that string is the only thing stored on chain.\n\n")
	b.WriteString(md.CodeBlock(orDash(g.Moves)))

	if !g.Over() && board.MoveCount() > 0 {
		b.WriteString(md.CollapsibleSection("Spoiler: is anyone one move from winning?", threats(board)))
	}
	b.WriteString("\n" + md.Link("Back to the lobby", self()) + "\n")
	return b.String()
}

func renderPlayer(raw string) string {
	addr := address(raw)
	if !addr.IsValid() {
		return "# Not a player\n\n`" + md.EscapeText(raw) + "` is not an address. [Back to the lobby](" + self() + ").\n"
	}
	var b strings.Builder
	b.WriteString("# " + short(addr) + "\n\n")
	b.WriteString(md.Link(addr.String(), "/u/"+addr.String()) + "\n\n")
	b.WriteString("Record: " + recordLine(addr) + "\n\n")

	rows := ""
	games.ReverseIterate("", "", func(k string, v any) bool {
		g := v.(*Game)
		if g.Red != addr && g.Yellow != addr {
			return false
		}
		rows += "| " + gameLink(g.ID) + " | " + player(other(g, addr)) + " | " + result(g) + " |\n"
		return false
	})
	if rows != "" {
		b.WriteString(md.H2("Games"))
		b.WriteString("| table | against | result |\n|---|---|---|\n" + rows + "\n")
	}
	b.WriteString(md.Link("Back to the lobby", self()) + "\n")
	return b.String()
}

func renderAbout() string {
	return `# What this realm is exploring

This is one of four small games built to answer a single question: **what does a
web2.5 application on gno.land actually need to get right?** Not the game, the
scaffolding around it.

The engine is a pure package with no chain import, so its rules are testable
with no node. This realm owns authority and rendering, and nothing else. The
board you see is an SVG generated at render time and inlined as a data URI, so
it costs no storage and there is no asset to go missing. Every page here is
reachable with no wallet and no JavaScript.

There are two deployments of this same source: this one, and a ` + "`/preview`" + `
twin flagged ` + "`private = true`" + ` so it stays redeployable while the design
is still moving. A public path can never be redeployed, which makes the flag the
most consequential line in the whole repository.

The repository, the checklist it is written against, and the other three games:
[github.com/moul/gno4](https://github.com/moul/gno4).

` + md.Link("Back to the lobby", self()) + "\n"
}

// --- small helpers -------------------------------------------------------

func status(g *Game, board *gno4.Board) string {
	switch {
	case g.Quit != "":
		return md.Bold(short(g.Quit)+" resigned.") + " " + player(g.Winner()) + " takes it."
	case board.Winner() != gno4.Empty:
		return md.Bold(disc(board.Winner())+" "+short(g.Winner())+" wins.") +
			" In " + itoa(board.MoveCount()) + " moves."
	case board.Draw():
		return md.Bold("A draw.") + " Forty-two discs, no line of four."
	case g.Yellow == "":
		return md.Bold("Waiting for an opponent.")
	default:
		turn := g.Red
		if board.Turn() == gno4.Yellow {
			turn = g.Yellow
		}
		return md.Bold(disc(board.Turn())+" "+short(turn)+" to move.") + " Move " + itoa(board.MoveCount()+1) + "."
	}
}

// moveRow is the move menu: one link per playable column, in column order, so
// its position under the board matches the board itself.
func moveRow(id int, board *gno4.Board) string {
	cells := make([]string, 0, gno4.Cols)
	for col := 0; col < gno4.Cols; col++ {
		label := itoa(col + 1)
		if !board.CanDrop(col) {
			cells = append(cells, "·")
			continue
		}
		cells = append(cells, md.Link("⬇ "+label, txlink.Call("Play", "id", itoa(id), "col", label)))
	}
	return strings.Join(cells, " · ")
}

func threats(board *gno4.Board) string {
	out := ""
	for _, d := range []gno4.Disc{gno4.Red, gno4.Yellow} {
		if col := board.WinningMove(d); col >= 0 {
			out += "- " + disc(d) + " wins immediately by playing column " + itoa(col+1) + ".\n"
		}
	}
	if out == "" {
		return "Neither side can win on this move.\n"
	}
	return out
}

func gameLink(id int) string { return md.Link(itoa(id), self()+":g/"+itoa(id)) }

func player(addr address) string {
	if addr == "" {
		return "_nobody_"
	}
	return md.Link(short(addr), self()+":u/"+addr.String())
}

func short(addr address) string {
	s := addr.String()
	if len(s) <= 12 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func disc(d gno4.Disc) string {
	switch d {
	case gno4.Red:
		return "🔴"
	case gno4.Yellow:
		return "🟡"
	}
	return "⚫"
}

func result(g *Game) string {
	if !g.Over() {
		return "in play"
	}
	if w := g.Winner(); w != "" {
		if g.Quit != "" {
			return player(w) + " (resignation)"
		}
		return player(w)
	}
	if g.Yellow == "" {
		return "withdrawn"
	}
	return "draw"
}

func recordLine(addr address) string {
	w, l, d := RecordOf(addr)
	return itoa(w) + "W / " + itoa(l) + "L / " + itoa(d) + "D"
}

func other(g *Game, addr address) address {
	if g.Red == addr {
		return g.Yellow
	}
	return g.Red
}

func orDash(s string) string {
	if s == "" {
		return "(no moves yet)"
	}
	return s
}

// howTo prints the two commands that cover the whole game, against whichever
// path this realm is actually deployed at.
func howTo() string {
	pkg := runtime.ChainDomain() + strings.TrimPrefix(self(), "/")
	tail := " \\\n  -gas-fee 1000000ugnot -gas-wanted 2000000 -broadcast" +
		" -chainid " + runtime.ChainID() + " \\\n  -remote https://rpc.gno.land:443 YOURKEY\n"
	return "```sh\n" +
		"# open a table; the transaction's output carries the id\n" +
		"gnokey maketx call -pkgpath " + pkg + " -func Open" + tail +
		"\n" +
		"# drop a disc into column 4 of table 7\n" +
		"gnokey maketx call -pkgpath " + pkg + " -func Play -args 7 -args 4" + tail +
		"```\n" +
		"\nThose gas numbers are a starting point, not a measurement. Simulate first: " +
		"drop `-broadcast` and the node answers with what the call actually costs.\n"
}

func itoa64(n int64) string { return itoa(int(n)) }

func atoi(s string) (int, bool) {
	if s == "" || len(s) > 9 {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	return n, true
}

