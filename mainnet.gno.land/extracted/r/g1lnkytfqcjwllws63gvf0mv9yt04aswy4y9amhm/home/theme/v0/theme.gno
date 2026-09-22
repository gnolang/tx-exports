// Package theme is the first look of gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home.
//
// It draws a header card as inline SVG, a divider and a footer, on top of the
// slot machinery the home realm provides. Everything else on the page comes
// from slots, so this file only decides HOW things are drawn, never WHAT is
// said.
//
// It is a candidate, not the page. Deploying it registers it (see init); the
// authority accepts it in a separate transaction. To change the look in a way
// slots and style knobs cannot express, copy this directory to theme/v1, edit,
// deploy, Accept. The home realm and every slot stay exactly where they are.
//
// Style knobs read from slots (all optional):
//
//	style.accent  #RRGGBB   brass by default
//	style.bg      #RRGGBB   card background
//	style.fg      #RRGGBB   card text
//	style.header  card | plain | none
//
// Widgets this theme adds to the layout, beside every slot and the home
// realm's computed placeholders:
//
//	:header:   the card (or a plain heading, or nothing, per style.header)
//	:divider:  a thin accent rule
//	:footer:   realm · revision · block · chain · theme · links
package theme

import (
	"encoding/base64"
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home"
)

const (
	defaultAccent = "#D9A441"
	defaultBg     = "#14161C"
	defaultFg     = "#F4EFE6"
)

// DefaultLayout is what renders when no layout slot is set. content/layout.md
// starts as a copy of it; push that slot to depart from it.
const DefaultLayout = `:header:

<gno-columns>
![Clockwork](https://avatars.githubusercontent.com/u/6826762?s=400)
<gno-columns-sep />
:intro:

:links:
</gno-columns>

## Now

:now:

## Previously

:previously:

## Stack

:stack:

## Before the rabbit hole

:before:

## Numbers

:numbers:

:divider:

:about:

:footer:
`

type clockwork struct{}

var instance = &clockwork{}

// Instance returns the theme object, for a caller that would rather register
// it explicitly than rely on this realm's init having done it.
func Instance() home.Theme { return instance }

// init nominates this theme. Deploying is what registers it; it serves
// nothing until the authority runs Accept("<this path>").
func init(cur realm) {
	home.Register(cross(cur), instance)
}

// Render draws the profile page and hands every other path to the built-in
// views, so the editor and the system page look the same under any theme.
func (clockwork) Render(path string) string {
	if path != "" {
		return home.Fallback(path)
	}
	layout := home.Layout()
	if layout == "" {
		layout = DefaultLayout
	}
	f := home.NewFiller()
	f.Add("header", header)
	f.Add("divider", divider)
	f.Add("footer", footer)
	return f.Fill(layout)
}

// ---------------------------------------------------------------------------
// Widgets

func header() string {
	name := home.Get("name")
	if name == "" {
		name = home.Path()
	}
	tagline := home.Get("tagline")
	switch home.Style("header", "card") {
	case "none":
		return ""
	case "plain":
		out := "# " + name + "\n"
		if tagline != "" {
			out += "\n_" + tagline + "_\n"
		}
		return out
	}
	meta := home.Get("handle")
	if meta != "" {
		meta += " · "
	}
	meta += "rev " + strconv.Itoa(home.Revision()) +
		" · block " + strconv.FormatInt(runtime.ChainHeight(), 10)
	return image(name, card(name, tagline, meta))
}

func divider() string {
	accent := color("accent", defaultAccent)
	svg := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 10" width="1200" height="10">` +
		`<defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="` + accent + `"/>` +
		`<stop offset="1" stop-color="` + accent + `" stop-opacity="0"/></linearGradient></defs>` +
		`<rect width="1200" height="10" rx="5" fill="url(#g)"/></svg>`
	return image("", svg)
}

func footer() string {
	theme := home.LivePath()
	if theme == "" {
		theme = "built-in"
	}
	return "`" + home.Path() + "` · rev " + strconv.Itoa(home.Revision()) +
		" · block " + strconv.FormatInt(runtime.ChainHeight(), 10) +
		" · " + runtime.ChainID() +
		" · theme `" + theme + "`" +
		" · [slots](" + home.Link("slots") + ")" +
		" · [edit](" + home.Link("edit") + ")" +
		" · [system](" + home.Link("system") + ")"
}

// ---------------------------------------------------------------------------
// SVG

// card draws the header: name, tagline and a meta line on a rounded panel,
// with a gear on the right. Text is clipped, not wrapped, so keep the
// tagline to one line.
func card(name, tagline, meta string) string {
	accent := color("accent", defaultAccent)
	bg := color("bg", defaultBg)
	fg := color("fg", defaultFg)

	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 300" width="1200" height="300" role="img" aria-label="`)
	b.WriteString(esc(name))
	b.WriteString(`"><defs><clipPath id="c"><rect width="1200" height="300" rx="24"/></clipPath>`)
	b.WriteString(`<clipPath id="t"><rect x="64" y="30" width="820" height="250"/></clipPath></defs>`)
	b.WriteString(`<g clip-path="url(#c)">`)
	b.WriteString(`<rect width="1200" height="300" fill="` + bg + `"/>`)
	b.WriteString(`<rect width="14" height="300" fill="` + accent + `"/>`)
	// The gear: a thick dashed ring reads as teeth without a single path command.
	b.WriteString(`<g transform="translate(1030 150)" fill="none" stroke="` + accent + `" opacity="0.9">`)
	b.WriteString(`<circle r="82" stroke-width="30" stroke-dasharray="21 15.8"/>`)
	b.WriteString(`<circle r="42" stroke-width="12"/>`)
	b.WriteString(`<circle r="11" fill="` + accent + `" stroke="none"/>`)
	b.WriteString(`</g>`)
	b.WriteString(`<g clip-path="url(#t)" fill="` + fg + `" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif">`)
	b.WriteString(`<text x="64" y="132" font-size="76" font-weight="700">` + esc(name) + `</text>`)
	if tagline != "" {
		b.WriteString(`<text x="64" y="188" font-size="30" opacity="0.85">` + esc(tagline) + `</text>`)
	}
	b.WriteString(`<text x="64" y="246" font-size="24" fill="` + accent + `" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace">` + esc(meta) + `</text>`)
	b.WriteString(`</g></g></svg>`)
	return b.String()
}

// image wraps an SVG document as a markdown image with a data: URI. gnoweb
// rejects every data: image except image/svg+xml, and gno.land's CSP allows
// data: in img-src, so this is the one way to draw without hosting anything.
func image(alt, svg string) string {
	alt = strings.NewReplacer("[", "", "]", "", "\n", " ").Replace(alt)
	return "![" + alt + "](data:image/svg+xml;base64," +
		base64.StdEncoding.EncodeToString([]byte(svg)) + ")"
}

// color returns the style knob when it is a well-formed #RRGGBB, else the
// default. Knobs are admin-written, but a value is still pasted into markup,
// so the shape is checked rather than trusted.
func color(key, fallback string) string {
	v := home.Style(key, fallback)
	if isHexColor(v) {
		return v
	}
	return fallback
}

func isHexColor(s string) bool {
	if len(s) != 7 || s[0] != '#' {
		return false
	}
	for i := 1; i < 7; i++ {
		c := s[i]
		switch {
		case c >= '0' && c <= '9', c >= 'a' && c <= 'f', c >= 'A' && c <= 'F':
		default:
			return false
		}
	}
	return true
}

// esc escapes text for an SVG element body or attribute.
func esc(s string) string {
	return strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		"\"", "&quot;",
		"\n", " ",
	).Replace(s)
}
