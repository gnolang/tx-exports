package home

import (
	"chain/runtime"
	"encoding/base64"
	"html"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// Suggested amount on the Tip button (1 GNOT); visitors can change it.
const tipSuggestion = "1000000ugnot"

// expand replaces every widget token in one pass. strings.Replacer does not
// rescan its output, so visitor text inside a widget can never trigger a
// token. Only the tokens present in md are built, found with a single scan
// of md.
func expand(md, tab string, page int) string {
	words := map[string]bool{}
	for _, w := range strings.Split(md, ":") {
		words[w] = true
	}
	var pairs []string
	add := func(tok string, build func() string) {
		if words[tok[1:len(tok)-1]] {
			pairs = append(pairs, tok, build())
		}
	}
	add(":banner:", bannerMD)
	add(":badges:", badgesMD)
	add(":now:", nowMD)
	add(":waves:", wavesMD)
	add(":tip:", tipMD)
	add(":sign:", signMD)
	add(":guestbook:", func() string {
		if tab != guestbookTab {
			return "" // a form would target /u/<name> on the profile view
		}
		return guestbookMD(page)
	})
	add(":blog:", func() string {
		if tab != blogTab {
			return "" // its page links lead to the Blog tab
		}
		return blogMD(page)
	})
	add(":posts:", postsMD)
	add(":height:", func() string { return strconv.FormatInt(runtime.ChainHeight(), 10) })
	add(":owner:", func() string { return owner.String() })
	if len(pairs) == 0 {
		return md
	}
	return strings.NewReplacer(pairs...).Replace(md)
}

func itoa(n int) string { return strconv.Itoa(n) }

// plural renders "1 wave", "2 waves".
func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return itoa(n) + " " + word + "s"
}

// svgImage embeds an SVG as a base64 data URI, the one inline image form
// gnoweb keeps.
func svgImage(alt, svg string) string {
	return "![" + sanitize.InlineText(alt) + "](data:image/svg+xml;base64," +
		base64.StdEncoding.EncodeToString([]byte(svg)) + ")"
}

// ----- colors -----

// gno.land's own greens, from gnoweb's palette. An image can't follow
// gnoweb's theme toggle, so each one reads on both its white and its
// near-black background.
const (
	colBrand  = "#226C57" // gnoweb's links and buttons
	colDeep   = "#144134" // banner background, text on colSoft
	colAccent = "#60AB96" // banner accents, pill outlines
	colSoft   = "#E7EFED" // pale surface
	colGhost  = "#F0F0F0"
	fontUI    = "system-ui, -apple-system, Segoe UI, Helvetica, Arial, sans-serif"
)

// ----- banner -----

func bannerMD() string {
	return svgImage(profile.name+" banner", bannerSVG(runtime.ChainHeight()))
}

