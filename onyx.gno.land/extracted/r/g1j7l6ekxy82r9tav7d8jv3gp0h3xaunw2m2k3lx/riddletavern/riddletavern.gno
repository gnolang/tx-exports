// Package riddletavern is Riddle Tavern: twice-daily puzzle rounds on
// Gno.land, a port of Puzzle Arena (BSC, 598 solves) to Gno.
//
// How it works:
//   - The owner (the deployer) creates rounds with CreateRound, committing
//     to the answer by its sha256 hash only — the answer itself is never
//     stored on-chain. See gno.land/p/g1j7l6ekxy82r9tav7d8jv3gp0h3xaunw2m2k3lx/puzzlerounds for the commitment
//     scheme.
//   - Anyone can Solve a round while its window is open by submitting the
//     answer. A correct answer counts once per address per round, updates
//     the solver's streak (same-day solves don't reset it, a next-day
//     solve extends it, a gap restarts it) and the leaderboard.
//   - gnoweb renders the current round, its puzzle and the leaderboard via
//     Render().
//
// There is no fee, no payment and no token: solving is free, the game is
// the puzzle. The realm holds no funds and has no withdraw function.
package riddletavern

import (
	"chain"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1j7l6ekxy82r9tav7d8jv3gp0h3xaunw2m2k3lx/puzzlerounds"
)

var (
	owner       address
	roundCount  int
	totalSolves int

	rounds    map[int]puzzlerounds.Round
	solved    map[int]map[address]bool // roundID -> solver -> solved?
	solvesOf  map[address]int
	streakOf  map[address]int
	lastDayOf map[address]int64
	seen      map[address]bool // solvers seen, for leaderboard iteration
	solvers   []address
)

func init(cur realm) {
	// The deployer becomes the owner. Inside init(), PreviousRealm is the
	// deployer; after this the deployer is no longer available, so the
	// address is saved here. (In `gno test` there is no deployer and the
	// owner is empty; tests set it explicitly.)
	owner = cur.Previous().Address()
	rounds = make(map[int]puzzlerounds.Round)
	solved = make(map[int]map[address]bool)
	solvesOf = make(map[address]int)
	streakOf = make(map[address]int)
	lastDayOf = make(map[address]int64)
	seen = make(map[address]bool)
}

// Owner returns the address that may create rounds and transfer ownership.
func Owner() address {
	return owner
}

// TransferOwnership moves round creation to newOwner. Only the owner.
func TransferOwnership(cur realm, newOwner address) {
	caller := cur.Previous().Address()
	if caller != owner {
		panic("riddletavern: only owner can transfer ownership")
	}
	if !newOwner.IsValid() {
		panic("riddletavern: invalid address")
	}
	prev := owner
	owner = newOwner
	chain.Emit("OwnershipTransfer", "from", prev.String(), "to", newOwner.String())
}

// CreateRound schedules a new puzzle round. Only the owner. The answer is
// committed by hash: answerHashHex is the 64-character lowercase hex of
// sha256(decimal answer) — see puzzlerounds.HashAnswer — with an optional
// "0x" prefix, as in the seed file and the BSC original. start/end are
// unix seconds; start must not be in the past.
func CreateRound(cur realm, question string, answerHashHex string, start, end int64) int {
	caller := cur.Previous().Address()
	if caller != owner {
		panic("riddletavern: only owner can create rounds")
	}
	if question == "" {
		panic("riddletavern: empty question")
	}
	answerHashHex = strings.TrimPrefix(answerHashHex, "0x")
	hashBytes, err := hex.DecodeString(answerHashHex)
	if err != nil || len(hashBytes) != 32 {
		panic("riddletavern: answer hash must be 64 hex characters")
	}
	var answerHash puzzlerounds.AnswerHash
	copy(answerHash[:], hashBytes)
	if end <= start {
		panic("riddletavern: end must be after start")
	}
	if start < time.Now().Unix() {
		panic("riddletavern: start in the past")
	}
	roundCount++
	rounds[roundCount] = puzzlerounds.Round{
		Question:   question,
		AnswerHash: answerHash,
		Start:      start,
		End:        end,
	}
	chain.Emit("RoundCreated", "round", strconv.Itoa(roundCount), "start", strconv.FormatInt(start, 10), "end", strconv.FormatInt(end, 10))
	return roundCount
}

