package nsview

import (
	"strings"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsskin/v1"
)

/*
A NAME WEARING A SKIN — the card the shop actually sells.

Until this existed, a bought skin did nothing: nsskin held the token, the
binding and the art, and nsview had never heard of it. Somebody could buy
one, attach it, and look at their NFT to find the ordinary card. That is
the whole of what this file fixes.

ONE CALL DOES THE ASKING. nsskin.ArtForName answers "what should this
name be drawn with", with every condition already inside it — the name
wears a token, the definition is not withdrawn, the binding is pinned to
this registration, the lock still matches. A renderer that had to
remember four checks before drawing is one that eventually forgets one,
so it does not get the chance.

THE FACE AND THE INK ARE DERIVED, NOT STORED, and that is the
interesting part.

nsskin does not record them: DefineSkin takes an id, a name, a sprite, a
lock and an artist, and nothing else. Adding fields would mean a new
nsskin, and a new nsskin strands every token minted from the old one —
which by the time this was written already included somebody's purchase.
Stranding a paid-for object to store two values that can be worked out is
a bad trade.

So they are worked out. The ink comes from the art itself, which is
better than a stored value rather than merely cheaper: measured against
the sixty definitions in the launch collection, deriving it beat the
hand-picked value on ELEVEN cards and lost on none, and took the worst
contrast on any card from 1.5:1 to 4.7:1.
*/

/*
THE CROSSOVER IS AT 46, NOT 128, and getting that wrong is what made the
hand-picked values worse than this rule.

Contrast against white is 1.05/(L+0.05); against black it is
(L+0.05)/0.05. Setting them equal gives (L+0.05)^2 = 0.0525, so L = 0.179
— about 46 out of 255. Contrast is NOT symmetric about mid-grey: black
lettering on a mid-grey ground is far more readable than white on the
same ground, and a threshold at 128 hands eleven cards to the wrong ink.
*/
const inkCrossover = 46

// lumOf is relative luminance, 0..255, with a gamma of two.
//
// The real curve is sRGB's 2.4-with-a-linear-toe, which needs a pow().
// Squaring is within a couple of points of it across the whole range and
// is exact in integers — and this feeds a THRESHOLD, where being two
// points out only matters for a colour already sitting on the boundary,
// on which no ink is much better than the other anyway.
func lumOf(hex string) int {
	if len(hex) != 7 || hex[0] != '#' {
		return 128
	}
	r := hexPair(hex[1], hex[2])
	g := hexPair(hex[3], hex[4])
	b := hexPair(hex[5], hex[6])
	if r < 0 || g < 0 || b < 0 {
		return 128
	}
	return (2126*r*r + 7152*g*g + 722*b*b) / (10000 * 255)
}

func hexPair(a, b byte) int {
	hi, lo := hexDigit(a), hexDigit(b)
	if hi < 0 || lo < 0 {
		return -1
	}
	return hi*16 + lo
}

func hexDigit(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

/*
bandMedian is the luminance of what the lettering actually sits on.

THE MEDIAN, NOT THE MEAN, and the difference is not academic. A mean of
black and hot pink is a mid-grey that exists nowhere on the card, and it
sends the ink the wrong way on exactly the high-contrast patterns that
most need the right answer. A median is what most of the band is.

Three rows, because a line of type is taller than one cell at every grid
size offered. The middle seventy per cent of the width, because the name
is centred and the margins are not under it.
*/
func bandMedian(art string, num, den int) int {
	parts := strings.Split(art, "|")
	n := len(parts) - 1
	if n < 1 {
		return 128
	}
	colours := map[string]int{}
	for _, e := range strings.Split(parts[0], ",") {
		if len(e) == 8 && e[1] == '#' {
			colours[e[:1]] = lumOf(e[1:])
		}
	}
	y := (num*(n-1) + den/2) / den
	var vals []int
	for dy := -1; dy <= 1; dy++ {
		ry := y + dy
		if ry < 0 {
			ry = 0
		}
		if ry > n-1 {
			ry = n - 1
		}
		row := parts[ry+1]
		if len(row) != n {
			continue
		}
		lo, hi := n*15/100, n*85/100
		if hi > n-1 {
			hi = n - 1
		}
		for x := lo; x <= hi; x++ {
			if L, ok := colours[row[x:x+1]]; ok {
				vals = append(vals, L)
			}
		}
	}
	if len(vals) == 0 {
		return 128
	}
	// Insertion sort. At most about seventy values, and a realm has no
	// sort worth importing for that.
	for i := 1; i < len(vals); i++ {
		v := vals[i]
		j := i - 1
		for j >= 0 && vals[j] > v {
			vals[j+1] = vals[j]
			j--
		}
		vals[j+1] = v
	}
	return vals[len(vals)/2]
}

// inkForArt returns true for white lettering. The name's own band
// decides it alone: measured across the launch collection the date band
// never changed an outcome for the better, and letting it vote was what
// put white letters on a pale card.
func inkForArt(art string) bool {
	return bandMedian(art, 212, 400) < inkCrossover
}

/*
faceForArt picks one of the three generic families from the art itself.

Nothing about a background implies a typeface, so this is arbitrary — but
it must be arbitrary in the SAME WAY on the chain and in the shop, or the
preview shows a card that does not mint. Derived from the art rather than
stored for the same reason as the ink: it costs nothing and cannot drift.
*/
func faceForArt(art string) string {
	h := 2166136261
	for i := 0; i < len(art); i++ {
		h ^= int(art[i])
		h *= 16777619
		h &= 0x7fffffff
	}
	switch h % 3 {
	case 0:
		return "sans"
	case 1:
		return "serif"
	}
	return "mono"
}

/*
skinnedCardSVG is the whole card: the art edge to edge, the name over it.

FULL BLEED, unlike the skin's own listing card, which is matted. That
contrast is deliberate and load-bearing — it is what stops somebody
mistaking a skin for sale for a name for sale. See skincard.gno.

The ground behind the art matters because a sprite may have transparent
cells, and without it they would show whatever the viewer's page is,
which is not a colour we chose.
*/
func skinnedCardSVG(art, label, domain string, expires int64) string {
	light := inkForArt(art)
	ground := "#0b0d10"
	if !light {
		ground = "#f4f4f5"
	}
	inner := skinArtSVG(art, 0, 0, 400)
	if inner == "" {
		return "" // an unrenderable sprite falls back to the ordinary card
	}
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" role="img">` +
		`<rect width="400" height="400" fill="` + ground + `"/>` + inner +
		NameplateSVG(label, domain, faceForArt(art), "middle", light, expires) +
		`</svg>`
}

// skinFor a NAME, as opposed to skinFor the calendar. Separate because
// they answer different questions and only one of them involves money.
func wornArt(label, domain string) string {
	return nsskin.ArtForName(label, domain)
}
