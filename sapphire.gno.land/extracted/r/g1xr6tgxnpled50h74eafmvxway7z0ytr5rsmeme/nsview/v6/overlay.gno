package nsview

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// Seasonal decoration, driven by DATA rather than by code.
//
// The card is generated on every read, so anything it draws can change
// after names have been sold. That makes a holiday overlay possible —
// snow in December, falling leaves in October — across every token at
// once. The temptation is to write a drawSnow() into this realm and a
// drawPumpkins() next year, which would make every new decoration a
// redeploy of the view.
//
// So it is parameterised instead. This realm knows how to draw drifting
// particles; WHICH particles, what colour, how many and until when live
// in a global that any admin call can rewrite. Christmas is then one
// transaction, not a deployment, and so is turning it off.
//
// Format, read from the global key `cardfx`:
//
//	dir:fall;n:22;c:#ffffff;c2:#dbeafe;s:3;d:9;until:1767225600
//
//	dir    fall | rise | burst    drift down, drift up, or fireworks
//	n      1..40                  how many
//	c      #rrggbb                colour (c2, c3 optional, cycled)
//	s      1..6                   pixel size
//	d      2..30                  seconds for one traverse (lower = faster)
//	sv     0..3                   size jitter, so they are not all identical
//	k      4..16                  sparks per shell, when dir is burst
//	sh     sq | leaf | petal      particle shape; leaf and petal are angled
//	until  unix seconds, 0 = no expiry
//
// `until` matters more than it looks: an overlay that expires on its own
// cannot be forgotten in January. Everything is parsed defensively and a
// malformed value yields NO overlay, for the same reason the sprite
// parser does — this markup lands inside a token that other people's
// software renders.
const keyFX = "cardfx"

func overlaySVG(now int64) string {
	return buildOverlay(nsdata.GetGlobal(keyFX), now)
}

// A SCHEDULE, so December snows without anybody remembering to make it.
//
// This is free in a way the treasury swap was not. That needed somebody
// to send a transaction, because a realm cannot act on its own. This
// needs nobody, because the card is generated on every read and can
// simply look at the clock — the decoration is a rendering decision, not
// an action.
//
// Rules are separated by "|" and the FIRST one whose window contains
// today wins, so put the specific ones first:
//
//	from:12-01;to:01-06;dir:fall;n:26;c:#ffffff|from:10-24;to:11-02;dir:rise;n:22;c:#f97316
//
// from/to are MM-DD and RECUR every year, which is the point — set it
// once and every December snows. A window whose start is after its end
// wraps the new year, so 12-01 to 01-06 is what you would expect rather
// than an empty range. A rule with no window is always eligible, so a
// bare spec still behaves as it did.
func pickRule(spec string, now int64) string {
	if spec == "" {
		return ""
	}
	t := time.Unix(now, 0).UTC()
	today := int(t.Month())*100 + t.Day()
	for _, rule := range strings.Split(spec, "|") {
		from := ruleField(rule, "from")
		to := ruleField(rule, "to")
		if from == "" && to == "" {
			return rule // no window: always eligible
		}
		f, okF := mmdd(from)
		e, okE := mmdd(to)
		if !okF || !okE {
			continue // a malformed window disables its rule, not the lot
		}
		if f <= e {
			if today >= f && today <= e {
				return rule
			}
		} else if today >= f || today <= e {
			// wraps the year end, e.g. 12-01 to 01-06
			return rule
		}
	}
	return ""
}

func ruleField(rule, key string) string {
	for _, part := range strings.Split(rule, ";") {
		kv := strings.SplitN(strings.TrimSpace(part), ":", 2)
		if len(kv) == 2 && strings.TrimSpace(kv[0]) == key {
			return strings.TrimSpace(kv[1])
		}
	}
	return ""
}

// mmdd reads "12-01" into 1201. Rejects anything that is not a real
// calendar date, so a typo cannot silently make a rule match all year.
func mmdd(s string) (int, bool) {
	if len(s) != 5 || s[2] != '-' {
		return 0, false
	}
	m, err1 := strconv.Atoi(s[:2])
	d, err2 := strconv.Atoi(s[3:])
	if err1 != nil || err2 != nil || m < 1 || m > 12 || d < 1 || d > 31 {
		return 0, false
	}
	return m*100 + d, true
}

