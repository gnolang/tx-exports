package villagersv1

import "gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"

// TraitCount is the number of traits; trait indexes are 0..TraitCount-1.
const TraitCount = 8

// Trait indexes.
const (
	TraitNightOwl   = 0
	TraitLoud       = 1
	TraitCharming   = 2
	TraitGrumpy     = 3
	TraitHardWorker = 4
	TraitBroke      = 5
	TraitCreative   = 6
	TraitCheerful   = 7
)

// Jobs (Villager.Job).
const (
	JobRegular = 0
	JobBard    = 1
	JobCook    = 2
	JobBarkeep = 3
)

const jobCount = 4

// TraitName returns the trait's display name, or "" for an index out of range.
func TraitName(i int) string {
	switch i {
	case TraitNightOwl:
		return "NIGHT OWL"
	case TraitLoud:
		return "LOUD"
	case TraitCharming:
		return "CHARMING"
	case TraitGrumpy:
		return "GRUMPY"
	case TraitHardWorker:
		return "HARD WORKER"
	case TraitBroke:
		return "BROKE"
	case TraitCreative:
		return "CREATIVE"
	case TraitCheerful:
		return "CHEERFUL"
	}
	return ""
}

// traitMods returns one trait's decay modifiers in basis points
// (10000 = normal). An index out of range is neutral (10000 each).
func traitMods(i int) townmath.TraitMods {
	switch i {
	case TraitNightOwl:
		return townmath.TraitMods{ThirstBps: 10000, FunBps: 10000, EnergyBps: 5000}
	case TraitLoud:
		return townmath.TraitMods{ThirstBps: 15000, FunBps: 10000, EnergyBps: 10000}
	case TraitCharming:
		return townmath.TraitMods{ThirstBps: 10000, FunBps: 7000, EnergyBps: 10000}
	case TraitGrumpy:
		return townmath.TraitMods{ThirstBps: 10000, FunBps: 15000, EnergyBps: 10000}
	case TraitHardWorker:
		return townmath.TraitMods{ThirstBps: 10000, FunBps: 10000, EnergyBps: 7000}
	case TraitBroke:
		return townmath.TraitMods{ThirstBps: 12000, FunBps: 10000, EnergyBps: 10000}
	case TraitCreative:
		return townmath.TraitMods{ThirstBps: 10000, FunBps: 8000, EnergyBps: 12000}
	case TraitCheerful:
		return townmath.TraitMods{ThirstBps: 9000, FunBps: 9000, EnergyBps: 10000}
	}
	return townmath.TraitMods{ThirstBps: 10000, FunBps: 10000, EnergyBps: 10000}
}

// CombinedMods multiplies the two traits' modifiers component by component
// (townmath.MulBps). An index out of range counts as 10000.
func CombinedMods(t [2]int) townmath.TraitMods {
	a, b := traitMods(t[0]), traitMods(t[1])
	return townmath.TraitMods{
		ThirstBps: townmath.MulBps(a.ThirstBps, b.ThirstBps),
		FunBps:    townmath.MulBps(a.FunBps, b.FunBps),
		EnergyBps: townmath.MulBps(a.EnergyBps, b.EnergyBps),
	}
}

// RollTraits returns the two distinct trait indexes a seed gives:
// a = Mix(seed) % 8, b = (a + 1 + Mix(seed ^ 0x5A5A) % 7) % 8, so b != a.
// Pure: the web client can replay it.
func RollTraits(seed uint64) [2]int {
	a := townmath.Mix(seed) % TraitCount
	b := (a + 1 + townmath.Mix(seed^0x5A5A)%(TraitCount-1)) % TraitCount
	return [2]int{int(a), int(b)}
}

// RollJob returns the job a seed gives: Mix(seed ^ 0xA5A5) % 4.
func RollJob(seed uint64) int64 {
	return int64(townmath.Mix(seed^0xA5A5) % jobCount)
}
