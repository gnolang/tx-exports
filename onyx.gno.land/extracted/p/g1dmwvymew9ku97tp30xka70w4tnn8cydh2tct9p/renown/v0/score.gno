package renown

// Milli is the number of milli-points in one point.
const Milli int64 = 1000

// Permille is the multiplier value for x1.0.
const Permille int64 = 1000

// Params are the tunable constants of the score formula.
type Params struct {
	HalfLife          int64 // seconds for a bucket to lose half its points
	MaturityPeriod    int64 // seconds from the first verified attestation to full weight
	MaturityStart     int64 // permille applied at the first verified attestation
	IdentityBonus     int64 // permille applied when the address has a registered name
	DiversityStep     int64 // permille added per active category after the first
	DiversityMax      int64 // permille ceiling of the diversity multiplier
	DefaultWeight     int64 // permille weight given to a newly verified source
	MaxWeight         int64 // permille ceiling for a source weight
	DefaultCap        int64 // milli-points a source bucket may hold by default
	MaxUnitsPerAttest int64 // largest units value one attestation may carry
}

// DefaultParams returns the v0 parameters.
func DefaultParams() Params {
	return Params{
		HalfLife:          30 * 24 * 3600,
		MaturityPeriod:    7 * 24 * 3600,
		MaturityStart:     500,
		IdentityBonus:     1200,
		DiversityStep:     150,
		DiversityMax:      1600,
		DefaultWeight:     1000,
		MaxWeight:         3000,
		DefaultCap:        100 * Milli,
		MaxUnitsPerAttest: 100,
	}
}

// Valid reports whether every field is in a sane range.
func (p Params) Valid() bool {
	return p.HalfLife > 0 &&
		p.MaturityPeriod >= 0 &&
		p.MaturityStart > 0 && p.MaturityStart <= Permille &&
		p.IdentityBonus >= Permille &&
		p.DiversityStep >= 0 &&
		p.DiversityMax >= Permille &&
		p.DefaultWeight >= 0 && p.DefaultWeight <= p.MaxWeight &&
		p.DefaultCap > 0 &&
		p.MaxUnitsPerAttest > 0
}

// Bucket is the decaying balance one source holds for one address.
type Bucket struct {
	Points int64 // milli-points as of LastTs
	LastTs int64 // unix seconds of the last update
}

// At returns the bucket value at now.
func (b Bucket) At(now, halfLife int64) int64 {
	return Decay(b.Points, now-b.LastTs, halfLife)
}

// Accrue decays b to now, adds add milli-points and clamps to capacity.
// The cap applies to the balance, not to a time window.
func (b Bucket) Accrue(add, now, halfLife, capacity int64) Bucket {
	v := b.At(now, halfLife)
	if add > 0 {
		v = SatAdd(v, add)
	}
	return Bucket{Points: Min(v, capacity), LastTs: now}
}

// Weighted applies a permille weight to a value.
func Weighted(value, weight int64) int64 {
	return MulDiv(value, weight, Permille)
}

// Maturity returns the permille multiplier for an address whose first
// verified attestation happened at firstSeen. It ramps linearly from
// MaturityStart to 1000 over MaturityPeriod. firstSeen <= 0 means never.
func Maturity(firstSeen, now int64, p Params) int64 {
	if firstSeen <= 0 || now < firstSeen {
		return p.MaturityStart
	}
	elapsed := now - firstSeen
	if p.MaturityPeriod <= 0 || elapsed >= p.MaturityPeriod {
		return Permille
	}
	return p.MaturityStart + MulDiv(Permille-p.MaturityStart, elapsed, p.MaturityPeriod)
}

// Diversity returns the permille multiplier for the number of categories
// with a positive weighted score: 1000 + step*(n-1), at most DiversityMax.
func Diversity(activeCategories int, p Params) int64 {
	if activeCategories <= 1 {
		return Permille
	}
	return Min(SatAdd(Permille, SatMul(p.DiversityStep, int64(activeCategories-1))), p.DiversityMax)
}

// Identity returns the permille multiplier for a registered name.
func Identity(named bool, p Params) int64 {
	if named {
		return p.IdentityBonus
	}
	return Permille
}

// Composite combines the weighted base (milli-points) with the identity,
// maturity and diversity multipliers (permille) into milli-points.
func Composite(base, identity, maturity, diversity int64) int64 {
	s := MulDiv(base, maturity, Permille)
	s = MulDiv(s, diversity, Permille)
	return MulDiv(s, identity, Permille)
}

// ToPoints converts milli-points to whole points, rounding down.
func ToPoints(milli int64) int64 {
	if milli <= 0 {
		return 0
	}
	return milli / Milli
}

// Tier names.
const (
	Stranger = "Stranger"
	Regular  = "Regular"
	Patron   = "Patron"
	Legend   = "Legend"
)

// Tier thresholds in whole points.
const (
	RegularMin int64 = 10
	PatronMin  int64 = 100
	LegendMin  int64 = 500
)

// TierOf maps a whole-point score to a tier name.
func TierOf(score int64) string {
	switch {
	case score >= LegendMin:
		return Legend
	case score >= PatronMin:
		return Patron
	case score >= RegularMin:
		return Regular
	}
	return Stranger
}
