package minichess

import (
	"encoding/base64"
	"strconv"
	"strings"

	mc "gno.land/p/g1um2pwwnx3gn8p3ryfdert8mhpu4u4up49sc9ru/minichess"
)

const listLimit = 10

// Render serves the gnoweb pages:
//
//	""               home: start a game, open challenges, recent games
//	"game/<id>"      a board with clickable legal moves
//	"player/<addr>"  a player's games
//	"rules"          how to enter moves and the draw rules
func Render(path string) string {
	path = strings.Trim(path, "/")
	switch {
	case path == "":
		return renderHome()
	case path == "rules":
		return renderRules()
	case strings.HasPrefix(path, "game/"):
		id, err := strconv.Atoi(strings.TrimPrefix(path, "game/"))
		if err != nil {
			return "# Not found\n\nBad game id."
		}
		g, ok := getGame(id)
		if !ok {
			return "# Not found\n\nGame " + strconv.Itoa(id) + " does not exist."
		}
		return renderGame(g)
	case strings.HasPrefix(path, "player/"):
		return renderPlayer(address(strings.TrimPrefix(path, "player/")))
	}
	return "# Not found\n\n[Back to Mini Chess](" + realmPath + ")"
}

// actionLink builds a gnoweb link that opens a prefilled call form.
func actionLink(label, fn string, args ...string) string {
	url := realmPath + "$help&func=" + fn
	for i := 0; i+1 < len(args); i += 2 {
		url += "&" + args[i] + "=" + args[i+1]
	}
	return "[" + label + "](" + url + ")"
}

func gameLink(id int) string {
	return "[#" + strconv.Itoa(id) + "](" + realmPath + ":game/" + strconv.Itoa(id) + ")"
}

func short(a address) string {
	s := a.String()
	if len(s) > 12 {
		return s[:7] + "…" + s[len(s)-4:]
	}
	return s
}

func playerName(g *Game, a address) string {
	if a == "" {
		if g.Mode == ModeSolo {
			return "🤖 bot (" + mc.Level(g.BotLevel).Name + ")"
		}
		return "_open seat_"
	}
	return "[" + short(a) + "](" + realmPath + ":player/" + a.String() + ")"
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# ♟ Mini Chess\n\n")
	sb.WriteString("Classic 8×8 chess, fully on-chain — play the bot or challenge a friend. ")
	sb.WriteString("[Rules](" + realmPath + ":rules)\n\n")

	sb.WriteString("## Play the bot\n\n")
	sb.WriteString("| Level | Play white | Play black |\n|---|---|---|\n")
	for lvl := mc.MinLevel; lvl <= mc.MaxLevel; lvl++ {
		l := strconv.Itoa(lvl)
		sb.WriteString("| " + mc.Level(lvl).Name + " | " +
			actionLink("Start as white", "NewSoloGame", "color", "white", "level", l) + " | " +
			actionLink("Start as black", "NewSoloGame", "color", "black", "level", l) + " |\n")
	}

	sb.WriteString("\n## Play a friend\n\n")
	sb.WriteString("- " + actionLink("Create an open challenge", "Challenge", "opponent", "", "color", "random") + " — anyone can join\n")
	sb.WriteString("- " + actionLink("Challenge a specific player", "Challenge", "opponent", "g1...", "color", "white") + " — paste their address\n\n")

	sb.WriteString("## Open challenges\n\n")
	open := 0
	openGames.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*Game)
		side := "white"
		if g.White == "" {
			side = "black"
		}
		who := "anyone"
		if g.Invitee != "" {
			who = playerName(g, g.Invitee)
		}
		sb.WriteString("- " + gameLink(g.ID) + " by " + playerName(g, g.Creator) +
			" — you play " + side + ", for " + who + " · " +
			actionLink("Accept", "AcceptChallenge", "gameID", strconv.Itoa(g.ID)) + "\n")
		open++
		return open >= listLimit
	})
	if open == 0 {
		sb.WriteString("_None right now._\n")
	}

	sb.WriteString("\n## Recent games\n\n")
	sb.WriteString("| Game | White | Black | Mode | Status |\n|---|---|---|---|---|\n")
	n := 0
	games.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*Game)
		if g.State == StateWaiting || g.State == StateCancelled {
			return false
		}
		sb.WriteString("| " + gameLink(g.ID) + " | " + playerName(g, g.White) + " | " +
			playerName(g, g.Black) + " | " + g.Mode.String() + " | " + statusText(g) + " |\n")
		n++
		return n >= listLimit
	})
	if n == 0 {
		sb.WriteString("| — | | | | no games yet |\n")
	}
	return sb.String()
}

func statusText(g *Game) string {
	if g.State == StateActive {
		return g.Pos.Turn.String() + " to move"
	}
	return g.State.String()
}

