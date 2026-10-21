package game33

import (
	"crypto/sha256"
	"strconv"
)

// ── Slots engine: every reel, line, scatter and Hold & Spin tile comes from the
// round's combined seed. The client renders what the realm stored and re-derives
// it with the same rules (src/lib/game/slots-engine.ts mirrors this file).
//
// Stream: block i = sha256(serverSeed ":" clientSecret ":" roundId ":slots:" i),
// bytes consumed in order. Reel c stops at uint32(next 4 bytes) % 40 and shows
// strip[(stop+r) % 40] for rows r = 0..3. Grid cells are indexed c*4+r.
//
// Paytable (see the RTP math in .bot-notes/casino/CASINO_100_PLAN.md):
//   25 lines pay left to right in units of the line bet (bet/25; bets are a
//   multiple of 25 so nothing is rounded); wild substitutes; the anchor is the
//   first symbol that is not wild/scatter/vault (an all-wild line pays wild).
//   3/4/5 scatters anywhere pay 2/10/50× the bet and grant 10/12/15 free spins.
//   3+ vaults start Hold & Spin. Every win of a round is capped at 500× the bet.

const (
	slotsReels      = 5
	slotsRows       = 4
	slotsCells      = 20
	slotsStripLen   = 40
	slotsBetStep    = uint64(25) // bet must be a multiple of the 25 lines
	slotsMaxWinMult = uint64(500)

	symWild    = byte(0)
	symScatter = byte(8)
	symVault   = byte(9)

	// Hold & Spin
	hsLandBelow = byte(8) // a free cell lands a coin when its byte < 8 (3.125%)
	hsRespins   = 3

	// Hold & Spin tile codes (anything < 100 is a multiple of the bet)
	hsMini  = uint16(101)
	hsMinor = uint16(102)
	hsMajor = uint16(103)
	hsGrand = uint16(104)
)

// One strip for all reels: wild 1, seven 3, diamond 4, trophy 5, star 6,
// clover 6, flame 7, coin 6, scatter 1, vault 1 (digits = symbol ids).
const slotsStrip = "8645732106457321645793216457326457364576"

var slotsSymbolNames = [10]string{"wild", "seven", "diamond", "trophy", "star", "clover", "flame", "coin", "scatter", "vault"}

// line-bet multiples for 3/4/5 of a kind, symbols 0..7
var slotsPays = [8][3]uint64{
	{60, 250, 1000}, // wild
	{40, 150, 500},  // seven
	{30, 100, 300},  // diamond
	{25, 75, 200},   // trophy
	{15, 40, 100},   // star
	{12, 30, 80},    // clover
	{10, 25, 60},    // flame
	{8, 20, 50},     // coin
}

// same 25 lines as src/lib/game/slots.ts PAYLINES (row per reel)
var slotsPaylines = [25][5]byte{
	{1, 1, 1, 1, 1}, {2, 2, 2, 2, 2}, {0, 0, 0, 0, 0}, {3, 3, 3, 3, 3},
	{0, 1, 2, 1, 0}, {3, 2, 1, 2, 3}, {0, 1, 3, 1, 0}, {3, 2, 0, 2, 3},
	{0, 1, 2, 3, 3}, {3, 2, 1, 0, 0}, {0, 0, 1, 2, 3}, {3, 3, 2, 1, 0},
	{1, 2, 1, 2, 1}, {2, 1, 2, 1, 2}, {1, 0, 1, 2, 1}, {2, 3, 2, 1, 2},
	{1, 0, 0, 0, 1}, {2, 3, 3, 3, 2}, {0, 2, 3, 2, 0}, {3, 1, 0, 1, 3},
	{1, 1, 2, 1, 1}, {2, 2, 1, 2, 2}, {0, 1, 0, 1, 0}, {3, 2, 3, 2, 3},
	{0, 3, 0, 3, 0},
}

var (
	slotsScatterPay = [6]uint64{0, 0, 0, 2, 10, 50} // × bet, by scatter count
	slotsFreeSpins  = [6]uint64{0, 0, 0, 10, 12, 15}
)

type slotsStream struct {
	prefix string
	ctr    int
	buf    [32]byte
	pos    int
}

func newSlotsStream(serverSeed, clientSecret, roundId string) *slotsStream {
	return &slotsStream{prefix: serverSeed + ":" + clientSecret + ":" + roundId + ":slots:", pos: 32}
}

