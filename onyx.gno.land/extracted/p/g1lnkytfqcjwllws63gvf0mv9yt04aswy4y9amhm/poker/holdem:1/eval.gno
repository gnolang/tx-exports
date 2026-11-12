// Package holdem implements the chain-independent rules of no-limit Texas
// Hold'em: hand evaluation, side pots and the betting state machine of one
// hand. Cards are indices 0..51 with rank = c % 13 (0 = Two .. 12 = Ace) and
// suit = c / 13.
package holdem

// Hand categories, the high bits of a score.
const (
	HighCard = iota
	OnePair
	TwoPair
	Trips
	Straight
	Flush
	FullHouse
	Quads
	StraightFlush
)

var categoryNames = []string{
	"high card", "pair", "two pair", "three of a kind", "straight",
	"flush", "full house", "four of a kind", "straight flush",
}

// CategoryName names the category of a score.
func CategoryName(score int) string {
	c := Category(score)
	if c < 0 || c >= len(categoryNames) {
		return "?"
	}
	return categoryNames[c]
}

// Category returns the hand category of a score.
func Category(score int) int {
	return score >> 20
}

func makeScore(cat int, ranks ...int) int {
	s := cat << 20
	for i := 0; i < 5; i++ {
		r := 0
		if i < len(ranks) {
			r = ranks[i]
		}
		s |= r << uint(16-4*i)
	}
	return s
}

// straightHigh returns the top rank of the best straight in a rank bitmask,
// 3 for the wheel (A-2-3-4-5), or -1.
func straightHigh(mask int) int {
	for hi := 12; hi >= 4; hi-- {
		m := 0x1f << uint(hi-4)
		if mask&m == m {
			return hi
		}
	}
	wheel := 0xf | 1<<12
	if mask&wheel == wheel {
		return 3
	}
	return -1
}

// topRanks returns up to n highest ranks set in mask, skipping excluded ranks.
func topRanks(mask int, n int, exclude ...int) []int {
	out := []int{}
	for r := 12; r >= 0 && len(out) < n; r-- {
		if mask&(1<<uint(r)) == 0 {
			continue
		}
		skip := false
		for _, e := range exclude {
			if e == r {
				skip = true
			}
		}
		if !skip {
			out = append(out, r)
		}
	}
	return out
}

// Evaluate scores the best five-card hand among 5 to 7 cards. Higher is better;
// equal scores tie.
func Evaluate(cards []int) int {
	if len(cards) < 5 || len(cards) > 7 {
		panic("evaluate needs 5 to 7 cards")
	}
	var counts [13]int
	var suitCount [4]int
	var suitMask [4]int
	rankMask := 0
	for _, c := range cards {
		if c < 0 || c >= 52 {
			panic("invalid card")
		}
		r, s := c%13, c/13
		counts[r]++
		suitCount[s]++
		suitMask[s] |= 1 << uint(r)
		rankMask |= 1 << uint(r)
	}
	flushSuit := -1
	for s := 0; s < 4; s++ {
		if suitCount[s] >= 5 {
			flushSuit = s
		}
	}
	if flushSuit >= 0 {
		if hi := straightHigh(suitMask[flushSuit]); hi >= 0 {
			return makeScore(StraightFlush, hi)
		}
	}
	quad, trip, trip2 := -1, -1, -1
	pairs := []int{}
	for r := 12; r >= 0; r-- {
		switch counts[r] {
		case 4:
			if quad < 0 {
				quad = r
			}
		case 3:
			if trip < 0 {
				trip = r
			} else if trip2 < 0 {
				trip2 = r
			}
		case 2:
			pairs = append(pairs, r)
		}
	}
	if quad >= 0 {
		return makeScore(Quads, append([]int{quad}, topRanks(rankMask, 1, quad)...)...)
	}
	if trip >= 0 {
		pairRank := -1
		if trip2 >= 0 {
			pairRank = trip2
		}
		if len(pairs) > 0 && pairs[0] > pairRank {
			pairRank = pairs[0]
		}
		if pairRank >= 0 {
			return makeScore(FullHouse, trip, pairRank)
		}
	}
	if flushSuit >= 0 {
		return makeScore(Flush, topRanks(suitMask[flushSuit], 5)...)
	}
	if hi := straightHigh(rankMask); hi >= 0 {
		return makeScore(Straight, hi)
	}
	if trip >= 0 {
		return makeScore(Trips, append([]int{trip}, topRanks(rankMask, 2, trip)...)...)
	}
	if len(pairs) >= 2 {
		return makeScore(TwoPair, pairs[0], pairs[1], topRanks(rankMask, 1, pairs[0], pairs[1])[0])
	}
	if len(pairs) == 1 {
		return makeScore(OnePair, append([]int{pairs[0]}, topRanks(rankMask, 3, pairs[0])...)...)
	}
	return makeScore(HighCard, topRanks(rankMask, 5)...)
}