// bannerSVG draws the 720x160 banner: the ghost, a coffee cup, the name and
// the tagline. The face depends on height % 4: calm, happy, wink, surprised.
func bannerSVG(height int64) string {
	var sb strings.Builder
	sb.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="720" height="160" viewBox="0 0 720 160">`)
	sb.WriteString(`<rect width="720" height="160" rx="16" fill="` + colDeep + `"/>`)
	sb.WriteString(`<path d="M60 140 V72 A50 50 0 0 1 160 72 V140 Q147.5 124 135 140 Q122.5 124 110 140 Q97.5 124 85 140 Q72.5 124 60 140 Z" fill="` + colGhost + `"/>`)
	switch height % 4 {
	case 0: // calm
		sb.WriteString(`<ellipse cx="92" cy="74" rx="6" ry="8" fill="` + colDeep + `"/>`)
		sb.WriteString(`<ellipse cx="128" cy="74" rx="6" ry="8" fill="` + colDeep + `"/>`)
		sb.WriteString(`<path d="M100 100 Q110 106 120 100" stroke="` + colDeep + `" stroke-width="4" fill="none" stroke-linecap="round"/>`)
	case 1: // happy
		sb.WriteString(`<path d="M84 78 Q92 66 100 78 M120 78 Q128 66 136 78" stroke="` + colDeep + `" stroke-width="4" fill="none" stroke-linecap="round"/>`)
		sb.WriteString(`<path d="M96 96 Q110 116 124 96 Z" fill="` + colDeep + `"/>`)
	case 2: // wink
		sb.WriteString(`<ellipse cx="92" cy="74" rx="6" ry="8" fill="` + colDeep + `"/>`)
		sb.WriteString(`<path d="M120 76 H136" stroke="` + colDeep + `" stroke-width="4" stroke-linecap="round"/>`)
		sb.WriteString(`<path d="M98 98 Q110 110 122 98" stroke="` + colDeep + `" stroke-width="4" fill="none" stroke-linecap="round"/>`)
	default: // surprised
		sb.WriteString(`<circle cx="92" cy="72" r="8" fill="` + colDeep + `"/>`)
		sb.WriteString(`<circle cx="128" cy="72" r="8" fill="` + colDeep + `"/>`)
		sb.WriteString(`<ellipse cx="110" cy="104" rx="7" ry="9" fill="` + colDeep + `"/>`)
	}
	// Coffee cup with steam: "I turn coffee into code".
	sb.WriteString(`<rect x="180" y="108" width="30" height="30" rx="5" fill="` + colAccent + `"/>`)
	sb.WriteString(`<path d="M210 114 h6 a7 7 0 0 1 0 14 h-6" stroke="` + colAccent + `" stroke-width="4" fill="none"/>`)
	sb.WriteString(`<path d="M188 100 q-5 -7 0 -14 M200 100 q-5 -7 0 -14" stroke="` + colAccent + `" stroke-width="3" fill="none" stroke-linecap="round"/>`)
	sb.WriteString(`<text x="260" y="78" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="` + fontSize(profile.name, 44, 26) + `" font-weight="700" fill="` + colGhost + `">` + html.EscapeString(profile.name) + `</text>`)
	sb.WriteString(`<text x="260" y="116" font-family="` + fontUI + `" font-size="` + fontSize(profile.tagline, 22, 12) + `" fill="` + colAccent + `">` + html.EscapeString(profile.tagline) + `</text>`)
	sb.WriteString(`</svg>`)
	return sb.String()
}

// fontSize shrinks size so text fits the 440 px between x=260 and the
// banner's right edge. perChar is the rough glyph width at that size; runes
// from U+1100 on (CJK, emoji and the like) count double. Scaling the font,
// rather than setting textLength, never stretches text that already fits.
func fontSize(s string, size, perChar int) string {
	w := 0
	for _, r := range s {
		w += perChar
		if r >= 0x1100 {
			w += perChar
		}
	}
	if w > 440 {
		size = size * 440 / w
	}
	return itoa(size)
}

// ----- pills: tabs, badges, buttons -----

// Pills come in two heights: tabs, and chips (badges and buttons). gnoweb
// draws a 16 px icon on a linked image, 8 px from its left edge: images in
// a row get an 8 px margin, and the icon's center sits that far above the
// image's bottom edge. It lands on the center line of a chip about 16 px
// high, so chips are 17 px, with iconGap pixels left clear for it.
// External and $help links get the icon; tabs and the guestbook button
// link inside the realm's own namespace and don't.
const (
	tabH    = 26
	chipH   = 17
	iconGap = 30
)

// seg is one colored part of a pill.
type seg struct{ text, fill, ink string }

func segOn(s string) seg   { return seg{s, colBrand, "#fff"} }
func segSoft(s string) seg { return seg{s, colSoft, colDeep} }

// pillSVG draws a pill h pixels high from segments, left to right, with
// gap empty pixels before the first text. SVG can't measure text before
// drawing, so widths come from the rune count, wide runes (U+1100 on)
// counting double. The outline gives the pale parts an edge on a white
// page.
func pillSVG(h, gap int, segs ...seg) string {
	font, char := 11, 7
	if h == tabH {
		font, char = 13, 8
	}
	widths := make([]int, len(segs))
	w := gap
	for i, s := range segs {
		widths[i] = h // half a pill's height of padding on each side
		for _, r := range s.text {
			widths[i] += char
			if r >= 0x1100 {
				widths[i] += char
			}
		}
		w += widths[i]
	}
	mid := half(h)
	var sb strings.Builder
	sb.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="` + itoa(w) + `" height="` + itoa(h) + `" viewBox="0 0 ` + itoa(w) + ` ` + itoa(h) + `">`)
	sb.WriteString(`<clipPath id="c"><rect width="` + itoa(w) + `" height="` + itoa(h) + `" rx="` + mid + `"/></clipPath>`)
	sb.WriteString(`<g clip-path="url(#c)" font-family="` + fontUI + `" font-size="` + itoa(font) + `" font-weight="600" text-anchor="middle" dominant-baseline="central">`)
	x := 0
	for i, s := range segs {
		pad := 0
		if i == 0 {
			pad = gap
		}
		sb.WriteString(`<rect x="` + itoa(x) + `" width="` + itoa(pad+widths[i]) + `" height="` + itoa(h) + `" fill="` + s.fill + `"/>`)
		sb.WriteString(`<text x="` + itoa(x+pad+widths[i]/2) + `" y="` + mid + `" fill="` + s.ink + `">` + html.EscapeString(s.text) + `</text>`)
		x += pad + widths[i]
	}
	sb.WriteString(`</g><rect x=".5" y=".5" width="` + itoa(w-1) + `" height="` + itoa(h-1) + `" rx="` + half(h-1) + `" fill="none" stroke="` + colAccent + `"/></svg>`)
	return sb.String()
}

