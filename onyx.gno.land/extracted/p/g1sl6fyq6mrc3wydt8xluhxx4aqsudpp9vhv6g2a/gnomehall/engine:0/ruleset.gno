package engine

// Clan is a named pool of special cards.
type Clan struct {
	Name string
	Pool uint64 // bit i set: Ruleset.Cards[i] is in the pool
}

// Ruleset holds every card and number the rules use.
type Ruleset struct {
	Cards         []Card
	Clans         []Clan
	HP            int // starting HP of both gnomes
	BlockCap      int
	CounterCap    int
	VulnerableCap int
	StrengthCap   int
	// VulnerableDoublesOneHit: each hit against a Vulnerable gnome deals double and uses a
	// token. Otherwise the next card to hit deals double on every hit and uses one token.
	VulnerableDoublesOneHit bool
	// StrengthLastsTheRound: Strength ends with the round, like Block and Counter. Otherwise
	// it lasts the match.
	StrengthLastsTheRound bool
	// VulnerableLastsTheRound: unused Vulnerable ends with the round. Otherwise it lasts
	// until hits use it.
	VulnerableLastsTheRound bool
}

// Gnome is one side's state between rounds; Block and Counter end with each round.
type Gnome struct {
	HP, Vulnerable, Strength int
	Spent                    uint64 // special cards played, by CardID bit
}

// State is the match between rounds. Round is the round about to be played, 1 to 3.
type State struct {
	Round  int
	Gnomes [2]Gnome
}

// Start is the state before round 1.
func (rs *Ruleset) Start() State {
	return State{Round: 1, Gnomes: [2]Gnome{{HP: rs.HP}, {HP: rs.HP}}}
}

func (rs *Ruleset) CardByName(name string) (CardID, bool) {
	for i := range rs.Cards {
		if rs.Cards[i].Name == name {
			return CardID(i), true
		}
	}
	return 0, false
}

// PlanOf looks each card up by name. It reports false when a name matches no card.
func (rs *Ruleset) PlanOf(names ...string) (Plan, bool) {
	plan := make(Plan, 0, len(names))
	for _, n := range names {
		id, ok := rs.CardByName(n)
		if !ok {
			return nil, false
		}
		plan = append(plan, id)
	}
	return plan, true
}

func (rs *Ruleset) ClanByName(name string) (Clan, bool) {
	for _, c := range rs.Clans {
		if c.Name == name {
			return c, true
		}
	}
	return Clan{}, false
}

func hits(n, damage int) []Effect {
	out := make([]Effect, n)
	for i := range out {
		out[i] = Effect{Hit, damage}
	}
	return out
}

