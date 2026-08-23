package nsview

import (
	"encoding/base64"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// The NFT artwork and every piece of display formatting live here, in a
// realm that can be redeployed, rather than in the vault that cannot.
// nsdata.TokenURI points at this realm through a settable prefix.

// TokenURI returns the full data: URI for a token, generated on every
// read so the image always reflects current state (never baked at mint).
func TokenURI(tid string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(BuildSVG(tid)))
}

// BuildSVG renders a token. Everything on the card derives from four
// stored values — owner, registered, expires, and the domain's drawing —
// so a renewal moves `expires` and the bar, the time remaining and the
// years held all follow from it. Nothing is baked at mint: the card is
// generated on every read, which is what lets a domain's artwork be
// changed after its names have been sold.
func BuildSVG(tid string) string {
	var registered, expires int64 // unix seconds
	var streak int64
	var frozen bool
	var domainLabel string

	if strings.HasPrefix(tid, "*") {
		label := tid[1:]
		if !nsdata.DomainExists(label) {
			return placeholderSVG("unknown")
		}
		_, registered, expires, streak, frozen = nsdata.GetDomainInfo(label)
		domainLabel = label
	} else {
		label, dom := splitTokenID(tid)
		if !nsdata.NameExists(label, dom) {
			return placeholderSVG("unknown")
		}
		_, registered, expires, streak, frozen, _ = nsdata.GetNameInfo(label, dom)
		domainLabel = dom
	}

	now := time.Now().Unix()
	accent := domainAccent(domainLabel)
	status, edge := statusFields(expires, frozen)

	// The ribbon says something the rest of the card does not.
	// "DIAMOND HANDS" on a name minted this morning is a joke that lands
	// once; tied to tenure it is a thing you get TO.
	ribbon := status
	if status == "LIVE" {
		if streak >= 1 {
			ribbon = "DIAMOND HANDS"
		} else {
			ribbon = "FIRST YEAR"
		}
	}

	// The domain's drawing as a wash, centred: twelve cells at 26px is
	// 312 wide, so 44px of margin on every side.
	wash := spriteSVG(nsdata.GetDomainExtra(domainLabel, keyArt), 26, 44, 44, "0.12")

	// The bar is the whole term, filled by how much of it is left.
	span := expires - registered
	if span < 1 {
		span = 1
	}
	left := expires - now
	if left < 0 {
		left = 0
	}
	if left > span {
		left = span
	}
	fill := (308 * left) / span

	heldLabel := "YEARS HELD"
	if streak == 1 {
		heldLabel = "YEAR HELD"
	}

	return ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" role="img">
  <rect width="400" height="400" fill="#10101a"/>
  %s
  <rect x="12" y="12" width="376" height="376" rx="18" fill="none" stroke="%s" stroke-width="3"/>
  <text x="30" y="42" font-family="monospace" font-size="10" fill="%s" opacity="0.7">MINTED ON GNO.LAND</text>
  <text x="370" y="42" text-anchor="end" font-family="monospace" font-size="10" fill="%s" opacity="0.7">SINCE %s</text>
  <text x="200" y="196" text-anchor="middle" font-family="monospace" font-size="%d" font-weight="bold" fill="#ffffff">%s</text>
  <text x="200" y="224" text-anchor="middle" font-family="monospace" font-size="13" fill="%s">%s<animate attributeName="opacity" calcMode="discrete" values="1;0" keyTimes="0;0.5" dur="8s" repeatCount="indefinite"/></text>
  <text x="200" y="224" text-anchor="middle" font-family="monospace" font-size="13" fill="%s" opacity="0">%s<animate attributeName="opacity" calcMode="discrete" values="0;1" keyTimes="0;0.5" dur="8s" repeatCount="indefinite"/></text>
  <rect x="46" y="256" width="308" height="9" rx="4" fill="#ffffff" opacity="0.13"/>
  <rect x="46" y="256" width="%d" height="9" rx="4" fill="%s"/>
  <text x="46" y="282" font-family="monospace" font-size="9" fill="#ffffff" opacity="0.45">%s</text>
  <text x="354" y="282" text-anchor="end" font-family="monospace" font-size="9" fill="#ffffff" opacity="0.45">%s</text>
  <text x="200" y="326" text-anchor="middle" font-family="monospace" font-size="30" font-weight="bold" fill="#ffffff">%d</text>
  <text x="200" y="344" text-anchor="middle" font-family="monospace" font-size="9" fill="%s" opacity="0.8">%s</text>
  <text x="200" y="372" text-anchor="middle" font-family="monospace" font-size="12" font-weight="bold" fill="%s">%s</text>
  %s
</svg>`,
		wash, edge,
		accent, accent, time.Unix(registered, 0).UTC().Format("2006"),
		fitSize(tid), escapeXML(tid),
		accent, time.Unix(expires, 0).UTC().Format("Jan 2, 2006"),
		accent, remaining(expires, now),
		fill, edge,
		time.Unix(registered, 0).UTC().Format("Jan 2006"),
		time.Unix(expires, 0).UTC().Format("Jan 2006"),
		streak, accent, heldLabel,
		edge, ribbon,
		overlaySVG(now))
}

// fitSize solves for a size rather than stepping through a ladder.
// Monospace glyphs are ~0.6em, so a name up to the full 32-character
// limit sets on one line without overflowing 336px.
func fitSize(s string) int {
	n := len(s)
	if n < 1 {
		n = 1
	}
	size := 336 * 10 / (6 * n)
	if size > 34 {
		size = 34
	}
	if size < 11 {
		size = 11
	}
	return size
}

// domainAccent reads the accent out of the domain's stored drawing, so
// the card wears the domain's own colour without this realm carrying a
// palette of its own. Falls back to the house colour.
func domainAccent(domainLabel string) string {
	enc := nsdata.GetDomainExtra(domainLabel, keyArt)
	if len(enc) >= 8 && enc[1] == '#' && isHexColour(enc[1:8]) {
		return enc[1:8]
	}
	return "#5eead4"
}

func remaining(expires, now int64) string {
	if now >= expires {
		d := (now - expires) / daySeconds
		if d <= 0 {
			return "expired today"
		}
		if d == 1 {
			return "1 day past due"
		}
		return ufmt.Sprintf("%d days past due", d)
	}
	d := (expires - now) / daySeconds
	if d <= 0 {
		return "expires today"
	}
	if d == 1 {
		return "1 day remaining"
	}
	return ufmt.Sprintf("%d days remaining", d)
}

// keyArt is the per-domain extension key holding the drawing. The value
// is "A#facc15,B#7c2d12|............|....AAAA....|..." — the palette,
// then twelve rows of twelve characters where '.' is transparent.
//
// PARSED DEFENSIVELY AND NEVER TRUSTED. It is written by whichever logic
// realm is current, so a future one could store something malformed;
// anything unexpected yields no sprite rather than broken markup inside
// a token that a marketplace will render.
const keyArt = "art"

func spriteSVG(enc string, px, ox, oy int, opacity string) string {
	if enc == "" {
		return ""
	}
	parts := strings.Split(enc, "|")
	if len(parts) != 13 {
		return ""
	}
	// palette: "A#facc15,B#7c2d12"
	colours := map[string]string{}
	for _, entry := range strings.Split(parts[0], ",") {
		// key + "#" + six hex digits: "A#facc15" is EIGHT characters.
		// This read 7 and rejected every valid sprite; the test caught it.
		if len(entry) != 8 || entry[1] != '#' {
			return ""
		}
		key := entry[:1]
		hex := entry[1:]
		if !isHexColour(hex) {
			return ""
		}
		colours[key] = hex
	}
	var b strings.Builder
	for y := 1; y <= 12; y++ {
		row := parts[y]
		if len(row) != 12 {
			return ""
		}
		for x := 0; x < 12; x++ {
			ch := row[x : x+1]
			if ch == "." {
				continue
			}
			c, ok := colours[ch]
			if !ok {
				return ""
			}
			b.WriteString(ufmt.Sprintf(
				`<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>`,
				ox+(x*px), oy+((y-1)*px), px, px, c))
		}
	}
	if b.Len() == 0 {
		return ""
	}
	return `<g opacity="` + opacity + `">` + b.String() + `</g>`
}

func isHexColour(s string) bool {
	if len(s) != 7 || s[0] != '#' {
		return false
	}
	for i := 1; i < 7; i++ {
		c := s[i]
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') && !(c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func placeholderSVG(msg string) string {
	return ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">`+
		`<rect width="400" height="400" fill="#10101a"/>`+
		`<text x="200" y="200" text-anchor="middle" font-family="monospace" font-size="18" fill="#666680">%s</text></svg>`,
		escapeXML(msg))
}

// statusFields formats a lifecycle state for display. Reads the grace
// period from nsdata rather than hardcoding it, so retuning the lifecycle
// is a config change and this stays correct.
// All lifecycle times are unix seconds, so this is integer arithmetic
// over a day constant rather than duration division.
const daySeconds = int64(24 * 60 * 60)

func statusFields(expires int64, frozen bool) (status, edge string) {
	if frozen {
		return "FROZEN", "#8888aa"
	}
	now := time.Now().Unix()
	grace := nsdata.GetGracePeriod()
	switch {
	case now < expires:
		return "LIVE", "#4ade80"
	case now < expires+grace:
		return "GRACE PERIOD", "#facc15"
	default:
		return "LAPSED", "#f87171"
	}
}

func escapeXML(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	return s
}