// Solve submits an answer for a round. The round must be open, the answer
// must match the committed hash, and the caller must not have solved this
// round before. One entry per address per round.
func Solve(cur realm, roundID int, answer int) {
	caller := cur.Previous().Address()
	round, ok := rounds[roundID]
	if !ok {
		panic("riddletavern: invalid round")
	}
	now := time.Now().Unix()
	if !round.IsOpen(now) {
		panic("riddletavern: round not open")
	}
	if !puzzlerounds.VerifyAnswer(round.AnswerHash, answer) {
		panic("riddletavern: wrong answer")
	}
	if solved[roundID] == nil {
		solved[roundID] = make(map[address]bool)
	}
	if solved[roundID][caller] {
		panic("riddletavern: already solved")
	}
	solved[roundID][caller] = true

	day := puzzlerounds.DayOf(now)
	streak := puzzlerounds.NextStreak(lastDayOf[caller], streakOf[caller], day)
	streakOf[caller] = streak
	lastDayOf[caller] = day

	if !seen[caller] {
		seen[caller] = true
		solvers = append(solvers, caller)
	}
	solvesOf[caller]++
	round.Solves++
	rounds[roundID] = round
	totalSolves++

	chain.Emit("Solved", "round", strconv.Itoa(roundID), "solver", caller.String(), "streak", strconv.Itoa(streak))
}

// RoundCount returns the number of rounds created so far (round IDs start at 1).
func RoundCount() int {
	return roundCount
}

// TotalSolves returns the number of correct solves across all rounds.
func TotalSolves() int {
	return totalSolves
}

// GetRound returns the round record and whether the round exists.
func GetRound(roundID int) (puzzlerounds.Round, bool) {
	round, ok := rounds[roundID]
	return round, ok
}

// SolvesOf returns a solver's lifetime correct-solve count.
func SolvesOf(solver address) int {
	return solvesOf[solver]
}

// StreakOf returns a solver's current streak in days.
func StreakOf(solver address) int {
	return streakOf[solver]
}

// SolvedBy reports whether solver already solved roundID.
func SolvedBy(roundID int, solver address) bool {
	if solved[roundID] == nil {
		return false
	}
	return solved[roundID][solver]
}

// Leaderboard returns all solvers ordered by solves (desc), then streak
// (desc), then address (asc). Empty when nobody has solved yet.
func Leaderboard() []puzzlerounds.Leader {
	leaders := make([]puzzlerounds.Leader, 0, len(solvers))
	for _, solver := range solvers {
		leaders = append(leaders, puzzlerounds.Leader{
			Solver: solver,
			Solves: solvesOf[solver],
			Streak: streakOf[solver],
		})
	}
	puzzlerounds.SortLeaders(leaders)
	return leaders
}

// Render shows the current round, its puzzle and the leaderboard in gnoweb.
// Render("/<roundID>") shows a specific round; any other path shows the
// latest round.
func Render(path string) string {
	var b strings.Builder
	b.WriteString("# Riddle Tavern\n\n")
	b.WriteString("Twice-daily puzzles, verified on-chain. One entry per player per round — solve it, grow your streak, top the board.\n\n")
	b.WriteString("Rounds: " + strconv.Itoa(roundCount) + " · Total solves: " + strconv.Itoa(totalSolves) + "\n\n")

	roundID := roundCount
	if path != "" && path != "/" {
		if n, err := strconv.Atoi(strings.TrimPrefix(path, "/")); err == nil && n >= 1 && n <= roundCount {
			roundID = n
		}
	}
	if roundID < 1 {
		b.WriteString("No rounds yet — check back soon.\n")
	} else {
		round, _ := rounds[roundID]
		now := time.Now().Unix()
		status := "open"
		if now < round.Start {
			status = "not yet open"
		} else if now > round.End {
			status = "sealed"
		}
		b.WriteString("## Round " + strconv.Itoa(roundID) + " (" + status + ")\n\n")
		b.WriteString("**Puzzle:** " + round.Question + "\n\n")
		b.WriteString("Window: " + formatTime(round.Start) + " – " + formatTime(round.End) + " · Solves: " + strconv.Itoa(round.Solves) + "\n\n")
	}

	b.WriteString("## Leaderboard\n\n")
	leaders := Leaderboard()
	if len(leaders) == 0 {
		b.WriteString("No solvers yet — be the first.\n")
	} else {
		top := len(leaders)
		if top > 10 {
			top = 10
		}
		for i := 0; i < top; i++ {
			b.WriteString(strconv.Itoa(i+1) + ". " + leaders[i].Solver.String() + " — " + strconv.Itoa(leaders[i].Solves) + " solves, streak " + strconv.Itoa(leaders[i].Streak) + "\n")
		}
	}
	return b.String()
}

func formatTime(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04")
}
