package home

import (
	"encoding/base64"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// This file is shared, unchanged, by every Samouraï home realm.
//
// A gallery is a named list of cards. gnoweb's CSP only paints images from a
// few hosts (YouTube thumbnails are not among them) but it allows
// data:image/svg+xml, so every card is a poster drawn here, on chain, and
// linked to its video or site.
//
// A gallery is written in one Set-like call as lines of
//
//	kind | title | meta | url [| description]
//
// The optional description becomes the card's hover text.
// and rendered wherever the layout says :gallery.<name>:.

const (
	galleryPrefix = "gallery."
	cardsPerRow   = 3
	maxCards      = 48
	maxTitleLen   = 80
	maxMetaLen    = 80
	maxDescLen    = 200
)

type card struct {
	kind, title, meta, url string
	desc                   string // hover text, optional
	label                  string // overrides the kind's label when set
}

var galleries = avl.NewTree() // name -> []card

type style struct {
	label, glyph, accent, shade string
	video                       bool
}

var styles = map[string]style{
	"report":        {"CONTRIBUTION REPORT", "報", "#e63946", "#3a1014", true},
	"gno":           {"GNO.LAND · FILMED BY SAMOURAÏ", "道", "#2ec4b6", "#0d2e2b", true},
	"webtrip":       {"WEB TRIP · SERIES", "旅", "#ff7aa2", "#3a1422", true},
	"peerdev":       {"PEER DEV · GNO TUTORIAL", "学", "#4ea8de", "#0f2536", true},
	"event":         {"EVENT", "祭", "#f4a261", "#3a2412", true},
	"festival":      {"FESTIVAL · BY SAMOURAÏ", "祭", "#f4a261", "#3a2412", false},
	"film":          {"FILM · DIRECTED BY THE CREW", "映", "#b388eb", "#261a36", true},
	"product":       {"PRODUCT", "作", "#e9c46a", "#352b10", false},
	"memba":         {"MEMBA · PRODUCT", "組", "#e9c46a", "#352b10", false},
	"game":          {"ARCADE · PLAY IN MEMBA", "遊", "#8ac926", "#1c2a0b", true},
	"oss":           {"OPEN SOURCE · GITHUB", "源", "#a8b3bd", "#1b2026", false},
	"blog":          {"BLOG · SAMOURAI.WORLD", "記", "#e8e2d8", "#2a2620", false},
	"member":        {"SAMOURAÏ · CREW", "侍", "#e63946", "#2a1012", false},
	"member-media":  {"SAMOURAÏ · MEDIA", "映", "#b388eb", "#261a36", false},
	"member-alumni": {"SAMOURAÏ · ALUMNI", "侍", "#9aa0a6", "#1d1f22", false},
}

func styleOf(kind string) style {
	if s, ok := styles[kind]; ok {
		return s
	}
	return style{strings.ToUpper(kind), "侍", "#e63946", "#2a1012", false}
}

// SetGallery replaces a whole gallery from its line format.
func SetGallery(cur realm, name, spec string) {
	assertAdmin(cur)
	if !validSlug(name) {
		panic("invalid gallery name: " + name)
	}
	cards := parseGallery(spec)
	rev++
	galleries.Set(name, cards)
}

// DeleteGallery removes a gallery.
func DeleteGallery(cur realm, name string) {
	assertAdmin(cur)
	if _, removed := galleries.Remove(name); !removed {
		panic("no such gallery: " + name)
	}
	rev++
}

func parseGallery(spec string) []card {
	var cards []card
	for _, line := range strings.Split(spec, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "|")
		if len(f) != 4 && len(f) != 5 {
			panic("gallery line needs 4 or 5 fields (kind | title | meta | url [| description]): " + line)
		}
		c := card{
			kind:  strings.TrimSpace(f[0]),
			title: strings.TrimSpace(f[1]),
			meta:  strings.TrimSpace(f[2]),
			url:   strings.TrimSpace(f[3]),
		}
		if len(f) == 5 {
			c.desc = strings.TrimSpace(f[4])
			if len(c.desc) > maxDescLen || strings.ContainsAny(c.desc, "\"\\") {
				panic("gallery description must be at most 200 bytes, without quotes or backslashes: " + line)
			}
		}
		if !validSlug(c.kind) || c.title == "" || len(c.title) > maxTitleLen || len(c.meta) > maxMetaLen {
			panic("bad gallery line: " + line)
		}
		if !strings.HasPrefix(c.url, "https://") && (!strings.HasPrefix(c.url, "/") || strings.HasPrefix(c.url, "//")) {
			panic("gallery url must be https:// or a /path: " + c.url)
		}
		if strings.ContainsAny(c.url, " ()<>\"\\") {
			panic("gallery url has characters markdown would break on: " + c.url)
		}
		cards = append(cards, c)
	}
	if len(cards) == 0 || len(cards) > maxCards {
		panic("a gallery holds 1 to 48 cards")
	}
	return cards
}

