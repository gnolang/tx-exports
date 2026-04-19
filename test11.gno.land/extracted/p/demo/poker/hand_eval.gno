package poker

// EvaluateHand evaluates the best 5-card poker hand from 7 cards
// (2 hole cards + 5 community cards)
func EvaluateHand(holeCards [2]Card, community []Card) HandResult {
	// Combine all available cards
	allCards := make([]Card, 0, 7)
	allCards = append(allCards, holeCards[0], holeCards[1])
	allCards = append(allCards, community...)

	if len(allCards) < 5 {
		return HandResult{Rank: HighCard}
	}

	// Generate all C(n, 5) combinations and find the best hand
	best := HandResult{Rank: HighCard}
	n := len(allCards)

	for i := 0; i < n-4; i++ {
		for j := i + 1; j < n-3; j++ {
			for k := j + 1; k < n-2; k++ {
				for l := k + 1; l < n-1; l++ {
					for m := l + 1; m < n; m++ {
						hand := [5]Card{allCards[i], allCards[j], allCards[k], allCards[l], allCards[m]}
						result := evaluate5(hand)
						if compareHands(result, best) > 0 {
							best = result
						}
					}
				}
			}
		}
	}

	return best
}

// evaluate5 evaluates exactly 5 cards
func evaluate5(cards [5]Card) HandResult {
	// Sort cards by value descending
	sorted := sortCards(cards)

	isFlush := checkFlush(sorted)
	isStraight, highCard := checkStraight(sorted)

	// Count value occurrences
	counts := make(map[int]int)
	for _, c := range sorted {
		counts[c.Value]++
	}

	// Classify hand
	if isFlush && isStraight {
		if highCard == 14 {
			return HandResult{Rank: RoyalFlush, TieBreak: [5]int{14, 0, 0, 0, 0}, BestCards: sorted}
		}
		return HandResult{Rank: StraightFlush, TieBreak: [5]int{highCard, 0, 0, 0, 0}, BestCards: sorted}
	}

	// Four of a kind
	if hasNOfAKind(counts, 4) {
		quad := getValuesWithCount(counts, 4)
		kicker := getValuesWithCount(counts, 1)
		return HandResult{
			Rank:      FourOfAKind,
			TieBreak:  [5]int{quad[0], kicker[0], 0, 0, 0},
			BestCards: sorted,
		}
	}

	// Full house
	if hasNOfAKind(counts, 3) && hasNOfAKind(counts, 2) {
		trips := getValuesWithCount(counts, 3)
		pair := getValuesWithCount(counts, 2)
		return HandResult{
			Rank:      FullHouse,
			TieBreak:  [5]int{trips[0], pair[0], 0, 0, 0},
			BestCards: sorted,
		}
	}

	if isFlush {
		return HandResult{
			Rank:      Flush,
			TieBreak:  [5]int{sorted[0].Value, sorted[1].Value, sorted[2].Value, sorted[3].Value, sorted[4].Value},
			BestCards: sorted,
		}
	}

	if isStraight {
		return HandResult{
			Rank:      Straight,
			TieBreak:  [5]int{highCard, 0, 0, 0, 0},
			BestCards: sorted,
		}
	}

	// Three of a kind
	if hasNOfAKind(counts, 3) {
		trips := getValuesWithCount(counts, 3)
		kickers := getValuesWithCount(counts, 1)
		sortDescending(kickers)
		tb := [5]int{trips[0], 0, 0, 0, 0}
		for i, v := range kickers {
			if i+1 < 5 {
				tb[i+1] = v
			}
		}
		return HandResult{Rank: ThreeOfAKind, TieBreak: tb, BestCards: sorted}
	}

	// Two pair
	pairs := getValuesWithCount(counts, 2)
	if len(pairs) == 2 {
		sortDescending(pairs)
		kickers := getValuesWithCount(counts, 1)
		return HandResult{
			Rank:      TwoPair,
			TieBreak:  [5]int{pairs[0], pairs[1], kickers[0], 0, 0},
			BestCards: sorted,
		}
	}

	// One pair
	if len(pairs) == 1 {
		kickers := getValuesWithCount(counts, 1)
		sortDescending(kickers)
		tb := [5]int{pairs[0], 0, 0, 0, 0}
		for i, v := range kickers {
			if i+1 < 5 {
				tb[i+1] = v
			}
		}
		return HandResult{Rank: OnePair, TieBreak: tb, BestCards: sorted}
	}

	// High card
	return HandResult{
		Rank:      HighCard,
		TieBreak:  [5]int{sorted[0].Value, sorted[1].Value, sorted[2].Value, sorted[3].Value, sorted[4].Value},
		BestCards: sorted,
	}
}

// compareHands compares two hand results: returns >0 if a is better, <0 if b is better, 0 if equal
func compareHands(a, b HandResult) int {
	if a.Rank != b.Rank {
		return int(a.Rank) - int(b.Rank)
	}
	for i := 0; i < 5; i++ {
		if a.TieBreak[i] != b.TieBreak[i] {
			return a.TieBreak[i] - b.TieBreak[i]
		}
	}
	return 0
}

// CompareHandResults is exported for use in the realm
func CompareHandResults(a, b HandResult) int {
	return compareHands(a, b)
}

// Helper functions

func sortCards(cards [5]Card) [5]Card {
	sorted := cards
	for i := 0; i < 4; i++ {
		for j := i + 1; j < 5; j++ {
			if sorted[j].Value > sorted[i].Value {
				sorted[i], sorted[j] = sorted[j], sorted[i]
			}
		}
	}
	return sorted
}

func checkFlush(cards [5]Card) bool {
	suit := cards[0].Suit
	for i := 1; i < 5; i++ {
		if cards[i].Suit != suit {
			return false
		}
	}
	return true
}

func checkStraight(cards [5]Card) (bool, int) {
	// Normal straight check (cards are sorted descending)
	isSeq := true
	for i := 0; i < 4; i++ {
		if cards[i].Value-cards[i+1].Value != 1 {
			isSeq = false
			break
		}
	}
	if isSeq {
		return true, cards[0].Value
	}

	// Check for A-2-3-4-5 (wheel)
	if cards[0].Value == 14 && cards[1].Value == 5 && cards[2].Value == 4 && cards[3].Value == 3 && cards[4].Value == 2 {
		return true, 5 // 5-high straight
	}

	return false, 0
}

func hasNOfAKind(counts map[int]int, n int) bool {
	for _, c := range counts {
		if c == n {
			return true
		}
	}
	return false
}

func getValuesWithCount(counts map[int]int, n int) []int {
	result := []int{}
	for v, c := range counts {
		if c == n {
			result = append(result, v)
		}
	}
	sortDescending(result)
	return result
}

func sortDescending(arr []int) {
	for i := 0; i < len(arr)-1; i++ {
		for j := i + 1; j < len(arr); j++ {
			if arr[j] > arr[i] {
				arr[i], arr[j] = arr[j], arr[i]
			}
		}
	}
}
