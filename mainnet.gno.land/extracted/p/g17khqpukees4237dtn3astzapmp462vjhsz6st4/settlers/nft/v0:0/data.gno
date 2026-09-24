package nft

// Parts. Every row is the left half of the sprite, left-padded with '.' (transparent) to 12
// columns, and parts are the rows one after the other. Row i starts at i*12.

const hatTall = "" +
	"...........o" + // y=0
	"..........oh" + // y=1
	"..........oH" + // y=2
	".........ohH" + // y=3
	".........oHH" + // y=4
	"........ohHH" + // y=5
	"........oHHH" + // y=6
	".......ohHHH" + // y=7
	".......oHHHH" + // y=8
	"......ohHHHH" + // y=9
	"......oHHHHH" // y=10

const brim = "" +
	"....ohHHHHHH" + // y=11
	"....ojjjjjjj" // y=12

const head = "" +
	"......ouuuuu" + // y=13
	"......osWWWs" + // y=14
	".....ossesss" + // y=15
	"....oussessn" + // y=16
	"......osssmn" // y=17

const headBeard = "" +
	".....owWWWvv" // y=18

const headNoBeard = "" +
	"......osssvv" + // y=18
	"......osssuu" + // y=19
	".......ossss" + // y=20
	"........oooo" // y=21

const beardLong = "" +
	".....owWWWWW" + // y=19
	".....owWWWxW" + // y=20
	"......owWWxW" + // y=21
	"......owWxWW" + // y=22
	".......owWxW" + // y=23
	".......owWWW" + // y=24
	"........owWx" + // y=25
	".........owW" + // y=26
	"..........ow" // y=27

const beardPointy = "" +
	".....owWWWWW" + // y=19
	"......owWWWW" + // y=20
	"......owWWxW" + // y=21
	".......owWWW" + // y=22
	".......owWxW" + // y=23
	"........owWW" + // y=24
	"........owWx" + // y=25
	".........owW" + // y=26
	".........owx" + // y=27
	"..........ow" // y=28

const beardRound = "" +
	".....owWWWWW" + // y=19
	".....owWWWWW" + // y=20
	"......owWWWW" + // y=21
	".......owWWx" + // y=22
	"........owWW" + // y=23
	".........owW" + // y=24
	"..........ow" // y=25

const body = "" +
	"....ocCCCCCC" + // y=19
	"...ocCCCCCCC" + // y=20
	"...ocCCCCCCC" + // y=21
	"...ocCCCCCCC" + // y=22
	"..oscCCCCCCC" + // y=23
	"..oucCCCCCCC" + // y=24
	"...okkkkkkky" + // y=25
	"...ocCCCCCCC" + // y=26
	"...odddddddd" // y=27

const boots = "" +
	".....opppppo" + // y=28
	".....opppppo" + // y=29
	".....oqqqqqo" + // y=30
	".....ooooooo" // y=31

// Bent-tip hat, see the spec section 6.1.
const coneY0 = 2

var coneK = [...]int{1, 1, 2, 2, 3, 3, 4, 4, 5}

// tailSpans are the pixels of the tip, when it falls to the right: row y, from x0 to x1 (inclusive).
var tailSpans = [...]span{{1, 11, 14}, {2, 14, 15}, {3, 15, 15}}

// Glasses, see the spec section 6.2. Pairs are x, y.
var (
	glassesFrame = [...][2]int{{7, 15}, {8, 15}, {9, 15}, {14, 15}, {15, 15}, {16, 15}, {7, 16}, {9, 16}, {10, 16}, {13, 16}, {14, 16}, {16, 16}, {7, 17}, {8, 17}, {9, 17}, {14, 17}, {15, 17}, {16, 17}}
	glassesEyes  = [...][2]int{{8, 16}, {15, 16}}
)

