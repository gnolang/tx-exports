package nisse

import "strconv"

// Stat profiles for encounterable creature kinds. Auto-mint on success.

type CompanionMintSpec struct {
	Type          string
	BoldSides     uint64
	KindnessSides uint64
	CautSides     uint64
	SoulSides     uint64
	MaxMints      uint64 // 0 = unlimited global mints of this kind
}

var companionMintSpecs map[string]*CompanionMintSpec
var companionMintedCounts map[string]uint64

func init() {
	companionMintSpecs = map[string]*CompanionMintSpec{
		"squirrel":  {Type: "squirrel", BoldSides: 4, KindnessSides: 6, CautSides: 8, SoulSides: 4},
		"rabbit":    {Type: "rabbit", BoldSides: 3, KindnessSides: 6, CautSides: 8, SoulSides: 4},
		"fox":       {Type: "fox", BoldSides: 6, KindnessSides: 4, CautSides: 8, SoulSides: 5},
		"deer":      {Type: "deer", BoldSides: 4, KindnessSides: 6, CautSides: 8, SoulSides: 6},
		"owl":       {Type: "owl", BoldSides: 4, KindnessSides: 6, CautSides: 8, SoulSides: 6},
		"dog":       {Type: "dog", BoldSides: 4, KindnessSides: 8, CautSides: 6, SoulSides: 6},
		"cat":       {Type: "cat", BoldSides: 5, KindnessSides: 5, CautSides: 7, SoulSides: 5},
		"goat":      {Type: "goat", BoldSides: 6, KindnessSides: 4, CautSides: 6, SoulSides: 5},
		"donkey":    {Type: "donkey", BoldSides: 6, KindnessSides: 6, CautSides: 4, SoulSides: 6},
		"mule":      {Type: "mule", BoldSides: 8, KindnessSides: 4, CautSides: 6, SoulSides: 6},
		"gull":      {Type: "gull", BoldSides: 4, KindnessSides: 4, CautSides: 7, SoulSides: 4},
		"seal":      {Type: "seal", BoldSides: 5, KindnessSides: 6, CautSides: 6, SoulSides: 6},
		"otter":     {Type: "otter", BoldSides: 5, KindnessSides: 7, CautSides: 6, SoulSides: 5},
		"dove":      {Type: "dove", BoldSides: 3, KindnessSides: 8, CautSides: 6, SoulSides: 6},
		"raven":     {Type: "raven", BoldSides: 5, KindnessSides: 4, CautSides: 7, SoulSides: 6},
		"eagle":     {Type: "eagle", BoldSides: 7, KindnessSides: 4, CautSides: 7, SoulSides: 6, MaxMints: 100},
		"reindeer":  {Type: "reindeer", BoldSides: 6, KindnessSides: 6, CautSides: 6, SoulSides: 6, MaxMints: 100},
		"bear":      {Type: "bear", BoldSides: 8, KindnessSides: 4, CautSides: 5, SoulSides: 6, MaxMints: 100},
		"wolverine": {Type: "wolverine", BoldSides: 8, KindnessSides: 4, CautSides: 6, SoulSides: 6, MaxMints: 100},
		"fairy":     {Type: "fairy", BoldSides: 3, KindnessSides: 8, CautSides: 6, SoulSides: 8, MaxMints: 100},
		"unicorn":   {Type: "unicorn", BoldSides: 6, KindnessSides: 9, CautSides: 7, SoulSides: 9, MaxMints: 20},
		"pegasus":   {Type: "pegasus", BoldSides: 8, KindnessSides: 8, CautSides: 8, SoulSides: 8, MaxMints: 20},
		"griffin":   {Type: "griffin", BoldSides: 9, KindnessSides: 5, CautSides: 8, SoulSides: 8, MaxMints: 20},
	}
	companionMintedCounts = make(map[string]uint64)
}

func companionMintSpec(companionType string) *CompanionMintSpec {
	return companionMintSpecs[normalizeKey(companionType)]
}

