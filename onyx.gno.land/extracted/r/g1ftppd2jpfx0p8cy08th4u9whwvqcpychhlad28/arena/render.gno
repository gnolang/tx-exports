package arena

import (
	"strconv"
	"strings"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/game"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	self string        // this realm's path as gnoweb links it, e.g. "/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena"
	tx   txlink.Realm  // builds transaction links to this realm
)

func init(cur realm) {
	full := cur.PkgPath()
	tx = txlink.Realm(full)
	self = full
	if i := strings.Index(full, "/"); i >= 0 {
		self = full[i:] // drop the chain domain
	}
}

// Render draws the arena pages in gnoweb:
//
//	""                   leaderboard, recent matches, rules
//	"bot/<name>"         a bot's record, source link and a challenge button
//	"match/<id>"         the final board, key moments and actions
//	"match/<id>/<turn>"  the board after one turn
func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case len(parts) == 2 && parts[0] == "bot":
		return renderBot(parts[1])
	case (len(parts) == 2 || len(parts) == 3) && parts[0] == "match":
		id, err := strconv.Atoi(parts[1])
		if _, ok := record(id); err != nil || !ok {
			return "# Match not found\n\n[Back to the arena](" + link("") + ")\n"
		}
		turn := -1
		if len(parts) == 3 {
			if t, err := strconv.Atoi(parts[2]); err == nil {
				turn = t
			}
		}
		return renderMatch(mustMatch(id), turn)
	}
	return renderHome()
}

func link(p string) string {
	if p == "" {
		return self
	}
	return self + ":" + p
}

func matchLink(id int) string { return link("match/" + strconv.Itoa(id)) }