func renderGame(g *Game) string {
	var sb strings.Builder
	id := strconv.Itoa(g.ID)
	sb.WriteString("# Game #" + id + "\n\n")
	sb.WriteString("⚪ White: " + playerName(g, g.White) + " · ⚫ Black: " + playerName(g, g.Black) + " · " + g.Mode.String() + "\n\n")

	// Status line.
	switch {
	case g.State == StateActive:
		turn := g.Pos.Turn.String()
		line := "**" + strings.ToUpper(turn[:1]) + turn[1:] + " to move**"
		if g.Pos.InCheck() {
			line += " — check!"
		}
		if g.DrawOffer != "" {
			line += " · draw offered by " + playerName(g, g.DrawOffer)
		}
		sb.WriteString(line + "\n\n")
	case g.State == StateWaiting:
		sb.WriteString("**Waiting for an opponent.** " +
			actionLink("Accept challenge", "AcceptChallenge", "gameID", id) + " · " +
			actionLink("Cancel (creator)", "CancelChallenge", "gameID", id) + "\n\n")
	default:
		sb.WriteString("**Game over: " + g.State.String() + "** (" + g.Reason + ")\n\n")
	}

	sb.WriteString(renderBoardSVG(g) + "\n\n")

	if g.State == StateActive {
		sb.WriteString("### Your move\n\n")
		if g.Mode == ModeSolo && g.playerToMove() == "" {
			sb.WriteString("_The bot is thinking…_\n\n")
		} else {
			sb.WriteString(renderMoveLinks(g))
			sb.WriteString("\n" + actionLink("Type a move", "Move", "gameID", id, "move", "") +
				" · " + actionLink("Resign", "Resign", "gameID", id))
			if g.Mode == ModeTwoPlayer {
				sb.WriteString(" · " + actionLink("Offer draw", "OfferDraw", "gameID", id))
				if g.DrawOffer != "" {
					sb.WriteString(" · " + actionLink("Accept draw", "AcceptDraw", "gameID", id))
				}
			}
			sb.WriteString("\n\n")
		}
	}

	sb.WriteString("### Moves\n\n")
	if len(g.Moves) == 0 {
		sb.WriteString("_No moves yet._\n")
	} else {
		for i := 0; i < len(g.Moves); i += 2 {
			sb.WriteString(strconv.Itoa(i/2+1) + ". " + g.Moves[i])
			if i+1 < len(g.Moves) {
				sb.WriteString(" " + g.Moves[i+1])
			}
			sb.WriteString("  \n")
		}
	}
	sb.WriteString("\n`" + g.Pos.FEN() + "`\n\n[← All games](" + realmPath + ")\n")
	return sb.String()
}

var glyphs = [7]string{"", "♟", "♞", "♝", "♜", "♛", "♚"}

// renderMoveLinks lists legal moves grouped by the piece that moves.
func renderMoveLinks(g *Game) string {
	moves := g.Pos.LegalMoves()
	if len(moves) == 0 {
		return ""
	}
	var sb strings.Builder
	id := strconv.Itoa(g.ID)
	// Group by origin square in board order.
	for from := 0; from < mc.NumSquares; from++ {
		var links []string
		for _, m := range moves {
			if m.From == from {
				links = append(links, actionLink(m.String()[2:], "Move", "gameID", id, "move", m.String()))
			}
		}
		if len(links) == 0 {
			continue
		}
		pc := g.Pos.Board[from]
		sb.WriteString("- " + glyphs[pc.Type()] + " **" + mc.SquareName(from) + "** → " + strings.Join(links, " ") + "\n")
	}
	return sb.String()
}

const (
	sqPx   = 56
	margin = 22
)

