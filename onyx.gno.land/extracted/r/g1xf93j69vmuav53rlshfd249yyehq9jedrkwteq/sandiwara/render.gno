package sandiwara

// Rendering. Four pages, all built with p/nt/mux:
//
//	/                        lobby list, one seat map per game
//	/game/{id}               the board for one game
//	/game/{id}/transcript    every commitment and reveal, phase by phase
//	/game/{id}/verify        the role root and the exact recomputation
//
// Every user-supplied string that reaches markdown goes through
// sanitize.InlineText or sanitize.TableCell. Game titles are user input.

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/svg/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Colour palette. Kept here so the board and the transcript agree.
const (
	colBackground = "#12161f"
	colSeatAlive  = "#243447"
	colSeatDead   = "#3a2028"
	colSeatActed  = "#1f4d3a"
	colStroke     = "#4a5b73"
	colText       = "#e6edf6"
	colMuted      = "#8b9bb4"
	colAccent     = "#63b3ed"
	colWarn       = "#f6ad55"
	colGood       = "#68d391"
	colBad        = "#fc8181"
)

func init() {
	router = mux.NewRouter()
	router.HandleFunc("", lobbyHandler)
	router.HandleFunc("game/{id}", boardHandler)
	router.HandleFunc("game/{id}/transcript", transcriptHandler)
	router.HandleFunc("game/{id}/verify", verifyHandler)
}

// Render is the realm's entry point. path is attacker-controlled.
func Render(path string) string {
	return router.Render(path)
}

// honestyLine is the one sentence the brief requires, unhedged, in the UI.
const honestyLine = "This realm does not implement an autonomous referee that secretly " +
	"knows who the werewolf is — Gno.land state is public, so a contract cannot hold a " +
	"secret; secrecy during play depends on the dealer not leaking, and only " +
	"verifiability after play is total."

// --- handlers --------------------------------------------------------------

func lobbyHandler(res *mux.ResponseWriter, req *mux.Request) {
	var b strings.Builder

	b.WriteString("# Sandiwara\n\n")
	b.WriteString("> The roles are sealed before the first night, and the dealer cannot rewrite them after the last.\n\n")
	b.WriteString("**" + honestyLine + "**\n\n")

	if gameCount() == 0 {
		b.WriteString("No tables yet. Open one with `NewGame`, then five to twelve players `Join`.\n")
		res.Write(b.String())
		return
	}

	b.WriteString("## Tables\n\n")
	b.WriteString("| # | title | seats | phase |\n")
	b.WriteString("|---|---|---|---|\n")
	for _, g := range games {
		b.WriteString("| " + strconv.FormatInt(g.ID, 10) + " | ")
		b.WriteString(sanitize.TableCell(g.Title))
		b.WriteString(" | " + strconv.Itoa(seatsFilled(g)) + "/" + strconv.Itoa(g.MaxPlyrs) + " | ")
		b.WriteString(g.Phase.String() + " |\n")
	}
	b.WriteString("\n")

	for _, g := range games {
		b.WriteString("### Table " + strconv.FormatInt(g.ID, 10) + ": " + sanitize.InlineText(g.Title) + "\n\n")
		b.WriteString(seatMap(g))
		b.WriteString("\n")
		b.WriteString(linkRow(g))
		b.WriteString("\n\n")
	}

	res.Write(b.String())
}

func boardHandler(res *mux.ResponseWriter, req *mux.Request) {
	g, ok := gameFromRequest(res, req)
	if !ok {
		return
	}

	var b strings.Builder
	b.WriteString("# " + sanitize.InlineText(g.Title) + "\n\n")
	b.WriteString("Table " + strconv.FormatInt(g.ID, 10) + " · phase **" + g.Phase.String() + "** · ")
	b.WriteString("dealer `" + shortAddr(g.Dealer) + "`\n\n")
	b.WriteString(seatMap(g))
	b.WriteString("\n")
	b.WriteString(seatGrid(g))
	b.WriteString("\n")

	b.WriteString("## This phase\n\n")
	b.WriteString(phaseSummary(g))
	b.WriteString("\n\n")
	b.WriteString(linkRow(g))
	b.WriteString("\n")

	res.Write(b.String())
}

