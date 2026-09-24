package home

import (
	"chain/runtime"
	"encoding/base64"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// A guess arrives in the page link, so anyone can write one: none of it may
// reach the rendered markdown.
func TestGuessIsNeverEchoed(t *testing.T) {
	setDay(launchDay)
	uassert.True(t, strings.Contains(Render("wordle/1?guess=abc"), "> That guess is not five letters, A to Z."))
	for _, guess := range []string{
		"[claim your reward](https://evil.example)",
		"x\n\n# OFFICIAL NOTICE",
		"![](https://evil.example/pixel.png)",
		`<gno-form exec="Transfer"><gno-input name="to" /></gno-form>`,
	} {
		// Any rejected guess renders the very page a harmless rejected one does.
		page := Render("wordle/1?guess=" + url.QueryEscape(guess))
		uassert.Equal(t, Render("wordle/1?guess=abc"), page, "guess leaked into the page: "+guess)
	}
}

func TestOnlyAdminWrites(cur realm, t *testing.T) {
	for _, caller := range []runtime.Realm{
		testing.NewUserRealm(testutils.TestAddress("mallory")),
		testing.NewCodeRealm("gno.land/r/evil/relay"),
	} {
		testing.SetRealm(caller)
		uassert.AbortsWithMessage(t, cur, "unauthorized", func() { Set(cross(cur), "header", "pwned") })
		uassert.AbortsWithMessage(t, cur, "unauthorized", func() { Delete(cross(cur), "header") })
	}
	uassert.False(t, strings.Contains(Render(""), "pwned"))
}

func TestChartTextIsEscaped(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	old := Get(reviewActivitySlot)
	Set(cross(cur), reviewActivitySlot, `title reviews; series <script>alert(1)</script>,a&b; 2026-01 1 2`)
	out := renderChart(reviewActivitySlot)
	raw, err := base64.StdEncoding.DecodeString(out[strings.Index(out, "base64,")+7 : len(out)-2])
	uassert.NoError(t, err)
	uassert.False(t, strings.Contains(string(raw), "<script>"))
	uassert.True(t, strings.Contains(string(raw), "&lt;script&gt;"))
	uassert.True(t, strings.Contains(string(raw), "a&amp;b"))
	Set(cross(cur), reviewActivitySlot, old)
}

func TestHeartsListIsPaged(t *testing.T) {
	hearts = avl.NewTree()
	for i := 0; i < 250; i++ {
		hearts.Set(testutils.TestAddress("fan"+strconv.Itoa(i)).String(), int64(i))
	}
	first := Render("hearts")
	uassert.Equal(t, heartsPerPage, strings.Count(first, "\n- "))
	uassert.True(t, strings.Contains(first, "Page 1 of 3."))
	uassert.True(t, strings.Contains(first, "[Next]("+home+":hearts/2)"))
	uassert.False(t, strings.Contains(first, "[Previous]"))
	last := Render("hearts/3")
	uassert.Equal(t, 50, strings.Count(last, "\n- "))
	uassert.True(t, strings.Contains(last, "[Previous]("+home+":hearts/2)"))
	uassert.False(t, strings.Contains(last, "[Next]"))
	for _, bad := range []string{"hearts/0", "hearts/4", "hearts/x", "hearts/-1"} {
		uassert.True(t, strings.Contains(Render(bad), "There is no such page."), bad)
	}
	hearts = avl.NewTree()
}

func TestOrderSurvivesBadEntries(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	old := Get(orderSlot)
	Set(cross(cur), orderSlot, "nosuchsection,,header")
	page := Render("")
	uassert.True(t, strings.HasPrefix(strings.TrimSpace(page), "I'm a developer engineer"))
	Delete(cross(cur), orderSlot)
	uassert.True(t, strings.Contains(Render(""), "This page is a contract"))
	Set(cross(cur), orderSlot, old)
}

func TestQueryDoesNotBreakPages(t *testing.T) {
	uassert.Equal(t, Render(""), Render("?utm_source=x"))
	uassert.Equal(t, Render(""), Render("?fbclid=abc&x=1"))
	uassert.Equal(t, Render("hearts"), Render("hearts?x=1"))
	// The game keeps its query: it carries the guess.
	setDay(launchDay)
	uassert.True(t, strings.Contains(Render("wordle/1?guess=crane"), "CRANE"))
}

func TestLongPathIsRefused(t *testing.T) {
	setDay(launchDay)
	// The longest link the game writes: six guesses and a typed one.
	longest := "wordle/99999/CRANE.SLATE.ROUTE.TRACE.QUERY.PROXY?guess=" + url.QueryEscape("  crane  ")
	uassert.True(t, len(longest) <= maxPathLen)
	uassert.False(t, strings.HasPrefix(Render(longest), "# Not found"))
	for _, p := range []string{
		"wordle/1?" + strings.Repeat("a=&", 100),
		"wordle/1/" + strings.Repeat(".", 300),
		"hearts/" + strings.Repeat("9", 300),
	} {
		uassert.True(t, strings.HasPrefix(Render(p), "# Not found"), p[:20])
	}
}

func TestHeroTextIsEditable(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	old := Get(heroSlot)
	decode := func() string {
		out := heroImage()
		raw, err := base64.StdEncoding.DecodeString(out[strings.Index(out, "base64,")+7 : len(out)-1])
		uassert.NoError(t, err)
		return string(raw)
	}
	uassert.True(t, strings.Contains(decode(), ">David G.</text>"))

	Set(cross(cur), heroSlot, "title Dave; subtitle <b>&co</b>; bogus x; tagline hello")
	svg := decode()
	uassert.True(t, strings.Contains(svg, ">Dave</text>"))
	uassert.True(t, strings.Contains(svg, ">&lt;b&gt;&amp;co&lt;/b&gt;</text>"))
	uassert.True(t, strings.Contains(svg, ">hello</text>"))
	// A key the section leaves out keeps its default.
	uassert.True(t, strings.Contains(svg, ">gno.land core contributor</text>"))
	uassert.True(t, strings.HasPrefix(heroImage(), "![David G., developer engineer at Samouraï Coop]("))

	Set(cross(cur), heroSlot, "alt a ]( trap")
	uassert.True(t, strings.HasPrefix(heroImage(), "![a )( trap]("))

	Set(cross(cur), heroSlot, old)
}

func TestSetActivity(cur realm, t *testing.T) {
	oldPR, oldRev, oldAreas := Get(activitySlot), Get(reviewActivitySlot), Get(areasSlot)
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("mallory")))
	uassert.AbortsWithMessage(t, cur, "unauthorized", func() { SetActivity(cross(cur), "x", "x", "x") })
	uassert.Equal(t, oldPR, Get(activitySlot))

	testing.SetRealm(testing.NewUserRealm(admin))
	SetActivity(cross(cur), "title a; series s; 2026-01 1", "", "title c; slice 3 Docs")
	uassert.Equal(t, "title a; series s; 2026-01 1", Get(activitySlot))
	uassert.Equal(t, oldRev, Get(reviewActivitySlot)) // empty leaves it as it is
	uassert.Equal(t, "title c; slice 3 Docs", Get(areasSlot))
	out := renderChart(activitySlot)
	raw, err := base64.StdEncoding.DecodeString(out[strings.Index(out, "base64,")+7 : len(out)-2])
	uassert.NoError(t, err)
	uassert.True(t, strings.Contains(string(raw), ">1 a</text>"))

	SetActivity(cross(cur), oldPR, oldRev, oldAreas)
}
