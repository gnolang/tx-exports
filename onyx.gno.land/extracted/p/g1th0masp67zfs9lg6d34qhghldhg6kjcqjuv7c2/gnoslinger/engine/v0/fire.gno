package engine

import (
	"strconv"
	"strings"
)

// HitLoc is a hit location on a FIRE card's hit chart (rule 13.5).
type HitLoc string

const (
	Miss     HitLoc = "-"
	Bullseye HitLoc = "BE" // the shooter picks the location (13.7)
	LegHit   HitLoc = "LEG"
	GunHit   HitLoc = "GUN"  // the gun arm
	ArmHit   HitLoc = "ARM"  // the other arm
	SideHit  HitLoc = "SIDE" // a flesh wound
	BodyHit  HitLoc = "BODY"
	CritHit  HitLoc = "CRIT"
	VitalHit HitLoc = "VITAL"
	HeadHit  HitLoc = "HEAD"
)

// Target statuses a FIRE card may list (rule 13.6), as the letters of a
// card's status string.
const (
	StatusMove = 'M' // played a foot action or dropped this turn (13.61)
	StatusRun  = 'R' // played a Run this turn (13.62)
	StatusDown = 'D' // is DOWN (13.63)
	StatusHead = 'H' // head counter shot at (13.64, not played)
)

// Band is an inclusive range of aim times or ranges; Hi < 0 is open-ended.
type Band struct{ Lo, Hi int }

// Contains reports whether n falls in the band.
func (b Band) Contains(n int) bool { return n >= b.Lo && (b.Hi < 0 || n <= b.Hi) }

// Chart is the hit chart of a FIRE card: a hit location per aim-time row
// and range column.
type Chart struct {
	Cols []Band
	Rows []ChartRow
}

// ChartRow is one aim-time row of a Chart.
type ChartRow struct {
	Aim   Band
	Cells []HitLoc
}

// Lookup is the preliminary hit location for an aim time and a range; off
// the chart is a miss (rule 13.5).
func (c *Chart) Lookup(aim, rng int) HitLoc {
	col := -1
	for i, b := range c.Cols {
		if b.Contains(rng) {
			col = i
			break
		}
	}
	if col < 0 {
		return Miss
	}
	for _, r := range c.Rows {
		if r.Aim.Contains(aim) {
			return r.Cells[col]
		}
	}
	return Miss
}

// Lesser is the hit the card's Target Status entries name: the chart's hit
// location other than a bullseye (every card has exactly one).
func (c *Chart) Lesser() HitLoc {
	for _, r := range c.Rows {
		for _, h := range r.Cells {
			if h != Miss && h != Bullseye {
				return h
			}
		}
	}
	return Miss
}

// Malfunction is the upper block of cards 101-108 (rule 13.3): whether the
// shot misfires per shell type, and the gun's fate on a second malfunction
// drawn after a misfire (13.31).
type Malfunction struct {
	Storebought bool // misfire with storebought shells
	Handloaded  bool // misfire with handloaded shells (the Colt 45's)
	CapAndBall  bool // misfire with cap-and-ball shells
	Second      string
}

// Second-draw penalties.
const (
	GunJams     = "jams"     // all shells crossed off; cannot fire until reloaded
	GunExplodes = "explodes" // cannot fire for the rest of the game
)

// fireCard is the transcription of a FIRE card's upper block: the hit chart
// as "<range bands>|<aim band>:<cell per column>|..." (bands "n", "n-m",
// "n+" or "n-m+") and the Target Status letters (M move, R run, D down,
// H head), each of which turns the card's lesser hit into a miss and, for
// M and R, a bullseye into the lesser hit.
type fireCard struct {
	chart, status string
}

