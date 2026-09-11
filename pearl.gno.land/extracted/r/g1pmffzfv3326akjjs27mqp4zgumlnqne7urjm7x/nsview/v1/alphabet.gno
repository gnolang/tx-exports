package nsview

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

/*
A HAND-DRAWN ALPHABET, STORED ONCE.

WHY THIS EXISTS. Every renderer that shows these cards — wallets,
marketplaces, block explorers — puts the SVG in a sandbox with no
network. A web font therefore never loads; it silently substitutes, and
the display lettering the mockups were designed around turns into
whatever that particular viewer happens to default to. Only the generic
families (serif, sans-serif, monospace) can be relied on, and none of
them is a marker pen.

The only way to get identical letterforms on every device is to ship the
letters themselves. These are strokes, not outlines: a path with a round
cap and a thick stroke looks like a pen, costs a fraction of the data an
outline font would, and scales without a second set of hinting.

THESE LETTERFORMS ARE OUR OWN. They are not traced from, derived from, or
measured against any existing typeface. A typeface is somebody's design
and often somebody's licensed asset; drawing our own marker capitals is
both cheaper and the only version we are entitled to put on chain
permanently. The house rule elsewhere on this project is "original art in
the spirit of the thing", and a font is art.

WHAT IT COSTS. Storage is 100 ugnot a byte and permanent, so the
encoding is deliberately dense rather than readable: each point is two
characters, each stroke is a run of points, strokes are separated by "|".
The whole alphabet — twenty-six letters, ten digits, and the punctuation
this project actually uses — is well under a kilobyte. An outline font
would have been tens of kilobytes and unreadable besides.

THE GRID. Ten wide by fourteen tall, origin top-left, so a glyph reads
directly as coordinates: "0d" is the bottom-left corner and "47" is the
middle. x never exceeds 9, so it is always one digit; y reaches 13, so
10..13 are written a..d.
*/

// glyph returns the stroke encoding for one character, or "" for
// anything unknown — an unknown character draws nothing rather than a
// box, because this markup lands inside a token that other people's
// software renders and a missing letter is better than a wrong one.
func glyph(c byte) string {
	switch c {
	// Generated from a readable point table rather than typed by
	// hand: forty glyphs of paired coordinate characters is precisely
	// the job where one stray character shifts a whole letter by one and
	// nobody spots it until it is on chain forever.
	case 'A':
		return "0d409d|2878"
	case 'B':
		return "000d|006206|06790d"
	case 'C':
		return "824014194d8b"
	case 'D':
		return "000d|00737a0d"
	case 'E':
		return "80000d8d|0666"
	case 'F':
		return "80000d|0666"
	case 'G':
		return "824014194d8b8757"
	case 'H':
		return "000d|909d|0696"
	case 'I':
		return "2070|404d|2d7d"
	case 'J':
		return "707a4d1a"
	case 'K':
		return "000d|8007|359d"
	case 'L':
		return "000d8d"
	case 'M':
		return "0d1047809d"
	case 'N':
		return "0d009d90"
	case 'O':
		return "4014194d898440"
	case 'P':
		return "0d00727507"
	case 'Q':
		return "4014194d898440|6a9d"
	case 'R':
		return "0d00727507|379d"
	case 'S':
		return "824013678a4d1b"
	case 'T':
		return "0090|404d"
	case 'U':
		return "00094d8980"
	case 'V':
		return "004d90"
	case 'W':
		return "002d457d90"
	case 'X':
		return "009d|900d"
	case 'Y':
		return "004790|474d"
	case 'Z':
		return "00900d9d"
	case '0':
		return "4014194d898440|2974"
	case '1':
		return "23404d|2d7d"
	case '2':
		return "1340830d9d"
	case '3':
		return "11508446|46895d1b"
	case '4':
		return "7d700999"
	case '5':
		return "80101666895d1b"
	case '6':
		return "7140151a5d8a5718"
	case '7':
		return "00903d"
	case '8':
		return "4613407346194d7946"
	case '9':
		return "8647144084895d2c"
	case '*':
		return "424a|1479|7419"
	case '-':
		return "1787"
	case '.':
		return "4c4d"
	case '!':
		return "4049|4c4d"
	case '?':
		return "1340734749|4c4d"
	case '\'':
		return "4043"
	case ' ':
		return ""
	}
	return ""
}

