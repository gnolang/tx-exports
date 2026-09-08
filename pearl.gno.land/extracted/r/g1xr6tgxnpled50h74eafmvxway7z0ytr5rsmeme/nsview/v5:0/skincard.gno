package nsview

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

/*
THE SKIN'S OWN CARD — what a skin token looks like when it is the thing
being listed, rather than the thing decorating a name.

WHY IT EXISTS. A skin is a separate token (see SKINS.md §1), so it has
its own listing on any marketplace that shows it. Drawn the way a name
card is drawn — art edge to edge, big lettering over the top — the two
would be indistinguishable, and somebody would buy a picture believing
they had bought a name. That is not a subtle risk: it is the single most
likely way this product hurts somebody.

THE FRAME IS THE WHOLE IDEA. A name card is FULL BLEED; this one is
MATTED, with the art inset inside a border and bands of ground above and
below it. The distinction survives at thumbnail size, at a glance, with
no text read at all — which is the only size and attention a marketplace
grid actually gets. The word SKIN across the top is the confirmation, not
the mechanism.

IT NAMES ITSELF, and it says what it will not go on. An extension-locked
skin that does not say so is a support ticket per sale.

WHAT IT DELIBERATELY DOES NOT SHOW: a price, an edition number, a rarity,
or anything else that frames the object as an investment. That rule is
from the risk policy and it applies to the artwork as much as to the copy
on the site — the card travels to places our words do not.
*/

// The matte. A name card uses all 400; this one is inset, and the inset
// is the tell.
const (
	skinTop  = 74 // the band the word SKIN sits in
	skinFoot = 62 // the band the skin's own name sits in

	// THE ART IS SQUARE, and its size is whatever the SHORTER dimension
	// allows — which is the height, because the two label bands eat into
	// it and the sides only give up a margin.
	//
	// This started as "340 wide" and was wrong: 340 is what the width
	// allows, but only 264 of height remains once the bands are taken,
	// so the art ran 76px down into the footer and sat behind the skin's
	// own name. A square sprite drawn into a non-square box either
	// stretches or overflows, and both are worse than being smaller.
	skinBox = 400 - skinTop - skinFoot // 264
	// Centred on what is left, so the side margins come out equal.
	skinPad = (400 - skinBox) / 2 // 68
)

/*
skinArtSVG renders a sprite to fill a box, INFERRING THE GRID from the
data rather than assuming twelve.

spriteSVG hardcodes twelve in four places, which is right for the domain
artwork it was written for and wrong here: SKINS.md §2a offers 12, 16, 24
and 32, and the whole point of inferring is that one format then covers
every size and every sprite already on chain keeps working.

Validation is spriteSVG's, unchanged and unrelaxed, because it is not
merely a parser — it is the thing standing between community-authored
data and markup inside somebody else's wallet. Any violation rejects the
WHOLE sprite rather than skipping the bad part: a partial picture hides
the fault.
*/
func skinArtSVG(enc string, ox, oy, box int) string {
	if enc == "" {
		return ""
	}
	parts := strings.Split(enc, "|")
	n := len(parts) - 1
	if n < 4 || n > 64 {
		return ""
	}
	colours := map[string]string{}
	for _, entry := range strings.Split(parts[0], ",") {
		if len(entry) != 8 || entry[1] != '#' {
			return ""
		}
		if !isHexColour(entry[1:]) {
			return ""
		}
		colours[entry[:1]] = entry[1:]
	}

	/*
		EVERY CELL IS PLACED FROM ITS OWN EXACT BOUNDARY, never from an
		accumulated cell size.

		The obvious way — cell := box / n, then x*cell — truncates once
		and then repeats the error n times, so the art stops short of its
		own frame by up to n pixels. Scaling the cell by a thousand first
		does not fix it either: at n=12 in a 340 box the cell is 28.333,
		28333 x 12 is 339996, and the last column still lands a pixel
		inside the frame. Which is a full pixel of bare matte down one
		edge, and by eye it reads as a design choice rather than a bug.

		Computing each boundary as x*box/n instead makes the LAST one
		exactly n*box/n = box, at every grid size, with no accumulation
		to go wrong.

		RUNS OF ONE COLOUR BECOME ONE RECT, which SKINS.md §2a asked for
		before the grid went much past 32 and which the collection has now
		made urgent rather than tidy.

		Every painted cell used to emit its own <rect>, inside every
		wallet that renders the card. That is tolerable for a sprite of a
		thing and ruinous for a BACKGROUND: a vertical gradient is one
		colour per row, so a 32-wide one emitted 1,024 rects to draw 32
		distinct bands. Merging horizontal runs draws it in 32 — the same
		picture, pixel for pixel, at a thirty-second of the markup.

		It costs nothing when it does not apply. A busy sprite with no
		horizontal runs merges nothing and emits exactly what it did
		before.
	*/
	var b strings.Builder
	for y := 1; y <= n; y++ {
		row := parts[y]
		if len(row) != n {
			return ""
		}
		y0 := oy + (y-1)*box/n
		h := oy + y*box/n - y0
		for x := 0; x < n; {
			ch := row[x : x+1]
			if ch == "." {
				x++
				continue
			}
			c, ok := colours[ch]
			if !ok {
				return ""
			}
			// How far this colour runs.
			run := x + 1
			for run < n && row[run:run+1] == ch {
				run++
			}
			x0 := ox + x*box/n
			w := ox + run*box/n - x0
			b.WriteString(ufmt.Sprintf(
				`<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>`,
				x0, y0, w, h, c))
			x = run
		}
	}
	if b.Len() == 0 {
		return ""
	}
	return b.String()
}

