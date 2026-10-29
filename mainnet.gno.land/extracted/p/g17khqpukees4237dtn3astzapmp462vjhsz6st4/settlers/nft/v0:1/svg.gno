package nft

import (
	"encoding/base64"
	"strconv"
)

// CanonicalSize is the width and height in pixels of the image used for NFTs.
const CanonicalSize = 512

// Options are the options to render a gnome.
type Options struct {
	// Size is the width and the height of the image in pixels, because the image is a square.
	// Multiples of 32 keep every art pixel as a whole number of screen pixels.
	// Zero omits the width and height, so that the image scales to its container.
	Size int

	// NoBackground omits the background.
	NoBackground bool

	// BackgroundColor replaces the color of the background, in "#rrggbb" format.
	BackgroundColor string
}

// RenderSVG renders the gnome as an SVG document.
// Traits must be valid.
// The same traits and options always give the same bytes.
func RenderSVG(t Traits, o Options) string {
	return render(t, o, &rawSyntax)
}

// RenderSeed renders the gnome of a seed as an SVG document.
func RenderSeed(seed string, o Options) string {
	return RenderSVG(NewTraits(seed), o)
}

// RenderDataURI renders the gnome as a "data:image/svg+xml;charset=utf-8," URI, percent-encoded.
//
// Cheapest way to embed a gnome.
// SVG is written encoded, instead of encoding it afterwards.
// Traits must be valid.
func RenderDataURI(t Traits, o Options) string {
	return "data:image/svg+xml;charset=utf-8," + render(t, o, &uriSyntax)
}

// DataURI encodes an SVG document as a "data:image/svg+xml;base64," URI.
// It is slower than RenderDataURI, use it when Base64 is needed.
func DataURI(svg string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

// syntax define the fixed pieces of the SVG document, that are the same for every gnome.
type syntax struct {
	open       string // start of the svg element, up to its size
	widthOpen  string
	heightOpen string
	sizeClose  string
	openEnd    string // end of the start of the svg element
	rectOpen   string // background, before its color
	rectClose  string
	pathOpen   string // before the color
	pathMid    string // after the color, before the segments
	pathClose  string
	end        string
	mHead      []string // start of a segment, by x
}

// rawSyntax contains the fixed pieces of the SVG document.
var rawSyntax = syntax{
	open:       `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-4 0 32 32"`,
	widthOpen:  ` width="`,
	heightOpen: `" height="`,
	sizeClose:  `"`,
	openEnd:    ` shape-rendering="crispEdges">`,
	rectOpen:   `<rect x="-4" width="32" height="32" fill="#`,
	rectClose:  `"/>`,
	pathOpen:   `<path fill="#`,
	pathMid:    `" d="`,
	pathClose:  `"/>`,
	end:        `</svg>`,
	mHead:      rawMHead[:],
}

// uriSyntax contains the fixes pieces of the SVG document encoded for data URI.
var uriSyntax = syntax{
	open:       `%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%22-4%200%2032%2032%22`,
	widthOpen:  `%20width=%22`,
	heightOpen: `%22%20height=%22`,
	sizeClose:  `%22`,
	openEnd:    `%20shape-rendering=%22crispEdges%22%3E`,
	rectOpen:   `%3Crect%20x=%22-4%22%20width=%2232%22%20height=%2232%22%20fill=%22%23`,
	rectClose:  `%22/%3E`,
	pathOpen:   `%3Cpath%20fill=%22%23`,
	pathMid:    `%22%20d=%22`,
	pathClose:  `%22/%3E`,
	end:        `%3C/svg%3E`,
	mHead:      uriMHead[:],
}

// maxGroups is the biggest number of different colors of a gnome: 22 keys.
const maxGroups = 24

// render draws the gnome:
//   - Pixels are scanned row by row, and horizontal runs of the same key are one segment.
//   - Segments are grouped by color, in the order in which each color appears first.
func render(t Traits, o Options, s *syntax) string {
	g := buildGrid(t)
	bg := bgColors[t.Background]
	if o.BackgroundColor != "" {
		bg = hexColor(o.BackgroundColor)
	}

	var (
		groupOf    [128]uint8 // group of a key plus one, or 0 when the key was not seen
		groupColor [maxGroups]string
		groupPath  [maxGroups]string
		groups     int
	)
	for y := 0; y < gridH; y++ {
		row := g[y*gridW : (y+1)*gridW]
		for x := 0; x < gridW; {
			c := row[x]
			if c == 0 {
				x++
				continue
			}

			n := 1
			for x+n < gridW && row[x+n] == c {
				n++
			}

			gi := int(groupOf[c])
			if gi == 0 {
				// First time that the key is seen, its color might be already used by another key
				color := colorOf(t, c)
				for i := 0; i < groups; i++ {
					if groupColor[i] == color {
						gi = i + 1
						break
					}
				}

				if gi == 0 {
					groupColor[groups] = color
					groups++
					gi = groups
				}

				groupOf[c] = uint8(gi)
			}

			gi--
			groupPath[gi] += s.mHead[x] + nums[y] + runTail[n]
			x += n
		}
	}

	out := s.open
	if o.Size > 0 {
		px := strconv.Itoa(o.Size)
		out += s.widthOpen + px + s.heightOpen + px + s.sizeClose
	}

	out += s.openEnd
	if !o.NoBackground {
		out += s.rectOpen + bg + s.rectClose
	}

	for i := 0; i < groups; i++ {
		out += s.pathOpen + groupColor[i] + s.pathMid + groupPath[i] + s.pathClose
	}
	return out + s.end
}

// colorOf returns the color of a palette key, in hex digits.
func colorOf(t Traits, key byte) string {
	if c := fixedColor(key); c != "" {
		return c
	}

	skin := int(t.Skin) * 3
	hat := int(t.Hat) * 3
	beard := int(t.BeardColor) * 3
	tunic := int(t.Tunic) * 3

	switch key {
	case 't':
		return skinColors[skin]
	case 's':
		return skinColors[skin+1]
	case 'u':
		return skinColors[skin+2]
	case 'h':
		return hatColors[hat]
	case 'H':
		return hatColors[hat+1]
	case 'j':
		return hatColors[hat+2]
	case 'w':
		return beardColors[beard]
	case 'W':
		return beardColors[beard+1]
	case 'x':
		return beardColors[beard+2]
	case 'c':
		return tunicColors[tunic]
	case 'C':
		return tunicColors[tunic+1]
	case 'd':
		return tunicColors[tunic+2]
	case 'g':
		return glassesColors[t.Glasses-1]
	}
	panic("unknown palette key " + string(rune(key)))
}

// hexColor checks a "#rrggbb" color and returns its hex digits.
func hexColor(color string) string {
	if len(color) != 7 || color[0] != '#' {
		panic("invalid background color, expected #rrggbb")
	}

	for i := 1; i < 7; i++ {
		c := color[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			panic("invalid background color, expected #rrggbb")
		}
	}
	return color[1:]
}
