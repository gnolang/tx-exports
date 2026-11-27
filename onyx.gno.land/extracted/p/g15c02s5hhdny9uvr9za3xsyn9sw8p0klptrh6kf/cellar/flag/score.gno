package flag

// Points a challenge starts at, by difficulty.
const (
	EasyPoints   = 100
	MediumPoints = 250
	HardPoints   = 500
)

// DecaySolves is the number of solves after which a challenge settles at
// its floor value.
const DecaySolves = 20

// Initial returns the value of a challenge nobody has solved yet.
func (d Difficulty) Initial() int {
	switch d {
	case Easy:
		return EasyPoints
	case Medium:
		return MediumPoints
	case Hard:
		return HardPoints
	}
	return 0
}

// Floor returns the lowest value a challenge of difficulty d decays to:
// two fifths of its initial value.
func (d Difficulty) Floor() int { return d.Initial() * 2 / 5 }

// Value returns what a challenge of difficulty d is worth to every one of
// its solvers once it has solves solvers. It follows the CTFd dynamic
// curve: the value falls with the square of the solve count and settles at
// the floor after DecaySolves solves. A lone solver keeps the full value,
// and the value applies retroactively to all solvers.
func Value(d Difficulty, solves int) int {
	initial, floor := d.Initial(), d.Floor()
	n := solves - 1
	if n <= 0 {
		return initial
	}
	if n >= DecaySolves {
		return floor
	}
	v := initial - (initial-floor)*n*n/(DecaySolves*DecaySolves)
	if v < floor {
		return floor
	}
	return v
}

// FirstBloodBonus returns the one-time bonus for the first solver.
func (d Difficulty) FirstBloodBonus() int { return d.Initial() / 10 }