/*
SkinCardSVG draws a skin token's own listing card.

	name   the skin's name, as the shop shows it
	art    the sprite string
	lock   the extension it is restricted to, or "" for one that goes
	       on any name
	light  true  = pale lettering on a dark matte
	       false = dark lettering on a pale matte

The return is a whole document rather than a fragment, because unlike the
nameplate this composites over nothing — it IS the card.
*/
func SkinCardSVG(name, art, lock string, light bool) string {
	ink, edge, matte := "#f4f4f5", "#26262b", "#0b0d10"
	if !light {
		ink, edge, matte = "#0b0d10", "#d4d4d8", "#f4f4f5"
	}

	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">`)
	b.WriteString(ufmt.Sprintf(`<rect width="400" height="400" fill="%s"/>`, matte))

	// THE WORD, big and flat across the top. Monospace and letter-spaced
	// so it reads as a label on the object rather than as a title for it.
	b.WriteString(ufmt.Sprintf(
		`<text x="%d" y="46" font-family="monospace" font-size="27" font-weight="bold"`+
			` letter-spacing="7" fill="%s">SKIN</text>`, skinPad, ink))

	// The art, inset, with a frame drawn AROUND it rather than over it —
	// a border that overlapped would eat a row of somebody's pixels.
	inner := skinArtSVG(art, skinPad, skinTop, skinBox)
	if inner == "" {
		// A skin whose art will not parse still has to render as
		// something, or the listing is a blank square with no clue why.
		b.WriteString(ufmt.Sprintf(
			`<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="%s"`+
				` stroke-width="2" stroke-dasharray="7 6"/>`,
			skinPad, skinTop, skinBox, skinBox, edge))
		b.WriteString(ufmt.Sprintf(
			`<text x="200" y="%d" text-anchor="middle" font-family="monospace"`+
				` font-size="13" fill="%s">ART WILL NOT RENDER</text>`,
			skinTop+skinBox/2, edge))
	} else {
		b.WriteString(inner)
	}
	b.WriteString(ufmt.Sprintf(
		`<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="%s" stroke-width="2"/>`,
		skinPad-1, skinTop-1, skinBox+2, skinBox+2, edge))

	// The skin's own name, and what it will not go on.
	b.WriteString(ufmt.Sprintf(
		`<text x="%d" y="%d" font-family="sans-serif" font-size="21" font-weight="bold"`+
			` fill="%s">%s</text>`,
		skinPad, 400-skinFoot+34, ink, esc(name)))

	tail := "goes on any name"
	if lock != "" {
		tail = "*" + lock + " names only"
	}
	b.WriteString(ufmt.Sprintf(
		`<text x="%d" y="%d" text-anchor="end" font-family="monospace" font-size="12"`+
			` letter-spacing="1" fill="%s">%s</text>`,
		400-skinPad, 400-skinFoot+34, edge, esc(strings.ToUpper(tail))))

	b.WriteString(`</svg>`)
	return b.String()
}