func transcriptHandler(res *mux.ResponseWriter, req *mux.Request) {
	g, ok := gameFromRequest(res, req)
	if !ok {
		return
	}

	var b strings.Builder
	b.WriteString("# Transcript: " + sanitize.InlineText(g.Title) + "\n\n")
	b.WriteString("Table " + strconv.FormatInt(g.ID, 10) + " · phase **" + g.Phase.String() + "**\n\n")

	b.WriteString("## Phase log\n\n")
	if len(g.Transcript) == 0 {
		b.WriteString("_Nothing has happened yet._\n")
	}
	for _, line := range g.Transcript {
		b.WriteString("- " + sanitize.InlineText(line) + "\n")
	}
	b.WriteString("\n")

	b.WriteString("## Commitments and reveals\n\n")
	b.WriteString("| seat | player | night commitment | night action | vote commitment | vote target |\n")
	b.WriteString("|---|---|---|---|---|---|\n")
	for i := range g.Seats {
		s := &g.Seats[i]
		b.WriteString("| " + strconv.Itoa(i) + " | `" + shortAddr(s.Addr) + "` | ")
		b.WriteString(hexOrDash(s.NightCommit) + " | " + actionOrDash(s.NightAction) + " | ")
		b.WriteString(hexOrDash(s.VoteCommit) + " | " + actionOrDash(s.VoteTarget) + " |\n")
	}
	b.WriteString("\n")

	b.WriteString("## Verification\n\n")
	if g.Verdict == "" {
		b.WriteString("Not yet verified: the dealer has not opened the envelopes.\n")
	} else {
		b.WriteString("**" + sanitize.InlineText(g.Verdict) + "**\n")
	}

	res.Write(b.String())
}

func verifyHandler(res *mux.ResponseWriter, req *mux.Request) {
	g, ok := gameFromRequest(res, req)
	if !ok {
		return
	}

	var b strings.Builder
	b.WriteString("# Verify: " + sanitize.InlineText(g.Title) + "\n\n")
	b.WriteString("A third party does not have to trust this realm's verdict. Everything needed to ")
	b.WriteString("recompute it is below.\n\n")

	b.WriteString("## The dealer's sealed commitment\n\n")
	if len(g.RoleRoot) == 0 {
		b.WriteString("_The role root has not been sealed yet._\n\n")
	} else {
		b.WriteString("```\nsealed root  " + fullHex(g.RoleRoot) + "\n```\n\n")
	}

	if len(g.Revealed) == 0 {
		b.WriteString("## Envelopes\n\n_The dealer has not revealed the envelopes yet._\n\n")
		b.WriteString(recomputeRecipe())
		res.Write(b.String())
		return
	}

	b.WriteString("## Revealed envelopes\n\n")
	b.WriteString("| seat | role | salt | leaf sha256(salt‖role) | verified |\n")
	b.WriteString("|---|---|---|---|---|\n")
	for i := range g.Revealed {
		e := &g.Revealed[i]
		b.WriteString("| " + strconv.Itoa(e.Index) + " | ")
		b.WriteString(sanitize.TableCell(e.Role) + " | `" + fullHex(e.Salt) + "` | ")
		b.WriteString("`" + fullHex(e.Leaf) + "` | ")
		if e.Verified {
			b.WriteString("yes |\n")
		} else {
			b.WriteString("no |\n")
		}
	}
	b.WriteString("\n")

	b.WriteString("## Verdict\n\n")
	b.WriteString("**" + sanitize.InlineText(g.Verdict) + "**\n\n")

	b.WriteString(recomputeRecipe())
	res.Write(b.String())
}

