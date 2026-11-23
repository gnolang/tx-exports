package tavern2048

// Tavern2048 — the classic 2048 puzzle, played one signed transaction at a
// time on gno.land.
//
// Every move is a real MsgCall: the board lives in this realm's state, keyed
// by the address that signed the call, so nobody can play (or fake) a game on
// your behalf and there is no server to trust. Tile spawns are derived from
// the block height and the player's address: deterministic and verifiable by
// anyone replaying the chain. Boards are rendered as SVG straight from chain
// state by gnoweb, together with an all-time leaderboard.

import (
	"chain"
	"chain/runtime"
	"encoding/base64"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// realmPath is the gnoweb path of this realm, used for in-page links.
const realmPath = "/r/g15crxnxd79syggtha6ymfhy8m8a4ytqel58cwkg/tavern2048/v0"

// MaxPlayMoves caps how many moves a single Play transaction may apply.
const MaxPlayMoves = 64

// TopN is how many players the leaderboard shows.
const TopN = 10

// Game is one player's current game.
type Game struct {
	Board   Board
	Seed    int   // per-player spawn salt, derived from the address
	Started int64 // block height of NewGame
	Updated int64 // block height of the last applied move
}

var (
	games      = avl.NewTree() // player address -> *Game (current game)
	best       = avl.NewTree() // player address -> int (best score ever)
	totalGames int
	totalMoves int
)

// NewGame starts a fresh board for the signer, replacing any current game.
// The best score ever reached is kept for the leaderboard.
func NewGame(cur realm) string {
	player := cur.Previous().Address().String()
	h := runtime.ChainHeight()
	salt := addrSeed(player)
	g := &Game{
		Board:   NewBoardSeeded(int(h) + salt),
		Seed:    salt,
		Started: h,
		Updated: h,
	}
	games.Set(player, g)
	if !best.Has(player) {
		best.Set(player, 0) // registers the player on the leaderboard
	}
	totalGames++
	chain.Emit("NewGame", "player", player)
	return "new game started: " + realmPath + ":" + player
}

// Move slides the signer's board once: dir is up, down, left or right
// (or u, d, l, r). A move that changes nothing is not counted.
func Move(cur realm, dir string) string {
	player := cur.Previous().Address().String()
	g := mustGame(player)
	d, ok := parseDir(dir)
	if !ok {
		panic("invalid direction " + strings.TrimSpace(dir) + ": use up, down, left or right")
	}
	_, msg := step(player, g, d)
	return msg
}

// Play applies a sequence of moves in a single transaction, e.g. "lldrul"
// (u=up, d=down, l=left, r=right; spaces and commas are ignored). It stops
// early when the game is over. At most MaxPlayMoves moves per call.
func Play(cur realm, moves string) string {
	player := cur.Previous().Address().String()
	g := mustGame(player)
	var dirs []int
	for _, c := range strings.ToLower(moves) {
		switch c {
		case ' ', ',':
			continue
		case 'u':
			dirs = append(dirs, DIR_UP)
		case 'r':
			dirs = append(dirs, DIR_RIGHT)
		case 'd':
			dirs = append(dirs, DIR_DOWN)
		case 'l':
			dirs = append(dirs, DIR_LEFT)
		default:
			panic("invalid move " + string(c) + ": use only u, d, l, r")
		}
	}
	if len(dirs) == 0 {
		panic("no moves given: e.g. lldrul")
	}
	if len(dirs) > MaxPlayMoves {
		panic("too many moves: at most " + Itoa(MaxPlayMoves) + " per call")
	}
	applied := 0
	for _, d := range dirs {
		if g.Board.Over {
			break
		}
		if moved, _ := step(player, g, d); moved {
			applied++
		}
	}
	out := "applied " + Itoa(applied) + "/" + Itoa(len(dirs)) + " moves, score " + Itoa(g.Board.Score)
	if g.Board.Over {
		out += ", game over"
	}
	return out
}

// ScoreOf returns the current score of a player (0 if no game).
func ScoreOf(player address) int {
	v := games.Get(player.String())
	if v == nil {
		return 0
	}
	return v.(*Game).Board.Score
}

// BestOf returns the best score a player ever reached.
func BestOf(player address) int {
	v := best.Get(player.String())
	if v == nil {
		return 0
	}
	return v.(int)
}

func mustGame(player string) *Game {
	v := games.Get(player)
	if v == nil {
		panic("no game yet: call NewGame first")
	}
	return v.(*Game)
}

// step applies one direction and records score, best and events.
func step(player string, g *Game, d int) (bool, string) {
	if g.Board.Over {
		return false, "game over: call NewGame to play again"
	}
	h := runtime.ChainHeight()
	moved, msg := g.Board.Move(d, int(h)+g.Seed)
	if !moved {
		return false, msg
	}
	g.Updated = h
	totalMoves++
	if g.Board.Score > BestOfKey(player) {
		best.Set(player, g.Board.Score)
	}
	chain.Emit("Move", "player", player, "dir", dirName(d), "score", Itoa(g.Board.Score))
	if g.Board.Over {
		chain.Emit("GameOver", "player", player, "score", Itoa(g.Board.Score))
		return true, "game over, final score " + Itoa(g.Board.Score)
	}
	return true, msg
}

// BestOfKey is BestOf for a raw address string.
func BestOfKey(player string) int {
	v := best.Get(player)
	if v == nil {
		return 0
	}
	return v.(int)
}

func parseDir(s string) (int, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "up", "u":
		return DIR_UP, true
	case "right", "r":
		return DIR_RIGHT, true
	case "down", "d":
		return DIR_DOWN, true
	case "left", "l":
		return DIR_LEFT, true
	}
	return 0, false
}

