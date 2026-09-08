package rules

import (
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/book"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/dice"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/types"
)

func EncounterChance(code uint8) uint64 {
	switch book.TerrainName(code) {
	case "forest", "meadow", "moor":
		return 75
	case "hills", "mountain", "coastal":
		return 60
	case "farm", "fishing_village", "mountain_village":
		return 55
	case "harbor", "monastery":
		return 40
	case "city", "city_north", "city_south", "village":
		return 30
	case "ocean":
		return 0
	default:
		return 40
	}
}

func PickCreature(seed string, code uint8) (types.Creature, bool) {
	pool := book.Habitat(book.TerrainName(code))
	if len(pool) == 0 {
		return types.Creature{}, false
	}
	total := uint64(0)
	for _, s := range pool {
		total += s.Weight
	}
	if total == 0 {
		c, ok := book.Creature(pool[0].Kind)
		return c, ok
	}
	needle := dice.Roll(seed, "encounter-pick", total)
	running := uint64(0)
	for i := 0; i < len(pool); i++ {
		running += pool[i].Weight
		if needle < running {
			c, ok := book.Creature(pool[i].Kind)
			return c, ok
		}
	}
	c, ok := book.Creature(pool[len(pool)-1].Kind)
	return c, ok
}

func moodStat(in types.EncounterInput, attitude string) uint64 {
	bold := in.Boldness + in.CompBold
	caut := in.Caution + in.CompCaution
	kind := in.Kindness + in.CompKind
	switch attitude {
	case "bold":
		return bold + 10
	case "kind":
		return kind + 10
	default:
		return caut + 10
	}
}

func encounterTarget(creatureLevel uint64, playerLevel uint64) uint64 {
	base := 12 + creatureLevel*3
	if playerLevel >= creatureLevel {
		diff := playerLevel - creatureLevel
		if diff > base/2 {
			diff = base / 2
		}
		base -= diff
	}
	if base < 8 {
		return 8
	}
	return base
}

func encounterBand(total int64, target int64) string {
	if total >= target+6 {
		return "triumph"
	}
	if total >= target {
		return "success"
	}
	if total >= target-6 {
		return "setback"
	}
	return "ruin"
}

func ResolveEncounter(in types.EncounterInput) types.EncounterOutcome {
	attitude := types.NormalizeAttitude(in.Attitude)
	roll := dice.D20(in.Seed, "encounter-"+in.CreatureKind)
	stat := moodStat(in, attitude)
	playerTotal := roll + stat + in.PlayerLevel
	target := encounterTarget(in.CreatureLevel, in.PlayerLevel)
	band := encounterBand(int64(playerTotal), int64(target))

	out := types.EncounterOutcome{
		Kind:        in.CreatureKind,
		Attitude:    attitude,
		Band:        band,
		Roll:        roll,
		Stat:        stat,
		PlayerTotal: playerTotal,
		Target:      target,
	}

	switch band {
	case "triumph":
		out.LevelGain = 1
		out.SoulDelta = 1
		out.ShouldMint = true
		switch attitude {
		case "bold":
			out.BoldDelta = 1
		case "kind":
			out.KindDelta = 1
		default:
			out.CautionDelta = 1
		}
	case "success":
		out.ShouldMint = true
		switch attitude {
		case "bold":
			out.BoldDelta = 1
		case "kind":
			out.KindDelta = 1
		default:
			out.CautionDelta = 1
		}
	case "setback":
		switch attitude {
		case "bold":
			out.BoldDelta = -1
		case "kind":
			out.KindDelta = -1
		default:
			out.CautionDelta = -1
		}
	default:
		out.SoulDelta = -1
		switch attitude {
		case "bold":
			out.BoldDelta = -2
		case "kind":
			out.KindDelta = -2
		default:
			out.CautionDelta = -2
		}
	}
	return out
}

func ResolveArrival(seed string, code uint8, in types.EncounterInput) (types.EncounterOutcome, bool) {
	chance := EncounterChance(code)
	if chance == 0 {
		return types.EncounterOutcome{}, false
	}
	if dice.Percent(seed, "encounter-chance") >= chance {
		return types.EncounterOutcome{}, false
	}
	creature, ok := PickCreature(seed, code)
	if !ok {
		return types.EncounterOutcome{}, false
	}
	in.Seed = seed
	in.CreatureKind = creature.Kind
	in.CreatureLevel = creature.Level
	return ResolveEncounter(in), true
}
