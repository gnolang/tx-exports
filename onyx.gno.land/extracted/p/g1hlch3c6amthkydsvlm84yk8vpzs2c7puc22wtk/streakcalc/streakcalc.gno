// Package streakcalc holds the pure streak arithmetic for the Streak
// habit tracker. It is a stateless Gno package (gno.land/p/...): it owns
// no storage and performs no chain calls, so the realm can stay a thin
// storage/rendering shell and every rule can be unit-tested in isolation.
package streakcalc

// SecondsPerDay is the number of seconds in one day.
const SecondsPerDay int64 = 86400

// State is the streak record kept for a single user.
//
// LastDay is a day index (see DayOf), not a timestamp, so all
// comparisons are plain integer arithmetic. Has distinguishes "never
// checked in" from a record whose counters happen to be zero.
type State struct {
	Current int64 // length of the running streak, in days
	Longest int64 // best streak ever reached, in days
	Total   int64 // lifetime number of check-in days
	LastDay int64 // day index of the most recent check-in
	Has     bool  // whether the user has ever checked in
}

// DayOf converts a unix timestamp (seconds since the epoch, UTC) into a
// day index. Two timestamps on the same UTC day map to the same index.
func DayOf(unixSec int64) int64 {
	return unixSec / SecondsPerDay
}

// Apply folds a check-in made on day `day` into s and returns the
// updated state. The rules are:
//
//   - first ever check-in: Current = 1, Longest = 1, Total = 1.
//   - same day as the last check-in (day == LastDay): no-op, checking
//     in twice in one day never inflates the counters.
//   - the day right after the last check-in (day == LastDay+1): the
//     streak continues, Current grows by one, Total grows by one.
//   - any later day (day > LastDay+1): the streak was broken, Current
//     restarts at 1, Total grows by one.
//   - a day before the last check-in (day < LastDay): no-op. This
//     guards against out-of-order or replayed calls moving a record
//     backwards.
//
// Longest is raised whenever Current passes it.
func Apply(s State, day int64) State {
	if !s.Has {
		return State{
			Current: 1,
			Longest: 1,
			Total:   1,
			LastDay: day,
			Has:     true,
		}
	}
	switch {
	case day <= s.LastDay:
		// Same-day repeat, or an out-of-order day: nothing changes.
		return s
	case day == s.LastDay+1:
		s.Current++
		s.Total++
		s.LastDay = day
	default: // day > s.LastDay+1: the streak lapsed.
		s.Current = 1
		s.Total++
		s.LastDay = day
	}
	if s.Current > s.Longest {
		s.Longest = s.Current
	}
	return s
}
