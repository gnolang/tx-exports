package hall

import (
	"strconv"
	"strings"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
)

// boardSize is how many rows the lobby leaderboard shows.
const boardSize = 10

var router = newRouter()

func newRouter() *mux.Router {
	r := mux.NewRouter()
	r.HandleFunc("", renderLobby)
	r.HandleFunc("c/{slug}", renderChallenge)
	r.HandleFunc("p/{who}", renderPlayer)
	r.HandleFunc("board", renderBoard)
	r.HandleFunc("seasons", renderSeasons)
	r.HandleFunc("community", renderCommunity)
	r.HandleFunc("api/{what}", renderAPI)
	r.SetNotFoundHandler(func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write("# Nothing on this shelf\n\n[Back to the hall](" + selfPath + ")\n")
	})
	return r
}

// Render serves the hall's pages to gnoweb, and JSON under api/ for the
// Cellar web client.
func Render(path string) string { return router.Render(path) }

func renderLobby(res *mux.ResponseWriter, _ *mux.Request) {
	s := currentSeason()
	res.Write("# The Cellar\n\n")
	res.Write("*A capture-the-flag wargame for Gno, played on-chain. Every challenge is a live realm with a flaw in it. Break it, then claim it here.*\n\n")
	res.Write("**Season " + strconv.Itoa(s.Number) + ": " + s.Name + "** · opened at block " +
		strconv.FormatInt(s.OpenedAt, 10) + " · " + strconv.Itoa(s.Claims) + " claims\n\n")

	res.Write("## The racks\n\n")
	res.Write(challengeTable(func(e *entry) bool { return e.status == Listed }))

	res.Write("\n## Standings this season\n\n")
	res.Write(boardTable(standings(s.Number), boardSize))

	res.Write("\n## Last pours\n\n")
	if len(feed) == 0 {
		res.Write("*Nobody has claimed a flag yet. The first one draws first blood.*\n")
	}
	for i := len(feed) - 1; i >= 0 && i >= len(feed)-10; i-- {
		res.Write("- " + feedLine(feed[i]) + "\n")
	}

	res.Write("\n---\n\n" + link("All-time board", "board") + " · " + link("Seasons", "seasons") +
		" · " + link("Community cellar", "community") + "\n")
}

func renderChallenge(res *mux.ResponseWriter, req *mux.Request) {
	e, ok := getEntry(req.GetVar("slug"))
	if !ok {
		res.Write("# No such challenge\n\n" + link("Back to the hall", "") + "\n")
		return
	}
	info := e.info
	res.Write("# " + sanitize.InlineText(info.Title) + "\n\n")
	res.Write("**" + info.Difficulty.String() + "** · " + sanitize.InlineText(info.Category) +
		" · " + e.status.String() + " · worth **" + strconv.Itoa(e.value()) + "** points to each of its " +
		strconv.Itoa(len(e.solvers)) + " solvers\n\n")
	res.Write(info.Brief + "\n\n")

	web := strings.TrimPrefix(e.path, "gno.land")
	res.Write("**Realm:** [" + e.path + "](" + web + ") · [read the source](" + web + "$source)\n\n")
	if e.status == Listed {
		res.Write("When you have broken it, [claim the flag](" + txlink.Call("Claim", "slug", info.Slug) + ").\n\n")
	}

	res.Write("## Solvers\n\n")
	if len(e.solvers) == 0 {
		res.Write("*Untouched. First blood is worth +" + strconv.Itoa(info.Difficulty.FirstBloodBonus()) + ".*\n")
	}
	for i, addr := range e.solvers {
		line := strconv.Itoa(i+1) + ". " + playerLink(addr)
		if i == 0 {
			line += " · first blood"
		}
		res.Write(line + "\n")
	}
}

func renderPlayer(res *mux.ResponseWriter, req *mux.Request) {
	addr, ok := resolvePlayer(req.GetVar("who"))
	p, found := findProfile(addr)
	if !ok || !found {
		res.Write("# Unknown player\n\nNobody by that name has claimed a flag yet.\n\n" + link("Back to the hall", "") + "\n")
		return
	}
	all, n, _ := p.score(0)
	season, _, _ := p.score(currentSeason().Number)
	res.Write("# " + DisplayName(addr) + "\n\n`" + addr.String() + "`\n\n")
	res.Write("**" + strconv.Itoa(all) + "** points all time · **" + strconv.Itoa(season) +
		"** this season · " + strconv.Itoa(n) + " flags\n\n")

	res.Write("## Flags\n\n")
	if len(p.solves) == 0 {
		res.Write("*No flags yet.*\n")
	}
	for _, s := range p.solves {
		e, _ := getEntry(s.Slug)
		line := "- " + link(sanitize.InlineText(e.info.Title), "c/"+s.Slug) + " · block " +
			strconv.FormatInt(s.Height, 10) + " · season " + strconv.Itoa(s.Season) + " · " +
			strconv.Itoa(solvePoints(s)) + " pts"
		if s.FirstBlood {
			line += " · first blood"
		}
		res.Write(line + "\n")
	}

	res.Write("\n## Badges\n\n")
	if len(p.badges) == 0 {
		res.Write("*No badges yet.*\n")
	}
	for _, tid := range p.badges {
		res.Write("- `" + tid + "`\n")
	}
}