func dirName(d int) string {
	switch d {
	case DIR_UP:
		return "up"
	case DIR_RIGHT:
		return "right"
	case DIR_DOWN:
		return "down"
	}
	return "left"
}

// addrSeed folds an address into a small positive salt.
func addrSeed(a string) int {
	s := 7
	for i := 0; i < len(a); i++ {
		s = (s*31 + int(a[i])) & 0xffffff
	}
	return s
}

func maxTile(b Board) int {
	m := 0
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			if b.Cells[i][j] > m {
				m = b.Cells[i][j]
			}
		}
	}
	return m
}

func shortAddr(a string) string {
	if len(a) > 14 {
		return a[:7] + "…" + a[len(a)-4:]
	}
	return a
}

// ---- rendering -------------------------------------------------------------

// Render serves the tavern home (path "") or a player's board (path = g1...).
func Render(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return renderHome()
	}
	if !address(path).IsValid() {
		return "# Not found\n\n`" + path + "` is not a player address. [Back to the tavern](" + realmPath + ")\n"
	}
	return renderPlayer(path)
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# 🍺 Tavern2048\n\n")
	sb.WriteString("_The classic 2048 puzzle, played one signed transaction at a time on gno.land._\n\n")
	sb.WriteString("Your board lives in this realm, keyed by the address that signs your moves: no server, no backend, nobody can play on your behalf. ")
	sb.WriteString("New tiles are derived from the block height, so every game is verifiable by replaying the chain.\n\n")
	sb.WriteString("**" + Itoa(best.Size()) + "** players · **" + Itoa(totalGames) + "** games · **" + Itoa(totalMoves) + "** on-chain moves\n\n")

	sb.WriteString("## How to play\n\n")
	sb.WriteString("1. [Start a new game](" + realmPath + "$help&func=NewGame) — signs `NewGame`.\n")
	sb.WriteString("2. Slide the tiles: [⬆ up](" + realmPath + "$help&func=Move&dir=up) · ")
	sb.WriteString("[⬇ down](" + realmPath + "$help&func=Move&dir=down) · ")
	sb.WriteString("[⬅ left](" + realmPath + "$help&func=Move&dir=left) · ")
	sb.WriteString("[➡ right](" + realmPath + "$help&func=Move&dir=right), ")
	sb.WriteString("or chain up to " + Itoa(MaxPlayMoves) + " moves in one transaction with `Play(\"lldrul\")`.\n")
	sb.WriteString("3. Watch your board at `" + realmPath + ":<your address>`.\n\n")
	sb.WriteString("Each link opens the call page: it prints the `gnokey maketx call` command for your address, or sign it with a browser wallet.\n\n")

	sb.WriteString("## 🏆 Leaderboard\n\n")
	sb.WriteString(renderLeaderboard())
	return sb.String()
}

type entry struct {
	player string
	score  int
}

func renderLeaderboard() string {
	var all []entry
	best.Iterate("", "", func(k string, v any) bool {
		all = append(all, entry{k, v.(int)})
		return false
	})
	if len(all) == 0 {
		return "_No scores yet — be the first gnome on the board._\n"
	}
	// selection sort on the top N only (best first, ties by address)
	lim := TopN
	if len(all) < lim {
		lim = len(all)
	}
	for i := 0; i < lim; i++ {
		mx := i
		for j := i + 1; j < len(all); j++ {
			if all[j].score > all[mx].score {
				mx = j
			}
		}
		all[i], all[mx] = all[mx], all[i]
	}
	medals := []string{"🥇", "🥈", "🥉"}
	var sb strings.Builder
	sb.WriteString("| # | player | best score | current game |\n|---|---|---|---|\n")
	for i := 0; i < lim; i++ {
		rank := Itoa(i + 1)
		if i < len(medals) {
			rank = medals[i]
		}
		cur := "—"
		if v := games.Get(all[i].player); v != nil {
			g := v.(*Game)
			cur = Itoa(g.Board.Score)
			if g.Board.Over {
				cur += " (over)"
			}
		}
		sb.WriteString("| " + rank + " | [" + shortAddr(all[i].player) + "](" + realmPath + ":" + all[i].player + ") | " + Itoa(all[i].score) + " | " + cur + " |\n")
	}
	return sb.String()
}

