// Package puzzlerounds is the reusable, stateless puzzle-round library
// behind Riddle Tavern (gno.land/r/g1j7l6ekxy82r9tav7d8jv3gp0h3xaunw2m2k3lx/riddletavern).
//
// It holds the commitment scheme, the round record, streak math and
// leaderboard ordering, so any other realm or package can import it and run
// the same twice-daily puzzle game without copying the logic.
//
// Answer commitment scheme (public, part of the game rules):
//   - An answer is an integer. It is encoded as its decimal string
//     (strconv.Itoa) and committed with sha256.
//   - Only the hash is ever stored on-chain; the answer itself is never
//     stored. Anyone can recompute HashAnswer to verify a round.
//   - Note the honest limitation, shared with the BSC original this ports
//     (Puzzle Arena, which used keccak256 the same way): small-integer
//     answers are brute-forceable from the hash in principle. The hash is
//     a commitment that the round cannot be changed after creation, not
//     a vault. The game is the puzzle, the live window and one entry per
//     player — not the secrecy of the answer.
package puzzlerounds

import (
	"crypto/sha256"
	"strconv"
)

// AnswerHash is a sha256 commitment to a puzzle answer.
type AnswerHash [32]byte

// HashAnswer computes the commitment for an answer.
//
// The answer is encoded as its decimal string and hashed with sha256.
// The encoding is part of the public commitment scheme: anyone can
// recompute it to verify a round, and the answer itself is never stored.
func HashAnswer(answer int) AnswerHash {
	return sha256.Sum256([]byte(strconv.Itoa(answer)))
}

// VerifyAnswer reports whether answer matches the stored commitment.
func VerifyAnswer(hash AnswerHash, answer int) bool {
	return HashAnswer(answer) == hash
}

// Round is the public record of one puzzle round. It carries no behaviour
// of its own; the realm that owns the round holds the state.
type Round struct {
	Question   string     // puzzle text, shown to players
	AnswerHash AnswerHash // sha256(decimal answer); the answer is never stored
	Start      int64      // unix seconds, inclusive
	End        int64      // unix seconds, inclusive
	Solves     int        // correct solves so far
}

// IsOpen reports whether unix time now falls inside the round window.
func (r Round) IsOpen(now int64) bool {
	return now >= r.Start && now <= r.End
}

// DayOf returns the UTC day number for a unix timestamp.
func DayOf(unix int64) int64 {
	return unix / 86400
}

// NextStreak computes the new streak after a solve on day today,
// given the day of the previous solve (lastDay, 0 if never) and the
// current streak. Ported from Puzzle Arena (BSC):
//   - a second solve on the same day leaves the streak unchanged
//     (two rounds run per day, so a same-day solve must not reset it),
//   - a solve the day after the last one extends the streak by one,
//   - anything else restarts the streak at 1.
func NextStreak(lastDay int64, streak int, today int64) int {
	if today > 0 && lastDay == today {
		return streak
	}
	if today > 0 && lastDay == today-1 {
		return streak + 1
	}
	return 1
}

// Leader is one row of the leaderboard.
type Leader struct {
	Solver address
	Solves int
	Streak int
}

// SortLeaders sorts in place: most solves first, then highest streak,
// then lowest address (deterministic tie-break).
func SortLeaders(leaders []Leader) {
	// Insertion sort: leaderboards are small, and sort.Slice is not
	// available in Gno.
	for i := 1; i < len(leaders); i++ {
		for j := i; j > 0 && lessLeader(leaders[j], leaders[j-1]); j-- {
			leaders[j], leaders[j-1] = leaders[j-1], leaders[j]
		}
	}
}

func lessLeader(a, b Leader) bool {
	if a.Solves != b.Solves {
		return a.Solves > b.Solves
	}
	if a.Streak != b.Streak {
		return a.Streak > b.Streak
	}
	return a.Solver.String() < b.Solver.String()
}
