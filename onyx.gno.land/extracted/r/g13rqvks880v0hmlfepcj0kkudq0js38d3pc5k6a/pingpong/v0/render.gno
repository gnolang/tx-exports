package pingpong

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const pageSize = 50

// Render serves "" (the first page), "page/N" and "game/<id>".
func Render(path string) string {
	switch {
	case path == "":
		return renderPage(1)
	case strings.HasPrefix(path, "page/"):
		n, err := strconv.Atoi(strings.TrimPrefix(path, "page/"))
		if err != nil || n < 1 {
			return "Not found."
		}
		return renderPage(n)
	case strings.HasPrefix(path, "game/"):
		id := strings.TrimPrefix(path, "game/")
		if !games.Has(id) {
			return "Not found."
		}
		return renderGame(games.Get(id).(*Game))
	}
	return "Not found."
}

// renderPage lists the games newest first, pageSize to a page.
func renderPage(n int) string {
	var b strings.Builder
	b.WriteString("# pingpong\n\n")
	pages := (games.Size() + pageSize - 1) / pageSize
	if n > pages {
		b.WriteString("No games on this page.\n")
		return b.String()
	}
	games.ReverseIterateByOffset((n-1)*pageSize, pageSize, func(_ string, v any) bool {
		g := v.(*Game)
		b.WriteString("- [**" + g.ID + "**](" + selfPath + ":game/" + g.ID + ") " +
			g.First.String() + " vs " + g.Second.String() + " · " + status(g) + "\n")
		return false
	})
	if n < pages {
		b.WriteString("\n[Next page](" + selfPath + ":page/" + strconv.Itoa(n+1) + ")\n")
	}
	return b.String()
}

func renderGame(g *Game) string {
	var b strings.Builder
	b.WriteString("# Game " + g.ID + "\n\n")
	b.WriteString("- First: " + g.First.String() + "\n")
	b.WriteString("- Second: " + g.Second.String() + "\n")
	b.WriteString("- Status: " + status(g) + "\n")
	if g.Started {
		b.WriteString("- Turn: " + strconv.Itoa(g.Turn) + "\n")
		b.WriteString("- Next: " + g.Next.String() + "\n")
	}
	b.WriteString("\n[All games](" + selfPath + ")\n")
	return b.String()
}

func status(g *Game) string {
	if !g.Started {
		return "pending"
	}
	return "started · turn " + strconv.Itoa(g.Turn) + " · next " + g.Next.String()
}

// selfPath is this realm's path on gnoweb. It is read at package init, where
// the realm itself is current; Render is not crossing, so reading it there
// would give the caller's path. It only builds links.
var selfPath = strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land")