func buildOverlay(spec string, now int64) string {
	spec = pickRule(spec, now)
	if spec == "" {
		return ""
	}
	dir := "fall"
	n := 0
	size := 3
	dur := 9
	jitter := 0
	sparks := 8
	shape := "sq"
	var until int64
	cols := []string{}

	for _, part := range strings.Split(spec, ";") {
		kv := strings.SplitN(strings.TrimSpace(part), ":", 2)
		if len(kv) != 2 {
			continue
		}
		k, v := strings.TrimSpace(kv[0]), strings.TrimSpace(kv[1])
		switch k {
		case "dir":
			if v == "fall" || v == "rise" || v == "burst" {
				dir = v
			}
		case "n":
			n = atoiClamp(v, 0, 40)
		case "s":
			size = atoiClamp(v, 1, 6)
		case "d":
			// Floor of 2, not 3: a 3-second traverse was the fastest the
			// card could go, and rain wants to be faster than snow by more
			// than that allows.
			dur = atoiClamp(v, 2, 30)
		case "sv":
			jitter = atoiClamp(v, 0, 3)
		case "k":
			sparks = atoiClamp(v, 4, 16)
		case "sh":
			if v == "sq" || v == "leaf" || v == "petal" {
				shape = v
			}
		case "until":
			if x, err := strconv.ParseInt(v, 10, 64); err == nil && x >= 0 {
				until = x
			}
		case "c", "c2", "c3":
			if isHexColour(v) {
				cols = append(cols, v)
			}
		}
	}

	if n <= 0 || len(cols) == 0 {
		return ""
	}
	// Expired decoration draws nothing, so a forgotten overlay retires
	// itself rather than snowing in July.
	if until > 0 && now >= until {
		return ""
	}

	if dir == "burst" {
		return fireworks(n, sparks, size, dur, cols)
	}

	var b strings.Builder
	b.WriteString(`<g opacity="0.85">`)
	for i := 0; i < n; i++ {
		// Deterministic scatter: the same token renders identically on
		// every read, which matters because a marketplace may cache it.
		h := hash(i)
		x := int(h % 392)
		delay := int(h/7) % (dur * 10)
		drift := int(h/13)%14 - 7
		wobble := dur + int(h/17)%5
		from, to := -12, 412
		if dir == "rise" {
			from, to = 412, -12
		}
		col := cols[i%len(cols)]
		// Not all the same size. Uniform particles read as a texture;
		// a little variation reads as depth, for two bytes of spec.
		px := size
		if jitter > 0 {
			px = size + int(h/23)%(jitter+1)
		}
		if shape == "sq" {
			b.WriteString(ufmt.Sprintf(
				`<rect x="%d" y="%d" width="%d" height="%d" fill="%s">`+
					`<animateTransform attributeName="transform" type="translate" `+
					`values="0 0;%d %d" dur="%ds" begin="-%d.%ds" repeatCount="indefinite"/></rect>`,
				x, from, px, px, col,
				drift, to-from, wobble, delay/10, delay%10))
			continue
		}
		// A shaped particle needs its own rotation, and an element can
		// carry only one transform. Animating the group and rotating the
		// shape inside it keeps the two independent — animating both on
		// one element would make each leaf drift along its own angle
		// instead of downward.
		b.WriteString(ufmt.Sprintf(
			`<g><animateTransform attributeName="transform" type="translate" `+
				`values="0 0;%d %d" dur="%ds" begin="-%d.%ds" repeatCount="indefinite"/>%s</g>`,
			drift, to-from, wobble, delay/10, delay%10,
			shapeAt(shape, x, from, px, int(h/31)%360, col)))
	}
	b.WriteString(`</g>`)
	return b.String()
}

// A small deterministic spread. Not random: the same index must always
// give the same particle, or a cached render and a fresh one disagree.
func hash(i int) int {
	h := (i+1)*2654435761 ^ 0x9e3779b9
	if h < 0 {
		h = -h
	}
	return h
}

