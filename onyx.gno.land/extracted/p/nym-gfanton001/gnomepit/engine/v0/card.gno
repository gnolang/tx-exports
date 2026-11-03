// Package engine holds the duel rules. The same source compiles as Go and as Gno, so it
// stays inside the Go 1.17 subset: no generics, no min or max builtins, no range over
// an integer, no maps and no imports.
package engine

const beatsPerRound = 3

// Tier orders effects inside a phase.
type Tier int

const (
	Quick Tier = iota
	Normal
	Slow
)

type EffectKind int

const (
	GainBlock EffectKind = iota
	GainCounter
	Hit      // deal N damage
	HitBlock // deal damage equal to your Block
	ApplyVulnerable
	GainStrength
	VulnerableIfCancelled // apply N Vulnerable if this card cancelled a card this beat
	MoveVulnerable        // Block phase: move all your Vulnerable to the opponent
	GainVulnerable        // gain N Vulnerable yourself
	HitPerVulnerable      // deal N damage, and N more for each Vulnerable on you
	BlockPerVulnerable    // Block phase: gain N Block, and N more for each Vulnerable on you
	StripBlock            // the opponent loses all Block at the end of the step
	HitHardest            // deal the HP the hardest opponent hit took from you this round, up to N
	HitIfNotAttacked      // deal N damage if no opponent attack lands this beat
)

type Effect struct {
	Kind EffectKind
	N    int
}

// CardID indexes Ruleset.Cards.
type CardID int

type Card struct {
	Name      string
	Cost      int
	Tier      Tier
	Special   bool // spent once played; basics are not
	Rare      bool // the clan's signature card; a deck holds exactly one
	Interrupt bool
	Parry     int      // Parry N: attacks it cancels while active; 0 for no Parry
	Block     []Effect // Block phase
	Damage    []Effect // Damage phase, in printed order
	OnCancel  []Effect // Block phase of the beat the card is cancelled on
	// CancelDamage resolves in the card's tier, in the Damage phase of the beat it is
	// cancelled on.
	CancelDamage []Effect
}

// Attack reports whether the card's text deals damage, including when it is cancelled.
func (c *Card) Attack() bool {
	return dealsDamage(c.Damage) || dealsDamage(c.CancelDamage)
}

func dealsDamage(effects []Effect) bool {
	for _, e := range effects {
		if e.Kind.isHit() {
			return true
		}
	}
	return false
}

func (k EffectKind) isHit() bool {
	return k == Hit || k == HitBlock || k == HitPerVulnerable || k == HitHardest || k == HitIfNotAttacked
}

// Plan is the ordered cards of one round; their costs sum to 3.
type Plan []CardID

type Side int

const (
	SideA Side = iota
	SideB
)
