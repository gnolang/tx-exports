package tavernfour

// gnoweb pages. Every page is rendered from on-chain state, so any visitor —
// player, opponent or passer-by — sees the same board at the same height.

import (
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1k6cl2huxpps9fxls8tqyxknvl7fgq9hua3f2yt/c4"
)

// Render dispatches gnoweb paths:
//
//	""             the tavern: open tables, games in play, the ladder
//	"game/<id>"    one table, its board, its clock and the commands it takes
//	"ladder"       every player who has sat down
//	"how"          the rules, the commands, and how the purse works
func Render(path string) string {
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return renderHome()
	case parts[0] == "how" && len(parts) == 1:
		return renderHow()
	case parts[0] == "ladder" && len(parts) == 1:
		return renderLadder()
	case parts[0] == "game" && len(parts) == 2:
		id, ok := parseUint(parts[1])
		if !ok {
			return renderNotFound(path)
		}
		return renderGame(id)
	}
	return renderNotFound(path)
}

// ------------------------------------------------------------------- home

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Tavern Four\n\n")
	b.WriteString("**Four in a row, for two, on gno.land — with a purse that settles itself.**\n\n")
	b.WriteString("A gnome chalks a board on the tavern table and puts up a stake. Someone takes ")
	b.WriteString("the other stool by matching it. They drop discs by transaction, one at a time; ")
	b.WriteString("the realm holds the pot and pays it out in the same transaction that makes the ")
	b.WriteString("fourth in a row. No one holds the money, no one can move out of turn, and every ")
	b.WriteString("board can be replayed from the first disc.\n\n")
	b.WriteString("[How it works and how to play](" + gnowebURL(RealmPath) + ":how) · ")
	b.WriteString("[The ladder](" + gnowebURL(RealmPath) + ":ladder)\n\n")

	now := runtime.ChainHeight()

	// Open tables.
	open := 0
	var rows strings.Builder
	rows.WriteString("| table | host | stake | clock | moves |\n|---|---|---|---|---|\n")
	for i := len(games) - 1; i >= 0; i-- {
		g := games[i]
		if g.Status != StatusOpen {
			continue
		}
		open++
		rows.WriteString("| [#" + uitoa(g.ID) + "](" + gameURL(g.ID) + ") | " + cell(nameOf(g.Host, g.HostName)))
		rows.WriteString(" | " + gnot(g.Stake) + " | " + itoa(g.TurnBlocks) + " blocks | — |\n")
	}
	b.WriteString("## Open tables\n\n")
	if open == 0 {
		b.WriteString("Nobody is waiting for a guest. [Open a table](" + gnowebURL(RealmPath) + ":how) ")
		b.WriteString("with a single transaction — the stake comes back if nobody sits down.\n\n")
	} else {
		b.WriteString(rows.String())
		b.WriteString("\n")
	}

	// Games in play.
	live := 0
	var liveRows strings.Builder
	liveRows.WriteString("| table | red | yellow | to move | clock | pot |\n|---|---|---|---|---|---|\n")
	for i := len(games) - 1; i >= 0; i-- {
		g := games[i]
		if g.Status != StatusLive {
			continue
		}
		live++
		liveRows.WriteString("| [#" + uitoa(g.ID) + "](" + gameURL(g.ID) + ") | " + cell(nameOf(g.Host, g.HostName)))
		liveRows.WriteString(" | " + cell(guestNameOf(g)))
		liveRows.WriteString(" | " + discName(colourForSide(g.Turn)))
		left := g.Deadline() - now
		if left < 0 {
			left = 0
		}
		liveRows.WriteString(" | " + itoa(left) + " blocks left")
		liveRows.WriteString(" | " + gnot(g.Pot()) + " |\n")
	}
	b.WriteString("## On the table\n\n")
	if live == 0 {
		b.WriteString("No game is in play right now.\n\n")
	} else {
		b.WriteString(liveRows.String())
		b.WriteString("\n")
	}

	// Recently settled.
	settled := 0
	var doneRows strings.Builder
	doneRows.WriteString("| table | red | yellow | result | moves |\n|---|---|---|---|---|\n")
	for i := len(games) - 1; i >= 0 && settled < 8; i-- {
		g := games[i]
		if g.Status != StatusFinished {
			continue
		}
		settled++
		doneRows.WriteString("| [#" + uitoa(g.ID) + "](" + gameURL(g.ID) + ") | " + cell(nameOf(g.Host, g.HostName)))
		doneRows.WriteString(" | " + cell(guestNameOf(g)))
		doneRows.WriteString(" | " + resultBadge(g))
		doneRows.WriteString(" | " + itoa(int64(len(g.Moves))) + " |\n")
	}
	if settled > 0 {
		b.WriteString("## Recently settled\n\n")
		b.WriteString(doneRows.String())
		b.WriteString("\n")
	}

	// Ladder, top five.
	b.WriteString("## The ladder\n\n")
	rowsL := Ladder()
	if len(rowsL) == 0 {
		b.WriteString("No one has finished a game yet — the first win takes the board.\n")
	} else {
		b.WriteString("| # | player | points | W-L-D | streak | won |\n|---|---|---|---|---|---|\n")
		for i := 0; i < len(rowsL) && i < 5; i++ {
			p := rowsL[i]
			b.WriteString("| " + strconv.Itoa(i+1) + " | " + cell(nameOfP(p)) + " | " + strconv.Itoa(p.Points))
			b.WriteString(" | " + strconv.Itoa(p.Wins) + "-" + strconv.Itoa(p.Losses) + "-" + strconv.Itoa(p.Draws))
			b.WriteString(" | " + strconv.Itoa(p.Streak) + " | " + gnot(p.Won) + " |\n")
		}
		b.WriteString("\n[Full ladder](" + gnowebURL(RealmPath) + ":ladder)\n")
	}
	return b.String()
}

