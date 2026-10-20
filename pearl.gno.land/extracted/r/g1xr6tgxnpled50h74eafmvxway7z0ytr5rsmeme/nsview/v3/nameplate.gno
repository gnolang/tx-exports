package nsview

import (
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

/*
THE NAMEPLATE — the name, the asterisk and the expiry, composited over
somebody else's artwork.

WHY IT IS THE CONTRACT'S JOB AND NOT THE ARTIST'S. A skin is a picture
somebody else drew. If they also controlled the lettering they could
omit it, cover it, shrink it to nothing, or write different text — and a
card that does not say which name it is, is not a name card. So the
artist chooses three things from short lists (face, position, ink) and
the contract does the rest.

THE ASTERISK IS DRAWN, NEVER TYPED. Every typeface sets `*` small and
lifted to cap height, because in running text it is a footnote marker.
Here it is a letter — it is the entire brand — so it is drawn at the
weight of the type around it, at the x-height of the lowercase letters
beside it, and centred on their optical band. Typing it produces a small
mark floating above the words, which is exactly what it is for and
exactly wrong here.

ONE ASTERISK IN ALL THREE FACES, cut square. Three shapes were tried —
tapered for serif, square for sans, square and lighter for mono — and the
lightest square one won outright, so the other two are gone. It is the
mark, not a glyph borrowed from whatever face happens to be set; making
it agree with the type was solving a problem nobody had.

A REALM CANNOT MEASURE TEXT, and that used to shape the whole algorithm.
It matters much less now: the widths below are real per-character
metrics rather than one average, and textLength makes the renderer honour
them. See the long note in NameplateSVG.

This file is the single source of truth for the geometry. Anything that
previews a card — the site, a mockup, a shop listing — must reproduce
these numbers exactly or it is showing something that will not ship.
tools/diff-nameplate.sh enforces that against the site's mirror.
*/

// The card is 400x400 and the name may use all but a margin either side.
const (
	plateW      = 400
	plateMargin = 30
	plateAvail  = plateW - 2*plateMargin // 340

	plateMaxSize = 56 // any larger and a two-letter name dominates the art

	// A LAST-RESORT floor, not a readability one, and the difference is
	// a bug worth recording. This was 18 — "any smaller and it stops
	// being readable in a thumbnail" — which is a fine aspiration and an
	// impossible guarantee. maxLabelLen is 63, and sixty-three m's need
	// about five pixels to fit a 400px card. The clamp won that argument
	// and the name ran off the edge, inside somebody else's wallet.
	//
	// Fitting beats legibility because they are not comparable failures:
	// a small name is small, a name that leaves the card is broken. And
	// there is no third option — the card has to show the WHOLE name, so
	// truncating it is not available. So the solver goes as small as the
	// width demands and this is only the point below which a glyph would
	// round away to nothing whatever we did. In practice it never binds:
	// the longest legal name still solves above it.
	plateMinSize = 4
)

/*
GLYPH WIDTHS, per generic family, in thousandths of the type size.

This replaced a single average-width ratio per family, and the reason is
worth keeping, because the average was not merely imprecise — it put
names visibly off centre, by an amount that depended on which letters
somebody had picked.

A serif "l" is 278 and a serif "m" is 833. One number cannot stand in for
both. The old ratio was 560 against a true average of 488, so a name made
of narrow letters — tessellation, say — came out forty per cent too wide,
and because the asterisk is placed using that figure, the whole name slid
sideways by half the error. That is exactly what showed up on the proof
sheet: tessellation pushed right, cosmos slightly left, say*gm slightly
right. Monospace was never off, because there one number IS the answer
and 600 was within two thousandths of it.

Only the three generic families are offered. Every renderer that shows
these puts the SVG in a sandbox with no network, so a web font never
loads — it silently substitutes, and the card becomes whatever that
viewer happens to default to. serif, sans-serif and monospace are the
only families that resolve everywhere. These are the metrics of the bold
faces they resolve to almost everywhere; textLength covers the rest.

Three digits per character, in the order of plateOrder. Names are
[a-z0-9-] — lowercase is enforced at registration — so that is the whole
alphabet this has to cover.
*/
const plateOrder = "abcdefghijklmnopqrstuvwxyz0123456789-"

const (
	plateWSerif = "500556444556444333500556278333556278833" +
		"556500556556444389333556500722500500444" +
		"500500500500500500500500500500333"

	plateWSans = "556611556611556333611611278278556278889" +
		"611611611611389556333611556778556556500" +
		"556556556556556556556556556556333"

	plateWMono = "602602602602602602602602602602602602602" +
		"602602602602602602602602602602602602602" +
		"602602602602602602602602602602602"
)

func plateWidths(face string) (tbl string, fallback int) {
	switch face {
	case "mono":
		return plateWMono, 602
	case "serif":
		return plateWSerif, 488
	default:
		return plateWSans, 538
	}
}

func plateFamily(face string) string {
	switch face {
	case "mono":
		return "monospace"
	case "serif":
		return "serif"
	default:
		return "sans-serif"
	}
}

// plateAdvance sums a string's width in thousandths of the type size.
// A character outside the alphabet falls back to the family's average
// rather than to zero: a name that somehow escapes the pattern should
// lay out slightly wrong, not collapse into the asterisk.
func plateAdvance(s, face string) int {
	tbl, fallback := plateWidths(face)
	total := 0
	for i := 0; i < len(s); i++ {
		idx := strings.IndexByte(plateOrder, s[i])
		if idx < 0 || (idx*3+2) >= len(tbl) {
			total += fallback
			continue
		}
		total += int(tbl[idx*3]-'0')*100 + int(tbl[idx*3+1]-'0')*10 + int(tbl[idx*3+2]-'0')
	}
	return total
}

/*
plateSize solves for the largest type size whose width fits.

The asterisk occupies a column of its own, 0.86 of the type size wide,
which is why it is in the denominator rather than added afterwards: the
letters and the asterisk have to shrink together or the proportions
drift as a name gets longer. That is the whole reason this is one
calculation instead of two.

`adv` is the summed advance of both halves, in thousandths.
*/
func plateSize(adv int, face string) int {
	if adv < 1 {
		adv = 1
	}
	// size * (adv/1000 + 0.86) <= avail
	denom := adv + 860
	size := plateAvail * 1000 / denom
	if size > plateMaxSize {
		size = plateMaxSize
	}
	if size < plateMinSize {
		size = plateMinSize
	}
	return size
}

/*
GEOMETRY, all derived from the type size so every proportion holds at
every length.

  capH       0.70 * size   the height of an uppercase letter
  xH         0.52 * size   the height of a lowercase e — no ascender
  starR      0.26 * size   half the x-height, so the asterisk is exactly
                           as tall as an "e" and not as tall as a "b".
                           Matching the cap height made it the tallest
                           thing on the line; names are lowercase, so the
                           x-height is what the eye reads as "letter
                           height" and anything above it reads as a mark
  starArm    0.104 * size  the asterisk's own stroke. This is the weight a
                           MONOSPACED face sets an asterisk at — lighter
                           than the letters around it, because every glyph
                           there has to fit one fixed width — and it is
                           the one that read best of the three that were
                           tried, so it is now the weight in every face
  outline    0.05 * size   the border, on the letters AND the asterisk,
                           the same on both because a border that differs
                           between them looks like a mistake rather than
                           a choice. Thin enough to be a contrast device
                           and not a second typeface: a heavy outline
                           thickens every stem and the name stops looking
                           like the face it was set in
*/
func plateGeom(size int) (capH, xH, starR, starArm, outline int) {
	capH = size * 70 / 100
	xH = size * 52 / 100
	starR = xH / 2
	starArm = size * 104 / 1000
	outline = size * 5 / 100
	if outline < 1 {
		outline = 1
	}
	if starArm < 2 {
		starArm = 2
	}
	return
}

/*
THE SIX RAYS, as unit vectors in thousandths.

An asterisk is six rays at sixty degrees. In SVG's coordinate system y
grows downward, so "up" is negative. cos30 is 866 and cos60 is 500.

Listed in CLOCKWISE SCREEN ORDER starting from straight up, which
starPoly depends on: it walks them in sequence to trace the outline, and
any other order produces a self-intersecting polygon.
*/
var starRays = [6][2]int{
	{0, -1000}, {866, -500}, {866, 500},
	{0, 1000}, {-866, 500}, {-866, -500},
}

/*
starPoints returns the asterisk's outline, IN HUNDREDTHS OF A PIXEL.

WHY IT IS AN OUTLINE AND NOT THREE CROSSING LINES. The border has to be
the same thickness the whole way round, exactly as it is on the letters,
and drawing the shape twice at two stroke widths cannot give that.

A wider stroke offsets a line sideways, but where two arms MEET the two
wide strokes overlap and fill the valley between them in, so the border
is fat at the hub. At the tips it only extends by its own half-width, so
it is thin there. That is not a rounding error, it is the wrong tool.
Widening a stroke is not the same operation as offsetting a boundary, and
they only agree on a shape with no concave corners. An asterisk is
nothing but concave corners.

The letters do not have this problem because a renderer strokes a glyph's
OUTLINE, which is a true offset — every point of the border ends up the
same distance from the edge. So the asterisk gets an outline too, and
then exactly the same two passes the text gets.

WHY HUNDREDTHS, AND NOT WHOLE PIXELS. Because whole pixels made the six
arms different widths, which is worse than the problem above and was
plainly visible. The arm half-width is arm/2, and at the sizes this
actually renders arm is 5, so the half-width is 2.5 — a number a pixel
grid cannot hold. Worse, each direction lost a DIFFERENT amount to
truncation: the vertical arm computed 1000*5/2000 = 2 exactly, while a
diagonal computed (500*5/2000, 866*5/2000) = (1,2), whose length is
2.236. So four arms came out twelve per cent fatter than the other two,
and every arm was a fifth thinner than intended.

SVG coordinates are not integers, so the fix is simply to stop rounding
to them. Everything below is computed in hundredths of a pixel and
printed with two decimals, which brings the six half-widths to 2.500 and
2.496 — a spread of 0.16% instead of 12%.

THE GEOMETRY. Each ray is a rectangle of half-width arm/2 out to radius
r, cut square at the tip. Where two adjacent rays meet, their inner edges
cross on the bisector — and for rays sixty degrees apart that crossing
sits at radius exactly arm, which falls out of the algebra rather than
being tuned. Eighteen points: two tip corners and one valley per ray,
walked in the ray order above.
*/
func starPoints(cx, cy, r, arm int) [18][2]int {
	var out [18][2]int
	for i := 0; i < 6; i++ {
		u := starRays[i]
		n := starRays[(i+1)%6]
		// The perpendicular, pointing toward the NEXT ray.
		px, py := -u[1], u[0]
		// u is in thousandths and the result is in hundredths, so
		// u*r/1000*100 collapses to u*r/10. Likewise p/1000 * arm/2 * 100
		// is p*arm/20.
		ox, oy := cx*100+u[0]*r/10, cy*100+u[1]*r/10
		dx, dy := px*arm/20, py*arm/20
		out[i*3] = [2]int{ox - dx, oy - dy}   // tip, trailing corner
		out[i*3+1] = [2]int{ox + dx, oy + dy} // tip, leading corner
		// The valley, on the bisector at radius arm. |u+n| is 1732 for
		// rays sixty degrees apart, so this normalises it.
		out[i*3+2] = [2]int{
			cx*100 + (u[0]+n[0])*arm*100/1732,
			cy*100 + (u[1]+n[1])*arm*100/1732,
		}
	}
	return out
}

// hundredths formats a coordinate held in hundredths of a pixel.
//
// Two things it must not do, both found the hard way. The sign is peeled
// off first, because integer division truncates toward zero on BOTH
// halves and -250 would otherwise print as "-2.-50". And the fraction is
// assembled a digit at a time rather than with "%02d", because ufmt does
// not implement the zero-padding flag — it silently printed 68.0 where
// two digits were asked for, which the mirror diff caught as drift.
func hundredths(v int) string {
	sign := ""
	if v < 0 {
		sign, v = "-", -v
	}
	f := v % 100
	return ufmt.Sprintf("%s%d.%d%d", sign, v/100, f/10, f%10)
}

func starPoly(cx, cy, r, arm int) string {
	pts := starPoints(cx, cy, r, arm)
	var b strings.Builder
	for i := 0; i < len(pts); i++ {
		if i > 0 {
			b.WriteString(" ")
		}
		b.WriteString(hundredths(pts[i][0]))
		b.WriteString(",")
		b.WriteString(hundredths(pts[i][1]))
	}
	return b.String()
}

// starSVG draws the asterisk in the two passes the lettering uses:
// border first at twice the width, ink over it. No face argument — one
// asterisk in every face, see the note at the top of the file.
func starSVG(cx, cy, r, arm, outline int, ink, edge string) string {
	pts := starPoly(cx, cy, r, arm)
	return ufmt.Sprintf(
		`<polygon points="%s" fill="%s" stroke="%s" stroke-width="%d" stroke-linejoin="round"/>`+
			`<polygon points="%s" fill="%s"/>`,
		pts, edge, edge, outline*2, pts, ink)
}

/*
NameplateSVG composites the name, the asterisk and the expiry over
whatever is already on the card.

  face   "mono" | "serif" | "sans"
  pos    "top" | "middle" | "bottom"
  light  true  = white letters with a black border
         false = black letters with a white border

Only two ink pairs exist, and that is not a limitation waiting to be
lifted. Both read on every background there is; a free colour choice does
not, and mid-grey lettering on a mid-grey drawing is exactly what
somebody will pick.
*/
// `now` is deliberately absent from the signature. Nothing here counts
// down, so nothing here needs the clock — see the note on the expiry.
func NameplateSVG(label, domain, face, pos string, light bool, expires int64) string {
	lAdv := plateAdvance(label, face)
	dAdv := plateAdvance(domain, face)
	size := plateSize(lAdv+dAdv, face)
	_, xH, starR, starArm, outline := plateGeom(size)
	fam := plateFamily(face)

	ink, edge := "#ffffff", "#0b0d10"
	if !light {
		ink, edge = "#0b0d10", "#ffffff"
	}

	var baseY, dateY int
	switch pos {
	case "top":
		baseY, dateY = 96, 356
	case "bottom":
		baseY, dateY = 322, 96
	default:
		baseY, dateY = 212, 356
	}

	/*
		THE TWO HALVES ARE ANCHORED TO THE ASTERISK, AND THEIR WIDTHS ARE
		DICTATED RATHER THAN GUESSED.

		Two faults came out of the same root, and the same pair of
		mechanisms closes both.

		The GAP before the asterisk: the width was estimated, and the
		estimate placed both the end of the label and the asterisk, so any
		error between the two opened up as a hole.

		The whole name sitting OFF CENTRE: the composition is centred on
		x0, computed from that same estimate. Work it through and the
		asterisk lands at 200 + (lw-dw)/2 when it needs to land at
		200 + (trueLw-trueDw)/2. The error is half the difference of the
		two errors — so a long narrow label against a short domain slid
		right, and the reverse slid left. Exactly what the proof sheet
		showed.

		FIRST, the halves are anchored TO the asterisk — label right,
		domain left — which hands the placement of the glyphs relative to
		it back to the renderer. That kills the gap outright.

		SECOND, and this is what makes the centring exact: textLength. SVG
		lets an element declare its own advance width and the renderer
		fits the text to it. So lw and dw stop being predictions and
		become instructions: whatever font the viewer actually resolved,
		the label occupies exactly lw and the domain exactly dw, and the
		arithmetic that centres them is true by construction rather than
		by luck.

		lengthAdjust="spacing", never "spacingAndGlyphs" — it moves the
		letters apart, it does not squeeze their shapes. With the real
		width table above, the adjustment on the usual fonts is nil, and
		on a substituted one it is a fraction of a pixel of tracking.
		Distorting glyphs to save a rounding error would be a bad trade.

		The one case left is a single-character half on a substituted
		font: there are no inter-glyph gaps, so "spacing" has nothing to
		adjust. The table is exact for one character by definition, so
		this only misses when the font ALSO substituted, and then by a few
		pixels. Left deliberately — the alternative distorts the glyph.
	*/
	lw := lAdv * size / 1000
	dw := dAdv * size / 1000
	starCol := size * 86 / 100
	total := lw + starCol + dw
	x0 := (plateW - total) / 2

	starCX := x0 + lw + starCol/2
	// Centred on the x-height, so the asterisk sits in the same optical
	// band as the lowercase letters either side of it.
	starCY := baseY - xH/2
	labelX := starCX - starCol/2
	domainX := starCX + starCol/2

	var b strings.Builder

	// One pass per layer. Border first, ink second, so the border sits
	// behind the letter rather than eating half of it. textLength goes on
	// every pass, or the two would disagree about where the letters are.
	const half = `<text x="%d" y="%d" text-anchor="%s" textLength="%d" lengthAdjust="spacing"` +
		` fill="none" stroke="%s" stroke-width="%d" stroke-linejoin="round">%s</text>`
	const fill = `<text x="%d" y="%d" text-anchor="%s" textLength="%d" lengthAdjust="spacing"` +
		` fill="%s">%s</text>`

	b.WriteString(ufmt.Sprintf(`<g font-family="%s" font-size="%d" font-weight="bold">`, fam, size))
	b.WriteString(ufmt.Sprintf(half, labelX, baseY, "end", lw, edge, outline*2, esc(label)))
	b.WriteString(ufmt.Sprintf(half, domainX, baseY, "start", dw, edge, outline*2, esc(domain)))
	b.WriteString(ufmt.Sprintf(fill, labelX, baseY, "end", lw, ink, esc(label)))
	b.WriteString(ufmt.Sprintf(fill, domainX, baseY, "start", dw, ink, esc(domain)))
	b.WriteString(`</g>`)

	b.WriteString(starSVG(starCX, starCY, starR, starArm, outline, ink, edge))

	/*
		THE EXPIRY, ON EVERY CARD, AS A DATE AND NOTHING ELSE.

		The ordinary card alternates a date with a countdown and carries a
		long note about which one a still frame must land on. A skinned
		card skips the problem: a marketplace thumbnail of "412 days left"
		is a number that was true once and is a lie afterwards, while a
		date is true forever. One sentence, always the same one.
	*/
	dateSize := 15
	// Same format the ordinary card already uses for an expiry, so a
	// skinned card and a plain one do not disagree about how a date looks.
	txt := "EXPIRES ON " + strings.ToUpper(time.Unix(expires, 0).UTC().Format("Jan 2, 2006"))
	b.WriteString(ufmt.Sprintf(
		`<g font-family="monospace" font-size="%d" font-weight="bold" text-anchor="middle">`+
			`<text x="200" y="%d" fill="none" stroke="%s" stroke-width="4" stroke-linejoin="round">%s</text>`+
			`<text x="200" y="%d" fill="%s">%s</text></g>`,
		dateSize, dateY, edge, txt, dateY, ink, txt))

	return b.String()
}
