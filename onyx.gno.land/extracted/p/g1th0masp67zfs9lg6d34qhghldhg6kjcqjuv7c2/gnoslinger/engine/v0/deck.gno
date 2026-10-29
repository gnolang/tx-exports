package engine

import (
	"crypto/sha256"
	"encoding/binary"
	"math/rand"
	"strings"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"
)

// Result is one line of a result card: a number of points, or a named
// penalty (rules 14.1, 14.21). Points are 0 or more; penalties are negative.
type Result int

const (
	// LoseAim: the character loses its aim (no aim is tracked yet).
	LoseAim Result = -1
	// WildShot: every cocked gun goes off without hitting anything, is
	// uncocked and loses a shell; the aim is lost.
	WildShot Result = -2
	// Drop: an upright character turns DOWN, draws 3 delay cards and loses
	// its aim; no effect when already DOWN.
	Drop Result = -3
)

// IsPoints reports whether the line is a number of points.
func (r Result) IsPoints() bool { return r >= 0 }

// String returns the penalty name used in events and JSON, or "" for points.
func (r Result) String() string {
	switch r {
	case LoseAim:
		return "lose_aim"
	case WildShot:
		return "wild_shot"
	case Drop:
		return "drop"
	}
	return ""
}

// ResultCard is one of the 108 result cards (rule 2.4): N is its number on
// the card. Delay and Wound are the DELAY and WOUND lines and Hex the HEX
// line (direction cards, 14.3: a relative direction, hex.Same or hex.Long).
// The upper block is either a FIRE hit chart with its Target Status letters
// (cards 1-100, see fire.gno) or a MALFUNCTION block (cards 101-108). The
// TAC line (optional rule 9) is not used by this game.
type ResultCard struct {
	N      int
	Delay  Result
	Wound  Result
	Hex    hex.Rel
	Fire   *Chart       // the hit chart of a FIRE card, nil on a MALFUNCTION
	Status string       // Target Status letters of a FIRE card (StatusMove...)
	Malf   *Malfunction // the block of a MALFUNCTION card, nil on a FIRE card
}

// IsFire reports whether the card is a FIRE card (13.2).
func (c ResultCard) IsFire() bool { return c.Malf == nil }

// DeckSize is the number of result cards.
const DeckSize = 108

// Cards is the result deck in card order, index 0 = card 1.
var Cards = buildCards()

func buildCards() (cards [DeckSize]ResultCard) {
	// Each row is a run of consecutive cards sharing the same three lines,
	// transcribed from the card images (assets/result_card_NNN.png).
	runs := []struct {
		from, to     int
		delay, wound Result
		hex          hex.Rel
	}{
		{1, 18, 0, 0, hex.Same},
		{19, 36, 0, 1, hex.Long},
		{37, 54, 1, 2, hex.Long},
		{55, 60, 1, 3, hex.AheadLeft},
		{61, 69, 2, 3, hex.Same},
		{70, 78, 2, 4, hex.Long},
		{79, 84, 2, 5, hex.AheadRight},
		{85, 87, 2, 6, hex.Ahead},
		{88, 93, LoseAim, 1, hex.BackRight},
		{94, 99, LoseAim, WildShot, hex.BackLeft},
		{100, 100, WildShot, Drop, hex.Back},
		{101, 103, WildShot, Drop, hex.Back},
		{104, 106, 1, Drop, hex.Ahead},
		{107, 108, Drop, Drop, hex.Back},
	}
	n := 0
	for _, r := range runs {
		for i := r.from; i <= r.to; i++ {
			c := ResultCard{N: i, Delay: r.delay, Wound: r.wound, Hex: r.hex}
			if i <= len(fireCards) {
				c.Fire = parseChart(fireCards[i-1].chart)
				c.Status = fireCards[i-1].status
			} else {
				c.Malf = &malfunctions[i-1-len(fireCards)]
			}
			cards[i-1] = c
			n++
		}
	}
	if n != DeckSize {
		panic("result deck: wrong card count")
	}
	return cards
}

// Card returns result card n (1 to 108).
func Card(n int) ResultCard { return Cards[n-1] }

// Drawer hands out result cards to Resolve.
type Drawer interface {
	// Draw returns the next result card.
	Draw() ResultCard
}

// Seed hashes the given parts into shuffle seed material.
func Seed(parts ...string) [32]byte {
	return sha256.Sum256([]byte(strings.Join(parts, "|")))
}

// Deck is the result deck shuffled once from a seed and dealt in order
// (rule 5.7: the deck is reshuffled when exhausted). The same seed always
// deals the same cards, so a turn can be replayed from its stored seed.
type Deck struct {
	r     *rand.Rand
	order [DeckSize]int // card numbers in deal order
	next  int
	drawn []int // every card dealt so far, in order
}

// NewDeck shuffles the 108 cards with the seed.
func NewDeck(seed [32]byte) *Deck {
	s1 := binary.BigEndian.Uint64(seed[0:8])
	s2 := binary.BigEndian.Uint64(seed[8:16])
	d := &Deck{r: rand.New(rand.NewPCG(s1, s2))}
	d.shuffle()
	return d
}

func (d *Deck) shuffle() {
	for i := range d.order {
		d.order[i] = i + 1
	}
	d.r.Shuffle(DeckSize, func(i, j int) { d.order[i], d.order[j] = d.order[j], d.order[i] })
	d.next = 0
}

// Draw implements Drawer: the next card of the shuffle, reshuffling the
// whole deck once every card has been dealt.
func (d *Deck) Draw() ResultCard {
	if d.next >= DeckSize {
		d.shuffle()
	}
	c := Cards[d.order[d.next]-1]
	d.next++
	d.drawn = append(d.drawn, c.N)
	return c
}

// Order returns the card numbers in the order the deck deals them.
func (d *Deck) Order() [DeckSize]int { return d.order }

// Drawn returns the numbers of every card dealt so far, in order: the trace
// of a turn's draws.
func (d *Deck) Drawn() []int { return d.drawn }

// Fixed is a Drawer that always deals the same card; tests use Fixed(37)
// (DELAY 1) to match the BGA reference engine's stub.
type Fixed int

// Draw implements Drawer.
func (f Fixed) Draw() ResultCard { return Card(int(f)) }

// Sequence is a Drawer dealing the given card numbers in order, then the
// last one forever; for tests.
type Sequence []int

// Draw implements Drawer.
func (s *Sequence) Draw() ResultCard {
	q := *s
	n := q[0]
	if len(q) > 1 {
		*s = q[1:]
	}
	return Card(n)
}
