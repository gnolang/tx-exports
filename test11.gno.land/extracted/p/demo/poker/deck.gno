package poker

// Deck manages a 52-card deck with deterministic shuffling
type Deck struct {
	Cards []Card
	Index int // Current deal position
}

// NewDeck creates a standard 52-card deck
func NewDeck() *Deck {
	cards := make([]Card, 52)
	idx := 0
	for suit := 0; suit < 4; suit++ {
		for value := 2; value <= 14; value++ {
			cards[idx] = Card{Suit: suit, Value: value}
			idx++
		}
	}
	return &Deck{Cards: cards, Index: 0}
}

// Shuffle shuffles the deck using a seed-based Fisher-Yates algorithm
// This is deterministic given the same seed, which is important for
// blockchain reproducibility. In production, the seed should come from
// a commit-reveal scheme where all players contribute randomness.
func (d *Deck) Shuffle(seed int64) {
	n := len(d.Cards)
	// Simple LCG (Linear Congruential Generator) for deterministic randomness
	state := seed
	for i := n - 1; i > 0; i-- {
		// LCG: state = (a * state + c) mod m
		state = (state*6364136223846793005 + 1442695040888963407) % (1 << 62)
		j := int(abs64(state) % int64(i+1))
		d.Cards[i], d.Cards[j] = d.Cards[j], d.Cards[i]
	}
	d.Index = 0
}

// Deal deals n cards from the deck
func (d *Deck) Deal(n int) []Card {
	if d.Index+n > len(d.Cards) {
		panic("not enough cards in deck")
	}
	cards := make([]Card, n)
	for i := 0; i < n; i++ {
		cards[i] = d.Cards[d.Index]
		d.Index++
	}
	return cards
}

// DealOne deals a single card from the deck
func (d *Deck) DealOne() Card {
	cards := d.Deal(1)
	return cards[0]
}

// Remaining returns the number of cards remaining in the deck
func (d *Deck) Remaining() int {
	return len(d.Cards) - d.Index
}

// Reset resets the deck to the beginning
func (d *Deck) Reset() {
	d.Index = 0
}

func abs64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}