func companionMintLimitReached(companionType string) bool {
	spec := companionMintSpec(companionType)
	if spec == nil || spec.MaxMints == 0 {
		return false
	}
	return companionMintedCounts[spec.Type] >= spec.MaxMints
}

func playerOwnsCompanionType(playerName string, companionType string) bool {
	companionType = normalizeKey(companionType)
	for assetID := uint64(1); assetID < nextAssetID; assetID++ {
		asset := assets[assetID]
		if asset == nil {
			continue
		}
		if asset.OwnerPlayer == playerName && asset.Kind == "companion" && asset.Subtype == companionType {
			return true
		}
	}
	return false
}

func companionLabel(companionType string) string {
	value := normalizeKey(companionType)
	if value == "" {
		return "Companion"
	}
	first := value[0]
	if first >= 'a' && first <= 'z' {
		first = first - ('a' - 'A')
	}
	return string(first) + value[1:]
}

func companionSpeciesDomain(companionType string) string {
	switch normalizeKey(companionType) {
	case "pegasus", "griffin", "unicorn":
		return "mythic"
	case "fairy":
		return "spirit"
	case "gull", "seal", "otter", "dove", "raven", "eagle", "owl":
		return "sky"
	default:
		return "land"
	}
}

func companionRollSeed(player *Player, companionType string, slot string) uint64 {
	source := normalizeKey(player.Name) +
		":" + normalizeKey(companionType) +
		":" + normalizeKey(slot) +
		":" + strconv.Itoa(int(nextAssetID)) +
		":" + strconv.Itoa(int(player.Turns))
	sum := uint64(0)
	for i := 0; i < len(source); i++ {
		sum += uint64(source[i]) * uint64(i+5)
	}
	return sum
}

func rollCompanionStat(player *Player, companionType string, slot string, sides uint64) uint64 {
	if sides == 0 {
		return 0
	}
	return (companionRollSeed(player, companionType, slot) % sides) + 1
}

func mintCompanionProfile(player *Player, companionType string) (uint64, uint64, uint64, uint64) {
	spec := companionMintSpec(companionType)
	if spec == nil {
		panic("unknown companion kind")
	}
	return rollCompanionStat(player, companionType, "bold", spec.BoldSides),
		rollCompanionStat(player, companionType, "kind", spec.KindnessSides),
		rollCompanionStat(player, companionType, "caut", spec.CautSides),
		rollCompanionStat(player, companionType, "soul", spec.SoulSides)
}

func mintCompanionWithProfile(playerKey string, player *Player, companionType string, bold uint64, kindn uint64, caut uint64, soul uint64) (bool, string) {
	spec := companionMintSpec(companionType)
	if spec == nil {
		panic("unknown companion kind")
	}
	if playerOwnsCompanionType(player.Name, spec.Type) {
		return false, ""
	}
	label := companionLabel(spec.Type)
	collection := ensureCompanionCollection(playerKey)
	id := nextCompanionID
	nextCompanionID++
	asset := createAsset("companion", spec.Type, label, player.Name, player.Turns, player.Pos)
	companion := &Companion{
		ID:          id,
		AssetID:     asset.ID,
		OwnerPlayer: player.Name,
		Species: CompanionSpecies{
			Kind: companionSpeciesDomain(spec.Type),
			Name: label,
		},
		FoundAt:   player.Pos,
		FoundTurn: player.Turns,
		Boldness:  bold,
		Kindness:  kindn,
		Caution:   caut,
		Soul:      soul,
	}
	collection[id] = companion
	companionMintedCounts[spec.Type]++
	return true, asset.DisplayName
}

func autoMintEncounterCompanion(playerKey string, player *Player, companionType string) (bool, string) {
	spec := companionMintSpec(companionType)
	if spec == nil {
		return false, ""
	}
	if companionMintLimitReached(spec.Type) {
		return false, ""
	}
	if playerOwnsCompanionType(player.Name, spec.Type) {
		return false, ""
	}
	bold, kindn, caut, soul := mintCompanionProfile(player, spec.Type)
	return mintCompanionWithProfile(playerKey, player, spec.Type, bold, kindn, caut, soul)
}