// ProofOfConcept is the proof-of-concept ruleset: the two basics and the 10-card
// starter packs of the Pickers, Ironhide and Delvers clans.
func ProofOfConcept() *Ruleset {
	cards := []Card{
		{Name: "Pick", Cost: 1, Tier: Normal, Damage: hits(1, 1)},
		{Name: "Brace", Cost: 1, Tier: Normal, Block: []Effect{{GainBlock, 1}}},

		{Name: "Pickaxe Flurry", Cost: 1, Tier: Quick, Special: true, Damage: hits(2, 1)},
		{Name: "Kneecap", Cost: 1, Tier: Quick, Special: true, Interrupt: true, Damage: hits(1, 1)},
		{Name: "Sling Stone", Cost: 1, Tier: Normal, Special: true, Damage: hits(1, 2)},
		{Name: "Dodge Roll", Cost: 2, Tier: Normal, Special: true, Parry: 1},
		{Name: "Chalk Dust", Cost: 1, Tier: Quick, Special: true, Damage: []Effect{{ApplyVulnerable, 1}}},
		{Name: "Double Tap", Cost: 2, Tier: Normal, Special: true, Damage: hits(3, 1)},
		{Name: "Momentum", Cost: 1, Tier: Normal, Special: true, Damage: []Effect{{GainStrength, 1}}},
		{Name: "Undermine", Cost: 1, Tier: Quick, Special: true, Rare: true, Interrupt: true, Damage: []Effect{{VulnerableIfCancelled, 2}}},
		{Name: "Hunker Down", Cost: 3, Tier: Normal, Special: true, Parry: 2},
		{Name: "Boot and Heel", Cost: 2, Tier: Slow, Special: true, Damage: hits(2, 2)},

		{Name: "Stone Guard", Cost: 3, Tier: Normal, Special: true, Parry: 2},
		{Name: "Bulwark", Cost: 2, Tier: Normal, Special: true, Block: []Effect{{GainBlock, 5}}},
		{Name: "Hammer Blow", Cost: 2, Tier: Slow, Special: true, Damage: hits(1, 5)},
		{Name: "Cobble Throw", Cost: 1, Tier: Slow, Special: true, Damage: hits(1, 2)},
		{Name: "Spiked Shield", Cost: 1, Tier: Normal, Special: true, Block: []Effect{{GainBlock, 1}, {GainCounter, 1}}},
		{Name: "Anvil Stomp", Cost: 2, Tier: Slow, Special: true, Damage: []Effect{{Hit, 2}, {ApplyVulnerable, 1}}},
		{Name: "Feint", Cost: 2, Tier: Normal, Special: true, Damage: hits(1, 4), OnCancel: []Effect{{GainBlock, 4}}},
		{Name: "Avalanche", Cost: 1, Tier: Slow, Special: true, Rare: true, Damage: []Effect{{HitBlock, 0}}},
		{Name: "Shield Catch", Cost: 2, Tier: Normal, Special: true, Parry: 1},
		{Name: "Loose Timbers", Cost: 2, Tier: Normal, Special: true, Block: []Effect{{GainBlock, 3}}, CancelDamage: hits(1, 4)},

		{Name: "Kickback", Cost: 1, Tier: Slow, Special: true, Rare: true, Damage: []Effect{{HitHardest, 5}}},
		{Name: "Overdig", Cost: 2, Tier: Normal, Special: true, Damage: []Effect{{Hit, 6}, {GainVulnerable, 1}}},
		{Name: "Ambush", Cost: 1, Tier: Normal, Special: true, Damage: []Effect{{GainVulnerable, 1}, {HitIfNotAttacked, 6}}},
		{Name: "Open Guard", Cost: 1, Tier: Normal, Special: true, Block: []Effect{{GainBlock, 4}}, Damage: []Effect{{GainVulnerable, 1}}},
		{Name: "Chisel Jab", Cost: 1, Tier: Normal, Special: true, Damage: hits(1, 2)},
		{Name: "Rockfall", Cost: 2, Tier: Slow, Special: true, Damage: hits(1, 5)},
		{Name: "Cribbing", Cost: 1, Tier: Normal, Special: true, Block: []Effect{{BlockPerVulnerable, 1}}},
		{Name: "Deadfall", Cost: 2, Tier: Normal, Special: true, Parry: 1, Damage: []Effect{{VulnerableIfCancelled, 1}}},
		{Name: "Blowback", Cost: 2, Tier: Normal, Special: true, Block: []Effect{{MoveVulnerable, 0}}},
		{Name: "Cave-In", Cost: 3, Tier: Slow, Special: true, Damage: []Effect{{StripBlock, 0}, {Hit, 5}}},
	}
	const firstPickers, firstIronhide, firstDelvers, end = 2, 12, 22, 32
	return &Ruleset{
		Cards: cards,
		Clans: []Clan{
			{Name: "Pickers", Pool: bitRange(firstPickers, firstIronhide)},
			{Name: "Ironhide", Pool: bitRange(firstIronhide, firstDelvers)},
			{Name: "Delvers", Pool: bitRange(firstDelvers, end)},
		},
		HP:            15,
		BlockCap:      20,
		CounterCap:    3,
		VulnerableCap: 3,
		StrengthCap:   8,

		VulnerableDoublesOneHit: true,
		StrengthLastsTheRound:   true,
	}
}

// bitRange sets bits from, from+1, ..., to-1.
func bitRange(from, to int) uint64 {
	var bits uint64
	for i := from; i < to; i++ {
		bits |= uint64(1) << uint(i)
	}
	return bits
}
