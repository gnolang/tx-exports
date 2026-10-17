package nsskin

import (
	"chain/runtime"
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nt/grc721/v0"
)

/*
WHAT A WALLET SHOWS FOR A SKIN.

Adena puts TokenURI(tid) straight into an <img src>, so it must return
the image itself, as a data URI, and it reads TokenMetadata as a camelCase
JSON string. The previous TokenURI returned a gnoweb path, which no wallet
can draw.

The picture is drawn HERE, from the definition's own sprite, rather than
by nsview: nsview imports this realm to put skins on name cards, so this
realm cannot import it back. It is the bare artwork on a dark matte —
nsview's matted shop card stays the gnoweb page, linked as externalUrl.
This realm is replaceable, so a richer wallet image is a redeploy away.

A WITHDRAWN SKIN DRAWS NOTHING. Withdrawal is the takedown control
(SKINS.md §6): a design that turns out to be somebody else's character or
something vile must stop appearing in wallets with our name beside it the
moment it is withdrawn. So its image is a neutral placeholder, its
metadata omits its name and link, and nothing else about the token
changes — the holder keeps it.
*/

// TokenURI is the skin's image, as a data URI, for a token that exists.
func TokenURI(tid grc721.TokenID) (string, error) {
	if _, err := token.OwnerOf(tid); err != nil {
		return "", err
	}
	s, ok := skinOfTID(string(tid))
	if !ok {
		return placeholderImage("UNKNOWN SKIN"), nil
	}
	if s.withdrawn {
		return placeholderImage("WITHDRAWN"), nil
	}
	if svg, ok := spriteSVG(s.art); ok {
		return dataURI(svg), nil
	}
	return placeholderImage("ART WILL NOT RENDER"), nil
}

// TokenMetadata is the skin's metadata as a camelCase JSON string: name,
// description, externalUrl and attributes of {traitType, value}. No image
// in it; that is TokenURI.
func TokenMetadata(tid grc721.TokenID) (string, error) {
	if _, err := token.OwnerOf(tid); err != nil {
		return "", err
	}
	t := string(tid)
	id, serial := t, ""
	if h := strings.LastIndex(t, "#"); h > 0 {
		id, serial = t[:h], t[h+1:]
	}
	s, ok := skinOfTID(t)
	if !ok || s.withdrawn {
		return `{"name":"Withdrawn skin #` + escapeJSON(serial) + `",` +
			`"description":"This skin has been withdrawn and no longer draws on any name.",` +
			`"attributes":[{"traitType":"Skin","value":"` + escapeJSON(id) + `"},` +
			`{"traitType":"Status","value":"withdrawn"}]}`, nil
	}
	goesOn := "any name"
	if s.lock != "" {
		goesOn = "*" + s.lock + " names"
	}
	worn := "no"
	if bindingIsLive(t) {
		b := bound.Get(t).(*binding)
		worn = b.label + "*" + b.domain
	}
	out := `{"name":"` + escapeJSON(s.name) + ` #` + escapeJSON(serial) + `",` +
		`"description":"Card art for a Meme Name Service name. Wear it and it travels with the name.",`
	if u := externalURL(t); u != "" {
		out += `"externalUrl":"` + escapeJSON(u) + `",`
	}
	out += `"attributes":[` +
		`{"traitType":"Skin","value":"` + escapeJSON(id) + `"},` +
		`{"traitType":"Edition","value":"` + escapeJSON(serial) + `"},` +
		`{"traitType":"Goes on","value":"` + escapeJSON(goesOn) + `"},` +
		`{"traitType":"Worn by","value":"` + escapeJSON(worn) + `"}]}`
	return out, nil
}

func skinOfTID(tid string) (*skin, bool) {
	id, ok := skinOfToken(tid)
	if !ok {
		return nil, false
	}
	v := skins.Get(strings.ToLower(strings.TrimSpace(id)))
	if v == nil {
		return nil, false
	}
	return v.(*skin), true
}

// externalURL is the skin's own page: tokenURIBase plus the token id, on
// the chain's gnoweb when the base is a path. "#" would start a URL
// fragment, so it is escaped.
func externalURL(tid string) string {
	esc := strings.ReplaceAll(tid, "#", "%23")
	switch {
	case strings.HasPrefix(tokenURIBase, "https://"):
		return tokenURIBase + esc
	case strings.HasPrefix(tokenURIBase, "/"):
		return "https://" + runtime.ChainDomain() + tokenURIBase + esc
	}
	return ""
}

/*
spriteSVG draws the sprite format DefineSkin validates ("A#rrggbb,..|row|row")
as one rect per horizontal run, on a dark matte. It re-checks every rule
assertValidArt applies rather than trusting that it ran, and refuses the
whole sprite on any fault — a picture with holes in it is worse than an
honest placeholder. Colours are emitted only after they are checked to be
exactly # and six hex digits, so nothing from the definition reaches the
SVG unvalidated.
*/
func spriteSVG(art string) (string, bool) {
	parts := strings.Split(art, "|")
	n := len(parts) - 1
	if n < 4 || n > 64 {
		return "", false
	}
	pal := map[byte]string{}
	for _, e := range strings.Split(parts[0], ",") {
		if len(e) != 8 || e[1] != '#' || !isHex6(e[2:]) {
			return "", false
		}
		pal[e[0]] = e[1:]
	}
	size := strconv.Itoa(n)
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ` + size + ` ` + size +
		`" shape-rendering="crispEdges"><rect width="` + size + `" height="` + size + `" fill="#0b0d10"/>`)
	for y := 0; y < n; y++ {
		row := parts[y+1]
		if len(row) != n {
			return "", false
		}
		for x := 0; x < n; {
			c := row[x]
			if c == '.' {
				x++
				continue
			}
			col, ok := pal[c]
			if !ok {
				return "", false
			}
			x0 := x
			for x < n && row[x] == c {
				x++
			}
			b.WriteString(`<rect x="` + strconv.Itoa(x0) + `" y="` + strconv.Itoa(y) +
				`" width="` + strconv.Itoa(x-x0) + `" height="1" fill="` + col + `"/>`)
		}
	}
	b.WriteString(`</svg>`)
	return b.String(), true
}

func isHex6(s string) bool {
	if len(s) != 6 {
		return false
	}
	for i := 0; i < 6; i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
			continue
		}
		return false
	}
	return true
}

func placeholderImage(msg string) string {
	return dataURI(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">` +
		`<rect width="400" height="400" fill="#0b0d10"/>` +
		`<rect x="40" y="40" width="320" height="320" fill="none" stroke="#3f3f46" stroke-width="2" stroke-dasharray="7 6"/>` +
		`<text x="200" y="206" text-anchor="middle" font-family="monospace" font-size="16" fill="#a1a1aa">` +
		escapeXML(msg) + `</text></svg>`)
}

func dataURI(svg string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

func escapeXML(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	s = strings.ReplaceAll(s, "'", "&apos;")
	return s
}

func escapeJSON(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c < 0x20:
			const hex = "0123456789abcdef"
			b.WriteString(`\u00`)
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&0xf])
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}
