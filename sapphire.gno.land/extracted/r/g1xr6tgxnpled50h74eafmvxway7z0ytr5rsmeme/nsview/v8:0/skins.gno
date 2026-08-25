package nsview

import (
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

/*
SKINS — the card becomes something else entirely for a day.

The decoration calendar already draws snow and embers ON TOP of a card.
A skin REPLACES it: on 22 May the token is a pizza, on 3 January it is a
newspaper. That is a different kind of change, so it is a different
field, and any date without one renders exactly as it always has.

HOW A CONTRACT KNOWS THE DATE AT ALL. It does not read a block height and
guess. Every block carries a timestamp in its header, agreed by consensus
the same way its transactions are, and `time.Now()` inside a realm returns
that block time. So a realm has a real clock, accurate to within a block
interval — which for a decoration that changes once a year is precision
nobody will ever notice. This is the same mechanism the seasonal overlay
has always used.

WHY THIS COSTS NOTHING TO RUN. The card is generated on every read rather
than fixed at mint, so a skin needs no transaction, no migration and
nobody awake at midnight. It applies to names sold years ago. Turning it
off is deleting one field from the calendar.

NO FONTS. Every renderer that shows these — wallets, marketplaces — puts
the SVG in a sandbox with no network, so a web font simply fails and
silently substitutes. Only the generic families resolve, which is why the
existing card says monospace and why these say serif or sans-serif. The
display faces in the mockups are a later job: an alphabet drawn as paths
and stored once, which is the only way to get identical letterforms on
every device.
*/

// skinFor returns the skin named by whichever calendar rule is active
// today, or "" for the ordinary card. Reusing pickRule means a skin
// obeys the same window rules, the same first-match-wins ordering and
// the same year wrapping as every other season.
func skinFor(now int64) string {
	return skinFromSpec(nsdata.GetGlobal(keyFX), now)
}

// Split out so the calendar logic can be tested against a spec directly,
// without standing up a vault to hold one.
func skinFromSpec(spec string, now int64) string {
	rule := pickRule(spec, now)
	if rule == "" {
		return ""
	}
	return ruleField(rule, "skin")
}

// hasSkin reports whether a name is renderable as this skin. Unknown
// names render nothing rather than a broken card — the same defensive
// stance the overlay parser takes, and for the same reason: this markup
// lands inside a token that other people's software renders.
func hasSkin(name string) bool {
	switch name {
	case "pizza", "paper", "cal", "fog", "slash", "pi", "heart":
		return true
	}
	return false
}

// seedOf turns a token id into a small number, so that a card can differ
// from the one beside it without any randomness — which a deterministic
// machine does not have. Every node computes the same answer for the same
// name, which is the requirement; looking arbitrary is merely the effect.
func seedOf(tid string) int {
	h := 2166136261
	for i := 0; i < len(tid); i++ {
		h ^= int(tid[i])
		h *= 16777619
		h &= 0x7fffffff
	}
	return h
}

// skinSVG renders a complete 400x400 card. Same frame as the ordinary
// one, so nothing downstream has to know which it received.
func skinSVG(name, tid string, now int64) string {
	label := tid
	if at := strings.Index(tid, "*"); at > 0 {
		label = tid
	}
	size := 34
	if len(label) > 14 {
		size = 22
	} else if len(label) > 10 {
		size = 27
	}
	switch name {
	case "pizza":
		return skinPizza(label, size, seedOf(tid))
	case "paper":
		return skinPaper(label, size, now)
	case "cal":
		return skinCal(label, size)
	case "fog":
		return skinFog(label, size)
	case "slash":
		return skinSlash(label, size)
	case "pi":
		return skinPi(label, size)
	case "heart":
		return skinHeart(label, size)
	}
	return ""
}

func head(bg string) string {
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" role="img">` +
		`<rect width="400" height="400" fill="` + bg + `"/>`
}

func foot() string {
	return `<text x="200" y="380" text-anchor="middle" font-family="monospace" font-size="10"` +
		` fill="#ffffff" opacity="0.45">MINTED ON GNO.LAND</text></svg>`
}

/* ---------------- 22 May: the pizza ----------------
 *
 * Eight wedges with a gap between them, so it reads as CUT rather than
 * merely divided, and each wedge carries its own toppings inside its own
 * group — that is what makes a slice leave with its pepperoni still on
 * it instead of leaving them floating over the board.
 *
 * EVERY NAME EATS IN ITS OWN ORDER. The seed decides which slice goes
 * first and how long each one waits, so a marketplace full of these is a
 * room full of pizzas being eaten from different sides at different
 * rates rather than one animation repeated. It is derived from the token
 * id, so it is the same on every node and different for every name.
 */
func skinPizza(label string, size, seed int) string {
	var b strings.Builder
	b.WriteString(head("#2a2018"))
	b.WriteString(`<circle cx="200" cy="200" r="168" fill="#3a2c20"/>`)

	order := make([]int, 8)
	for i := range order {
		order[i] = i
	}
	// A deterministic shuffle: the seed walks the list and swaps.
	s := seed
	for i := 7; i > 0; i-- {
		s = (s*1103515245 + 12345) & 0x7fffffff
		j := s % (i + 1)
		order[i], order[j] = order[j], order[i]
	}

	for pos, idx := range order {
		a0 := float64(idx)*45 + 1.8
		a1 := float64(idx+1)*45 - 1.8
		// Each slice waits a little longer than the last, with the gap
		// itself varying by name so two cards never keep step.
		begin := 3 + pos*3 + (seed>>uint(pos))%4
		b.WriteString(`<g>`)
		b.WriteString(`<animate attributeName="opacity" values="1;1;0" keyTimes="0;0.5;1"`)
		b.WriteString(ufmt.Sprintf(` dur="%ds" begin="%ds" fill="freeze"/>`, 2, begin))
		b.WriteString(wedge(200, 200, 162, a0, a1, "#d9822b"))
		b.WriteString(wedge(200, 200, 143, a0+1.2, a1-1.2, "#f0b23c"))
		// Three toppings inside this wedge: one pepperoni, two herbs.
		for t := 0; t < 3; t++ {
			s = (s*1103515245 + 12345) & 0x7fffffff
			ang := a0 + 4 + float64(s%int(a1-a0-8))
			s = (s*1103515245 + 12345) & 0x7fffffff
			rad := 46 + float64(s%86)
			x, y := polar(200, 200, rad, ang)
			if t == 0 {
				b.WriteString(ufmt.Sprintf(`<circle cx="%d" cy="%d" r="13" fill="#b8342a"/>`, x, y))
			} else {
				b.WriteString(ufmt.Sprintf(
					`<rect x="%d" y="%d" width="13" height="13" rx="3" fill="#4e8b3a"/>`, x-6, y-6))
			}
		}
		b.WriteString(`</g>`)
	}
	b.WriteString(ufmt.Sprintf(
		`<text x="200" y="212" text-anchor="middle" font-family="sans-serif" font-size="%d"`+
			` font-weight="bold" fill="#2a1405">%s</text>`, size, esc(label)))
	b.WriteString(foot())
	return b.String()
}

func wedge(cx, cy int, r float64, a0, a1 float64, fill string) string {
	x0, y0 := polar(cx, cy, r, a0)
	x1, y1 := polar(cx, cy, r, a1)
	return ufmt.Sprintf(`<path d="M%d %d L%d %d A%d %d 0 0 1 %d %d Z" fill="%s"/>`,
		cx, cy, x0, y0, int(r), int(r), x1, y1, fill)
}

// Degrees clockwise from twelve o'clock, which is how a pizza is cut.
// Integer maths throughout: a realm has no floating point worth trusting
// across nodes, and a pizza does not need sub-pixel accuracy.
func polar(cx, cy int, r float64, deg float64) (int, int) {
	rad := (deg - 90) * 3.14159265 / 180
	return cx + int(r*cosApprox(rad)), cy + int(r*sinApprox(rad))
}

func sinApprox(x float64) float64 {
	for x > 3.14159265 {
		x -= 6.2831853
	}
	for x < -3.14159265 {
		x += 6.2831853
	}
	x2 := x * x
	return x * (1 - x2/6 + x2*x2/120 - x2*x2*x2/5040)
}

func cosApprox(x float64) float64 { return sinApprox(x + 1.5707963) }

/* ---------------- 3 Jan: the front page ---------------- */
func skinPaper(label string, size int, now int64) string {
	year := time.Unix(now, 0).UTC().Year()
	return head("#f4f0e4") +
		`<text x="200" y="66" text-anchor="middle" font-family="serif" font-size="30"` +
		` font-weight="bold" fill="#141210">THE LEDGER</text>` +
		`<line x1="40" y1="80" x2="360" y2="80" stroke="#141210" stroke-width="2"/>` +
		ufmt.Sprintf(`<text x="200" y="100" text-anchor="middle" font-family="monospace"`+
			` font-size="11" fill="#5a5348">3 JANUARY %d &#183; BLOCK ZERO</text>`, year) +
		ufmt.Sprintf(`<text x="200" y="176" text-anchor="middle" font-family="serif"`+
			` font-size="%d" font-weight="bold" fill="#141210">%s</text>`, size+6, esc(label)) +
		`<text x="200" y="214" text-anchor="middle" font-family="sans-serif" font-size="13"` +
		` fill="#39342c">The first block is mined. A chain begins.</text>` +
		`<text x="200" y="234" text-anchor="middle" font-family="sans-serif" font-size="13"` +
		` fill="#39342c">Years later somebody registers a name</text>` +
		`<text x="200" y="254" text-anchor="middle" font-family="sans-serif" font-size="13"` +
		` fill="#39342c">on it that does nothing at all.</text>` +
		`<line x1="40" y1="278" x2="360" y2="278" stroke="#b9b2a2" stroke-width="1"/>` +
		`<text x="200" y="380" text-anchor="middle" font-family="monospace" font-size="10"` +
		` fill="#5a5348">MINTED ON GNO.LAND</text></svg>`
}

/* ---------------- 29 Feb: the calendar page ---------------- */
func skinCal(label string, size int) string {
	return head("#ffffff") +
		`<rect width="400" height="72" fill="#c0392b"/>` +
		`<text x="200" y="49" text-anchor="middle" font-family="sans-serif" font-size="26"` +
		` font-weight="bold" fill="#ffffff" letter-spacing="6">FEBRUARY</text>` +
		`<circle cx="150" cy="24" r="9" fill="#f7f4ee" stroke="#00000055" stroke-width="3"/>` +
		`<circle cx="250" cy="24" r="9" fill="#f7f4ee" stroke="#00000055" stroke-width="3"/>` +
		`<text x="200" y="252" text-anchor="middle" font-family="sans-serif" font-size="170"` +
		` font-weight="bold" fill="#e8e3d9">29</text>` +
		ufmt.Sprintf(`<text x="200" y="300" text-anchor="middle" font-family="monospace"`+
			` font-size="%d" font-weight="bold" fill="#1a1a1a">%s</text>`, size, esc(label)) +
		`<text x="200" y="380" text-anchor="middle" font-family="monospace" font-size="10"` +
		` fill="#8a857a">MINTED ON GNO.LAND</text></svg>`
}

/* ---------------- 20 Apr: the fog ---------------- */
func skinFog(label string, size int) string {
	return head("#1d4028") +
		`<defs><radialGradient id="g"><stop offset="0" stop-color="#8fd48a"/>` +
		`<stop offset="0.68" stop-color="#3f7a4a"/><stop offset="1" stop-color="#1d4028"/>` +
		`</radialGradient><filter id="b"><feGaussianBlur stdDeviation="26"/></filter></defs>` +
		`<rect width="400" height="400" fill="url(#g)"/>` +
		`<g filter="url(#b)" opacity="0.5">` +
		`<circle cx="130" cy="140" r="90" fill="#ffffff" opacity="0.5">` +
		`<animate attributeName="cx" values="130;190;130" dur="18s" repeatCount="indefinite"/>` +
		`</circle>` +
		`<circle cx="280" cy="250" r="80" fill="#ffffff" opacity="0.35">` +
		`<animate attributeName="cy" values="250;200;250" dur="22s" repeatCount="indefinite"/>` +
		`</circle></g>` +
		ufmt.Sprintf(`<text x="200" y="212" text-anchor="middle" font-family="sans-serif"`+
			` font-size="%d" font-weight="bold" fill="#f2fff2">%s</text>`, size, esc(label)) +
		foot()
}

/* ---------------- Friday 13th: the poster ---------------- */
func skinSlash(label string, size int) string {
	return head("#15080a") +
		`<path d="M88 -20 L112 420 L96 420 L72 -20 Z" fill="#c42c24" opacity="0.85"/>` +
		`<path d="M252 420 L268 -20 L278 -20 L262 420 Z" fill="#8e1d18" opacity="0.7"/>` +
		ufmt.Sprintf(`<text x="200" y="212" text-anchor="middle" font-family="serif"`+
			` font-size="%d" font-weight="bold" fill="#d8342c">%s</text>`, size+4, esc(label)) +
		foot()
}

/* ---------------- 14 Mar: pi ---------------- */
func skinPi(label string, size int) string {
	digits := []string{
		"3.14159265358979323846", "26433832795028841971", "69399375105820974944",
		"59230781640628620899", "86280348253421170679", "82148086513282306647",
	}
	var b strings.Builder
	b.WriteString(head("#101418"))
	for i, row := range digits {
		b.WriteString(ufmt.Sprintf(
			`<text x="26" y="%d" font-family="monospace" font-size="30" fill="#2b4756">%s</text>`,
			70+i*56, row))
	}
	b.WriteString(`<rect x="52" y="176" width="296" height="52" rx="8" fill="#101418"/>`)
	b.WriteString(ufmt.Sprintf(
		`<text x="200" y="212" text-anchor="middle" font-family="monospace" font-size="%d"`+
			` font-weight="bold" fill="#eaf2f6">%s</text>`, size, esc(label)))
	b.WriteString(foot())
	return b.String()
}

/* ---------------- 14 Feb: the heart ----------------
 *
 * A real double thump, not one pulse: squeeze, small recoil, second
 * smaller squeeze, then a long rest. The rest is most of what makes it
 * read as a heartbeat rather than a throb.
 */
func skinHeart(label string, size int) string {
	return head("#fbe3ec") +
		`<g transform="translate(200,196)">` +
		`<animateTransform attributeName="transform" type="scale"` +
		` values="1;1.085;0.995;1.05;1;1" keyTimes="0;0.09;0.18;0.27;0.40;1"` +
		` dur="1.15s" repeatCount="indefinite" additive="sum"/>` +
		`<path transform="translate(-150,-140)" fill="#f7c3d5" stroke="#e39bb5" stroke-width="5"` +
		` d="M150 258 C66 198 24 150 24 102 A60 60 0 0 1 150 72 A60 60 0 0 1 276 102` +
		` C276 150 234 198 150 258 Z"/></g>` +
		ufmt.Sprintf(`<text x="200" y="212" text-anchor="middle" font-family="sans-serif"`+
			` font-size="%d" font-weight="bold" fill="#7e1f3d" letter-spacing="2">%s</text>`,
			size, esc(strings.ToUpper(label))) +
		`<text x="200" y="380" text-anchor="middle" font-family="monospace" font-size="10"` +
		` fill="#b03a62" opacity="0.7">MINTED ON GNO.LAND</text></svg>`
}

// Markup safety, same as everywhere else that puts a name into SVG: a
// label is validated on registration, but this is the last gate before
// it lands inside somebody else's renderer.
func esc(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}
