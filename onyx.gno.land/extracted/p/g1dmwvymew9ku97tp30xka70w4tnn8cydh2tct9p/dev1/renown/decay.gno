package renown

// Scale is the fixed-point scale of the decay table.
const Scale int64 = 1_000_000

// decaySteps holds 2^(-k/8) * Scale for k = 0..7, rounded to nearest.
var decaySteps = [8]int64{1_000_000, 917_004, 840_896, 771_105, 707_107, 648_420, 594_604, 545_254}

// Decay returns points after dt seconds of exponential decay with the given
// half-life. Whole half-lives are a right shift; the remainder is rounded
// down to the nearest eighth of a half-life and applied from a table. The
// result never increases with dt and is exact at every multiple of the
// half-life. Non-positive points return 0; a non-positive dt or half-life
// returns points unchanged.
func Decay(points, dt, halfLife int64) int64 {
	if points <= 0 {
		return 0
	}
	if dt <= 0 || halfLife <= 0 {
		return points
	}
	halves := dt / halfLife
	if halves >= 63 {
		return 0
	}
	p := points >> uint(halves)
	k := MulDiv(dt%halfLife, 8, halfLife) // 0..7
	return MulDiv(p, decaySteps[k], Scale)
}
