package nsview

import (
	"encoding/base64"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsdata/v1"
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
	// The three vault reads happen HERE, not inside cardSVG. That is what
	// leaves the card itself a pure function of its inputs, which is what
	// lets a test assert what a marketplace will show without standing up
	// a registry to do it.
	// A SKIN REPLACES THE CARD, so it is decided before anything is read
	// from the vault for drawing one. The ordinary path is untouched on
	// every other day of the year.
	/* A BOUGHT SKIN BEATS THE CALENDAR, and that ordering is a
	   decision rather than an accident. The calendar skin is a gift
	   everybody gets on the same day; a worn skin is a thing somebody
	   paid for and chose. On the two or three days a year they collide,
	   the one that was bought wins.

	   Only NAMES can wear one. A domain token has no owner to bind to
	   and no shop entry, so it takes the calendar path as before. */
	if !strings.HasPrefix(tid, "*") {
		label, dom := splitTokenID(tid)
		if art := wornArt(label, dom); art != "" {
			if card := skinnedCardSVG(art, label, dom, expires); card != "" {
				return card
			}
			// An unrenderable sprite falls through to the ordinary card
			// rather than returning nothing: a blank token is worse than
			// an unskinned one, and the holder still owns the name.
		}
	}

	if sk := skinFor(now); sk != "" && hasSkin(sk) {
		return skinSVG(sk, tid, now)
	}

	art := nsdata.GetDomainExtra(domainLabel, keyArt)
	return cardSVG(tid, art, registered, expires, streak, frozen, now, overlaySVG(now))
}