// Palettes, as hex digits without '#'. Every entry has 3 tones: skin t s u, hat h H j,
// beard w W x, tunic c C d. Entry i starts at i*3.
var (
	skinColors    = [...]string{"ffd2b0", "f2b58c", "d18f68", "f0bd94", "d99a6c", "b57650", "c98f66", "a86f48", "83502f"}
	hatColors     = [...]string{"f06a5a", "d1413a", "9c2a33", "6aa0f0", "3f6fd1", "2b4a99", "7ed36a", "4aa84a", "2e7a3a", "b58cf0", "8a5cd1", "5e3c9a", "ffb45a", "f08a2a", "b5601c"}
	beardColors   = [...]string{"ffffff", "e9ecf2", "b9c0d0", "d5d9e0", "aab1bd", "7b8494", "ffb05a", "e07a2a", "a4501c", "a8744e", "7f5234", "573622"}
	tunicColors   = [...]string{"5fb0e8", "3f8fd1", "2b649a", "8fd06a", "5fa83f", "3d7a2a", "c98a5a", "a4673a", "75452a", "e9868f", "cc5a68", "994050", "f0d36a", "d1a83a", "a07a25"}
	glassesColors = [...]string{"2a1a2e", "e8b422", "d1413a", "2aa198"}
	bgColors      = [...]string{"cfe8f3", "f3e3c9", "dbeed2", "eadcf3", "f6d9d5"}
)

// fixedColor returns the color of the keys that do not depend on a trait, or "".
func fixedColor(key byte) string {
	switch key {
	case 'o':
		return "2a1a2e"
	case 'e':
		return "1b1626"
	case 'k':
		return "6b3f22"
	case 'y':
		return "f5c542"
	case 'p':
		return "6a4126"
	case 'q':
		return "46271a"
	case 'n':
		return "f08c7c"
	case 'm':
		return "ffb0a0"
	case 'v':
		return "c8645a"
	}
	return ""
}

// swapTable has the key used on the right half for each key of the left half.
var swapTable = [128]byte{
	'C': 'C',
	'H': 'H',
	'W': 'W',
	'c': 'd',
	'd': 'd',
	'e': 'e',
	'h': 'j',
	'j': 'j',
	'k': 'k',
	'm': 'v',
	'n': 'n',
	'o': 'o',
	'p': 'p',
	'q': 'q',
	's': 's',
	'u': 'u',
	'v': 'v',
	'w': 'x',
	'x': 'x',
	'y': 'y',
}

// Path segments are "M{x} {y}h{n}v1h-{n}z", written as mHead[x] + nums[y] + runTail[n].
// The percent-encoded variant only differs in the space, that is written as %20.
var (
	rawMHead = [...]string{"M0 ", "M1 ", "M2 ", "M3 ", "M4 ", "M5 ", "M6 ", "M7 ", "M8 ", "M9 ", "M10 ", "M11 ", "M12 ", "M13 ", "M14 ", "M15 ", "M16 ", "M17 ", "M18 ", "M19 ", "M20 ", "M21 ", "M22 ", "M23 "}
	uriMHead = [...]string{"M0%20", "M1%20", "M2%20", "M3%20", "M4%20", "M5%20", "M6%20", "M7%20", "M8%20", "M9%20", "M10%20", "M11%20", "M12%20", "M13%20", "M14%20", "M15%20", "M16%20", "M17%20", "M18%20", "M19%20", "M20%20", "M21%20", "M22%20", "M23%20"}
	nums     = [...]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31"}
	runTail  = [...]string{"", "h1v1h-1z", "h2v1h-2z", "h3v1h-3z", "h4v1h-4z", "h5v1h-5z", "h6v1h-6z", "h7v1h-7z", "h8v1h-8z", "h9v1h-9z", "h10v1h-10z", "h11v1h-11z", "h12v1h-12z", "h13v1h-13z", "h14v1h-14z", "h15v1h-15z", "h16v1h-16z", "h17v1h-17z", "h18v1h-18z", "h19v1h-19z", "h20v1h-20z", "h21v1h-21z", "h22v1h-22z", "h23v1h-23z", "h24v1h-24z"}
)
