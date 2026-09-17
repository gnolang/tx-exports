package pixelgnomes

import (
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// The drawing. A port of the Classic trait sheet: a 20×28 gnome sprite on a
// 32×32 canvas, with nine traits layered on top. Integer arithmetic only.

const (
	side       = 32
	traitCount = 9
	ink        = "#1b1b22"
	white      = "#ffffff"
)

type option struct{ name, color string }

var traitNames = [traitCount]string{"hat", "pattern", "beard", "coat", "skin", "eyes", "accessory", "friend", "background"}

var (
	hats     = []option{{"red", "#d63c3c"}, {"blue", "#3867d6"}, {"green", "#4f9d4a"}, {"purple", "#8e4fc9"}, {"orange", "#f07f2d"}, {"pink", "#ff7fb5"}, {"teal", "#2aa198"}, {"navy", "#283a8f"}, {"ice", "#6fd3e8"}, {"berry", "#a33b5c"}, {"slate", "#5c6b73"}, {"gold", "#f2c230"}}
	patterns = []option{{"plain", ""}, {"stripes", ""}, {"dots", ""}, {"star", ""}}
	beards   = []option{{"snow", "#f4f1ea"}, {"silver", "#cfd6dc"}, {"brown", "#8a5a3b"}, {"ginger", "#d9793b"}, {"black", "#2d2a2a"}, {"blond", "#f2d27a"}, {"lilac", "#d8c4f2"}, {"frost", "#9fd0ff"}}
	coats    = []option{{"blue", "#3b6fd8"}, {"red", "#c9443a"}, {"moss", "#3f8f4f"}, {"leather", "#7a4e2d"}, {"mustard", "#f2b53a"}, {"denim", "#23406e"}, {"teal", "#2aa198"}, {"mint", "#7ed9c3"}, {"charcoal", "#2c2f36"}, {"violet", "#6a3fa0"}}
	skins    = []option{{"light", "#f6d3b4"}, {"peach", "#eab28a"}, {"tan", "#c98b5e"}, {"brown", "#95603f"}, {"deep", "#6b422c"}}
	eyeTypes = []option{{"open", ""}, {"happy", ""}, {"sleepy", ""}, {"wink", ""}}
	accs     = []option{{"none", ""}, {"rosy cheeks", ""}, {"scarf", ""}, {"glasses", ""}, {"beard flower", ""}}
	friends  = []option{{"none", ""}, {"mushroom", ""}, {"flower", ""}, {"lantern", ""}, {"star", ""}, {"snail", ""}}
	bgs      = []option{{"mint", "#bfe8d6"}, {"lemon", "#fbeaa0"}, {"peach", "#ffd6c2"}, {"sky", "#c9e6ff"}, {"mist", "#d9ecf2"}, {"lavender", "#ddd5f5"}, {"sand", "#f3dfb3"}, {"frost", "#cfe6f5"}, {"butter", "#ffe3a3"}, {"blush", "#ffd6e8"}, {"dusk", "#1d2a4a"}, {"midnight", "#141a33"}, {"plum night", "#2a1f4a"}, {"deep night", "#1c2447"}, {"space", "#0f1633"}}
)

func pools() [traitCount][]option {
	return [traitCount][]option{hats, patterns, beards, coats, skins, eyeTypes, accs, friends, bgs}
}

func optionName(trait, idx int) string { return pools()[trait][idx].name }

const digits = "0123456789abcdefghijklmnopqrstuvwxyz"

func traitsOf(id int) [traitCount]int {
	var t [traitCount]int
	row := traitTable[(id-1)*traitCount : id*traitCount]
	p := pools()
	for i := 0; i < traitCount; i++ {
		v := strings.IndexByte(digits, row[i])
		if v < 0 || v >= len(p[i]) {
			panic("gnomes: corrupt trait table")
		}
		t[i] = v
	}
	return t
}

var body = []string{
	"...........H........",
	"..........HHh.......",
	".........HHHh.......",
	".........HHHHh......",
	"........HHHHHh......",
	"........HHHHHHh.....",
	".......HHHHHHHh.....",
	"......HHHHHHHHHh....",
	".....HHHHHHHHHHHh...",
	"....HHHHHHHHHHHHHh..",
	"...hhhhhhhhhhhhhhhh.",
	".....SSSSSSSSSSSS...",
	".....S..SSSSS..SS...",
	".....S..SSSSS..SS...",
	".....RSSSSNNSSSSR...",
	"....BBSSSSSSSSSSBB..",
	"....BBBBBBBBBBBBBB..",
	"...BBBBBBBBBBBBBBBB.",
	"..CBBBBBBBBBBBBBBBBC",
	"..CCBBBBBBBBBBBBBBCC",
	"..SCCCBBBBBBBBBBCCCS",
	"...CCCCbBBBBBBbCCCC.",
	"...LLLLLLBBBBLLLLLL.",
	"...CCCCCCCBBCCCCCCC.",
	"...PPPPPPPPPPPPPPPP.",
	"...PPPPPPP..PPPPPPP.",
	"..OOOOOOOO..OOOOOOOO",
	"..OOOOOOOO..OOOOOOOO",
}

// Eyes fill the two 2×2 holes: row, col, paint.
var eyeCells = map[string][][3]int{
	"open":   {{12, 6, 'W'}, {12, 7, 'E'}, {13, 6, 'E'}, {13, 7, 'E'}, {12, 13, 'W'}, {12, 14, 'E'}, {13, 13, 'E'}, {13, 14, 'E'}},
	"happy":  {{12, 6, 'E'}, {12, 7, 'S'}, {13, 6, 'S'}, {13, 7, 'E'}, {12, 13, 'S'}, {12, 14, 'E'}, {13, 13, 'E'}, {13, 14, 'S'}},
	"sleepy": {{12, 6, 'S'}, {12, 7, 'S'}, {13, 6, 'E'}, {13, 7, 'E'}, {12, 13, 'S'}, {12, 14, 'S'}, {13, 13, 'E'}, {13, 14, 'E'}},
	"wink":   {{12, 6, 'W'}, {12, 7, 'E'}, {13, 6, 'E'}, {13, 7, 'E'}, {12, 13, 'S'}, {12, 14, 'S'}, {13, 13, 'E'}, {13, 14, 'E'}},
}

type friendSprite struct {
	rows []string
	x, y int
}

var friendSprites = map[string]friendSprite{
	"mushroom": {[]string{"..RRR..", ".RWRRR.", "RRRRWRR", "...T...", "..TTT.."}, 0, 25},
	"star":     {[]string{".Y.", "YYY", ".Y."}, 17, 0},
	"lantern":  {[]string{".K.", "KYK", "KYK", ".K."}, 26, 22},
	"flower":   {[]string{".F.", "FYF", ".F.", ".G."}, 6, 19},
	"snail":    {[]string{"..KKK", ".KYYK", "TTTKK"}, 26, 28},
}

var friendPaint = map[byte]string{'R': "#e8453c", 'W': white, 'T': "#efe6d2", 'Y': "#ffd84a", 'K': "#5a4636", 'F': "#ff8fb8", 'G': "#4c9a52"}

type canvas struct{ px [side * side]string }

func (c *canvas) put(x, y int, col string) {
	if x >= 0 && y >= 0 && x < side && y < side {
		c.px[y*side+x] = col
	}
}

const hexDigits = "0123456789abcdef"

// shade scales a #rrggbb colour by pct percent.
func shade(hex string, pct int) string {
	v, err := strconv.ParseUint(hex[1:], 16, 32)
	if err != nil {
		panic("gnomes: bad colour " + hex)
	}
	out := []byte{'#'}
	for _, shift := range []uint{16, 8, 0} {
		ch := int((v>>shift)&255) * pct / 100
		if ch > 255 {
			ch = 255
		}
		out = append(out, hexDigits[ch>>4], hexDigits[ch&15])
	}
	return string(out)
}

// Art draws gnome `tid` as an SVG.
func Art(tid string) string {
	id := mustID(tid)
	t := traitsOf(id)
	hat, beard, coat, skin, bg := hats[t[0]].color, beards[t[2]].color, coats[t[3]].color, skins[t[4]].color, bgs[t[8]]
	night := t[8] >= 10

	paint := map[byte]string{
		'H': hat, 'h': shade(hat, 72), 'S': skin, 'R': shade(skin, 88), 'N': shade(skin, 82),
		'B': beard, 'b': shade(beard, 82), 'C': coat, 'L': "#3a2a1f", 'P': shade(coat, 55),
		'O': "#2a2220", 'E': ink, 'W': white,
	}
	var c canvas
	const ox, oy = 6, 3
	sp := func(x, y int, col string) { c.put(ox+x, oy+y, col) }

	for y, row := range body {
		for x := 0; x < len(row); x++ {
			if row[x] != '.' {
				sp(x, y, paint[row[x]])
			}
		}
	}
	switch patterns[t[1]].name {
	case "stripes":
		for y, row := range body {
			if y == 3 || y == 6 || y == 9 {
				for x := 0; x < len(row); x++ {
					if row[x] == 'H' {
						sp(x, y, shade(hat, 140))
					}
				}
			}
		}
	case "dots":
		for _, d := range [][2]int{{10, 4}, {9, 7}, {12, 6}, {7, 9}, {11, 9}, {14, 8}} {
			sp(d[0], d[1], white)
		}
	case "star":
		for _, d := range [][2]int{{10, 5}, {9, 6}, {10, 6}, {11, 6}, {10, 7}} {
			sp(d[0], d[1], "#ffd84a")
		}
	}
	for _, e := range eyeCells[eyeTypes[t[5]].name] {
		sp(e[1], e[0], paint[byte(e[2])])
	}
	switch accs[t[6]].name {
	case "rosy cheeks":
		sp(5, 14, "#ff7f96")
		sp(6, 14, "#ff9fae")
		sp(15, 14, "#ff9fae")
		sp(16, 14, "#ff7f96")
	case "glasses":
		const frame = "#3b2f2a"
		for _, cols := range [][4]int{{5, 6, 7, 8}, {12, 13, 14, 15}} {
			for _, x := range cols {
				sp(x, 11, frame)
				sp(x, 14, frame)
			}
			sp(cols[0], 12, frame)
			sp(cols[0], 13, frame)
			sp(cols[3], 12, frame)
			sp(cols[3], 13, frame)
		}
		sp(9, 12, frame)
		sp(10, 12, frame)
		sp(11, 12, frame)
	case "scarf":
		for x := 4; x <= 17; x++ {
			if x%2 == 1 {
				sp(x, 15, "#e8b53a")
			} else {
				sp(x, 15, "#c7922a")
			}
		}
		for y := 16; y <= 20; y++ {
			sp(14, y, "#e8b53a")
			sp(15, y, "#c7922a")
		}
	case "beard flower":
		sp(12, 18, "#ff8fb8")
		sp(11, 19, "#ff8fb8")
		sp(13, 19, "#ff8fb8")
		sp(12, 20, "#ff8fb8")
		sp(12, 19, "#ffd84a")
	}
	if f, ok := friendSprites[friends[t[7]].name]; ok {
		for y, row := range f.rows {
			for x := 0; x < len(row); x++ {
				if col, ok := friendPaint[row[x]]; ok {
					c.put(f.x+x, f.y+y, col)
				}
			}
		}
	}

	var b strings.Builder
	b.WriteString(ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges">`, side, side))
	b.WriteString(`<rect width="32" height="32" fill="` + bg.color + `"/>`)
	grass := "#6fbf73"
	if night {
		grass = "#2a4a3c"
		for _, s := range [][2]int{{3, 4}, {9, 2}, {27, 5}, {23, 11}, {2, 14}, {29, 16}, {14, 1}} {
			b.WriteString(ufmt.Sprintf(`<rect x="%d" y="%d" width="1" height="1" fill="#fff6c9"/>`, s[0], s[1]))
		}
	}
	b.WriteString(`<rect y="29" width="32" height="3" fill="` + grass + `"/>`)
	b.WriteString(`<rect y="29" width="32" height="1" fill="` + shade(grass, 115) + `"/>`)
	for y := 0; y < side; y++ {
		x := 0
		for x < side {
			col := c.px[y*side+x]
			if col == "" {
				x++
				continue
			}
			n := 1
			for x+n < side && c.px[y*side+x+n] == col {
				n++
			}
			b.WriteString(ufmt.Sprintf(`<rect x="%d" y="%d" width="%d" height="1" fill="%s"/>`, x, y, n, col))
			x += n
		}
	}
	b.WriteString(`</svg>`)
	return b.String()
}
