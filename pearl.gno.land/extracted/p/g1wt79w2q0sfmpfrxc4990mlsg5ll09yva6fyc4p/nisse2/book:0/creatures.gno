package book

import "gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/types"

// CreatureManual is the frozen bestiary. Habitat tables are weights only;
// stats and lore live on the creature entry. Like the AD&D monster book:
// lookup, don't mutate.

var creatures map[string]types.Creature
var habitat map[string][]types.Spawn

func init() {
	creatures = map[string]types.Creature{
		"squirrel":  {Kind: "squirrel", Label: "Squirrel", Domain: "land", Level: 2, BoldSides: 4, KindnessSides: 6, CautSides: 8, SoulSides: 4, Lore: "A bright-eyed hoarder of winter stores."},
		"rabbit":    {Kind: "rabbit", Label: "Rabbit", Domain: "land", Level: 1, BoldSides: 3, KindnessSides: 6, CautSides: 8, SoulSides: 4, Lore: "Still as frost until it bolts."},
		"fox":       {Kind: "fox", Label: "Fox", Domain: "land", Level: 4, BoldSides: 6, KindnessSides: 4, CautSides: 8, SoulSides: 5, Lore: "Watches from the treeline, counting your mistakes."},
		"deer":      {Kind: "deer", Label: "Deer", Domain: "land", Level: 3, BoldSides: 4, KindnessSides: 6, CautSides: 8, SoulSides: 6, Lore: "A quiet court of the forest edge."},
		"owl":       {Kind: "owl", Label: "Owl", Domain: "sky", Level: 3, BoldSides: 4, KindnessSides: 6, CautSides: 8, SoulSides: 6, Lore: "Night librarian of the pines."},
		"dog":       {Kind: "dog", Label: "Dog", Domain: "land", Level: 3, BoldSides: 4, KindnessSides: 8, CautSides: 6, SoulSides: 6, Lore: "Already decided you are pack."},
		"cat":       {Kind: "cat", Label: "Cat", Domain: "land", Level: 2, BoldSides: 5, KindnessSides: 5, CautSides: 7, SoulSides: 5, Lore: "Agrees to travel if the terms amuse it."},
		"goat":      {Kind: "goat", Label: "Goat", Domain: "land", Level: 2, BoldSides: 6, KindnessSides: 4, CautSides: 6, SoulSides: 5, Lore: "Eats the map legend and still finds the way."},
		"donkey":    {Kind: "donkey", Label: "Donkey", Domain: "land", Level: 3, BoldSides: 6, KindnessSides: 6, CautSides: 4, SoulSides: 6, Lore: "Stubborn in the useful direction."},
		"mule":      {Kind: "mule", Label: "Mule", Domain: "land", Level: 4, BoldSides: 8, KindnessSides: 4, CautSides: 6, SoulSides: 6, Lore: "Carries more than you asked and less than you hoped."},
		"gull":      {Kind: "gull", Label: "Gull", Domain: "sky", Level: 2, BoldSides: 4, KindnessSides: 4, CautSides: 7, SoulSides: 4, Lore: "Harbour gossip with wings."},
		"seal":      {Kind: "seal", Label: "Seal", Domain: "land", Level: 4, BoldSides: 5, KindnessSides: 6, CautSides: 6, SoulSides: 6, Lore: "A wet stone that decided to live."},
		"otter":     {Kind: "otter", Label: "Otter", Domain: "land", Level: 3, BoldSides: 5, KindnessSides: 7, CautSides: 6, SoulSides: 5, Lore: "Theft, but charming."},
		"dove":      {Kind: "dove", Label: "Dove", Domain: "sky", Level: 2, BoldSides: 3, KindnessSides: 8, CautSides: 6, SoulSides: 6, Lore: "Monastery post and quiet weather."},
		"raven":     {Kind: "raven", Label: "Raven", Domain: "sky", Level: 3, BoldSides: 5, KindnessSides: 4, CautSides: 7, SoulSides: 6, Lore: "Remembers names you have not spoken yet."},
		"eagle":     {Kind: "eagle", Label: "Eagle", Domain: "sky", Level: 5, BoldSides: 7, KindnessSides: 4, CautSides: 7, SoulSides: 6, MaxMints: 100, Lore: "The mountain's own signature."},
		"reindeer":  {Kind: "reindeer", Label: "Reindeer", Domain: "land", Level: 5, BoldSides: 6, KindnessSides: 6, CautSides: 6, SoulSides: 6, MaxMints: 100, Lore: "Winter's working animal, antlers like a ledger."},
		"bear":      {Kind: "bear", Label: "Bear", Domain: "land", Level: 7, BoldSides: 8, KindnessSides: 4, CautSides: 5, SoulSides: 6, MaxMints: 100, Lore: "The forest standing up."},
		"wolverine": {Kind: "wolverine", Label: "Wolverine", Domain: "land", Level: 7, BoldSides: 8, KindnessSides: 4, CautSides: 6, SoulSides: 6, MaxMints: 100, Lore: "Small, and uninterested in that fact."},
		"fairy":     {Kind: "fairy", Label: "Fairy", Domain: "spirit", Level: 6, BoldSides: 3, KindnessSides: 8, CautSides: 6, SoulSides: 8, MaxMints: 100, Lore: "A bargain wearing a smile."},
		"unicorn":   {Kind: "unicorn", Label: "Unicorn", Domain: "mythic", Level: 12, BoldSides: 6, KindnessSides: 9, CautSides: 7, SoulSides: 9, MaxMints: 20, Lore: "Rare as a true north."},
		"pegasus":   {Kind: "pegasus", Label: "Pegasus", Domain: "mythic", Level: 13, BoldSides: 8, KindnessSides: 8, CautSides: 8, SoulSides: 8, MaxMints: 20, Lore: "Sky made animal."},
		"griffin":   {Kind: "griffin", Label: "Griffin", Domain: "mythic", Level: 14, BoldSides: 9, KindnessSides: 5, CautSides: 8, SoulSides: 8, MaxMints: 20, Lore: "Eagle mind, lion contract."},
	}

	habitat = map[string][]types.Spawn{
		"forest": {
			{Kind: "squirrel", Weight: 28}, {Kind: "deer", Weight: 22}, {Kind: "owl", Weight: 18},
			{Kind: "fox", Weight: 14}, {Kind: "bear", Weight: 8}, {Kind: "fairy", Weight: 6},
			{Kind: "unicorn", Weight: 2}, {Kind: "griffin", Weight: 1},
		},
		"meadow": {
			{Kind: "rabbit", Weight: 30}, {Kind: "deer", Weight: 22}, {Kind: "fox", Weight: 18},
			{Kind: "dog", Weight: 14}, {Kind: "unicorn", Weight: 2},
		},
		"moor": {
			{Kind: "rabbit", Weight: 30}, {Kind: "deer", Weight: 22}, {Kind: "fox", Weight: 18},
			{Kind: "dog", Weight: 14}, {Kind: "unicorn", Weight: 2},
		},
		"hills": {
			{Kind: "goat", Weight: 26}, {Kind: "fox", Weight: 20}, {Kind: "deer", Weight: 16},
			{Kind: "reindeer", Weight: 12}, {Kind: "wolverine", Weight: 8},
			{Kind: "griffin", Weight: 2}, {Kind: "pegasus", Weight: 1},
		},
		"mountain": {
			{Kind: "goat", Weight: 24}, {Kind: "eagle", Weight: 18}, {Kind: "wolverine", Weight: 14},
			{Kind: "bear", Weight: 12}, {Kind: "griffin", Weight: 3}, {Kind: "pegasus", Weight: 2},
		},
		"mountain_village": {
			{Kind: "goat", Weight: 24}, {Kind: "eagle", Weight: 18}, {Kind: "wolverine", Weight: 14},
			{Kind: "bear", Weight: 12}, {Kind: "griffin", Weight: 3}, {Kind: "pegasus", Weight: 2},
		},
		"farm": {
			{Kind: "dog", Weight: 30}, {Kind: "donkey", Weight: 24}, {Kind: "mule", Weight: 18},
			{Kind: "cat", Weight: 16}, {Kind: "fox", Weight: 8},
		},
		"coastal": {
			{Kind: "gull", Weight: 28}, {Kind: "seal", Weight: 20}, {Kind: "otter", Weight: 18},
			{Kind: "dog", Weight: 12}, {Kind: "pegasus", Weight: 1},
		},
		"harbor": {
			{Kind: "gull", Weight: 28}, {Kind: "seal", Weight: 20}, {Kind: "otter", Weight: 18},
			{Kind: "dog", Weight: 12}, {Kind: "pegasus", Weight: 1},
		},
		"fishing_village": {
			{Kind: "gull", Weight: 28}, {Kind: "seal", Weight: 20}, {Kind: "otter", Weight: 18},
			{Kind: "dog", Weight: 12}, {Kind: "pegasus", Weight: 1},
		},
		"monastery": {
			{Kind: "dove", Weight: 30}, {Kind: "cat", Weight: 22}, {Kind: "owl", Weight: 18}, {Kind: "fairy", Weight: 8},
		},
		"default": {
			{Kind: "dog", Weight: 28}, {Kind: "cat", Weight: 24}, {Kind: "fox", Weight: 12}, {Kind: "raven", Weight: 12},
		},
	}
}

func Creature(kind string) (types.Creature, bool) {
	c, ok := creatures[kind]
	return c, ok
}

func Habitat(terrainName string) []types.Spawn {
	pool, ok := habitat[terrainName]
	if !ok {
		return habitat["default"]
	}
	return pool
}

func ListCreatures() []types.Creature {
	out := make([]types.Creature, 0, len(creatures))
	for _, c := range creatures {
		out = append(out, c)
	}
	return out
}