// cardSVG is the card itself, with every stored value already resolved.
// Split out from BuildSVG so the markup can be rendered — and asserted
// against — without a vault under it. TestStaticFrameShowsTheDate is the
// reason: what a marketplace shows as a still is a property of this
// string and of nothing else, and it deserves to be checked rather than
// assumed.
func cardSVG(tid, art string, registered, expires, streak int64, frozen bool, now int64, overlay string) string {
	accent := accentOf(art)
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
	//
	// 0.07, not 0.12. At 0.12 a bright sprite competed with the name
	// sitting on top of it — the eye landed on the picture first and had
	// to hunt for the type. A wash should be felt rather than read.
	wash := spriteSVG(art, 26, 44, 44, "0.07")

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

	/* ---- SAYING IT IS DEAD, LOUDLY ----
	 *
	 * A lapsed card and a live card differed by a border colour and one
	 * word in 12px type at the very bottom. In a wallet's grid they read
	 * as the same purple card — for the one fact that changes what you
	 * can DO with the token: an expired name cannot be sold, cannot be
	 * transferred, and is about to belong to somebody else.
	 *
	 * A wash over the whole card in the status colour, and the status
	 * word on a filled band at nearly twice the size. The band sits at
	 * y=352 because the tenure caption is at 344 and a taller band ate
	 * it; a card that shouts LAPSED and hides how long somebody held it
	 * has traded one fact for another rather than adding one.
	 *
	 * A LIVE CARD IS UNTOUCHED. This must not make the ordinary case
	 * noisier — that is the card somebody paid for.
	 *
	 * Mirrored byte-for-byte in the site's nft.js. If this changes, that
	 * changes, or a preview stops matching what the chain draws. */
	metalDefs, frameStroke, frameWidth := metalFrame(tid, status, edge, streak)

	statusWash, statusBand := "", ""
	if status == "GRACE PERIOD" || status == "LAPSED" {
		washOp := "0.13"
		if status == "LAPSED" {
			washOp = "0.17"
		}
		statusWash = ufmt.Sprintf(
			`<rect width="400" height="400" fill="%s" opacity="%s"/>`, edge, washOp)
		statusBand = ufmt.Sprintf(
			`<rect x="12" y="352" width="376" height="36" fill="%s" opacity="0.92"/>`+
				`<rect x="12" y="352" width="376" height="36" fill="none" stroke="%s" stroke-width="3"/>`+
				`<text x="200" y="378" text-anchor="middle" font-family="monospace" `+
				`font-size="20" font-weight="bold" fill="#1b1200">%s</text>`,
			edge, edge, ribbon)
	}

	body := ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" role="img">
  %s<rect width="400" height="400" fill="#10101a"/>
  %s%s
  <rect x="12" y="12" width="376" height="376" rx="18" fill="none" stroke="%s" stroke-width="%s"/>
  <text x="30" y="42" font-family="monospace" font-size="10" fill="%s" opacity="0.7">MINTED ON GNO.LAND</text>
  <text x="370" y="42" text-anchor="end" font-family="monospace" font-size="10" fill="%s" opacity="0.7">SINCE %s</text>
  <text x="200" y="196" text-anchor="middle" font-family="monospace" font-size="%d" font-weight="bold" fill="#ffffff">%s</text>
  <!-- THE STATIC FRAME. A marketplace showing this token as a still
       gets whichever of these two lines is visible with no animation
       running, and that MUST be the date. Everything that matters about
       a name at a glance -- is it live, is it expired, when does it go
       -- is in the date; "412 days left" frozen into a thumbnail is a
       number that was true once and is a lie thereafter.

       It works out that way under both kinds of renderer, which is why
       it is written like this and not any other way:

         a renderer that IGNORES SMIL uses the base attribute in the
         markup, so the date's opacity="1" and the counter's opacity="0"
         decide it

         a renderer that HONOURS SMIL and seeks to t=0 uses the first
         keyTime, so the date's values="1;0" and the counter's "0;1"
         decide it

       Both must keep agreeing. Reorder these two lines, or drop an
       explicit opacity, and the still becomes a countdown -- with
       nothing failing and nothing to notice until a card in somebody
       else's gallery says a name has 412 days left three years from
       now. Guarded by TestStaticFrameShowsTheDate. -->
  <text x="200" y="224" text-anchor="middle" font-family="monospace" font-size="13" fill="%s" opacity="1">%s<animate attributeName="opacity" calcMode="discrete" values="1;0" keyTimes="0;0.5" dur="8s" repeatCount="indefinite"/></text>
  <text x="200" y="224" text-anchor="middle" font-family="monospace" font-size="13" fill="%s" opacity="0">%s<animate attributeName="opacity" calcMode="discrete" values="0;1" keyTimes="0;0.5" dur="8s" repeatCount="indefinite"/></text>
  <rect x="46" y="256" width="308" height="9" rx="4" fill="#ffffff" opacity="0.13"/>
  <rect x="46" y="256" width="%d" height="9" rx="4" fill="%s"/>
  <text x="46" y="282" font-family="monospace" font-size="9" fill="#ffffff" opacity="0.45">%s</text>
  <text x="354" y="282" text-anchor="end" font-family="monospace" font-size="9" fill="#ffffff" opacity="0.45">%s</text>
  <text x="200" y="326" text-anchor="middle" font-family="monospace" font-size="30" font-weight="bold" fill="#ffffff">%d</text>
  <text x="200" y="344" text-anchor="middle" font-family="monospace" font-size="9" fill="%s" opacity="0.8">%s</text>
  %s
  %s
</svg>`,
		metalDefs, wash, statusWash, frameStroke, frameWidth,
		accent, accent, time.Unix(registered, 0).UTC().Format("2006"),
		fitSize(tid), escapeXML(tid),
		accent, time.Unix(expires, 0).UTC().Format("Jan 2, 2006"),
		accent, remaining(expires, now),
		fill, edge,
		time.Unix(registered, 0).UTC().Format("Jan 2006"),
		time.Unix(expires, 0).UTC().Format("Jan 2006"),
		streak, accent, heldLabel,
		smallRibbon(status, edge, ribbon, statusBand),
		overlay)

	/* ---- GRACE AND LAPSED, LAYERED ON TOP ----
	 *
	 * Both branch OUT of `body` rather than building their own copy of
	 * it, on purpose: `body` above is untouched from before this pair of
	 * treatments existed, so a LIVE or FROZEN card -- the two states
	 * that are not supposed to change AT ALL -- takes neither branch and
	 * returns exactly the string it always returned. TestCardUnchangedForLiveAndFrozen
	 * pins that down against a captured pre-change baseline, which is a
	 * stronger guarantee than "I re-read the template and it looks
	 * right" for a template this dense.
	 *
	 * LAPSED only needs one more thing drawn on top, so it is one
	 * strings.Replace of the closing tag.
	 *
	 * GRACE needs three pieces of `body` re-wrapped in place -- the art
	 * wash, the frame-and-header block, and the term bar -- while the
	 * status band and the date line in between are left exactly where
	 * they are. That is done by locating each piece with a FIXED anchor
	 * string from the template above (never a byte offset, and never
	 * anything built from a dynamic value like a colour or a date, so a
	 * future edit to what's IN the template cannot silently point this
	 * at the wrong slice) and splicing a <g> around it. See heartbeat()
	 * and TestGraceHeartbeatLeavesBandAndDateAlone. */
	switch status {
	case "LAPSED":
		return strings.Replace(body, "</svg>", crackOverlay+"</svg>", 1)
	case "GRACE PERIOD":
		return graceHeartbeat(body, statusWash)
	default:
		return body
	}
}

// graceHeartbeat re-wraps three pieces of an already-built grace card in
// the failing-heartbeat flicker, leaving the status band and the date
// line between them untouched. See the "GRACE AND LAPSED, LAYERED ON
// TOP" comment in cardSVG for why this operates on the finished string
// rather than building a second template.
//
// Every anchor here is fixed template text, not a dynamic value, so it
// does not drift when a colour, a date or a name changes -- only when
// the template itself does, and TestGraceHeartbeatLeavesBandAndDateAlone
// would catch that (the -1 guards below make a missed anchor degrade to
// the plain card rather than a corrupted one).
func graceHeartbeat(body, statusWash string) string {
	const bgAnchor = `<rect width="400" height="400" fill="#10101a"/>` + "\n  "
	bgEnd := strings.Index(body, bgAnchor)
	frameStart := strings.Index(body, `<rect x="12" y="12" width="376" height="376" rx="18"`)
	commentStart := strings.Index(body, `<!-- THE STATIC FRAME`)
	barStart := strings.Index(body, `<rect x="46" y="256" width="308" height="9" rx="4" fill="#ffffff" opacity="0.13"/>`)
	bandStart := strings.Index(body, `<rect x="12" y="352"`)
	if bgEnd < 0 || frameStart < 0 || commentStart < 0 || barStart < 0 || bandStart < 0 {
		return body
	}
	washStart := bgEnd + len(bgAnchor)
	washRel := strings.Index(body[washStart:], statusWash)
	if washRel < 0 {
		return body
	}
	washEnd := washStart + washRel

	return body[:washStart] +
		heartbeat(body[washStart:washEnd]) + // the art wash alone
		body[washEnd:frameStart] + // statusWash, held steady
		heartbeat(body[frameStart:commentStart]) + // frame, MINTED/SINCE, the name
		body[commentStart:barStart] + // the STATIC FRAME comment + the date line, held steady
		heartbeat(body[barStart:bandStart]) + // the term bar, both dates, the held count
		body[bandStart:] // the status band onward, held steady
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
	// 40, not 34: the name is the thing somebody bought, and on a card
	// where the drawing sits behind it, the type has to be the loudest
	// object on the tile. Short names were leaving the middle of the card
	// half empty.
	if size > 40 {
		size = 40
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
	return accentOf(nsdata.GetDomainExtra(domainLabel, keyArt))
}

func accentOf(enc string) string {
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

/* ---- THE METAL LADDER ----
 *
 * From the "Name States" study, 2026-08-23, where it was designed and
 * then not built for a fortnight. One rung per year held, carried by the
 * frame: 1 bronze, 2 silver, 3 gold, 4 platinum, 5+ diamond.
 *
 * THE LADDER IS PICKED FOR SEPARATION, not for what the metals are
 * worth. Brown, then cool grey, then yellow, then warm white, then
 * something that is not a metal at all. The obvious ladder — silver,
 * platinum, rhodium — is three whitish metals in a row, and nobody can
 * tell year two from year five across a grid of thumbnails. Platinum is
 * pulled deliberately WARM to keep it off the gold below it.
 *
 * The highlight travels faster at the higher rungs, so a longer-held
 * name reads as brighter as well as merely different.
 *
 * DIAMOND IS SATURATED AND KEEPS ITS WHITE. Fire in a real stone is
 * spectral colour separated BY white; take the white bands out and it
 * stops reading as a gem and starts reading as an oil slick.
 *
 * IT ADDS NO WORDS. The ribbon has said DIAMOND HANDS since year one and
 * at year five the card finally makes good on it. The domain's own
 * colour still runs through the type and the term bar, so a name reads
 * as its domain first and its tenure second.
 *
 * YEAR ZERO GETS NO METAL, which is the whole point of a ladder: if a
 * new name looked decorated, the rungs a name EARNS would mean nothing.
 *
 * Mirrored in the site's nft.js. These two move together or a preview
 * stops matching what the chain draws.
 */
type metal struct {
	dur   int
	stops string // already-rendered <stop> elements
}

func metalFor(streak int64) (metal, bool) {
	switch {
	case streak <= 0:
		return metal{}, false
	case streak == 1:
		return metal{13, `<stop offset="0%" stop-color="#3a1c0c"/><stop offset="32%" stop-color="#e6b088"/>` +
			`<stop offset="52%" stop-color="#b87333"/><stop offset="100%" stop-color="#3a1c0c"/>`}, true
	case streak == 2:
		return metal{11, `<stop offset="0%" stop-color="#3f4650"/><stop offset="32%" stop-color="#f1f5f9"/>` +
			`<stop offset="52%" stop-color="#aab4c0"/><stop offset="100%" stop-color="#3f4650"/>`}, true
	case streak == 3:
		return metal{9, `<stop offset="0%" stop-color="#6b2f0a"/><stop offset="32%" stop-color="#fde68a"/>` +
			`<stop offset="52%" stop-color="#f59e0b"/><stop offset="100%" stop-color="#6b2f0a"/>`}, true
	case streak == 4:
		return metal{9, `<stop offset="0%" stop-color="#6b6357"/><stop offset="30%" stop-color="#fbf7ef"/>` +
			`<stop offset="50%" stop-color="#ddd4c4"/><stop offset="100%" stop-color="#6b6357"/>`}, true
	default:
		return metal{5, `<stop offset="0%" stop-color="#0369a1"/><stop offset="16%" stop-color="#ffffff"/>` +
			`<stop offset="30%" stop-color="#22d3ee"/><stop offset="44%" stop-color="#ffffff"/>` +
			`<stop offset="58%" stop-color="#e879f9"/><stop offset="72%" stop-color="#ffffff"/>` +
			`<stop offset="86%" stop-color="#38bdf8"/><stop offset="100%" stop-color="#0369a1"/>`}, true
	}
}

/*
metalFrame returns the <defs>, the stroke and the stroke width for a
card, or the plain versions when no metal is earned.

THE METAL ONLY APPLIES TO A LIVE NAME. A gilded frame around a lapsed
card would celebrate a name that is about to belong to somebody else, and
it would fight the red wash that exists to say so. Grace and lapsed lose
the metal, which is itself information: the frame going plain is the
tenure visibly at risk.

THE GRADIENT ID CARRIES THE TOKEN. A Render() page draws many of these
into one document and SVG resolves url(#id) document-wide, so a fixed id
would make every card after the first wear the first card's metal. The
token id is unique by construction; it is sanitised because "*" and "-"
are not valid in an id.
*/
func metalFrame(tid, status, edge string, streak int64) (defs, stroke, width string) {
	m, ok := metalFor(streak)
	if !ok || status != "LIVE" {
		return "", edge, "3"
	}
	id := "m" + idSafe(tid)
	defs = ufmt.Sprintf(
		`<defs><linearGradient id="%s" x1="0" y1="0" x2="1" y2="1">%s`+
			`<animateTransform attributeName="gradientTransform" type="rotate" `+
			`from="0 .5 .5" to="360 .5 .5" dur="%ds" repeatCount="indefinite"/>`+
			`</linearGradient></defs>`, id, m.stops, m.dur)
	return defs, "url(#" + id + ")", "4"
}

// An XML id may not contain "*", and a name may not contain anything
// else that would need escaping — the registry's own label rules see to
// that — so one substitution is enough.
func idSafe(tid string) string {
	return strings.ReplaceAll(tid, "*", "-")
}

// The foot of the card: a quiet ribbon while the name is alive, the loud
// band once it is not. One function so the two cannot both be drawn.
func smallRibbon(status, edge, ribbon, band string) string {
	if band != "" {
		return band
	}
	return ufmt.Sprintf(
		`<text x="200" y="372" text-anchor="middle" font-family="monospace" `+
			`font-size="12" font-weight="bold" fill="%s">%s</text>`, edge, ribbon)
}

/* ---- FAILING HEARTBEAT (grace period) ----
 *
 * From the "Name States" study, 2026-08-23 -- the "Failing heartbeat"
 * treatment, built around pulses()/BURSTS/track() there. Bursts of two,
 * one, three and one flash at 0.02/0.30/0.55/0.80 of a 7.5s cycle read
 * as an unpredictable fault rather than an even, designed blink, so the
 * rhythm carries over unchanged. graceValues and graceKeyTimes below are
 * that generator's output for base=1, dip=0.25 -- computed once, not
 * rebuilt on every read, since a fixed rhythm shared by every grace card
 * on the chain has nothing left to vary.
 *
 * INVERTED FROM THE STUDY, and deliberately. There the track sits DARK
 * and briefly flashes LIT -- fine for something animating live in a
 * browser tab, useless for a marketplace that renders one still frame:
 * the base opacity in the markup and the first keyframe are BOTH the
 * dark value there, so a still render of that track is nearly
 * invisible. Here the rest state is fully lit -- opacity 1, exactly the
 * live card -- and the bursts are brief DIPS toward .25 instead, so
 * whichever still a renderer takes (the base attribute for one that
 * ignores SMIL, the first keyframe for one that honours it) lands on
 * the fully-lit card. graceValues therefore reads "1;1;0.25;..." and
 * graceKeyTimes starts "0.0000;...": both a "1" at index zero, on
 * purpose. TestGraceHeartbeatLeavesBandAndDateAlone checks exactly that.
 *
 * Mirrored in the site's nft.js (pulseTrack/heartbeat there, same two
 * numbers). If this changes, that changes, or a preview stops matching
 * what the chain draws.
 */
const graceValues = "1;1;0.25;0.25;1;1;0.25;0.25;1;1;0.25;0.25;1;1;0.25;0.25;1;1;0.25;0.25;1;1;0.25;0.25;1;1;0.25;0.25;1;1"
const graceKeyTimes = "0.0000;0.0200;0.0240;0.0350;0.0390;0.0570;0.0610;0.0720;0.0760;0.3000;0.3040;0.3150;0.3190;0.5500;0.5540;0.5650;0.5690;0.5870;0.5910;0.6020;0.6060;0.6240;0.6280;0.6390;0.6430;0.8000;0.8040;0.8150;0.8190;1.0000"

// heartbeat wraps one piece of a grace card in the failing-heartbeat
// flicker. Called three separate times in graceHeartbeat rather than
// once around the whole card, so the status band and the date line can
// sit between the wrapped pieces untouched. Every call shares the same
// values/keyTimes/dur; SMIL times every <animate> from document load, so
// three separate <g>s stay in lockstep without needing to share one.
func heartbeat(inner string) string {
	return `<g opacity="1">` + inner +
		`<animate attributeName="opacity" values="` + graceValues +
		`" keyTimes="` + graceKeyTimes + `" dur="7.5s" repeatCount="indefinite"/></g>`
}