// half writes n/2 with its .5, for SVG coordinates.
func half(n int) string {
	if n%2 == 1 {
		return itoa(n/2) + ".5"
	}
	return itoa(n / 2)
}

// pillLink is a pill image linked to url, with alt text for screen readers.
func pillLink(alt, url string, h, gap int, segs ...seg) string {
	return "[" + svgImage(alt, pillSVG(h, gap, segs...)) + "](" + url + ")"
}

// badgesMD draws the badges as one paragraph. A new row starts after a
// hard line break (a backslash ending the line), so rows sit as close as
// wrapped ones.
func badgesMD() string {
	var sb strings.Builder
	for i, b := range badges {
		switch {
		case i > 0 && b.row:
			sb.WriteString("\\\n")
		case i > 0:
			sb.WriteString(" ")
		}
		sb.WriteString(pillLink(b.label+": "+b.value, b.url, chipH, iconGap, segSoft(b.label), segOn(b.value)))
	}
	return sb.String()
}

// ----- now, buttons -----

func nowMD() string {
	if now.text == "" {
		return ""
	}
	return "> [!SUCCESS] Now\n> " + now.text + " (block " + strconv.FormatInt(now.height, 10) + ")"
}

// button is a linked chip: the action, then its count. $help links get
// gnoweb's transaction icon, hence the gap.
func button(action, count, url string, gap int) string {
	return pillLink(action+", "+count, url, chipH, gap, segOn(action), segSoft(count))
}

func wavesMD() string {
	return button("Wave", plural(waves, "wave"), base+"$help&func=Wave", iconGap)
}

func tipMD() string {
	return button("Tip 1 GNOT", plural(tips.count, "tip"), base+"$help&func=Tip&.send="+tipSuggestion, iconGap)
}

// signMD counts hidden entries too: their authors did sign.
func signMD() string {
	return button("Sign the guestbook", plural(order.Size(), "signature"), tabURL(guestbookTab), 0)
}