// fightLink opens a pre-filled Fight transaction; either name may be empty
// for the player to fill in.
func fightLink(a, b string) string { return tx.Call("Fight", "a", a, "b", b) }

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# Code Arena\n\n")
	sb.WriteString("Bots are realms. Deploy one, register it, and the chain referees every match by calling each bot's code turn by turn. Every bot's source is public, so you can study a rival before you challenge it.\n\n")
	sb.WriteString(ufmt.Sprintf("**%d bots** · **%d matches** · [Start a fight](%s)\n\n", bots.Size(), lastID, fightLink("", "")))

	sb.WriteString("## Leaderboard\n\n")
	ranked := leaderboard()
	if len(ranked) == 0 {
		sb.WriteString("No bots yet.\n\n")
	} else {
		sb.WriteString("| # | Bot | Elo | W-L-D | |\n|---|---|---|---|---|\n")
		for i, b := range ranked {
			if i == 20 {
				break
			}
			sb.WriteString(ufmt.Sprintf("| %d | [%s](%s) | %d | %d-%d-%d | [code](%s) · [fight](%s) |\n",
				i+1, b.Name, link("bot/"+b.Name), b.Rating, b.Wins, b.Losses, b.Draws, sourceLink(b.Realm), fightLink("", b.Name)))
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Recent matches\n\n")
	writeRecent(&sb, "", 10)

	sb.WriteString("## Rules\n\n")
	sb.WriteString("- 9×9 board, 50 turns. Bots start in opposite corners; coins are placed point-symmetrically, so neither corner has an advantage. A new pair of coins appears every 5 turns.\n")
	sb.WriteString("- Each turn both bots choose at once: `Up`, `Down`, `Left`, `Right`, `Stay`, `Attack` or `Defend`.\n")
	sb.WriteString("- Step on a coin to take it. Bots never share a square: if both step onto the same one, priority alternates each turn.\n")
	sb.WriteString("- Next to the enemy, `Attack` steals one coin. But attacking into a `Defend` is parried, and the defender takes a coin from you instead.\n")
	sb.WriteString("- Most gold after 50 turns wins. Ratings are Elo-style; a pair of bots plays at most one rated match every ")
	sb.WriteString(strconv.Itoa(RatedCooldown) + " blocks, and rematches in between are friendlies.\n\n")
	sb.WriteString("Each turn a bot sees the board, both scores, and what both bots did last turn, so a bot can learn its opponent's habits.\n\n")

	sb.WriteString("## Build a bot\n\n")
	sb.WriteString("1. Import [`gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot`](/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot) and write a `Move(bot.State) bot.Action` method (a realm bot can keep memory) or a plain function.\n")
	sb.WriteString("2. Register it from your realm's `init`: `arena.RegisterBot(cross(cur), \"my-bot\", &myBot{})`.\n")
	sb.WriteString(ufmt.Sprintf("3. [Fight](%s) anyone on the leaderboard.\n\n", fightLink("my-bot", "")))
	sb.WriteString("Starter bots to read and beat: [strategies](/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/strategies) · [reader](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/reader), a realm bot that learns each opponent's habits.\n\n")

	sb.WriteString("## No escaping a loss\n\n")
	sb.WriteString("A crash inside a realm cancels the whole transaction, so a bot could crash on purpose to cancel a match it is losing. It doesn't work here: the match switches to step mode, one move per transaction, and a bot that can't make its move by the deadline loses by forfeit.\n")
	return sb.String()
}

func (b *Bot) kind() string {
	if b.fn != nil {
		return "function"
	}
	return "realm"
}

func leaderboard() []*Bot {
	var out []*Bot
	bots.Iterate("", "", func(_ string, v any) bool {
		out = append(out, v.(*Bot))
		return false
	})
	// insertion sort: highest rating first, then most wins, then name
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && better(out[j], out[j-1]); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func better(a, b *Bot) bool {
	if a.Rating != b.Rating {
		return a.Rating > b.Rating
	}
	if a.Wins != b.Wins {
		return a.Wins > b.Wins
	}
	return a.Name < b.Name
}

func sourceLink(realmPath string) string {
	if i := strings.Index(realmPath, "/"); i >= 0 {
		realmPath = realmPath[i:]
	}
	return realmPath + "$source"
}

// writeRecent lists the latest matches, optionally only those of one bot
// among the last 500.
func writeRecent(sb *strings.Builder, botName string, limit int) {
	n := 0
	eachRecent(500, func(m *Match) bool {
		if botName != "" && m.BotA != botName && m.BotB != botName {
			return false
		}
		sb.WriteString(ufmt.Sprintf("- [%s](%s)\n", m.Summary(), matchLink(m.ID)))
		n++
		return n >= limit
	})
	if n == 0 {
		sb.WriteString("No matches yet.\n")
	}
	sb.WriteString("\n")
}

func renderBot(name string) string {
	v := bots.Get(name)
	if v == nil {
		return "# Bot not found\n\n[Back to the arena](" + link("") + ")\n"
	}
	b := v.(*Bot)
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# %s\n\n", b.Name))
	sb.WriteString(ufmt.Sprintf("[Challenge %s](%s) · [Read its code](%s)\n\n", b.Name, fightLink("", b.Name), sourceLink(b.Realm)))
	sb.WriteString(ufmt.Sprintf("- **Rating:** %d\n- **Record:** %d wins, %d losses (%d by forfeit), %d draws\n", b.Rating, b.Wins, b.Losses, b.Forfeits, b.Draws))
	sb.WriteString(ufmt.Sprintf("- **Kind:** %s bot\n- **Realm:** `%s`\n- **Owner:** `%s`\n- **Registered at block:** %d\n\n", b.kind(), b.Realm, b.Owner.String(), b.Registered))
	sb.WriteString("## Matches\n\n")
	writeRecent(&sb, name, 20)
	sb.WriteString("[Back to the arena](" + link("") + ")\n")
	return sb.String()
}

func renderMatch(m *Match, turn int) string {
	g := &m.Game
	played := g.Turn
	if turn < 0 || turn > played {
		turn = played
	}
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Match #%d: %s vs %s\n\n", m.ID, m.Bot(0), m.Bot(1)))
	sb.WriteString("**" + m.Summary() + "**\n\n")
	switch {
	case !m.Rated:
		sb.WriteString(ufmt.Sprintf("Friendly: these two bots had a rated match less than %d blocks before this one, so ratings don't change.\n\n", RatedCooldown))
	case m.Status == Finished && m.Winner >= 0:
		sb.WriteString(ufmt.Sprintf("Rating change: %s %s, %s %s\n\n", m.Bot(0), signed(m.Delta), m.Bot(1), signed(-m.Delta)))
	}
	writeActions(&sb, m)

	snap := g.At(turn)
	sb.WriteString(ufmt.Sprintf("## After turn %d of %d\n\n", turn, bot.Turns))
	sb.WriteString(ufmt.Sprintf("**A** = %s, %d gold · **B** = %s, %d gold · **$** = coin\n\n", m.Bot(0), snap.Gold[0], m.Bot(1), snap.Gold[1]))
	sb.WriteString("```\n" + drawBoard(snap.Pos, snap.Coins) + "```\n\n")

	nav := []string{}
	if turn > 0 {
		nav = append(nav, ufmt.Sprintf("[« start](%s)", link(ufmt.Sprintf("match/%d/0", m.ID))))
		nav = append(nav, ufmt.Sprintf("[‹ prev](%s)", link(ufmt.Sprintf("match/%d/%d", m.ID, turn-1))))
	}
	if turn < played {
		nav = append(nav, ufmt.Sprintf("[next ›](%s)", link(ufmt.Sprintf("match/%d/%d", m.ID, turn+1))))
		nav = append(nav, ufmt.Sprintf("[end »](%s)", link(ufmt.Sprintf("match/%d/%d", m.ID, played))))
	}
	if len(nav) > 0 {
		sb.WriteString(strings.Join(nav, " · ") + "\n\n")
	}
	if turn > 0 {
		sb.WriteString(ufmt.Sprintf("Turn %d: %s **%s**%s, %s **%s**%s\n\n",
			turn, m.Bot(0), snap.Act[0].String(), eventNote(snap.Events, 0), m.Bot(1), snap.Act[1].String(), eventNote(snap.Events, 1)))
	}

	writeMoments(&sb, m)
	sb.WriteString(ufmt.Sprintf("Bots: [%s](%s) · [%s](%s) · [Back to the arena](%s)\n",
		m.Bot(0), link("bot/"+m.Bot(0)), m.Bot(1), link("bot/"+m.Bot(1)), link("")))
	return sb.String()
}

// writeActions shows the buttons that move an unfinished match along.
func writeActions(sb *strings.Builder, m *Match) {
	id := strconv.Itoa(m.ID)
	switch m.Status {
	case Pending:
		sb.WriteString(ufmt.Sprintf("Not played yet: [Play it](%s). If a bot keeps making it fail, [switch to step mode](%s).\n\n",
			tx.Call("Play", "id", id), tx.Call("StartStepMode", "id", id)))
	case Stepping:
		sb.WriteString(ufmt.Sprintf("**Step mode:** waiting for **%s** to move, deadline block %d (now %d). [Submit the next move](%s) · [Finish in one go](%s)",
			m.Bot(m.Waiting), m.Deadline, height(), tx.Call("SubmitMove", "id", id), tx.Call("Play", "id", id)))
		if height() > m.Deadline {
			sb.WriteString(ufmt.Sprintf(" · [Claim the forfeit](%s)", tx.Call("ClaimForfeit", "id", id)))
		}
		sb.WriteString("\n\n")
	}
}

// writeMoments lists the turns where coins changed hands.
func writeMoments(sb *strings.Builder, m *Match) {
	var lines []string
	for i, ev := range m.Game.Timeline() {
		for side := 0; side < 2; side++ {
			what := ""
			switch {
			case ev.Stole[side]:
				what = "stole a coin from"
			case ev.Parried[side]:
				what = "parried and took a coin from"
			}
			if what != "" {
				lines = append(lines, ufmt.Sprintf("- [Turn %d](%s): %s %s %s", i+1,
					link(ufmt.Sprintf("match/%d/%d", m.ID, i+1)), m.Bot(side), what, m.Bot(1-side)))
			}
		}
	}
	if len(lines) == 0 {
		return
	}
	sb.WriteString("## Key moments\n\n")
	if len(lines) > 12 {
		more := len(lines) - 12
		lines = append(lines[:12], ufmt.Sprintf("- …and %d more", more))
	}
	sb.WriteString(strings.Join(lines, "\n") + "\n\n")
}

func signed(n int) string {
	if n > 0 {
		return "+" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

func eventNote(ev game.Events, side int) string {
	switch {
	case ev.Stole[side]:
		return " (stole a coin)"
	case ev.Parried[side]:
		return " (parried and took a coin)"
	}
	return ""
}

func drawBoard(pos [2]bot.Pos, coins []bot.Pos) string {
	var sb strings.Builder
	for y := 0; y < bot.Size; y++ {
		for x := 0; x < bot.Size; x++ {
			p := bot.Pos{x, y}
			cell := "·"
			for _, c := range coins {
				if c == p {
					cell = "$"
				}
			}
			switch p {
			case pos[0]:
				cell = "A"
			case pos[1]:
				cell = "B"
			}
			sb.WriteString(cell)
			if x < bot.Size-1 {
				sb.WriteString(" ")
			}
		}
		sb.WriteString("\n")
	}
	return sb.String()
}