func renderPlayer(player string) string {
	var sb strings.Builder
	sb.WriteString("# 🍺 Tavern2048 — " + shortAddr(player) + "\n\n")
	v := games.Get(player)
	if v == nil {
		sb.WriteString("This gnome has not started a game yet. [Start a new game](" + realmPath + "$help&func=NewGame).\n\n")
		sb.WriteString("[← Back to the tavern](" + realmPath + ")\n")
		return sb.String()
	}
	g := v.(*Game)
	b := g.Board
	sb.WriteString(boardSVG(b) + "\n\n")
	status := "in play"
	if b.Over {
		status = "**game over**"
	}
	sb.WriteString("**Score** " + Itoa(b.Score) + " · **Best** " + Itoa(BestOfKey(player)) + " · **Moves** " + Itoa(b.Moves) + " · **Top tile** " + Itoa(maxTile(b)) + " · " + status + "\n\n")
	sb.WriteString("Started at block " + Itoa(int(g.Started)) + ", last move at block " + Itoa(int(g.Updated)) + ".\n\n")
	if b.Over {
		sb.WriteString("[Start a new game](" + realmPath + "$help&func=NewGame)\n\n")
	} else {
		sb.WriteString("Move: [⬆ up](" + realmPath + "$help&func=Move&dir=up) · ")
		sb.WriteString("[⬇ down](" + realmPath + "$help&func=Move&dir=down) · ")
		sb.WriteString("[⬅ left](" + realmPath + "$help&func=Move&dir=left) · ")
		sb.WriteString("[➡ right](" + realmPath + "$help&func=Move&dir=right)\n\n")
		sb.WriteString("Or play a whole combo in one transaction:\n\n")
		sb.WriteString("<gno-form exec=\"Play\">\n")
		sb.WriteString("<gno-input name=\"moves\" placeholder=\"e.g. lldrul (u/d/l/r)\" />\n")
		sb.WriteString("</gno-form>\n\n")
	}
	sb.WriteString("[← Back to the tavern](" + realmPath + ")\n")
	return sb.String()
}

func tileColors(v int) (bg, fg string) {
	switch v {
	case 0:
		return "#cdc1b4", "#776e65"
	case 2:
		return "#eee4da", "#776e65"
	case 4:
		return "#ede0c8", "#776e65"
	case 8:
		return "#f2b179", "#f9f6f2"
	case 16:
		return "#f59563", "#f9f6f2"
	case 32:
		return "#f67c5f", "#f9f6f2"
	case 64:
		return "#f65e3b", "#f9f6f2"
	case 128:
		return "#edcf72", "#f9f6f2"
	case 256:
		return "#edcc61", "#f9f6f2"
	case 512:
		return "#edc850", "#f9f6f2"
	case 1024:
		return "#edc53f", "#f9f6f2"
	case 2048:
		return "#edc22e", "#f9f6f2"
	}
	return "#3c3a32", "#f9f6f2"
}

// boardSVG draws the board as an inline SVG image (data URI) for gnoweb.
func boardSVG(b Board) string {
	const cell = 100
	const gap = 12
	const size = gap + N*(cell+gap)
	var sb strings.Builder
	sb.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="` + Itoa(size) + `" height="` + Itoa(size) + `" viewBox="0 0 ` + Itoa(size) + ` ` + Itoa(size) + `">`)
	sb.WriteString(`<rect width="` + Itoa(size) + `" height="` + Itoa(size) + `" rx="14" fill="#bbada0"/>`)
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			x := gap + j*(cell+gap)
			y := gap + i*(cell+gap)
			v := b.Cells[i][j]
			bg, fg := tileColors(v)
			sb.WriteString(`<rect x="` + Itoa(x) + `" y="` + Itoa(y) + `" width="` + Itoa(cell) + `" height="` + Itoa(cell) + `" rx="8" fill="` + bg + `"/>`)
			if v != 0 {
				txt := Itoa(v)
				fs := 52
				switch {
				case len(txt) >= 5:
					fs = 26
				case len(txt) == 4:
					fs = 34
				case len(txt) == 3:
					fs = 42
				}
				sb.WriteString(`<text x="` + Itoa(x+cell/2) + `" y="` + Itoa(y+cell/2) + `" dy="0.35em" text-anchor="middle" font-family="Arial,Helvetica,sans-serif" font-weight="bold" font-size="` + Itoa(fs) + `" fill="` + fg + `">` + txt + `</text>`)
			}
		}
	}
	sb.WriteString(`</svg>`)
	return "![Tavern2048 board](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(sb.String())) + ")"
}