/* ---- CRACKED (lapsed) ----
 *
 * From the same study, under LAPSED. Static, no animation: a fracture
 * across the glass with two short branches, drawn last so it sits over
 * everything else on the card; the art behind it is untouched and
 * undimmed.
 *
 * THE STUDY'S PATH IS NOT USED AS-IS. Its middle segment runs through
 * x=140-176 at y=168-214 -- dead centre, right through where the name
 * sits on the study's fixed-width demo cards. That is not fine here:
 * the name is centred on x=200 with text-anchor="middle" and can run up
 * to 32 characters (see fitSize), so its box can span nearly the full
 * card width -- as far out as roughly x=30 to x=370 -- for a long one.
 * No amount of routing the crack sideways dodges that band, because a
 * long enough name is somewhere underneath any vertical line drawn
 * across it.
 *
 * So the crack is drawn as two pieces rather than one continuous line:
 * an upper fracture that stays above y=158 and a lower one that stays
 * below y=224, leaving the name's row (166-206) and the date line under
 * it (214-228) untouched regardless of how long the name is. It reads
 * as the fracture running into the nameplate and continuing on the far
 * side, rather than through it -- arguably truer to how a crack behaves
 * against a raised, painted surface anyway. Other type on the card (the
 * term bar, the held count) is still legitimately crossed, same as in
 * the study; only the name and the date get the gap.
 *
 * Mirrored byte-for-byte in the site's nft.js (CRACK_OVERLAY there).
 */
const crackOverlay = `<g stroke="#ffffff" fill="none" opacity="0.5" stroke-width="2">` +
	`<path d="M92 24 L150 72 L112 118 L162 152"/>` +
	`<path d="M112 118 L54 138"/>` +
	`<path d="M158 224 L206 270 L172 318 L228 388"/>` +
	`<path d="M172 318 L268 300"/>` +
	`</g>` +
	`<g stroke="#000000" fill="none" opacity="0.35" stroke-width="4">` +
	`<path d="M94 26 L152 74 L114 120 L164 154"/>` +
	`<path d="M160 226 L208 272 L174 320 L230 390"/>` +
	`</g>`

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
