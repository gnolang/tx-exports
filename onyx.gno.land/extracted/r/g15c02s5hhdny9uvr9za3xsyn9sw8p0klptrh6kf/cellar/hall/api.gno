package hall

import (
	"strconv"
	"strings"

	"gno.land/p/nt/mux/v0"
)

// renderAPI answers api/<what> with JSON for the Cellar web client:
// challenges, board, board-<season>, feed, seasons, player-<address>.
func renderAPI(res *mux.ResponseWriter, req *mux.Request) {
	what := req.GetVar("what")
	switch {
	case what == "challenges":
		res.Write(challengesJSON())
	case what == "board":
		res.Write(boardJSON(0))
	case strings.HasPrefix(what, "board-"):
		n, err := strconv.Atoi(strings.TrimPrefix(what, "board-"))
		if err != nil || n < 1 || n > len(seasons) {
			res.Write(`{"error":"no such season"}`)
			return
		}
		res.Write(boardJSON(n))
	case what == "feed":
		res.Write(feedJSON())
	case what == "seasons":
		res.Write(seasonsJSON())
	case strings.HasPrefix(what, "player-"):
		res.Write(playerJSON(strings.TrimPrefix(what, "player-")))
	default:
		res.Write(`{"error":"unknown endpoint"}`)
	}
}

func challengesJSON() string {
	var items []string
	eachEntry(func(slug string, e *entry) {
		first := ""
		if len(e.solvers) > 0 {
			first = e.solvers[0].String()
		}
		items = append(items, object(
			"slug", quote(slug),
			"title", quote(e.info.Title),
			"difficulty", quote(e.info.Difficulty.String()),
			"category", quote(e.info.Category),
			"brief", quote(e.info.Brief),
			"path", quote(e.path),
			"official", strconv.FormatBool(e.official),
			"status", quote(e.status.String()),
			"solves", strconv.Itoa(len(e.solvers)),
			"value", strconv.Itoa(e.value()),
			"firstBloodBonus", strconv.Itoa(e.info.Difficulty.FirstBloodBonus()),
			"firstBlood", quote(first),
			"enlistedAt", strconv.FormatInt(e.enlistedAt, 10),
		))
	})
	return array(items)
}

func boardJSON(season int) string {
	var items []string
	for _, r := range standings(season) {
		items = append(items, object(
			"player", quote(r.Player.String()),
			"name", quote(DisplayName(r.Player)),
			"points", strconv.Itoa(r.Points),
			"solves", strconv.Itoa(r.Solves),
		))
	}
	return array(items)
}

func feedJSON() string {
	var items []string
	for i := len(feed) - 1; i >= 0; i-- {
		items = append(items, solveJSON(feed[i]))
	}
	return array(items)
}

func solveJSON(s Solve) string {
	return object(
		"player", quote(s.Player.String()),
		"name", quote(DisplayName(s.Player)),
		"slug", quote(s.Slug),
		"height", strconv.FormatInt(s.Height, 10),
		"season", strconv.Itoa(s.Season),
		"firstBlood", strconv.FormatBool(s.FirstBlood),
		"points", strconv.Itoa(solvePoints(s)),
	)
}

func seasonsJSON() string {
	var items []string
	for _, s := range seasons {
		var podium []string
		for _, a := range s.Podium {
			podium = append(podium, quote(a.String()))
		}
		items = append(items, object(
			"number", strconv.Itoa(s.Number),
			"name", quote(s.Name),
			"openedAt", strconv.FormatInt(s.OpenedAt, 10),
			"closedAt", strconv.FormatInt(s.ClosedAt, 10),
			"claims", strconv.Itoa(s.Claims),
			"podium", array(podium),
		))
	}
	return array(items)
}

func playerJSON(who string) string {
	addr, ok := resolvePlayer(who)
	if !ok {
		return `{"error":"unknown player"}`
	}
	p, found := findProfile(addr)
	if !found {
		p = &profile{addr: addr}
	}
	all, n, _ := p.score(0)
	season, _, _ := p.score(currentSeason().Number)
	var solves, badges []string
	for _, s := range p.solves {
		solves = append(solves, solveJSON(s))
	}
	for _, tid := range p.badges {
		badges = append(badges, object("id", quote(tid), "uri", quote(BadgeURI(tid))))
	}
	return object(
		"player", quote(addr.String()),
		"name", quote(DisplayName(addr)),
		"handle", quote(p.handle),
		"points", strconv.Itoa(all),
		"seasonPoints", strconv.Itoa(season),
		"flags", strconv.Itoa(n),
		"solves", array(solves),
		"badges", array(badges),
	)
}

// object renders alternating keys and raw JSON values as a JSON object.
func object(kv ...string) string {
	var b strings.Builder
	b.WriteByte('{')
	for i := 0; i+1 < len(kv); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(quote(kv[i]) + ":" + kv[i+1])
	}
	b.WriteByte('}')
	return b.String()
}

func array(items []string) string { return "[" + strings.Join(items, ",") + "]" }

// quote encodes s as a JSON string.
func quote(s string) string {
	const hex = "0123456789abcdef"
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString(`\n`)
		case c < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&0xf])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