// shortAddr keeps the ends of an address: g1jg8mtu…sqf5.
func shortAddr(a address) string {
	s := a.String()
	if len(s) < 16 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// userLink links an address to its profile page under its short form. The
// address comes from the chain, never from visitor text.
func userLink(a address) string {
	return "[" + shortAddr(a) + "](/u/" + a.String() + ")"
}

// ----- paging -----

// clampPage returns the page to show, at most the last one, and the last
// page for total items.
func clampPage(page, total int) (int, int) {
	last := (total + pageSize - 1) / pageSize
	if page > last {
		page = last
	}
	return page, last
}

// pageNav links the pages around page on tab: Newer, then Older.
func pageNav(tab string, page, last int) string {
	var nav []string
	if page > 1 {
		nav = append(nav, "[Newer]("+tabURL(tab)+"?page="+itoa(page-1)+")")
	}
	if page < last {
		nav = append(nav, "[Older]("+tabURL(tab)+"?page="+itoa(page+1)+")")
	}
	if len(nav) == 0 {
		return ""
	}
	return "\n" + strings.Join(nav, " · ") + "\n"
}

// ----- guestbook -----

const signForm = `<gno-form exec="Sign">
  <gno-input name="msg" type="text" placeholder="Say hi in 140 characters" required="true" />
</gno-form>`

// visitorText makes a stored message safe as one markdown list item.
// sanitize.InlineText escapes links, images, HTML and emphasis; the escaped
// @ and the &#103; entity for the g of g1 keep gnoweb from turning "@name"
// or a typed g1 address into a profile link. Neither replacement produces
// the other's pattern, so the order doesn't matter.
func visitorText(msg string) string {
	s := strings.ReplaceAll(sanitize.InlineText(msg), "@", `\@`)
	return strings.ReplaceAll(s, "g1", "&#103;1")
}

// guestbookMD shows the form and one page of entries, newest first. Hidden
// entries still count toward the offset, so a page can show fewer than 20.
func guestbookMD(page int) string {
	var sb strings.Builder
	sb.WriteString(signForm)
	sb.WriteString("\n\n")
	total := order.Size()
	if total == 0 {
		sb.WriteString("No entries yet.\n")
		return sb.String()
	}
	page, last := clampPage(page, total)
	order.ReverseIterateByOffset((page-1)*pageSize, pageSize, func(_ string, v any) bool {
		addr, _ := v.(address)
		e, ok := entries.Get(addr.String()).(*entry)
		if ok && !e.hidden { // Render never panics, even on a broken invariant
			sb.WriteString("- " + userLink(addr) + ": " + visitorText(e.msg) + "\n")
		}
		return false
	})
	sb.WriteString(pageNav(guestbookTab, page, last))
	return sb.String()
}

// ----- blog -----

// postList lists count posts from offset, newest first: one item each with
// the publish date as a code chip and the linked title.
func postList(offset, count int) string {
	var sb strings.Builder
	postOrder.ReverseIterateByOffset(offset, count, func(_ string, v any) bool {
		slug, _ := v.(string)
		if p, ok := posts.Get(slug).(*post); ok { // Render never panics, even on a broken invariant
			sb.WriteString("- `" + p.published + "` [" + sanitize.InlineText(p.title) + "](" + tabURL(blogTab) + "/" + slug + ")\n")
		}
		return false
	})
	return sb.String()
}

// blogMD lists one page of posts.
func blogMD(page int) string {
	total := postOrder.Size()
	if total == 0 {
		return "No posts yet.\n"
	}
	page, last := clampPage(page, total)
	return postList((page-1)*pageSize, pageSize) + pageNav(blogTab, page, last)
}

// postsMD is the Latest posts section, or nothing while there are no posts,
// so no empty heading shows.
func postsMD() string {
	if postOrder.Size() == 0 {
		return ""
	}
	return "## Latest posts\n\n" + postList(0, latestPosts) + "\n[All posts](" + tabURL(blogTab) + ")\n"
}

// postMD is a post's page. The body is shown as written: no tokens.
func postMD(p *post) string {
	date := p.published
	if p.edited != "" && p.edited != p.published {
		date += " · edited " + p.edited
	}
	return "# " + sanitize.InlineText(p.title) + "\n\n*" + date + "*\n\n" + p.body +
		"\n\n[All posts](" + tabURL(blogTab) + ")"
}
