package profiles

import (
	"strconv"
	"strings"

	"gno.land/p/moul/md/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
)

// rankingLimit is how many players the gnoweb page lists.
const rankingLimit = 50

var router = mux.NewRouter()

func init() {
	router.HandleFunc("", renderHome)
	router.HandleFunc("json/profile/{addr}", func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(ProfileJSON(req.GetVar("addr")))
	})
	router.HandleFunc("json/players/{offset}/{count}", func(res *mux.ResponseWriter, req *mux.Request) {
		offset, err1 := strconv.Atoi(req.GetVar("offset"))
		count, err2 := strconv.Atoi(req.GetVar("count"))
		if err1 != nil || err2 != nil {
			panic("profiles: invalid page")
		}
		res.Write(PlayersJSON(offset, count))
	})
}

// Render serves the ranking page ("") and the raw JSON views the web client
// reads ("json/profile/{addr}", "json/players/{offset}/{count}").
func Render(path string) string {
	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write(md.H1("Gnoslinger top guns"))
	if ranking.Size() == 0 {
		res.Write(md.Paragraph("Nobody has played yet."))
	} else {
		var b strings.Builder
		b.WriteString("| Rank | Player | Victory points | Games played |\n|---|---|---|---|\n")
		rank := 0
		ranking.Iterate("", "", func(_ string, v any) bool {
			p := v.(*Profile)
			rank++
			b.WriteString("| " + strconv.Itoa(rank) + " | " + label(p.Addr) +
				" | " + strconv.Itoa(p.VictoryPoints) + " | " + strconv.Itoa(p.GamesPlayed) + " |\n")
			return rank >= rankingLimit
		})
		res.Write(b.String() + "\n")
	}
	res.Write(md.H2("Scored games"))
	var l []string
	for _, g := range Games() {
		l = append(l, md.InlineCode(g))
	}
	res.Write(md.BulletList(l))
}

// label shows an address by its registered name when it has one.
func label(a address) string {
	if name := Name(a); name != "" {
		return md.Bold(sanitize.InlineText(name))
	}
	return md.InlineCode(sanitize.InlineText(a.String()))
}