// fireCards are cards 1 to 100, from the card images (assets/result_card_NNN.png).
var fireCards = [100]fireCard{
	{"0,1-5,6-12+|2-5:BE,-,-|6-8:BE,SIDE,-|9+:BE,BE,SIDE", "H"},         // 1
	{"0,1-5,6-9|3-6:BE,-,-|7:BE,SIDE,-|8+:BE,BE,SIDE", "M"},             // 2
	{"0-1,2-4|1-3:SIDE,-|4+:BE,SIDE", "H"},                              // 3
	{"0-2,3-7|1-6:SIDE,-|7+:BE,SIDE", "H"},                              // 4
	{"0-5,6-8|2-4:SIDE,-|5+:BE,SIDE", "D"},                              // 5
	{"0,1|3-4:BE,-|5-7:BE,SIDE|8+:BE,BE", "H"},                          // 6
	{"0,1-3|1-4:SIDE,-|5:BE,SIDE|6+:BE,BE", "H"},                        // 7
	{"0,1-4|2-6:BE,-|7+:BE,SIDE", ""},                                   // 8
	{"0-1,2-6|1-5:SIDE,-|6+:BE,SIDE", "D"},                              // 9
	{"0-3,4-5|2-6:SIDE,-|7-8:BE,-|9+:BE,SIDE", "H"},                     // 10
	{"0-2,3-6|4-8:SIDE,-|9+:BE,BE", ""},                                 // 11
	{"0-1,2-3,4-5|3-4:SIDE,SIDE,-|5-8:BE,SIDE,SIDE|9+:BE,BE,SIDE", "D"}, // 12
	{"0,1-3,4-7|6-8:BE,SIDE,-|9+:BE,BE,SIDE", ""},                       // 13
	{"0-7|4-6:SIDE|7+:BE", "M"},                                         // 14
	{"0,1,2-5|1-2:BE,-,-|3-7:BE,BE,-|8-9:BE,BE,SIDE", "D"},              // 15
	{"0-4|1-3:SIDE|4+:BE", "D"},                                         // 16
	{"0-5,6-11|8:SIDE,-|9+:BE,BE", ""},                                  // 17
	{"0-6|3-5:SIDE|6+:BE", ""},                                          // 18
	{"0,1|3-4:BE,-|5-7:BE,BODY|8+:BE,BE", ""},                           // 19
	{"0,1-5,6-12+|2-5:BE,-,-|6-8:BE,BODY,-|9+:BE,BE,BODY", ""},          // 20
	{"0-1,2,3|1-2:BODY,-,-|3-8:BE,BODY,-|9+:BE,BE,BODY", ""},            // 21
	{"0,1-3|2-6:BODY,-|7+:BE,BE", ""},                                   // 22
	{"0-3,4-7|2-7:BODY,-|8+:BE,BODY", ""},                               // 23
	{"0-4,5-10|4-6:BODY,-|7:BE,BODY|8+:BE,BE", ""},                      // 24
	{"0-5,6-8|2-4:BODY,-|5+:BE,BODY", "D"},                              // 25
	{"0-6|3-5:BODY|6+:BE", ""},                                          // 26
	{"0-1,2,3-5|1-2:BE,BODY,BODY|3-4:BE,BE,BODY|5+:BE,BE,BE", "R"},      // 27
	{"0-2,3-9|2-8:BODY,-|9+:BE,BE", ""},                                 // 28
	{"0,1-4|2-6:BE,-|7+:BE,BODY", "H"},                                  // 29
	{"0-1,2,3|8:BE,BODY,-|9+:BE,BE,BODY", ""},                           // 30
	{"0,1-3|1-4:BODY,-|5:BE,BODY|6+:BE,BE", "H"},                        // 31
	{"0-5,6-11|8:BODY,-|9+:BE,BE", ""},                                  // 32
	{"0-1,2-3,4|2-7:BE,-,-|8:BE,BODY,-|9+:BE,BE,BODY", "H"},             // 33
	{"0,1-2,3-6|1-2:BODY,-,-|3-7:BE,BODY,-|8+:BE,BE,BODY", "H"},         // 34
	{"0,1-4,5-8|1-5:BE,-,-|6-8:BE,BODY,-|9+:BE,BE,BODY", "H"},           // 35
	{"0,1-5,6-9|3-6:BE,-,-|7:BE,BODY,-|8+:BE,BE,BODY", "H"},             // 36
	{"0,1-2,3-4|1-4:BODY,-,-|5+:BE,BE,BODY", "DH"},                      // 37
	{"0-4|3-7:BODY|8+:BE", "D"},                                         // 38
	{"0-1,2-3,4-5|3-4:BODY,BODY,-|5-8:BE,BODY,BODY|9+:BE,BE,BODY", "D"}, // 39
	{"0-2,3-7|1-6:BODY,-|7+:BE,BODY", "MH"},                             // 40
	{"0-1,2-6|1-5:BODY,-|6+:BE,BODY", "H"},                              // 41
	{"0-1,2,3|8:BE,BODY,-|9+:BE,BE,BODY", ""},                           // 42
	{"0-2,3-4|5+:BE,BODY", "H"},                                         // 43
	{"0,1-4|2-6:BE,-|7+:BE,CRIT", "R"},                                  // 44
	{"0-3,4-9|1-5:CRIT,-|6+:BE,CRIT", "DH"},                             // 45
	{"0,1-2,3-6|1-2:CRIT,-,-|3-7:BE,CRIT,-|8+:BE,BE,CRIT", "DH"},        // 46
	{"0-5,6-11|2-7:CRIT,-|8+:BE,CRIT", ""},                              // 47
	{"0-1,2-3|4-7:CRIT,-|8+:BE,BE", "M"},                                // 48
	{"0,1,2-4|1-2:BE,-,-|3+:BE,BE,CRIT", "D"},                           // 49
	{"0-1,2-5|3-7:CRIT,-|8+:BE,CRIT", "H"},                              // 50
	{"0-3,4-6|5+:BE,CRIT", "MD"},                                        // 51
	{"0-1,2-3,4|2-3:BE,-,-|4-8:BE,CRIT,-|9+:BE,BE,CRIT", "D"},           // 52
	{"0-3,4-5|2-6:CRIT,-|7-8:BE,-|9+:BE,CRIT", "H"},                     // 53
	{"0,1-3|2-6:CRIT,-|7+:BE,BE", "M"},                                  // 54
	{"0-1,2,3|1-2:CRIT,-,-|3-8:BE,CRIT,-|9+:BE,BE,CRIT", "M"},           // 55
	{"0,1-3,4-7|6-8:BE,CRIT,-|9+:BE,BE,CRIT", "R"},                      // 56
	{"0-2,3-9|2-8:CRIT,-|9+:BE,BE", "M"},                                // 57
	{"0-7|4-6:CRIT|7+:BE", "H"},                                         // 58
	{"0,1-2,3-6|1-4:VITAL,-,-|5-8:BE,BE,-|9+:BE,BE,BE", "M"},            // 59
	{"0-2,3,4-7|2-5:BE,VITAL,-|6-8:BE,VITAL,VITAL|9+:BE,BE,BE", "R"},    // 60
	{"0-1,2,3-4|1-2:BE,VITAL,-|3+:BE,VITAL,VITAL", "M"},                 // 61
	{"0-1,2,3-5|3:VITAL,-,-|4-8:BE,VITAL,-|9+:BE,BE,VITAL", "DH"},       // 62
	{"0-2,3-4|2-4:VITAL,-|5-6:VITAL,VITAL|7+:BE,VITAL", "DH"},           // 63
	{"0-1,2-3,4-7|1-5:VITAL,-,-|6-7:VITAL,VITAL,-|8+:BE,BE,VITAL", "H"}, // 64
	{"0-1,2,3-6|4-6:VITAL,-,-|7-8:BE,VITAL,VITAL|9+:BE,BE,VITAL", "M"},  // 65
	{"0-1,2-5|1-5:BE,-|6-8:BE,HEAD|9+:BE,BE", "M"},                      // 66
	{"0,1-4,5-8|1-5:BE,-,-|6-8:BE,HEAD,-|9+:BE,BE,HEAD", ""},            // 67
	{"0-1,2-6|3:HEAD,-|4-6:BE,-|7+:BE,HEAD", "R"},                       // 68
	{"0-2,3-5|1-6:HEAD,-|7-8:BE,-|9+:BE,HEAD", "R"},                     // 69
	{"0-3|4-7:HEAD|8+:BE", ""},                                          // 70
	{"0,1-4|2-6:BE,-|7+:BE,HEAD", ""},                                   // 71
	{"0-1,2-4|1-3:HEAD,-|4+:BE,HEAD", "M"},                              // 72
	{"0-2,3-5,6+|1-4:BE,LEG,LEG|5+:BE,BE,LEG", "H"},                     // 73
	{"0-5,6-11|2-7:LEG,-|8+:BE,LEG", "RH"},                              // 74
	{"0-3,4-6|5+:BE,LEG", "MD"},                                         // 75
	{"0-3,4-9|1-5:LEG,-|6+:BE,LEG", "MH"},                               // 76
	{"0-2,3-4|2:BE,-|3+:BE,LEG", "MH"},                                  // 77
	{"0-2,3-4|5+:BE,LEG", "H"},                                          // 78
	{"0-4|1-3:LEG|4+:BE", "DH"},                                         // 79
	{"0-4,5-10|4-6:LEG,-|7:BE,LEG|8+:BE,BE", "DH"},                      // 80
	{"0,1-2|1-3:GUN,-|4-7:BE,GUN|8+:BE,BE", ""},                         // 81
	{"0-3,4-5,6-7|3-8:BE,GUN,-|9+:BE,BE,BE", "M"},                       // 82
	{"0-1,2-8|2-7:GUN,-|8+:BE,BE", "R"},                                 // 83
	{"0-1|3-8:GUN|9+:BE", ""},                                           // 84
	{"0-3,4-5|5-8:GUN,-|9+:BE,GUN", ""},                                 // 85
	{"0-3,4-5|1-6:GUN,-|7+:BE,GUN", "MD"},                               // 86
	{"0-2,3-6|1-5:GUN,-|6-7:BE,-|8+:BE,GUN", "R"},                       // 87
	{"0-1,2-3|5-6:BE,-|7+:BE,GUN", ""},                                  // 88
	{"0-4|2-8:GUN|9+:BE", "R"},                                          // 89
	{"0-2,3-6|4+:BE,GUN", "RD"},                                         // 90
	{"0,1-2|1-3:ARM,-|4-7:BE,ARM|8+:BE,BE", "H"},                        // 91
	{"0-3,4-5,6-7|3-8:BE,ARM,-|9+:BE,BE,BE", "MH"},                      // 92
	{"0-1,2-8|2-7:ARM,-|8+:BE,BE", "RH"},                                // 93
	{"0-1|3-8:ARM|9+:BE", "H"},                                          // 94
	{"0-3,4-5|5-8:ARM,-|9+:BE,ARM", "H"},                                // 95
	{"0-3,4-7|1-6:ARM,-|8+:BE,ARM", "MDH"},                              // 96
	{"0-2,3-6|1-5:ARM,-|6-7:BE,-|8+:BE,ARM", "RH"},                      // 97
	{"0-1,2-3|5-6:BE,-|7+:BE,ARM", "H"},                                 // 98
	{"0-4|2-8:ARM|9+:BE", "RH"},                                         // 99
	{"0-2,3-6|4+:BE,ARM", "RDH"},                                        // 100
}