func atoiClamp(s string, lo, hi int) int {
	v, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Fireworks: a shell climbs, vanishes, and throws sparks outward.
//
// The cost question is worth answering plainly, because it is the first
// decoration that is not one rect per particle. A shell is 1 rect for
// the climb plus k rects for the burst, so `n:5;k:10` is 55 rects — the
// same order as the 34 the rain already draws, and a fifth of the 128
// the domain sprite draws on every card anyway. None of it is stored:
// the card is built during a read, so this costs no gas and no storage,
// only the browser's time. That is the real ceiling, so the totals are
// capped below rather than left to whoever writes the spec.
//
// Two phases in one loop, driven by keyTimes on a single animation each,
// because a <set> chain or nested <g> would double the element count for
// the same picture.
func fireworks(shells, sparks, size, dur int, cols []string) string {
	if shells > 6 {
		shells = 6 // 6 x 16 sparks is already 102 rects
	}
	var b strings.Builder
	b.WriteString(`<g opacity="0.9">`)
	for i := 0; i < shells; i++ {
		h := hash(i * 7)
		x := 40 + int(h%340)          // keep the burst off the very edge
		burstY := 96 + int(h/11)%140  // where it stops climbing
		lift := 400 - burstY          // how far it climbs from the base
		// Shells are staggered across the cycle so they do not all go up
		// together, and each has its own colour from the palette.
		begin := int(h/29) % (dur * 10)
		// One colour per shell, not one per spark. A real firework is a
		// single charge, and mixing colours inside one burst reads as
		// confetti rather than pyrotechnics.
		col := cols[i%len(cols)]

		// The climb. Held at the top for the rest of the cycle rather
		// than looping straight away, and faded out at the moment of the
		// burst so the eye reads one event, not two objects.
		b.WriteString(ufmt.Sprintf(
			`<rect x="%d" y="400" width="%d" height="%d" fill="%s" opacity="0">`+
				`<animateTransform attributeName="transform" type="translate" `+
				`values="0 0;0 -%d;0 -%d" keyTimes="0;0.4;1" dur="%ds" begin="-%d.%ds" repeatCount="indefinite"/>`+
				`<animate attributeName="opacity" values="1;1;0;0" keyTimes="0;0.38;0.4;1" `+
				`dur="%ds" begin="-%d.%ds" repeatCount="indefinite"/></rect>`,
			x, size, size, col, lift, lift, dur, begin/10, begin%10, dur, begin/10, begin%10))

		for j := 0; j < sparks; j++ {
			g := hash(i*97 + j*13)
			d := j * 16 / sparks // one of the 16 fixed directions
			r := 34 + int(g%34)  // how far this spark travels
			dx := r * dirCos[d] / 100
			dy := r * dirSin[d] / 100
			// Sparks fall as they fly, which is the whole difference
			// between a firework and a starburst.
			dy += r / 3
			px := size
			if int(g/7)%3 == 0 {
				px = size + 1 // a few brighter, bigger sparks per shell
			}
			b.WriteString(ufmt.Sprintf(
				`<rect x="%d" y="%d" width="%d" height="%d" fill="%s" opacity="0">`+
					`<animateTransform attributeName="transform" type="translate" `+
					`values="0 0;0 0;%d %d" keyTimes="0;0.4;1" dur="%ds" begin="-%d.%ds" repeatCount="indefinite"/>`+
					`<animate attributeName="opacity" values="0;0;1;0" keyTimes="0;0.4;0.52;1" `+
					`dur="%ds" begin="-%d.%ds" repeatCount="indefinite"/></rect>`,
				x, burstY, px, px, col,
				dx, dy, dur, begin/10, begin%10, dur, begin/10, begin%10))
		}
	}
	b.WriteString(`</g>`)
	return b.String()
}

// Sixteen directions on a circle, as hundredths. A table rather than
// math.Sin: the same integers must come out on every node, and this is
// the whole of the trigonometry the card needs.
var (
	dirCos = [16]int{100, 92, 71, 38, 0, -38, -71, -92, -100, -92, -71, -38, 0, 38, 71, 92}
	dirSin = [16]int{0, 38, 71, 92, 100, 92, 71, 38, 0, -38, -71, -92, -100, -92, -71, -38}
)

// shapeAt draws one non-square particle at a position, turned to its own
// angle. Leaves and petals are two curves each rather than a polygon: a
// leaf is pointed at both ends, a petal is round at one, and that single
// difference is the whole of what distinguishes October from April.
//
// The numbers are derived from the particle size so `s` still means what
// it means everywhere else, and both shapes stay legible at the size a
// card is actually looked at.
func shapeAt(kind string, x, y, px, ang int, col string) string {
	w, hh := px, px*2
	switch kind {
	case "leaf":
		// Wider than a petal at the same size. A lens with its control
		// points at the particle width is a sliver, not a leaf.
		w = px * 3 / 2
		return ufmt.Sprintf(
			`<path d="M0 -%dQ%d 0 0 %dQ-%d 0 0 -%dZ" fill="%s" transform="translate(%d,%d) rotate(%d)"/>`,
			hh, w, hh, w, hh, col, x, y, ang)
	case "petal":
		return ufmt.Sprintf(
			`<ellipse rx="%d" ry="%d" fill="%s" transform="translate(%d,%d) rotate(%d)"/>`,
			w, hh, col, x, y, ang)
	}
	return ufmt.Sprintf(`<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>`, x, y, px, px, col)
}