const (
	glyphW  = 10 // grid width of one glyph
	glyphH  = 14 // grid height, top to bottom
	glyphAd = 12 // advance: glyph width plus the gap to the next one
)

// hexish decodes one coordinate character. Digits are themselves; a..d
// carry 10..13, which is the only reason y can exceed nine in two
// characters.
func hexish(c byte) int {
	if c >= '0' && c <= '9' {
		return int(c - '0')
	}
	if c >= 'a' && c <= 'd' {
		return int(c-'a') + 10
	}
	return -1
}

/*
MarkerText draws a line of text as stroked paths.

`size` is the CAP HEIGHT in user units, not an em size: it is the height
of a capital letter, which is the measurement anybody positioning this by
eye is actually thinking in.

`x` is the left edge and `y` is the TOP of the capitals, matching how the
rest of this file positions things and unlike SVG's own text baseline,
which is a trap when mixing the two.

The jitter is what makes it read as a pen rather than a plotter. It is
derived from the character and its position, so it is stable: the same
string renders identically on every read, which matters because these
cards are regenerated constantly and a letter that wobbled between reads
would look like a rendering fault.
*/
func MarkerText(s string, x, y, size int, colour string, weight int) string {
	if s == "" || size <= 0 {
		return ""
	}
	if weight <= 0 {
		weight = 1 + size/7
	}
	var out strings.Builder
	out.WriteString(ufmt.Sprintf(
		`<g fill="none" stroke="%s" stroke-width="%d" stroke-linecap="round" stroke-linejoin="round">`,
		colour, weight))

	up := strings.ToUpper(s)
	for i := 0; i < len(up); i++ {
		enc := glyph(up[i])
		if enc == "" {
			continue
		}
		ox := x + i*glyphAd*size/glyphH
		out.WriteString(strokes(enc, ox, y, size, i))
	}
	out.WriteString(`</g>`)
	return out.String()
}

// strokes turns one glyph's encoding into path elements at a position.
func strokes(enc string, ox, oy, size, idx int) string {
	var out strings.Builder
	for _, run := range strings.Split(enc, "|") {
		d := ""
		n := 0
		for j := 0; j+1 < len(run); j += 2 {
			gx := hexish(run[j])
			gy := hexish(run[j+1])
			if gx < 0 || gy < 0 {
				continue // a space inside an encoding is padding, not a point
			}
			// Scale from the grid to cap height, then nudge. The nudge is
			// at most one unit and comes from a fixed mix of the glyph
			// index and the point index, so it never changes between reads.
			px := ox + gx*size/glyphH
			py := oy + gy*size/glyphH
			px += wobble(idx*7 + j*3)
			py += wobble(idx*5 + j*11 + 1)
			if n == 0 {
				d += ufmt.Sprintf("M%d %d", px, py)
			} else {
				d += ufmt.Sprintf("L%d %d", px, py)
			}
			n++
		}
		if n > 1 {
			out.WriteString(`<path d="` + d + `"/>`)
		} else if n == 1 {
			// A single point would draw nothing without a round cap on a
			// zero-length path, which not every renderer honours. Give it
			// a hair of length instead.
			out.WriteString(`<path d="` + d + `l1 0"/>`)
		}
	}
	return out.String()
}

// wobble is a tiny deterministic offset in the range -1..1. Not random:
// the cards are regenerated on every read, and anything genuinely random
// would make the lettering shimmer.
func wobble(seed int) int {
	return (seed*2654435761)%3 - 1
}

// MarkerWidth is what MarkerText will occupy, so a caller can centre it.
// Counts every character including the ones that draw nothing, because a
// space still advances.
func MarkerWidth(s string, size int) int {
	if s == "" {
		return 0
	}
	return len(s) * glyphAd * size / glyphH
}

// MarkerCentred draws text centred on cx, which is what almost every
// caller here wants and what the SVG text-anchor attribute would have
// done for them if a font had been available.
func MarkerCentred(s string, cx, y, size int, colour string, weight int) string {
	return MarkerText(s, cx-MarkerWidth(s, size)/2, y, size, colour, weight)
}