func renderBoard(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# All-time board\n\n")
	rows := standings(0)
	res.Write(boardTable(rows, len(rows)))
	res.Write("\n" + link("Back to the hall", "") + "\n")
}

func renderSeasons(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# Seasons\n\n")
	for i := len(seasons) - 1; i >= 0; i-- {
		s := seasons[i]
		res.Write("## Season " + strconv.Itoa(s.Number) + ": " + s.Name + "\n\n")
		span := "opened at block " + strconv.FormatInt(s.OpenedAt, 10)
		if s.ClosedAt != 0 {
			span += ", closed at block " + strconv.FormatInt(s.ClosedAt, 10)
		} else {
			span += ", still open"
		}
		res.Write(span + " · " + strconv.Itoa(s.Claims) + " claims\n\n")
		for rank, addr := range s.Podium {
			res.Write(strconv.Itoa(rank+1) + ". " + playerLink(addr) + "\n")
		}
		if s.ClosedAt == 0 {
			res.Write(boardTable(standings(s.Number), boardSize))
		}
		res.Write("\n")
	}
}

func renderCommunity(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# Community cellar\n\n")
	res.Write("Anyone can build a challenge: import `gno.land/p/" + strings.TrimPrefix(officialPrefix, "gno.land/r/") +
		"flag`, keep a `flag.Ledger`, and call `hall.Enlist(cross(cur), challenge{})` from your realm's `init`. " +
		"The curator reviews it, then it opens for claims.\n\n")
	res.Write("## Listed\n\n")
	res.Write(challengeTable(func(e *entry) bool { return !e.official && e.status == Listed }))
	res.Write("\n## Awaiting review\n\n")
	res.Write(challengeTable(func(e *entry) bool { return e.status == Pending }))
}

func challengeTable(keep func(*entry) bool) string {
	var b strings.Builder
	b.WriteString("| Challenge | Grade | Teaches | Solves | Worth |\n|---|---|---|---:|---:|\n")
	rows := 0
	eachEntry(func(slug string, e *entry) {
		if !keep(e) {
			return
		}
		rows++
		b.WriteString("| " + link(sanitize.TableCell(e.info.Title), "c/"+slug) + " | " + e.info.Difficulty.String() +
			" | " + sanitize.TableCell(e.info.Category) + " | " + strconv.Itoa(len(e.solvers)) +
			" | " + strconv.Itoa(e.value()) + " |\n")
	})
	if rows == 0 {
		return "*Empty rack.*\n"
	}
	return b.String()
}

func boardTable(rows []Standing, limit int) string {
	if len(rows) == 0 {
		return "*No points on the board yet.*\n"
	}
	var b strings.Builder
	b.WriteString("| # | Player | Points | Flags |\n|---:|---|---:|---:|\n")
	for i, r := range rows {
		if i == limit {
			break
		}
		b.WriteString("| " + strconv.Itoa(i+1) + " | " + playerLink(r.Player) + " | " +
			strconv.Itoa(r.Points) + " | " + strconv.Itoa(r.Solves) + " |\n")
	}
	return b.String()
}

func feedLine(s Solve) string {
	title := s.Slug
	if e, ok := getEntry(s.Slug); ok {
		title = sanitize.InlineText(e.info.Title)
	}
	line := "block " + strconv.FormatInt(s.Height, 10) + ": " + playerLink(s.Player) + " broke " + link(title, "c/"+s.Slug)
	if s.FirstBlood {
		line += " (first blood)"
	}
	return line
}

func playerLink(addr address) string { return link(DisplayName(addr), "p/"+addr.String()) }

// link points at a page of this realm.
func link(text, page string) string {
	if page == "" {
		return "[" + text + "](" + selfPath + ")"
	}
	return "[" + text + "](" + selfPath + ":" + page + ")"
}
