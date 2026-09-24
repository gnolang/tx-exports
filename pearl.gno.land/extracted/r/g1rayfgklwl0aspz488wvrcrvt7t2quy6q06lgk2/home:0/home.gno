// Package home is David G.'s profile page on gno.land.
//
// gnoweb renders a profile by calling Render("") on the realm at exactly
// /r/<address>/home, so this path carries no /vN suffix.
//
// The page is a list of sections, each a markdown body the owner edits with
// one Set transaction, so changing the text never needs a redeploy. The slot
// named "order" lists the sections to show. Six sections are drawn rather
// than stored: "hero", the page banner, "banner" and "reviews", the activity
// charts, "areachart", the ring of pull requests by area, "game", today's
// Gnordle, and "hearts", the heart count and wall.
package home

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/nt/avl/v0"
)

// admin is the only address allowed to edit sections.
const admin = address("g1rayfgklwl0aspz488wvrcrvt7t2quy6q06lgk2")

const (
	home       = "/r/g1rayfgklwl0aspz488wvrcrvt7t2quy6q06lgk2/home"
	orderSlot  = "order"
	maxNameLen = 32
	// maxPathLen is far above any link the page writes, and turns a long
	// crafted link away before the query parser, whose cost grows with it.
	maxPathLen = 256
)

var (
	slots  = avl.NewTree() // section name -> markdown body
	hearts = avl.NewTree() // address -> block height of the heart
)

func init() {
	for _, s := range defaultSlots {
		slots.Set(s.name, s.body)
	}
}

// Set writes one section of the page. Only the admin can call it.
//
// name is the section to write and body is its markdown. The text sections are
// "header", the bio at the top, then "gno", "projects", "peerdev" and
// "unrelated"; any other name creates a new section.
//
// name "order" decides which sections show and in which order. Its body lists
// every section name, comma separated, with no spaces. A name left out of the
// list is hidden, so copy the current list, from Get("order"), and edit it.
//
// name "herotext" is the banner's text: "key value" pairs split by ";", with
// the keys kicker, the small line on top, title, subtitle, tagline, footline,
// the small line at the bottom, and alt, the banner's description for screen
// readers. A key left out keeps its current default.
//
// "hero", "banner", "reviews", "areachart", "game" and "hearts" are drawn by
// the page itself: they cannot be set, only placed through "order".
//
// Examples, as the two fields of the form:
//
//	name: header
//	body: I'm a developer engineer at [Samouraï Coop](https://www.samourai.world/).
//
//	name: herotext
//	body: title David G.; subtitle Developer engineer at Samouraï Coop; footline Open for contribution
//
//	name: talks
//	body: ## Talks
//
//	name: order
//	body: hero,header,activityhead,banner,reviews,gno,areachart,projects,peerdev,unrelated,talks,game,hearts
func Set(cur realm, name, body string) {
	assertAdmin(cur)
	if name == "" || len(name) > maxNameLen || strings.ContainsAny(name, ", \n") {
		panic("invalid section name")
	}
	if drawnSections[name] {
		panic("reserved section: " + name)
	}
	slots.Set(name, body)
}

// SetActivity refreshes the three charts in one transaction. Only the admin
// can call it. Its three arguments are the bodies of the "activity",
// "reviewactivity" and "areas" sections, as scripts/activity.py prints them;
// an empty argument leaves that chart as it is.
func SetActivity(cur realm, activity, reviews, areas string) {
	assertAdmin(cur)
	for _, s := range []struct{ name, body string }{
		{activitySlot, activity},
		{reviewActivitySlot, reviews},
		{areasSlot, areas},
	} {
		if s.body != "" {
			slots.Set(s.name, s.body)
		}
	}
}

// Delete removes one section. Only the admin can call it.
//
// name is the section to remove, "talks" for example. Its name can stay in
// "order": a name with no section shows nothing.
func Delete(cur realm, name string) {
	assertAdmin(cur)
	if _, ok := slots.Remove(name); !ok {
		panic("no such section: " + name)
	}
}

// Get returns a section's markdown, or "" when it does not exist.
// Get("order") returns the current section list, the one to edit before
// setting "order".
func Get(name string) string {
	if v := slots.Get(name); v != nil {
		return v.(string)
	}
	return ""
}

// Heart records one heart from the caller. Each address can send exactly one.
func Heart(cur realm) {
	from := cur.Previous().Address().String()
	if hearts.Has(from) {
		panic("already sent: one heart per address")
	}
	hearts.Set(from, runtime.ChainHeight())
}

// Hearts returns how many distinct addresses sent a heart.
func Hearts() int { return hearts.Size() }

// HasHeart reports whether addr already sent a heart.
func HasHeart(addr address) bool { return hearts.Has(addr.String()) }

func assertAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("unauthorized")
	}
}