func (s *slotsStream) next() byte {
	if s.pos >= 32 {
		s.buf = sha256.Sum256([]byte(s.prefix + strconv.Itoa(s.ctr)))
		s.ctr++
		s.pos = 0
	}
	b := s.buf[s.pos]
	s.pos++
	return b
}

func (s *slotsStream) u32() uint32 {
	return uint32(s.next())<<24 | uint32(s.next())<<16 | uint32(s.next())<<8 | uint32(s.next())
}

// slotsSpinGrid draws the 5 reel stops and returns the 20 visible symbols.
func slotsSpinGrid(s *slotsStream) [slotsCells]byte {
	var g [slotsCells]byte
	for c := 0; c < slotsReels; c++ {
		stop := int(s.u32() % slotsStripLen)
		for r := 0; r < slotsRows; r++ {
			g[c*slotsRows+r] = slotsStrip[(stop+r)%slotsStripLen] - '0'
		}
	}
	return g
}

// slotsLineMult = Σ line pays in line-bet units, and how many lines paid.
func slotsLineMult(g *[slotsCells]byte) (uint64, int) {
	total := uint64(0)
	lines := 0
	for l := 0; l < 25; l++ {
		var sym [5]byte
		anchor := byte(255)
		for c := 0; c < 5; c++ {
			sym[c] = g[c*slotsRows+int(slotsPaylines[l][c])]
			if anchor == 255 && sym[c] != symWild && sym[c] != symScatter && sym[c] != symVault {
				anchor = sym[c]
			}
		}
		if anchor == 255 {
			if sym[0] != symWild {
				continue
			}
			anchor = symWild
		}
		m := 0
		for c := 0; c < 5; c++ {
			if sym[c] == anchor || sym[c] == symWild {
				m++
			} else {
				break
			}
		}
		if m >= 3 {
			total += slotsPays[anchor][m-3]
			lines++
		}
	}
	return total, lines
}

func slotsCount(g *[slotsCells]byte, sym byte) int {
	n := 0
	for i := 0; i < slotsCells; i++ {
		if g[i] == sym {
			n++
		}
	}
	return n
}

// hsDrawValue: 1× 50%, 2× 28%, 3× 12%, 5× 6%, MINI 3%, MINOR 0.9%, MAJOR 0.08%, GRAND 0.02%.
func hsDrawValue(s *slotsStream) uint16 {
	v := s.u32() % 10000
	switch {
	case v < 5000:
		return 1
	case v < 7800:
		return 2
	case v < 9000:
		return 3
	case v < 9600:
		return 5
	case v < 9900:
		return hsMini
	case v < 9990:
		return hsMinor
	case v < 9998:
		return hsMajor
	}
	return hsGrand
}

// slotsHoldAndSpin resolves the whole bonus from the stream: the vault cells
// start locked with a value each; then while respins remain and the board isn't
// full, every empty cell (in index order) lands a coin when its byte < 8, and a
// landing resets the respins to 3. Returns the 20 tiles (0 = empty), how many
// respins were played, and whether the board filled (blackout = GRAND).
func slotsHoldAndSpin(s *slotsStream, g *[slotsCells]byte) ([slotsCells]uint16, int, bool) {
	var tiles [slotsCells]uint16
	locked := 0
	for i := 0; i < slotsCells; i++ {
		if g[i] == symVault {
			tiles[i] = hsDrawValue(s)
			locked++
		}
	}
	respins := hsRespins
	played := 0
	for respins > 0 && locked < slotsCells {
		played++
		landed := false
		for i := 0; i < slotsCells; i++ {
			if tiles[i] != 0 {
				continue
			}
			if s.next() < hsLandBelow {
				tiles[i] = hsDrawValue(s)
				locked++
				landed = true
			}
		}
		if landed {
			respins = hsRespins
		} else {
			respins--
		}
	}
	return tiles, played, locked == slotsCells
}

func slotsGridString(g *[slotsCells]byte) string {
	b := make([]byte, slotsCells)
	for i := 0; i < slotsCells; i++ {
		b[i] = '0' + g[i]
	}
	return string(b)
}

func hsTilesString(t *[slotsCells]uint16) string {
	out := ""
	for i := 0; i < slotsCells; i++ {
		if i > 0 {
			out += "."
		}
		out += strconv.Itoa(int(t[i]))
	}
	return out
}