// renderBoardSVG draws the board as an inline SVG image (white at bottom).
func renderBoardSVG(g *Game) string {
	size := mc.Size*sqPx + margin
	var sb strings.Builder
	sb.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="` + strconv.Itoa(size) +
		`" height="` + strconv.Itoa(size) + `" viewBox="0 0 ` + strconv.Itoa(size) + " " + strconv.Itoa(size) +
		`" font-family="DejaVu Sans,Segoe UI Symbol,Noto Sans Symbols2,sans-serif">`)
	sb.WriteString(`<rect width="100%" height="100%" fill="#2b2b2b"/>`)

	from, to := -1, -1
	if n := len(g.Moves); n > 0 {
		if m, err := mc.ParseMove(g.Moves[n-1]); err == nil {
			from, to = m.From, m.To
		}
	}
	checkSq := -1
	if g.State == StateActive || g.Reason == "checkmate" {
		if g.Pos.InCheck() {
			k := mc.King
			if g.Pos.Turn == mc.Black {
				k = -mc.King
			}
			for i := 0; i < mc.NumSquares; i++ {
				if g.Pos.Board[i] == k {
					checkSq = i
				}
			}
		}
	}

	for r := 0; r < mc.Size; r++ {
		for f := 0; f < mc.Size; f++ {
			sq := r*mc.Size + f
			x := margin + f*sqPx
			y := (mc.Size - 1 - r) * sqPx
			fill := "#eeeed2"
			if (r+f)%2 == 0 {
				fill = "#769656"
			}
			if sq == from || sq == to {
				fill = "#f6f669"
				if (r+f)%2 == 0 {
					fill = "#baca2b"
				}
			}
			if sq == checkSq {
				fill = "#e05555"
			}
			sb.WriteString(`<rect x="` + strconv.Itoa(x) + `" y="` + strconv.Itoa(y) + `" width="` +
				strconv.Itoa(sqPx) + `" height="` + strconv.Itoa(sqPx) + `" fill="` + fill + `"/>`)
			pc := g.Pos.Board[sq]
			if pc == mc.Empty {
				continue
			}
			color, stroke := "#111", "#111"
			if pc.Color() == mc.White {
				color, stroke = "#fff", "#222"
			}
			sb.WriteString(`<text x="` + strconv.Itoa(x+sqPx/2) + `" y="` + strconv.Itoa(y+sqPx/2+2) +
				`" font-size="44" text-anchor="middle" dominant-baseline="middle" fill="` + color +
				`" stroke="` + stroke + `" stroke-width="1.2">` + glyphs[pc.Type()] + `</text>`)
		}
	}
	// Coordinates.
	for i := 0; i < mc.Size; i++ {
		sb.WriteString(`<text x="` + strconv.Itoa(margin/2) + `" y="` + strconv.Itoa(i*sqPx+sqPx/2+5) +
			`" font-size="14" text-anchor="middle" fill="#ddd">` + strconv.Itoa(mc.Size-i) + `</text>`)
		sb.WriteString(`<text x="` + strconv.Itoa(margin+i*sqPx+sqPx/2) + `" y="` + strconv.Itoa(mc.Size*sqPx+16) +
			`" font-size="14" text-anchor="middle" fill="#ddd">` + string(rune('a'+i)) + `</text>`)
	}
	sb.WriteString(`</svg>`)
	return "![Board for game " + strconv.Itoa(g.ID) + "](data:image/svg+xml;base64," +
		base64.StdEncoding.EncodeToString([]byte(sb.String())) + ")"
}

func renderPlayer(a address) string {
	var sb strings.Builder
	sb.WriteString("# Player " + short(a) + "\n\n")
	v := playerGames.Get(a.String())
	if v == nil {
		sb.WriteString("_No games yet._\n\n[← All games](" + realmPath + ")\n")
		return sb.String()
	}
	ids := v.([]int)
	wins, losses, draws := 0, 0, 0
	sb.WriteString("| Game | White | Black | Mode | Status |\n|---|---|---|---|---|\n")
	for i := len(ids) - 1; i >= 0; i-- {
		g, ok := getGame(ids[i])
		if !ok {
			continue
		}
		switch {
		case g.State == StateDraw:
			draws++
		case (g.State == StateWhiteWon && g.White == a) || (g.State == StateBlackWon && g.Black == a):
			wins++
		case g.State == StateWhiteWon || g.State == StateBlackWon:
			losses++
		}
		sb.WriteString("| " + gameLink(g.ID) + " | " + playerName(g, g.White) + " | " +
			playerName(g, g.Black) + " | " + g.Mode.String() + " | " + statusText(g) + " |\n")
	}
	sb.WriteString("\n**Record:** " + strconv.Itoa(wins) + " W · " + strconv.Itoa(losses) + " L · " +
		strconv.Itoa(draws) + " D\n\n[← All games](" + realmPath + ")\n")
	return sb.String()
}

func renderRules() string {
	return `# Mini Chess rules

Standard chess on the normal 8×8 board, with all the usual rules:
castling, en passant, the pawn's two-square first move and promotion.

## Entering moves

Moves are written as the from-square followed by the to-square:

| Move | Example |
|---|---|
| Normal move or capture | ` + "`e2e4`, `g1f3`, `f3e5`" + ` |
| Castling (move the king two squares) | ` + "`e1g1`" + ` (king side), ` + "`e1c1`" + ` (queen side) |
| En passant (pawn to the empty target square) | ` + "`e5d6`" + ` |
| Promotion (queen by default) | ` + "`e7e8`" + ` or ` + "`e7e8q`" + `; ` + "`e7e8n`" + ` for a knight, ` + "`b`" + ` bishop, ` + "`r`" + ` rook |

On a game page every legal move is a link, so you rarely need to type one.

## How games end

- **Checkmate** wins.
- **Stalemate**, **threefold repetition**, the **50-move rule** and **insufficient material** (king vs king, or king and one minor piece vs king) are draws and are applied automatically.
- Two-player games can also end by **resignation** or an agreed **draw**. Bot games can be resigned.

## Bot levels

| Level | Searches | Typical gas per reply |
|---|---|---|
| easy | 1 move ahead + captures | ~10–50M |
| medium | 2 moves ahead + captures | ~40–220M |
| hard | 3 moves ahead + captures | ~170–370M |

[← Back](` + realmPath + `)
`
}