// malfunctions are the blocks of cards 101 to 108.
var malfunctions = [8]Malfunction{
	{false, false, true, GunJams},    // 101
	{false, false, true, GunJams},    // 102
	{false, false, true, GunJams},    // 103
	{true, true, true, GunJams},      // 104
	{true, true, true, GunJams},      // 105
	{true, true, true, GunJams},      // 106
	{false, true, true, GunExplodes}, // 107
	{false, true, true, GunExplodes}, // 108
}

func parseChart(s string) *Chart {
	parts := strings.Split(s, "|")
	c := &Chart{}
	for _, b := range strings.Split(parts[0], ",") {
		c.Cols = append(c.Cols, parseBand(b))
	}
	for _, row := range parts[1:] {
		i := strings.IndexByte(row, ':')
		r := ChartRow{Aim: parseBand(row[:i])}
		for _, cell := range strings.Split(row[i+1:], ",") {
			r.Cells = append(r.Cells, HitLoc(cell))
		}
		if len(r.Cells) != len(c.Cols) {
			panic("fire chart row/column mismatch: " + s)
		}
		c.Rows = append(c.Rows, r)
	}
	return c
}

func parseBand(s string) Band {
	open := strings.HasSuffix(s, "+")
	s = strings.TrimSuffix(s, "+")
	lo, hi := s, s
	if i := strings.IndexByte(s, '-'); i >= 0 {
		lo, hi = s[:i], s[i+1:]
	}
	b := Band{Lo: atoi(lo), Hi: atoi(hi)}
	if open {
		b.Hi = -1
	}
	return b
}

func atoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		panic("fire chart: bad number " + strconv.Quote(s))
	}
	return n
}