// recomputeRecipe prints the exact steps a third party runs.
func recomputeRecipe() string {
	var b strings.Builder
	b.WriteString("## How to check this yourself\n\n")
	b.WriteString("1. For each seat `i`, compute `leaf_i = acak.Commit(salt_i, []byte(role_i))`, ")
	b.WriteString("which is `sha256(salt_i ‖ role_i)`.\n")
	b.WriteString("2. Build the tree over the leaves **in seat order**: `acak.NewTree(leaves)`.\n")
	b.WriteString("3. Compare `tree.Root()` with the sealed root printed above.\n")
	b.WriteString("4. For a single seat: `aunts, total := tree.Prove(i)` then ")
	b.WriteString("`acak.Verify(root, leaf_i, i, total, aunts)`.\n\n")
	b.WriteString("If step 3 does not match, the dealer changed the role map after sealing it. ")
	b.WriteString("That is what `DealerDisputed` records, permanently, in this realm's state.\n")
	return b.String()
}

// --- the seat map ----------------------------------------------------------

// seatMap draws the table as an SVG grid. Each seat shows its address prefix,
// whether the player is alive, and whether they have acted in the current
// phase. During NIGHT this is the only public information, which is exactly
// right: who has acted is public, what they did is not.
func seatMap(g *Game) string {
	const (
		cellW  = 210
		cellH  = 96
		margin = 18
		perRow = 3
		gap    = 12
	)

	rows := (len(g.Seats) + perRow - 1) / perRow
	if rows == 0 {
		rows = 1
	}
	w := margin*2 + perRow*cellW + (perRow-1)*gap
	h := margin*2 + 46 + rows*cellH + (rows-1)*gap

	c := svg.NewCanvas(w, h).WithViewBox(0, 0, w, h)
	c.Append(svg.NewRectangle(0, 0, w, h, colBackground))

	// Title strip: the phase, so a screenshot of the board is self-describing.
	c.Append(svg.NewText(margin, margin+16, g.Phase.String(), colAccent))
	c.Append(svg.NewText(margin+150, margin+16,
		ufmt.Sprintf("seats %d/%d   alive %d", seatsFilled(g), g.MaxPlyrs, livingCount(g)), colMuted))

	for i := range g.Seats {
		s := &g.Seats[i]
		col := i % perRow
		row := i / perRow
		x := margin + col*(cellW+gap)
		y := margin + 46 + row*(cellH+gap)

		fill := colSeatAlive
		if !s.Alive {
			fill = colSeatDead
		}
		acted := hasActed(g.Phase, s)
		if acted {
			fill = colSeatActed
		}

		c.Append(svg.NewRectangle(x, y, cellW, cellH, fill))
		// A second, unfilled rectangle with a visible stroke, so the cell
		// edge reads clearly against the dark background.
		border := svg.NewRectangle(x, y, cellW, cellH, "none")
		border.Attr.Stroke = colStroke
		border.Attr.StrokeWidth = "2"
		c.Append(border)

		// Seat number and address prefix.
		c.Append(svg.NewText(x+14, y+26, ufmt.Sprintf("#%d", i), colMuted))
		c.Append(svg.NewText(x+14, y+50, shortAddr(s.Addr), colText))

		// Status line: alive/dead, then acted/not.
		status := "alive"
		statusCol := colGood
		if !s.Alive {
			status = "dead"
			statusCol = colBad
		}
		c.Append(svg.NewText(x+14, y+76, status, statusCol))

		act := "not submitted"
		actCol := colMuted
		if acted {
			act = "submitted"
			actCol = colGood
		}
		if s.Absent {
			act = "absent"
			actCol = colWarn
		}
		c.Append(svg.NewText(x+86, y+76, act, actCol))

		// A small marker for the dealer, so the table's authority is visible.
		if s.Addr == g.Dealer {
			c.Append(svg.NewText(x+cellW-72, y+26, "dealer", colWarn))
		}
	}

	return c.Render("table " + strconv.FormatInt(g.ID, 10) + ", phase " + g.Phase.String())
}

