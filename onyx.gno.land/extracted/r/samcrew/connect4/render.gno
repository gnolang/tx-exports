package connect4

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"net/url"
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/svg/v0"
)

// lobbyRows caps the games the lobby lists, so Render stays within query gas
// however many games are open; clients page through ActiveJSON instead.
const lobbyRows = 50

// Board colours. gnoweb only embeds SVG as data-URI images, so each column is
// its own image, wrapped in its Play link while the game is being played.
const (
	red            = "#e53935"
	yellow         = "#fdd835"
	hole           = "#ffffff"
	boardBlue      = "#1565c0"
	lastMoveStroke = "#212121"
	winStroke      = "#00e676"
	cellPx         = 48
	headerPx       = 20
)

var pieceColor = [...]string{hole, red, yellow}
var pieceName = [...]string{"empty", "red", "yellow"}

// Render serves "" (lobby and leaderboards), "new" (offer form) and
// "game/<id>" (one game with every action its state allows).
// Everything written comes from realm state or from query values that have
// been validated and re-formatted; raw path input is never echoed.
func Render(path string) string {
	p, query, _ := strings.Cut(path, "?")
	switch {
	case p == "":
		return renderLobby()
	case p == "new":
		return renderNew(query)
	}
	if s, ok := strings.CutPrefix(p, "game/"); ok {
		if id, err := strconv.Atoi(s); err == nil {
			if g := get(id); g != nil {
				return renderGame(g)
			}
		}
	}
	return "# Not found\n"
}

// pageURL links to one of this realm's Render pages. The realm path is read
// at runtime, like txlink does, so links work wherever the realm is deployed.
func pageURL(page string) string {
	base := strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), runtime.ChainDomain())
	if page == "" {
		return base
	}
	return base + ":" + page
}

func gameLink(base string, id int) string {
	return "[#" + strconv.Itoa(id) + "](" + base + ":game/" + strconv.Itoa(id) + ")"
}

func renderLobby() string {
	now := time.Now()
	base := pageURL("")
	var open, live strings.Builder
	// Only rows actually written count toward lobbyRows: expired offers nobody
	// cancelled must not crowd out live games.
	shown := 0
	active.Iterate("", "", func(_ string, v any) bool {
		g := v.(*Game)
		switch {
		case g.Status == Open && now.Before(g.ExpiresAt):
			open.WriteString("| " + gameLink(base, g.ID) + " | " + gnot(g.Stake) + " | " + gnot(g.Fee) + " | " + g.Creator.String() + " | " + openTo(g) +
				" | " + remaining(g.ExpiresAt.Sub(now)) + " | [Accept](" + acceptURL(g) + ") |\n")
		case g.Status == Playing:
			live.WriteString("| " + gameLink(base, g.ID) + " | " + gnot(2*g.Stake) + " | " + onTurn(g) + " | " + clockLeft(g, now) + " |\n")
		default:
			return false
		}
		shown++
		return shown == lobbyRows
	})

	var b strings.Builder
	b.WriteString("# Connect 4\n\n")
	b.WriteString("Both players stake the same amount; the winner takes the pot minus the house fee shown on each offer " +
		"(" + gnot(fee) + " for new offers). " +
		"90s per move: run out and you forfeit. If the first mover never moves, both stakes are refunded.\n\n")
	b.WriteString("**[Post an offer](" + base + ":new)** · open a game below to play it\n\n")
	b.WriteString("## Open offers\n\n")
	if open.Len() == 0 {
		b.WriteString("No open offers.\n\n")
	} else {
		b.WriteString("| Game | Stake | Fee | Creator | For | Expires in | |\n|---|---|---|---|---|---|---|\n" + open.String() + "\n")
	}
	b.WriteString("## Live games\n\n")
	if live.Len() == 0 {
		b.WriteString("No games in progress.\n\n")
	} else {
		b.WriteString("| Game | Pot | Turn | Time left |\n|---|---|---|---|\n" + live.String() + "\n")
	}
	if shown == lobbyRows {
		b.WriteString("Showing the first " + strconv.Itoa(lobbyRows) + " games.\n\n")
	}
	b.WriteString("## Most games won\n\n")
	b.WriteString(leaderboard(topWins, func(v int64) string { return strconv.FormatInt(v, 10) }))
	b.WriteString("## Most gnot won\n\n")
	b.WriteString(leaderboard(topGnot, gnot))
	return b.String()
}

