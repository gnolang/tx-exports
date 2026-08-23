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

func BuildSVG(tid string) string {
	var expires int64 // unix seconds
	var streak int64
	var frozen bool
	var domainLabel string

	if strings.HasPrefix(tid, "*") {
		label := tid[1:]
		if !nsdata.DomainExists(label) {
			return placeholderSVG("unknown")
		}
		_, _, expires, streak, frozen = nsdata.GetDomainInfo(label)
		domainLabel = label
	} else {
		label, dom := splitTokenID(tid)
		if !nsdata.NameExists(label, dom) {
			return placeholderSVG("unknown")
		}
		_, _, expires, streak, frozen, _ = nsdata.GetNameInfo(label, dom)
		domainLabel = dom
	}

	// The domain's drawing, if it is carrying one. Stored as data in the
	// vault's extension slot rather than compiled into this realm, so a
	// new domain or a new picture is one transaction and never a redeploy
	// of this file. A domain with no `art` key simply renders without a
	// sprite, so writing the artwork is optional and can lag behind
	// registration.
	sprite := spriteSVG(nsdata.GetDomainExtra(domainLabel, keyArt), 9, 146, 62)

	status, statusColor, daysLine := statusFields(expires)
	if frozen {
		status, statusColor = "FROZEN", "#8888aa"
	}

	return ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  <rect width="400" height="400" fill="#10101a"/>
  %s
  <rect x="12" y="12" width="376" height="376" rx="16" fill="none" stroke="%s" stroke-width="3"/>
  <text x="200" y="170" text-anchor="middle" font-family="monospace" font-size="30" font-weight="bold" fill="#ffffff">%s</text>

  <text x="200" y="215" text-anchor="middle" font-family="monospace" font-size="16" fill="#cccccc">
    <tspan>%s</tspan>
    <animate attributeName="opacity" values="1;1;0;0" keyTimes="0;0.499;0.5;1" dur="10s" repeatCount="indefinite"/>
  </text>
  <text x="200" y="215" text-anchor="middle" font-family="monospace" font-size="16" fill="#cccccc" opacity="0">
    <tspan>%s</tspan>
    <animate attributeName="opacity" values="0;0;1;1" keyTimes="0;0.499;0.5;1" dur="10s" repeatCount="indefinite"/>
  </text>

  <text x="200" y="245" text-anchor="middle" font-family="monospace" font-size="13" fill="#999999">%s</text>
  <text x="200" y="270" text-anchor="middle" font-family="monospace" font-size="13" fill="#999999">%d yr streak</text>
  <text x="200" y="360" text-anchor="middle" font-family="monospace" font-size="15" font-weight="bold" fill="%s">%s</text>
</svg>`,
		sprite, statusColor, escapeXML(tid),
		time.Unix(expires, 0).UTC().Format("2006-01-02"),
		time.Unix(expires, 0).UTC().Format("Jan 2, 2006"),
		daysLine, streak, statusColor, status)
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

func spriteSVG(enc string, px, ox, oy int) string {
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
	return b.String()
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
// All lifecycle times are unix seconds now, so this is integer
// arithmetic over a day constant rather than duration division.
const daySeconds = int64(24 * 60 * 60)

func statusFields(expires int64) (status, color, daysLine string) {
	now := time.Now().Unix()
	grace := nsdata.GetGracePeriod()
	switch {
	case now < expires:
		return "VALID", "#4ade80", ufmt.Sprintf("%d days left", (expires-now)/daySeconds)
	case now < expires+grace:
		return "GRACE PERIOD", "#facc15", ufmt.Sprintf("%d days to reclaim", (expires+grace-now)/daySeconds)
	default:
		return "EXPIRED", "#f87171", "available to register"
	}
}

func escapeXML(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	return s
}