// seatGrid is the same information as the SVG, as a markdown table. The SVG is
// the thing a human looks at; the table is the thing a screen reader, a diff,
// and `grep` can read. Both are generated from the same state, so they cannot
// disagree.
func seatGrid(g *Game) string {
	var b strings.Builder
	b.WriteString("| seat | player | status | this phase |\n")
	b.WriteString("|---|---|---|---|\n")
	for i := range g.Seats {
		s := &g.Seats[i]
		b.WriteString("| " + strconv.Itoa(i) + " | `" + shortAddr(s.Addr) + "` | ")
		if s.Alive {
			b.WriteString("alive")
		} else {
			b.WriteString("dead")
		}
		b.WriteString(" | ")
		switch {
		case s.Absent:
			b.WriteString("absent")
		case hasActed(g.Phase, s):
			b.WriteString("submitted")
		default:
			b.WriteString("not submitted")
		}
		b.WriteString(" |\n")
	}
	return b.String()
}

// hasActed reports whether the seat has acted in the given phase.
func hasActed(p Phase, s *Seat) bool {
	switch p {
	case PhaseNight:
		return len(s.NightCommit) != 0
	case PhaseDawn, PhaseVote:
		return len(s.VoteCommit) != 0
	case PhaseReveal, PhaseDone:
		return s.VoteOpen
	}
	return false
}

// phaseSummary is one paragraph of plain prose about the current phase.
func phaseSummary(g *Game) string {
	switch g.Phase {
	case PhaseLobby:
		return ufmt.Sprintf("%d of %d minimum seats filled. The dealer seals the role map when the table is ready.",
			seatsFilled(g), g.MinPlyrs)
	case PhaseSeal:
		return "The lobby is closed."
	case PhaseNight:
		return ufmt.Sprintf("%d of %d living players have committed a night action. Nothing they did is public until they reveal.",
			submittedNight(g), livingCount(g))
	case PhaseDawn:
		return "The night has resolved. Voting opens."
	case PhaseVote:
		return ufmt.Sprintf("%d of %d living players have committed a vote.",
			submittedVote(g), livingCount(g))
	case PhaseReveal:
		return "Voting is closed. The dealer must now open every role envelope."
	case PhaseDone:
		if g.Disputed {
			return "**The dealer disputed the record: the revealed envelopes do not match the sealed root.**"
		}
		return "The game is over and the transcript is final."
	}
	return ""
}

// --- small formatters ------------------------------------------------------

// linkRow renders the three per-game navigation links.
func linkRow(g *Game) string {
	base := "/r/" + realmPath + "/game/" + strconv.FormatInt(g.ID, 10)
	return "[board](" + base + ") · [transcript](" + base + "/transcript) · [verify](" + base + "/verify)"
}

// gameFromRequest resolves the {id} path variable, writing a 404 body when it
// does not name a game.
func gameFromRequest(res *mux.ResponseWriter, req *mux.Request) (*Game, bool) {
	id, ok := parseGameID(req.GetVar("id"))
	if !ok {
		res.Write("No such table.\n")
		return nil, false
	}
	return games[id], true
}

// hexOrDash renders a commitment as short hex, or a dash when absent.
func hexOrDash(b []byte) string {
	if len(b) == 0 {
		return "—"
	}
	return "`" + shortHex(b) + "…`"
}

// actionOrDash renders a revealed action, or a dash when absent.
func actionOrDash(s string) string {
	if s == "" {
		return "—"
	}
	if s == UnrevealedAction {
		return "_unrevealed_"
	}
	return sanitize.TableCell(s)
}

// parseGameID parses a game id from a render path segment.
func parseGameID(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n < 0 || n >= int64(len(games)) {
		return 0, false
	}
	return n, true
}