// renderNew shows the offer form and, once submitted, a single Offer link
// with the stake and every argument prefilled (gnoweb cannot edit .send).
func renderNew(query string) string {
	var b strings.Builder
	b.WriteString("# Post an offer\n\n[← Lobby](" + pageURL("") + ")\n\n")
	b.WriteString("Generate a fresh random passphrase for every offer and keep it: " +
		"once someone accepts you have 90s to reveal it, or you forfeit. " +
		"A guessable one lets an opponent work out who moves first. " +
		"Paste only its sha256 below, never the passphrase itself:\n\n" +
		"    pass=$(openssl rand -hex 32); echo \"$pass\"\n" +
		"    printf %s \"$pass\" | shasum -a 256\n\n")
	b.WriteString(`<gno-form path="new">
<gno-input name="stake" type="text" placeholder="Stake in GNOT, e.g. 10 (min 1)" />
<gno-input name="validFor" type="number" placeholder="Minutes the offer stays open, 1-60 (default 15)" />
<gno-input name="opponent" type="text" placeholder="Opponent address (optional, leave empty for anyone)" />
<gno-input name="commitment" type="text" placeholder="sha256 of your passphrase (64 hex chars)" />
</gno-form>

`)
	if query == "" {
		return b.String()
	}

	q, err := url.ParseQuery(query)
	if err != nil {
		return b.String() + "Could not read the form.\n"
	}
	// Parse first; the offer rules themselves live in validateOffer so this
	// page and Offer cannot drift apart.
	var errs []string
	stake, ok := parseGNOT(q.Get("stake"))
	if !ok {
		errs = append(errs, "stake must be a GNOT amount with at most 6 decimals, e.g. 10 or 2.5")
	}
	validFor := 15
	if v := q.Get("validFor"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			errs = append(errs, "validFor must be a whole number of minutes")
		}
		validFor = n
	}
	opponent := address(q.Get("opponent"))
	commitment := q.Get("commitment")
	if len(errs) == 0 {
		errs = validateOffer(stake, validFor, opponent, commitment)
	}
	if len(errs) > 0 {
		b.WriteString("**Fix the following:**\n\n")
		for _, e := range errs {
			b.WriteString("- " + e + "\n")
		}
		return b.String()
	}

	b.WriteString("## Ready\n\n")
	who := "anyone"
	if opponent != "" {
		who = opponent.String()
	}
	b.WriteString("Stake " + gnot(stake) + ", open to " + who + " for " + strconv.Itoa(validFor) + " min, " +
		"house fee at most " + gnot(fee) + ", commitment `" + commitment + "`. " +
		"Check it is the sha256 of your own passphrase before signing.\n\n")
	b.WriteString("**[Post offer for " + gnot(stake) + "](" + txlink.NewLink("Offer").
		AddArgs("opponent", opponent.String(), "validFor", strconv.Itoa(validFor), "commitment", commitment,
			"maxFee", strconv.FormatInt(fee, 10)).
		SetSend(strconv.FormatInt(stake, 10)+denom).URL() + ")**\n")
	return b.String()
}