// renderGallery lays cards out cardsPerRow to a row, each one a poster that
// links to its target.
func renderGallery(name string) (string, bool) {
	v := galleries.Get(name)
	if v == nil {
		return "", false
	}
	cards := v.([]card)
	var b strings.Builder
	for i := 0; i < len(cards); i += cardsPerRow {
		b.WriteString("<gno-columns>\n")
		for j := i; j < i+cardsPerRow; j++ {
			if j > i {
				b.WriteString("<gno-columns-sep />\n")
			}
			if j < len(cards) {
				c := cards[j]
				b.WriteString("[![" + mdText(c.title) + "](" + posterURI(c) + ")](" + c.url + linkTitle(c.desc) + ")\n")
			}
		}
		b.WriteString("</gno-columns>\n\n")
	}
	return strings.TrimSuffix(b.String(), "\n\n"), true
}

// linkTitle renders an optional markdown link title, which gnoweb emits as
// the link's hover text.
func linkTitle(desc string) string {
	if desc == "" {
		return ""
	}
	return ` "` + desc + `"`
}

// mdText keeps a title from closing the markdown image alt text early.
func mdText(s string) string {
	return strings.NewReplacer("[", "(", "]", ")", "\\", "/").Replace(s)
}

func xmlText(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;", "'", "&#39;").Replace(s)
}

// wrap splits s into at most two lines of about width runes; the second line
// is cut with an ellipsis when the title is longer.
func wrap(s string, width int) []string {
	words := strings.Fields(s)
	var lines []string
	cur := ""
	for _, w := range words {
		if cur == "" {
			cur = w
		} else if runeLen(cur)+1+runeLen(w) <= width {
			cur += " " + w
		} else {
			lines = append(lines, cur)
			cur = w
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	if len(lines) > 2 {
		second := []rune(strings.Join(lines[1:], " "))
		if len(second) > width {
			second = append(second[:width-1], '…')
		}
		lines = []string{lines[0], string(second)}
	}
	return lines
}

func runeLen(s string) int { return len([]rune(s)) }

// clip cuts s to at most n runes, ending with an ellipsis when it had to cut.
func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(append(r[:n-1], '…'))
}

func posterURI(c card) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(poster(c)))
}

// poster draws a 320x180 card: a dark gradient, a rising sun in the kind's
// accent (a play button for videos), a large kanji watermark, the kind label,
// the title on up to two lines and a meta line.
func poster(c card) string {
	st := styleOf(c.kind)
	if c.label != "" {
		st.label = c.label
	}
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180">`)
	b.WriteString(`<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#121212"/><stop offset="1" stop-color="` + st.shade + `"/></linearGradient></defs>`)
	b.WriteString(`<rect width="320" height="180" rx="14" fill="url(#g)"/>`)
	b.WriteString(`<text x="306" y="170" text-anchor="end" font-family="serif" font-size="120" fill="#ffffff" fill-opacity=".06">` + st.glyph + `</text>`)
	b.WriteString(`<circle cx="268" cy="52" r="30" fill="` + st.accent + `"/>`)
	if st.video {
		b.WriteString(`<path d="M260 38 L282 52 L260 66 Z" fill="#121212"/>`)
	} else {
		b.WriteString(`<path d="M256 52 H280 M272 44 L280 52 L272 60" stroke="#121212" stroke-width="4" fill="none" stroke-linecap="round" stroke-linejoin="round"/>`)
	}
	b.WriteString(`<rect x="18" y="20" width="3" height="12" fill="` + st.accent + `"/>`)
	b.WriteString(`<text x="27" y="31" font-family="ui-monospace,Menlo,monospace" font-size="10" letter-spacing="1.5" fill="` + st.accent + `">` + xmlText(st.label) + `</text>`)
	lines := wrap(c.title, 24)
	y := 108
	if len(lines) == 1 {
		y = 126
	}
	for _, l := range lines {
		b.WriteString(`<text x="18" y="` + itoa(y) + `" font-family="system-ui,-apple-system,Segoe UI,sans-serif" font-weight="700" font-size="20" fill="#ffffff">` + xmlText(l) + `</text>`)
		y += 25
	}
	// The meta line hugs the bottom-right corner: gnoweb draws its
	// external-link badge over the bottom-left one.
	b.WriteString(`<text x="304" y="164" text-anchor="end" font-family="ui-monospace,Menlo,monospace" font-size="11" fill="#bdbdbd">` + xmlText(clip(c.meta, 40)) + `</text>`)
	b.WriteString(`</svg>`)
	return b.String()
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var d []byte
	for n > 0 {
		d = append([]byte{byte('0' + n%10)}, d...)
		n /= 10
	}
	return string(d)
}
