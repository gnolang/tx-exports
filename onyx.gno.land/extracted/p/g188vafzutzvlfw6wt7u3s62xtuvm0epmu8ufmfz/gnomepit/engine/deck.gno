package engine

// deckSize is the number of special cards in a deck.
const deckSize = 8

// LegalDeck reports whether deck, a bit set by CardID, is deckSize cards of clan's pool
// holding exactly one Rare.
func (rs *Ruleset) LegalDeck(clan Clan, deck uint64) bool {
	if deck&^clan.Pool != 0 {
		return false
	}
	cards, rares := 0, 0
	for i := range rs.Cards {
		if deck&(uint64(1)<<uint(i)) == 0 {
			continue
		}
		cards++
		if rs.Cards[i].Rare {
			rares++
		}
	}
	return cards == deckSize && rares == 1
}
