package types

import "strings"

type Address string

type Position struct {
	X uint64
	Y uint64
}

func SameTile(a Position, b Position) bool {
	return a.X == b.X && a.Y == b.Y
}

func NormalizeAttitude(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "cautious":
		return "cautious"
	case "kind":
		return "kind"
	case "bold":
		return "bold"
	default:
		panic("unknown attitude")
	}
}

type Spawn struct {
	Kind   string
	Weight uint64
}

type Creature struct {
	Kind          string
	Label         string
	Domain        string
	Level         uint64
	Lore          string
	BoldSides     uint64
	KindnessSides uint64
	CautSides     uint64
	SoulSides     uint64
	MaxMints      uint64
}

type EncounterInput struct {
	Seed          string
	Attitude      string
	PlayerLevel   uint64
	Boldness      uint64
	Caution       uint64
	Kindness      uint64
	Soul          uint64
	CompBold      uint64
	CompCaution   uint64
	CompKind      uint64
	CompSoul      uint64
	CreatureKind  string
	CreatureLevel uint64
}

type EncounterOutcome struct {
	Kind         string
	Attitude     string
	Band         string
	Roll         uint64
	Stat         uint64
	PlayerTotal  uint64
	Target       uint64
	LevelGain    uint64
	BoldDelta    int64
	CautionDelta int64
	KindDelta    int64
	SoulDelta    int64
	ShouldMint   bool
}

type TravelPlan struct {
	UseBoat    bool
	Cost       uint64
	Budget     uint64
	LeavesBoat bool
}
