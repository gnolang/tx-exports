package arena

import (
	"strconv"
	"strings"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/rules/v1"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/svg/v1"
	"gno.land/p/moul/txlink/v0"
)

const pageSize = 20

// Render serves the arena pages:
//
//	""                       home: latest game replay, top of the table
//	"table"                  full league table
//	"bot/<id>"               one bot: record, games, source links
//	"game/<key>"             one game: animated replay, step links
//	"game/<key>/t/<turn>"    the board after a given turn
//	"games[?page=N]"         finished games, newest first
//	"pending"                games still to play, with PlayPair links
//	"guide"                  how to write and register a bot
func Render(path string) string {
	path, page := splitPage(path)
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return renderHome()
	case path == "table":
		return renderTable(0)
	case parts[0] == "bot" && len(parts) == 2:
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return notFound()
		}
		return renderBot(id)
	case parts[0] == "game" && len(parts) == 2:
		return renderGame(parts[1], -1)
	case parts[0] == "game" && len(parts) == 4 && parts[2] == "t":
		t, err := strconv.Atoi(parts[3])
		if err != nil || t < 0 {
			return notFound()
		}
		return renderGame(parts[1], t)
	case path == "games":
		return renderGames(page)
	case path == "pending":
		return renderPending(page)
	case path == "guide":
		return renderGuide()
	}
	return notFound()
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Ribbonfight\n\n")
	b.WriteString("A grid duel where the players are Go programs you can read. Each ribbon moves one cell per turn and leaves a wall behind it; crash into anything and you lose.\n\n")
	if lastKey != "" {
		gm := games.Get(lastKey).(*Game)
		b.WriteString("## Latest game\n\n")
		b.WriteString(gameTitle(gm) + "\n\n")
		if img, err := svg.Animated(gm.Match, 60); err == nil {
			b.WriteString(svg.Image("latest game replay", img) + "\n\n")
		}
		b.WriteString(resultLine(gm) + " [Step through it](" + link("game/"+lastKey) + ")\n\n")
	}
	b.WriteString("## League\n\n")
	b.WriteString(renderTableBody(10))
	b.WriteString("\n[Full table](" + link("table") + ") | [Finished games](" + link("games") + ") | [Pending games](" + link("pending") + ") | [Write a bot](" + link("guide") + ")\n")
	return b.String()
}

func renderTable(limit int) string {
	return "# League table\n\nEvery pair of bots plays once on each of the " + strconv.Itoa(len(maps)) + " maps. Win 2, draw 1, loss 0; unplayed games count 0.\n\n" + renderTableBody(limit) + "\n[Home](" + link("") + ")\n"
}

func renderTableBody(limit int) string {
	list := activeBots()
	sortBots(list, func(x, y *Bot) bool {
		if x.Points != y.Points {
			return x.Points > y.Points
		}
		if x.Wins != y.Wins {
			return x.Wins > y.Wins
		}
		return x.ID < y.ID
	})
	if len(list) == 0 {
		return "_No bots yet._\n"
	}
	var b strings.Builder
	b.WriteString("| # | Bot | Pts | W | D | L | Crashes | Played |\n|---|---|---|---|---|---|---|---|\n")
	total := (len(list) - 1) * len(maps)
	for i, bt := range list {
		if limit > 0 && i >= limit {
			break
		}
		played := bt.Wins + bt.Draws + bt.Losses
		b.WriteString("| " + strconv.Itoa(i+1) + " | [" + bt.Name + "](" + link("bot/"+u(bt.ID)) + ") | " + strconv.Itoa(bt.Points) + " | " + strconv.Itoa(bt.Wins) + " | " + strconv.Itoa(bt.Draws) + " | " + strconv.Itoa(bt.Losses) + " | " + strconv.Itoa(bt.Crashes) + " | " + strconv.Itoa(played) + "/" + strconv.Itoa(total) + " |\n")
	}
	return b.String()
}

