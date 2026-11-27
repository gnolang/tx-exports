package townmath

// Needs are a villager's three needs, each in 0..10000.
type Needs struct {
	Thirst, Fun, Energy int64
}

// TraitMods scale the per-hour decay of each need, in basis points
// (10000 = normal speed, 15000 = decays 50% faster).
type TraitMods struct {
	ThirstBps, FunBps, EnergyBps int64
}

const (
	MoodMiserable = 0
	MoodOkay      = 1
	MoodHappy     = 2

	// RoundCostCg is the gold cost (in centigold) of buying a round.
	RoundCostCg = 600
	// DayOffCostCg is the gold cost of a day off (free).
	DayOffCostCg = 0
)

const (
	needMax         int64 = 10000
	maxDecayHours   int64 = 48
	thirstPerHour   int64 = 300
	funPerHour      int64 = 200
	energyPerHour   int64 = 100
	roundThirstGain int64 = 4000
	dayOffEnergy    int64 = 5000
	moodHappyMin    int64 = 6200
	moodOkayMin     int64 = 4000
)

func clampNeeds(n Needs) Needs {
	return Needs{
		Thirst: clamp(n.Thirst, 0, needMax),
		Fun:    clamp(n.Fun, 0, needMax),
		Energy: clamp(n.Energy, 0, needMax),
	}
}

func decayOne(v, base, modBps, hours int64) int64 {
	perHour := MulBps(base, clamp(modBps, 0, 1<<40))
	return clamp(v-perHour*hours, 0, needMax)
}

// Decay lowers each need by its base hourly rate (thirst 300, fun 200,
// energy 100) scaled by the trait modifier, for the given hours. Hours are
// clamped to 0..48. Results are clamped to 0..10000; negative modifiers
// count as zero.
func Decay(n Needs, m TraitMods, hours int64) Needs {
	n = clampNeeds(n)
	h := clamp(hours, 0, maxDecayHours)
	return Needs{
		Thirst: decayOne(n.Thirst, thirstPerHour, m.ThirstBps, h),
		Fun:    decayOne(n.Fun, funPerHour, m.FunBps, h),
		Energy: decayOne(n.Energy, energyPerHour, m.EnergyBps, h),
	}
}

// Mood maps the average of the three needs to a mood:
// >= 6200 happy, >= 4000 okay, otherwise miserable.
func Mood(n Needs) int {
	n = clampNeeds(n)
	avg := (n.Thirst + n.Fun + n.Energy) / 3
	if avg >= moodHappyMin {
		return MoodHappy
	}
	if avg >= moodOkayMin {
		return MoodOkay
	}
	return MoodMiserable
}

// BuyRound raises thirst by 4000, capped at 10000.
func BuyRound(n Needs) Needs {
	n = clampNeeds(n)
	n.Thirst = clamp(n.Thirst+roundThirstGain, 0, needMax)
	return n
}

// DayOff raises energy by 5000, capped at 10000.
func DayOff(n Needs) Needs {
	n = clampNeeds(n)
	n.Energy = clamp(n.Energy+dayOffEnergy, 0, needMax)
	return n
}

// RegularBonus is the extra customers a villager brings to their tavern.
// Only during hours 18..22: a happy villager with loyalty >= 5 gives 1 (plus
// 1 more at loyalty >= 9); an okay villager with loyalty >= 5 gives 1;
// anything else gives 0.
func RegularBonus(mood int, loyalty int64, hour int) int64 {
	if hour < 18 || hour > 22 || loyalty < 5 {
		return 0
	}
	switch mood {
	case MoodHappy:
		if loyalty >= 9 {
			return 2
		}
		return 1
	case MoodOkay:
		return 1
	}
	return 0
}