func renderGame(g *Game) string {
	now := time.Now()
	var b strings.Builder
	id := strconv.Itoa(g.ID)
	b.WriteString("# Game #" + id + " — " + g.Status.String() + "\n\n[← Lobby](" + pageURL("") + ")\n\n")
	b.WriteString("🔴 " + g.Creator.String() + "  \n🟡 " + orNone(g.Acceptor) + "  \n")
	b.WriteString("Stake: " + gnot(g.Stake) + " each · fee " + gnot(g.Fee) + "\n\n")
	b.WriteString(boardView(g, now) + "\n\n")

	switch g.Status {
	case Open:
		cancel := "[Cancel offer](" + txlink.NewLink("Cancel").AddArgs("id", id).URL() + ")"
		if now.Before(g.ExpiresAt) {
			b.WriteString("Open offer for " + openTo(g) + ", expires in " + remaining(g.ExpiresAt.Sub(now)) + ".\n\n")
			b.WriteString("**[Accept for " + gnot(g.Stake) + "](" + acceptURL(g) + ")** with the sha256 of a fresh random seed " +
				"(`openssl rand -hex 32`). Keep the seed: you reveal it after the creator, within 90s, or forfeit.\n\n")
			b.WriteString(cancel + " (creator)\n")
		} else {
			b.WriteString("This offer expired. Anyone can " + cancel + " to refund the creator.\n")
		}
	case Playing:
		left := g.deadline().Sub(now)
		claim := "Clock ran out: **[Claim timeout](" + txlink.NewLink("ClaimTimeout").AddArgs("id", id).URL() + ")**\n\n"
		resign := "[Resign](" + txlink.NewLink("Resign").AddArgs("id", id).URL() + ")\n"
		if g.Turn == 0 {
			if !g.Revealed {
				b.WriteString("Waiting for the creator to reveal the passphrase.\n\n")
			} else {
				b.WriteString("Passphrase revealed. Waiting for the acceptor to reveal the seed.\n\n")
			}
			if left >= 0 {
				b.WriteString("Time left: " + remaining(left) + "\n\n")
				if !g.Revealed {
					b.WriteString("**[Reveal](" + txlink.NewLink("Reveal").AddArgs("id", id, "passphrase", "").URL() + ")** (creator)\n\n")
				} else {
					b.WriteString("**[Reveal seed](" + txlink.NewLink("RevealSeed").AddArgs("id", id, "seed", "").URL() + ")** (acceptor)\n\n")
				}
			} else {
				b.WriteString(claim)
			}
			b.WriteString(resign)
			break
		}
		b.WriteString("Turn: " + [...]string{"", "🔴", "🟡"}[g.Turn] + " " + g.player(g.Turn).String() + "\n\n")
		if left >= 0 {
			b.WriteString("Time left: " + remaining(left) + " · click a column to drop your piece\n\n")
		} else {
			b.WriteString(claim)
		}
		b.WriteString(resign)
	case Won:
		b.WriteString("Winner: " + g.Winner.String() + ", paid " + gnot(2*g.Stake-g.Fee) + ".\n")
	case Draw:
		b.WriteString("Draw: both stakes refunded.\n")
	case Void:
		b.WriteString("Void: the first mover never moved, both stakes refunded.\n")
	case Cancelled:
		b.WriteString("Cancelled: stake refunded to the creator.\n")
	}
	return b.String()
}

// boardView draws the board. While a move can be played it is 7 column
// images, each wrapped in its Play link (gnoweb lays linked images out side by
// side). Otherwise it is one image of all 7 columns, since gnoweb stacks bare
// images vertically. The last move gets a dark ring, a winning line a green one.
func boardView(g *Game, now time.Time) string {
	playable := g.Status == Playing && g.Turn != 0 && !now.After(g.deadline())
	var win [cols][rows]bool
	if g.Status == Won && g.Moves > 0 {
		for _, cell := range g.Board.winLine(g.LastCol, g.LastRow) {
			win[cell[0]][cell[1]] = true
		}
	}
	const height = headerPx + rows*cellPx
	if !playable {
		canvas := svg.NewCanvas(cols*cellPx, height).WithViewBox(0, 0, cols*cellPx, height)
		alt := "board:"
		for c := 0; c < cols; c++ {
			alt += " " + drawColumn(canvas, g, &win, c, c*cellPx) + ";"
		}
		return canvas.Render(alt)
	}
	id := strconv.Itoa(g.ID)
	var b strings.Builder
	for c := 0; c < cols; c++ {
		canvas := svg.NewCanvas(cellPx, height).WithViewBox(0, 0, cellPx, height)
		alt := drawColumn(canvas, g, &win, c, 0)
		b.WriteString("[" + canvas.Render(alt) + "](" +
			txlink.NewLink("Play").AddArgs("id", id, "column", strconv.Itoa(c+1), "move", strconv.Itoa(g.Moves)).URL() + ")")
	}
	return b.String()
}