func renderBot(id uint64) string {
	bt, ok := getBot(id)
	if !ok {
		return notFound()
	}
	var b strings.Builder
	b.WriteString("# " + bt.Name + "\n\n")
	if bt.Retired {
		b.WriteString("**Retired** by the admin: it no longer plays.\n\n")
	}
	b.WriteString("- Points " + strconv.Itoa(bt.Points) + ", record " + strconv.Itoa(bt.Wins) + "-" + strconv.Itoa(bt.Draws) + "-" + strconv.Itoa(bt.Losses) + ", crashes " + strconv.Itoa(bt.Crashes) + "\n")
	b.WriteString("- Brain (claimed source): [" + bt.Brain + "](" + webPath(bt.Brain) + "$source)\n")
	b.WriteString("- Entry realm: [" + bt.Entry + "](" + webPath(bt.Entry) + "$source)\n")
	b.WriteString("- Owner: " + bt.Owner.String() + ", registered at block " + strconv.FormatInt(bt.Height, 10) + "\n\n")
	b.WriteString("## Games\n\n| Opponent | Map | Result |\n|---|---|---|\n")
	for _, o := range allBots() {
		if o.ID == id {
			continue
		}
		for m := range maps {
			a, c := id, o.ID
			if a > c {
				a, c = c, a
			}
			key := gameKey(a, c, m)
			res := "not played"
			if v := games.Get(key); v != nil {
				gm := v.(*Game)
				res = "[" + outcomeFor(gm, id) + "](" + link("game/"+key) + ")"
			}
			if res == "not played" && !o.Retired && !bt.Retired {
				res = "[play](" + playLink(a, c, m) + ")"
			}
			b.WriteString("| [" + o.Name + "](" + link("bot/"+u(o.ID)) + ") | " + maps[m].Name + " | " + res + " |\n")
		}
	}
	b.WriteString("\n[Table](" + link("table") + ")\n")
	return b.String()
}

func renderGame(key string, t int) string {
	v := games.Get(key)
	if v == nil {
		return notFound()
	}
	gm := v.(*Game)
	var b strings.Builder
	b.WriteString("# " + gameTitle(gm) + "\n\n")
	g, err := rules.ReplayTo(gm.Match, t)
	if err != nil {
		return notFound()
	}
	if t < 0 && gm.Done {
		if img, err := svg.Animated(gm.Match, 60); err == nil {
			b.WriteString(svg.Image("replay", img) + "\n\n")
		}
	} else {
		if img, err := svg.Frame(gm.Match, t); err == nil {
			b.WriteString(svg.Image("board", img) + "\n\n")
		}
	}
	b.WriteString(resultLine(gm) + "\n\n")
	cur := g.Turn()
	b.WriteString("Turn " + strconv.Itoa(cur) + " of " + strconv.Itoa(gm.Turns) + ": ")
	b.WriteString("[start](" + link("game/"+key+"/t/0") + ")")
	if cur > 0 {
		b.WriteString(" | [-10](" + link("game/"+key+"/t/"+strconv.Itoa(max0(cur-10))) + ") | [-1](" + link("game/"+key+"/t/"+strconv.Itoa(cur-1)) + ")")
	}
	if cur < gm.Turns {
		b.WriteString(" | [+1](" + link("game/"+key+"/t/"+strconv.Itoa(cur+1)) + ") | [+10](" + link("game/"+key+"/t/"+strconv.Itoa(minInt(cur+10, gm.Turns))) + ")")
	}
	b.WriteString(" | [replay](" + link("game/"+key) + ")\n\n")
	if !gm.Done {
		b.WriteString("This game is still pending: [play the next 40 turns](" + playLink(gm.A, gm.B, gm.Map) + ").\n\n")
	}
	b.WriteString("Match string (the whole game; replay it with `rules.Replay`):\n\n```\n" + gm.Match + "\n```\n")
	return b.String()
}

func renderGames(page int) string {
	var b strings.Builder
	b.WriteString("# Finished games\n\n")
	if nDone == 0 {
		return b.String() + "_None yet._\n"
	}
	b.WriteString("| Game | Map | Result |\n|---|---|---|\n")
	skip := page * pageSize
	n := 0
	done.ReverseIterate("", "", func(_ string, v any) bool {
		if skip > 0 {
			skip--
			return false
		}
		key := v.(string)
		gm := games.Get(key).(*Game)
		b.WriteString("| [" + botName(gm.A) + " vs " + botName(gm.B) + "](" + link("game/"+key) + ") | " + maps[gm.Map].Name + " | " + resultLine(gm) + " |\n")
		n++
		return n >= pageSize
	})
	b.WriteString(pager("games", page, nDone))
	return b.String()
}

func renderPending(page int) string {
	var b strings.Builder
	b.WriteString("# Pending games\n\nAnyone can play these: each click plays up to 40 turns.\n\n| Game | Map | Progress |\n|---|---|---|\n")
	list := activeBots()
	sortBots(list, func(x, y *Bot) bool { return x.ID < y.ID })
	count, shown := 0, 0
	for i := 0; i < len(list); i++ {
		for j := i + 1; j < len(list); j++ {
			for m := range maps {
				a, c := list[i].ID, list[j].ID
				key := gameKey(a, c, m)
				turns := 0
				if v := games.Get(key); v != nil {
					gm := v.(*Game)
					if gm.Done {
						continue
					}
					turns = gm.Turns
				}
				count++
				if count <= page*pageSize || shown >= pageSize {
					continue
				}
				shown++
				b.WriteString("| " + list[i].Name + " vs " + list[j].Name + " | " + maps[m].Name + " | turn " + strconv.Itoa(turns) + ", [play](" + playLink(a, c, m) + ") |\n")
			}
		}
	}
	if count == 0 {
		return "# Pending games\n\n_Nothing to play: the table is complete._\n"
	}
	b.WriteString(pager("pending", page, count))
	return b.String()
}

