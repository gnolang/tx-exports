package hall

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/uassert/v0"
)

func itoa(n int) string { return strconv.Itoa(n) }

func TestRenderPages(cur realm, t *testing.T) {
	ch := newFake("pages", flag.Easy)
	ch.info.Title = "Pages | <b>bold</b>"
	enlistFrom(cur, officialPrefix+"pages", ch)
	ch.broken[ash] = true
	claimAs(cur, ash, "pages")
	testing.SetRealm(testing.NewUserRealm(ash))
	SetHandle(cross(cur), "ashen")

	lobby := Render("")
	for _, want := range []string{"# The Cellar", "## The racks", "## Standings this season", "## Last pours", "ashen", "(first blood)"} {
		uassert.True(t, strings.Contains(lobby, want), "lobby lacks "+want)
	}
	uassert.False(t, strings.Contains(lobby, "| <b>"), "titles must be table-safe")

	page := Render("c/pages")
	uassert.True(t, strings.Contains(page, "first blood"))
	uassert.True(t, strings.Contains(page, "$source"))
	uassert.True(t, strings.Contains(Render("c/missing"), "No such challenge"))

	uassert.True(t, strings.Contains(Render("p/ashen"), "`"+string(ash)+"`"))
	uassert.True(t, strings.Contains(Render("p/"+string(ash)), "## Badges"))
	uassert.True(t, strings.Contains(Render("p/<script>"), "Unknown player"))
	uassert.True(t, strings.Contains(Render("board"), "# All-time board"))
	uassert.True(t, strings.Contains(Render("seasons"), "## Season"))
	uassert.True(t, strings.Contains(Render("community"), "hall.Enlist(cross(cur), challenge{})"))
	uassert.True(t, strings.Contains(Render("no/such/page"), "Nothing on this shelf"))
}

func TestRenderAPI(cur realm, t *testing.T) {
	ch := newFake("api", flag.Medium)
	ch.info.Brief = "Line one\nsays \"hi\" \\ there"
	enlistFrom(cur, officialPrefix+"api", ch)

	out := Render("api/challenges")
	uassert.True(t, strings.HasPrefix(out, "[{"))
	uassert.True(t, strings.Contains(out, `"brief":"Line one\nsays \"hi\" \\ there"`))
	uassert.True(t, strings.Contains(out, `"slug":"api","title":"Fake api","difficulty":"Medium"`))

	uassert.True(t, strings.HasPrefix(Render("api/board"), "["))
	uassert.True(t, strings.HasPrefix(Render("api/board-1"), "["))
	uassert.Equal(t, `{"error":"no such season"}`, Render("api/board-99"))
	uassert.True(t, strings.HasPrefix(Render("api/feed"), "["))
	uassert.True(t, strings.Contains(Render("api/seasons"), `"name":"First Pressing"`))
	uassert.True(t, strings.Contains(Render("api/player-"+string(cask)), `"player":"`+string(cask)+`"`))
	uassert.Equal(t, `{"error":"unknown player"}`, Render("api/player-nobody"))
	uassert.Equal(t, `{"error":"unknown endpoint"}`, Render("api/what"))
}

func TestQuote(t *testing.T) {
	uassert.Equal(t, `"a\u0001b\u0009c"`, quote("a\x01b\tc"))
}