// drawColumn draws column c at horizontal offset x and returns its alt text.
func drawColumn(canvas *svg.Canvas, g *Game, win *[cols][rows]bool, c, x int) string {
	bg := svg.NewRectangle(x, 0, cellPx, headerPx+rows*cellPx, boardBlue)
	bg.Attr.Class = "col"
	canvas.Append(bg, svg.NewText(x+cellPx/2-4, 15, strconv.Itoa(c+1), hole))
	alt := "column " + strconv.Itoa(c+1) + ":"
	for r := 0; r < rows; r++ {
		disc := svg.NewCircle(x+cellPx/2, headerPx+(rows-1-r)*cellPx+cellPx/2, cellPx/2-5, pieceColor[g.Board[c][r]])
		switch {
		case win[c][r]:
			disc.Attr.Stroke, disc.Attr.StrokeWidth = winStroke, "5"
		case g.Moves > 0 && c == g.LastCol && r == g.LastRow:
			disc.Attr.Stroke, disc.Attr.StrokeWidth = lastMoveStroke, "3"
		}
		canvas.Append(disc)
		alt += " " + pieceName[g.Board[c][r]]
	}
	return alt
}

// onTurn names who the game waits for.
func onTurn(g *Game) string {
	switch {
	case g.Turn != 0:
		return g.player(g.Turn).String()
	case g.Revealed:
		return g.Acceptor.String() + " (reveal seed)"
	}
	return g.Creator.String() + " (reveal)"
}

// clockLeft is the time left on the move clock, or "clock ran out". Play is
// still accepted in the deadline block itself, so zero left is not expired.
func clockLeft(g *Game, now time.Time) string {
	if now.After(g.deadline()) {
		return "clock ran out"
	}
	return remaining(g.deadline().Sub(now))
}

func acceptURL(g *Game) string {
	return txlink.NewLink("Accept").AddArgs("id", strconv.Itoa(g.ID), "seedCommitment", "").
		SetSend(strconv.FormatInt(g.Stake, 10) + denom).URL()
}

func digits(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func openTo(g *Game) string {
	if g.Opponent != "" {
		return g.Opponent.String()
	}
	return "anyone"
}

// parseGNOT parses a decimal GNOT amount ("10", "2.5") into ugnot.
func parseGNOT(s string) (int64, bool) {
	whole, frac, _ := strings.Cut(s, ".")
	if whole == "" || len(whole) > 12 || len(frac) > 6 {
		return 0, false
	}
	if !digits(whole) || !digits(frac) {
		return 0, false
	}
	w, _ := strconv.ParseInt(whole, 10, 64)
	f, _ := strconv.ParseInt(frac+strings.Repeat("0", 6-len(frac)), 10, 64)
	return w*1_000_000 + f, true
}

// leaderboard renders a board kept at settlement (topWins, topGnot).
func leaderboard(board []leader, format func(int64) string) string {
	if len(board) == 0 {
		return "No finished games yet.\n\n"
	}
	var b strings.Builder
	b.WriteString("| # | Player | |\n|---|---|---|\n")
	for i, r := range board {
		b.WriteString("| " + strconv.Itoa(i+1) + " | " + r.Addr.String() + " | " + format(r.Score) + " |\n")
	}
	b.WriteString("\n")
	return b.String()
}

// gnot formats ugnot as GNOT with up to 6 decimals.
func gnot(ugnot int64) string {
	whole := strconv.FormatInt(ugnot/1_000_000, 10)
	frac := ugnot % 1_000_000
	if frac == 0 {
		return whole + " GNOT"
	}
	f := strconv.FormatInt(frac, 10)
	f = strings.TrimRight(strings.Repeat("0", 6-len(f))+f, "0")
	return whole + "." + f + " GNOT"
}

func remaining(d time.Duration) string { return d.Truncate(time.Second).String() }

func orNone(a address) string {
	if a == "" {
		return "waiting for opponent"
	}
	return a.String()
}