func renderGuide() string {
	return `# Write a Ribbonfight bot

A bot is one Go function:

` + "```go" + `
func Move(v rules.View) rules.Dir
` + "```" + `

It is called once per turn. ` + "`v`" + ` always shows the board from your side (side B sees it rotated), so the same code works on both sides. Return ` + "`rules.Up`, `rules.Right`, `rules.Down` or `rules.Left`" + `. Useful calls: ` + "`v.Me()`, `v.Opp()`, `v.Heading()`, `v.Free(x, y)`, `v.FreeDirs(x, y)`, `v.Reach(x, y, limit)`" + `.

1. Put the function in a /p/ package (so its source is public and a panic only loses you the game).
2. Deploy a tiny entry realm whose init registers it:

` + "```go" + `
func init(cur realm) {
	arena.Register(cross(cur), "my-bot", "gno.land/p/<you>/mybot/v1", mybot.Move)
}
` + "```" + `

3. Play your games from your bot page, or let the keeper do it.

Gas budget: keep each move under 10M gas. A function call costs about 15k gas and a flood-fill cell about 21k, so ` + "`v.Reach(x, y, 150)`" + ` is about 3M. A move that runs out of gas makes the game unplayable: it stays pending and scores 0 for both bots.

[Home](` + link("") + `)
`
}

// helpers

func activeBots() []*Bot {
	var out []*Bot
	bots.Iterate("", "", func(_ string, v any) bool {
		if b := v.(*Bot); !b.Retired {
			out = append(out, b)
		}
		return false
	})
	return out
}

func allBots() []*Bot {
	var out []*Bot
	bots.Iterate("", "", func(_ string, v any) bool {
		out = append(out, v.(*Bot))
		return false
	})
	return out
}

func gameTitle(gm *Game) string {
	return botName(gm.A) + " (pink) vs " + botName(gm.B) + " (cyan), " + maps[gm.Map].Name
}

func resultLine(gm *Game) string {
	if !gm.Done {
		return "Pending at turn " + strconv.Itoa(gm.Turns) + "."
	}
	switch gm.Winner {
	case rules.WinA:
		return "**" + botName(gm.A) + "** won in " + strconv.Itoa(gm.Turns) + " turns."
	case rules.WinB:
		return "**" + botName(gm.B) + "** won in " + strconv.Itoa(gm.Turns) + " turns."
	}
	return "Draw after " + strconv.Itoa(gm.Turns) + " turns."
}

func outcomeFor(gm *Game, id uint64) string {
	if !gm.Done {
		return "pending"
	}
	if gm.Winner == rules.Draw {
		return "draw"
	}
	if (gm.Winner == rules.WinA) == (gm.A == id) {
		return "won"
	}
	return "lost"
}

func playLink(a, b uint64, m int) string {
	return txlink.Realm("gno.land"+self).Call("PlayPair", "a", u(a), "b", u(b), "m", strconv.Itoa(m), "n", "40")
}

// self is this realm's web path. It is a constant so links stay right when
// another realm calls Render.
const self = "/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/arena/v1"

func link(p string) string {
	base := self
	if p == "" {
		return base
	}
	return base + ":" + p
}

func webPath(pkg string) string { return strings.TrimPrefix(pkg, "gno.land") }

func u(id uint64) string { return strconv.FormatUint(id, 10) }

func splitPage(path string) (string, int) {
	i := strings.Index(path, "?page=")
	if i < 0 {
		return path, 0
	}
	p, err := strconv.Atoi(path[i+6:])
	if err != nil || p < 0 {
		p = 0
	}
	return path[:i], p
}

func pager(route string, page, total int) string {
	s := "\n"
	if page > 0 {
		s += "[newer](" + link(route) + "?page=" + strconv.Itoa(page-1) + ") "
	}
	if (page+1)*pageSize < total {
		s += "[older](" + link(route) + "?page=" + strconv.Itoa(page+1) + ")"
	}
	return s + "\n"
}

func notFound() string { return "# Not found\n\n[Home](" + link("") + ")\n" }

func max0(n int) int {
	if n < 0 {
		return 0
	}
	return n
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// sortBots is an insertion sort; the league holds at most maxBots bots.
func sortBots(list []*Bot, less func(x, y *Bot) bool) {
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && less(list[j], list[j-1]); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}