// Render serves:
//
//	""             the profile page
//	"wordle/..."   the Gnordle game
//	"hearts[/<n>]" the addresses that sent a heart, heartsPerPage per page
func Render(path string) string {
	if len(path) > maxPathLen {
		return "# Not found\n\n[Back home](" + home + ")\n"
	}
	// Only the game reads a query; elsewhere one is dropped, so a shared link
	// carrying ?utm_source=... still shows the page.
	if !strings.HasPrefix(path, "wordle") {
		path, _, _ = strings.Cut(path, "?")
	}
	switch {
	case path == "":
		return renderPage()
	case path == "wordle" || strings.HasPrefix(path, "wordle/") || strings.HasPrefix(path, "wordle?"):
		return renderWordle(path)
	case path == "hearts" || strings.HasPrefix(path, "hearts/"):
		return renderHearts(strings.TrimPrefix(strings.TrimPrefix(path, "hearts"), "/"))
	}
	return "# Not found\n\n[Back home](" + home + ")\n"
}

func renderPage() string {
	var b strings.Builder
	for _, name := range strings.Split(Get(orderSlot), ",") {
		switch name = strings.TrimSpace(name); name {
		case "":
		case "hero":
			b.WriteString(heroImage())
		case "areachart":
			b.WriteString(renderAreas())
		case "banner":
			b.WriteString(renderChart(activitySlot))
		case "reviews":
			b.WriteString(renderChart(reviewActivitySlot))
		case "game":
			b.WriteString(renderGameTeaser())
		case "hearts":
			b.WriteString(renderHeartsTeaser())
		default:
			b.WriteString(Get(name))
		}
		b.WriteString("\n\n")
	}
	b.WriteString("---\n\nThis page is a contract: [gno.land" + home + "](" + home + "$source).\n")
	return b.String()
}

func renderHeartsTeaser() string {
	return "## Hearts\n\n**" + strconv.Itoa(Hearts()) + "** so far. " +
		"[Send one](" + home + "$help&func=Heart): one transaction, one per address, " +
		"forever on chain. [See who did](" + home + ":hearts).\n\n" + renderHeartsWall()
}

// drawnSections are rendered from code and state, so Set refuses their names.
var drawnSections = map[string]bool{
	"hero": true, "banner": true, "reviews": true, "areachart": true, "game": true, "hearts": true,
}

// heroSlot holds the banner's text, one "key value" pair per field, split by
// ";": kicker, title, subtitle, tagline, footline and alt, the image's
// description. A field the section leaves out keeps its value from hero.
const heroSlot = "herotext"

func currentHero() heroText {
	h := hero
	for _, pair := range strings.Split(Get(heroSlot), ";") {
		key, value, _ := strings.Cut(strings.TrimSpace(pair), " ")
		value = strings.TrimSpace(value)
		switch key {
		case "kicker":
			h.kicker = value
		case "title":
			h.title = value
		case "subtitle":
			h.subtitle = value
		case "tagline":
			h.tagline = value
		case "footline":
			h.footline = value
		case "alt":
			h.alt = value
		}
	}
	return h
}

// mdText keeps s from closing a markdown link or image label.
func mdText(s string) string {
	return strings.NewReplacer("[", "(", "]", ")").Replace(s)
}

// xmlText escapes s for SVG text and attributes.
func xmlText(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;", "'", "&#39;").Replace(s)
}

// heartsPerPage keeps one page of the list far under the query gas limit,
// which a list of every heart would pass at about 15,000 of them.
const heartsPerPage = 100

func renderHearts(page string) string {
	n := 1
	if page != "" {
		v, err := strconv.Atoi(page)
		if err != nil || v < 1 {
			return "# Hearts\n\nThere is no such page.\n\n[Back home](" + home + ")\n"
		}
		n = v
	}
	pages := (hearts.Size() + heartsPerPage - 1) / heartsPerPage
	if n > 1 && n > pages {
		return "# Hearts\n\nThere is no such page.\n\n[Back home](" + home + ")\n"
	}
	var b strings.Builder
	b.WriteString("# Hearts\n\n")
	if hearts.Size() == 0 {
		b.WriteString("Nobody yet. [Be the first](" + home + "$help&func=Heart).\n")
	}
	hearts.IterateByOffset((n-1)*heartsPerPage, heartsPerPage, func(addr string, h any) bool {
		b.WriteString("- " + addr + ", block " + strconv.FormatInt(h.(int64), 10) + "\n")
		return false
	})
	if pages > 1 {
		b.WriteString("\nPage " + strconv.Itoa(n) + " of " + strconv.Itoa(pages) + ".")
		if n > 1 {
			b.WriteString(" [Previous](" + home + ":hearts/" + strconv.Itoa(n-1) + ")")
		}
		if n < pages {
			b.WriteString(" [Next](" + home + ":hearts/" + strconv.Itoa(n+1) + ")")
		}
		b.WriteString("\n")
	}
	b.WriteString("\n[Back home](" + home + ")\n")
	return b.String()
}