// ------------------------------------------------------------------- game

func renderGame(id uint64) string {
	g := GetGame(id)
	if g == nil {
		return renderNotFound("game/" + uitoa(id))
	}
	height := runtime.ChainHeight()

	var b strings.Builder
	b.WriteString("# Table #" + uitoa(g.ID) + " · " + cell(nameOf(g.Host, g.HostName)) + " vs " + cell(guestNameOf(g)) + "\n\n")
	b.WriteString(statusLine(g, height) + "\n\n")

	// Board.
	lastCol := -1
	if len(g.Moves) > 0 {
		lastCol = g.Moves[len(g.Moves)-1].Col
	}
	b.WriteString(boardTable(g.Board, g.WinLine, lastCol))
	b.WriteString("\n")
	if len(g.Moves) > 0 {
		m := g.Moves[len(g.Moves)-1]
		b.WriteString("Last disc: column " + strconv.Itoa(m.Col+1) + " by " + cell(nameOf(m.By, nameFallback(g, m.By))) +
			" at block " + itoa(m.Height) + ".\n\n")
	}

	// Money and clock.
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| purse | " + gnot(g.Pot()) + " held by the realm" + purseNote(g) + " |\n")
	b.WriteString("| stake | " + gnot(g.Stake) + " each |\n")
	b.WriteString("| seat red | " + cell(nameOf(g.Host, g.HostName)) + " `" + short(g.Host.String()) + "` |\n")
	if g.Guest != "" {
		b.WriteString("| seat yellow | " + cell(guestNameOf(g)) + " `" + short(g.Guest) + "` |\n")
	} else {
		b.WriteString("| seat yellow | *open — take it by matching the stake* |\n")
	}
	b.WriteString("| clock | " + itoa(g.TurnBlocks) + " blocks a move · now " + itoa(height))
	if g.Status == StatusLive {
		left := g.Deadline() - height
		if left < 0 {
			left = 0
		}
		b.WriteString(" · deadline " + itoa(g.Deadline()) + " (" + itoa(left) + " left)")
	}
	b.WriteString(" |\n")
	b.WriteString("| opened | block " + itoa(g.OpenedHeight) + " |\n\n")

	renderActions(&b, g, height)

	// Move list, newest first.
	if len(g.Moves) > 0 {
		b.WriteString("## Moves\n\n")
		b.WriteString("| # | colour | player | column | block |\n|---|---|---|---|---|\n")
		for i := len(g.Moves) - 1; i >= 0; i-- {
			m := g.Moves[i]
			b.WriteString("| " + strconv.Itoa(i+1) + " | " + discName(colourOf(g, m.By)) + " | " + cell(nameOf(m.By, nameFallback(g, m.By))))
			b.WriteString(" | " + strconv.Itoa(m.Col+1) + " | " + itoa(m.Height) + " |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("Every move is a transaction; the board above is the realm's state, not a screenshot. ")
	b.WriteString("A replayed game is in [the how page](" + gnowebURL(RealmPath) + ":how).\n")
	return b.String()
}

func renderActions(b *strings.Builder, g *Game, height int64) {
	b.WriteString("## What this table takes now\n\n")

	switch g.Status {
	case StatusOpen:
		b.WriteString("Waiting for a guest. Matching the stake takes the yellow seat and starts the game:\n\n")
		writeCmd(b, "Join", []string{uitoa(g.ID), "\"your name\""}, g.Stake)
		b.WriteString("The host can close the table and take the stake back:\n\n")
		writeCmd(b, "Cancel", []string{uitoa(g.ID)}, 0)
	case StatusLive:
		b.WriteString("It is " + discName(colourForSide(g.Turn)) + "'s turn — the player to move drops a disc into a column:\n\n")
		writeCmd(b, "Drop", []string{uitoa(g.ID), "4"}, 0)
		b.WriteString("Columns are 1-7, left to right. Open columns: " + openColumns(g.Board) + ".\n\n")
		b.WriteString("Walking away hands the pot to the other seat:\n\n")
		writeCmd(b, "Forfeit", []string{uitoa(g.ID)}, 0)
		left := g.Deadline() - height
		if left <= 0 {
			b.WriteString("**The clock has run out.** The seated player whose turn it is not can take the game:\n\n")
		} else {
			b.WriteString("If the player to move lets the clock run out (" + itoa(left) + " blocks left), the other seat can take the game:\n\n")
		}
		writeCmd(b, "ClaimTimeout", []string{uitoa(g.ID)}, 0)
	case StatusFinished:
		b.WriteString("Settled — " + resultBadge(g) + ". The pot was paid in the transaction that ended the game, ")
		b.WriteString("and the ledger row was written at the same height. Open a new table with `Open` on [the how page](" +
			gnowebURL(RealmPath) + ":how).\n")
	case StatusCancelled:
		b.WriteString("Cancelled by the host before a guest arrived; the stake went back to the host.\n")
	}
}

// ---------------------------------------------------------------- ladder

func renderLadder() string {
	var b strings.Builder
	b.WriteString("# The tavern ladder\n\n")
	b.WriteString("Points are the house's own: **3 for a win, 1 for a draw, 0 for a loss**. ")
	b.WriteString("Ties break on wins, then on fewer games played, so a short unbeaten run outranks a long ")
	b.WriteString("even one. `won` is what the purse paid this player, in ugnot.\n\n")

	rows := Ladder()
	if len(rows) == 0 {
		b.WriteString("Nobody has finished a game yet.\n")
		return b.String()
	}
	b.WriteString("| # | player | points | games | W | L | D | streak | best | won |\n|---|---|---|---|---|---|---|---|---|---|\n")
	for i := 0; i < len(rows); i++ {
		p := rows[i]
		b.WriteString("| " + strconv.Itoa(i+1) + " | " + cell(nameOfP(p)) + " | " + strconv.Itoa(p.Points))
		b.WriteString(" | " + strconv.Itoa(p.Games) + " | " + strconv.Itoa(p.Wins) + " | " + strconv.Itoa(p.Losses))
		b.WriteString(" | " + strconv.Itoa(p.Draws) + " | " + strconv.Itoa(p.Streak) + " | " + strconv.Itoa(p.BestStreak))
		b.WriteString(" | " + gnot(p.Won) + " |\n")
	}
	b.WriteString("\n[Back to the tavern](" + gnowebURL(RealmPath) + ")\n")
	return b.String()
}

// ------------------------------------------------------------------- how

func renderHow() string {
	var b strings.Builder
	b.WriteString("# How Tavern Four works\n\n")
	b.WriteString("## The rules\n\n")
	b.WriteString("- Board 7 columns wide, 6 rows high. You drop a disc into a column and it falls to the lowest free row.\n")
	b.WriteString("- Red (the host) moves first; yellow (the guest) answers. Turns alternate, one transaction each.\n")
	b.WriteString("- Four of your colour in a line — across, down, or either diagonal — wins. A full board with no line is a draw.\n")
	b.WriteString("- A move must come from the player whose turn it is. The realm refuses anything else, so a board cannot be edited by a spectator.\n")
	b.WriteString("- Each move must arrive within the table's clock, counted in blocks. Past it, the other seat may claim the game.\n\n")

	b.WriteString("## Opening a table\n\n")
	b.WriteString("The host sends exactly the stake with the call; the realm holds it until someone joins. ")
	b.WriteString("A stake of `0` opens a friendly table and moves no coins.\n\n")
	writeCmd(&b, "Open", []string{"1000000", "300", "\"Gno Tavern\""}, 1000000)
	b.WriteString("That opens a 1 GNOT table with a 300-block clock, hosted as `Gno Tavern`. The call returns ")
	b.WriteString("the table number, and the host's `1000000ugnot` is now the pot's first half.\n\n")

	b.WriteString("## Where the money lives\n\n")
	b.WriteString("Stakes are paid into the realm's own account — the address of `" + RealmPath + "`. ")
	b.WriteString("The realm keeps a running total of what it holds and pays only out of it, so one table can never ")
	b.WriteString("spend another's pot. Settlement happens in the same transaction as the winning move: there is no ")
	b.WriteString("claim step and no keeper to trust. A cancelled table returns the stake to the host; a draw returns ")
	b.WriteString("each stake.\n\n")
	b.WriteString("| moment | who acts | what the realm does |\n|---|---|---|\n")
	b.WriteString("| open | host | takes the stake into escrow, seats red |\n")
	b.WriteString("| join | guest | takes a matching stake, seats yellow, starts the clock |\n")
	b.WriteString("| move | player to move | drops the disc, checks the line, passes the turn |\n")
	b.WriteString("| win / draw | the move that ends it | pays the pot and records the ladder row, in that transaction |\n")
	b.WriteString("| timeout | the waiting seat | pays the pot after the clock runs out |\n")
	b.WriteString("| cancel | host, before a guest arrives | returns the stake |\n\n")

	b.WriteString("## Reading a board without trusting this page\n\n")
	b.WriteString("The realm exposes the board, the moves and the money as JSON:\n\n")
	b.WriteString("```\n" + RealmPath + ".GameJSON(1)\n" + RealmPath + ".LadderJSON()\n```\n\n")
	b.WriteString("`GameJSON` carries `board` as 42 characters — `0` empty, `1` red, `2` yellow, top row first — ")
	b.WriteString("so a checker can replay every move with the same rules package the realm uses.\n\n")

	b.WriteString("## Playing in a browser\n\n")
	b.WriteString("The project ships a single-file browser table (`web/index.html`) that draws this same board, ")
	b.WriteString("polls the chain and signs `Drop` with the visitor's own wallet — the realm never asks for a key. ")
	b.WriteString("`GameJSON` and `LadderJSON` above are exactly what it reads.\n\n")
	b.WriteString("[Back to the tavern](" + gnowebURL(RealmPath) + ")\n")
	return b.String()
}

// --------------------------------------------------------------- helpers

func boardTable(b c4.Board, win []int, lastCol int) string {
	var s strings.Builder
	s.WriteString("|   | 1 | 2 | 3 | 4 | 5 | 6 | 7 |\n")
	s.WriteString("|---|---|---|---|---|---|---|---|\n")
	for row := 0; row < c4.Rows; row++ {
		s.WriteString("| ")
		s.WriteString(strconv.Itoa(row + 1))
		s.WriteString(" ")
		for col := 0; col < c4.Cols; col++ {
			s.WriteString("| ")
			s.WriteString(disc(b.At(row, col), inLine(win, row*c4.Cols+col)))
			s.WriteString(" ")
		}
		s.WriteString("|\n")
	}
	// A row of arrows under the columns, marking where the last disc fell.
	s.WriteString("|   ")
	for col := 0; col < c4.Cols; col++ {
		if col == lastCol {
			s.WriteString("| ▾ ")
		} else {
			s.WriteString("|   ")
		}
	}
	s.WriteString("|\n")
	return s.String()
}

func disc(cell uint8, winning bool) string {
	glyph := "⚪"
	if cell == c4.Red {
		glyph = "🔴"
	} else if cell == c4.Yellow {
		glyph = "🟡"
	}
	if winning {
		return "**" + glyph + "**"
	}
	return glyph
}

// colourForSide maps a seat name to the disc it plays.
func colourForSide(side string) uint8 {
	if side == SeatGuest {
		return c4.Yellow
	}
	return c4.Red
}

func discName(cell uint8) string {
	if cell == c4.Red {
		return "🔴 red"
	}
	if cell == c4.Yellow {
		return "🟡 yellow"
	}
	return "—"
}

func inLine(line []int, idx int) bool {
	for i := 0; i < len(line); i++ {
		if line[i] == idx {
			return true
		}
	}
	return false
}

func statusLine(g *Game, height int64) string {
	switch g.Status {
	case StatusOpen:
		return "**Waiting for a guest** — " + gnot(g.Stake) + " on the table, " + itoa(g.TurnBlocks) + " blocks a move."
	case StatusLive:
		left := g.Deadline() - height
		if left < 0 {
			left = 0
		}
		return "**In play** — " + discName(colourForSide(g.Turn)) + " to move, " + itoa(left) + " blocks left on the clock."
	case StatusFinished:
		return "**Settled** — " + resultBadge(g)
	case StatusCancelled:
		return "**Cancelled** — the host closed the table and took the stake back."
	}
	return g.Status
}

func resultBadge(g *Game) string {
	switch g.Result {
	case ResultHost:
		return "🔴 " + cell(nameOf(g.Host, g.HostName)) + " wins"
	case ResultGuest:
		return "🟡 " + cell(guestNameOf(g)) + " wins"
	case ResultDraw:
		return "draw"
	}
	return "—"
}

func purseNote(g *Game) string {
	if g.Stake == 0 {
		return " (friendly table, no coins)"
	}
	return ""
}

func openColumns(b c4.Board) string {
	cols := b.Legal()
	if len(cols) == 0 {
		return "none — the board is full"
	}
	out := ""
	for i := 0; i < len(cols); i++ {
		if i > 0 {
			out += ", "
		}
		out += strconv.Itoa(cols[i] + 1)
	}
	return out
}

// writeCmd prints a gnokey command that does one thing on this realm.
func writeCmd(b *strings.Builder, fn string, args []string, send int64) {
	b.WriteString("```\n")
	b.WriteString("gnokey maketx call -pkgpath " + RealmPath + " -func " + fn)
	for i := 0; i < len(args); i++ {
		b.WriteString(" -args " + args[i])
	}
	b.WriteString(" \\\n  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast \\\n")
	b.WriteString("  -chainid " + runtime.ChainID() + " -remote https://rpc." + testnetHost() + " YOUR_KEY\n")
	b.WriteString("```\n")
	if send > 0 {
		b.WriteString("*add `-send " + itoa(send) + "ugnot` — the stake goes with the call.*\n")
	}
	b.WriteString("\n")
}

func testnetHost() string {
	if runtime.ChainID() == "onyx-1" {
		return "onyx.testnets.gno.land:443"
	}
	return "rpc.gno.land:443"
}

func gnot(amount int64) string {
	if amount == 0 {
		return "0"
	}
	whole := amount / 1000000
	frac := amount % 1000000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	f := strconv.FormatInt(frac, 10)
	for len(f) < 6 {
		f = "0" + f
	}
	for len(f) > 0 && f[len(f)-1] == '0' {
		f = f[:len(f)-1]
	}
	return strconv.FormatInt(whole, 10) + "." + f + " GNOT"
}

func nameFallback(g *Game, a address) string {
	if sideOf(g, a) == SeatGuest {
		return g.GuestName
	}
	return g.HostName
}

func nameOfP(p *Player) string {
	if p.Name != "" {
		return p.Name
	}
	return short(p.Address)
}

func short(s string) string {
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "…" + s[len(s)-6:]
}

// cell keeps a free-text field from breaking a markdown table.
func cell(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '|' {
			out += "\\|"
		} else if c == '\n' || c == '\r' {
			out += " "
		} else {
			out += string(c)
		}
	}
	return out
}

func gameURL(id uint64) string {
	return gnowebURL(RealmPath) + ":game/" + uitoa(id)
}

// gnowebURL turns a package path into the path part of its gnoweb URL by
// dropping the chain domain: gno.land/r/x/y -> /r/x/y.
func gnowebURL(pkgPath string) string {
	i := strings.Index(pkgPath, "/")
	if i < 0 {
		return "/" + pkgPath
	}
	return pkgPath[i:]
}

func renderNotFound(path string) string {
	return "# Not found\n\nNo page at `" + cell(path) + "`.\n\n[Back to the tavern](" + gnowebURL(RealmPath) + ")\n"
}

func parseUint(s string) (uint64, bool) {
	if s == "" {
		return 0, false
	}
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

// stamp is used by the docs pages: UTC and KST side by side.
func stamp(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04") + " UTC"
}
