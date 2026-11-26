package aegis_core

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
)

// A duel is 3 rounds. Each fighter commits a 3-letter move string such as
// "SGF" before the commit deadline. Triangle: Strike > Feint > Guard > Strike.
const (
	Rounds     = 3
	StartHP    = 100
	RoundDmg   = 34
	ChipDmg    = 8 // both chose the same move: both take chip damage
	MoveStrike = "S"
	MoveGuard  = "G"
	MoveFeint  = "F"
)

var (
	ErrBadMoves = errors.New("aegis: moves must be exactly 3 of S/G/F")
	ErrBadSalt  = errors.New("aegis: salt must be 8..64 chars")
)

// CommitHash = hex(sha256(moves + ":" + salt)).
func CommitHash(moves, salt string) string {
	sum := sha256.Sum256([]byte(moves + ":" + salt))
	return hex.EncodeToString(sum[:])
}

// VerifyReveal checks that (moves, salt) opens the commitment and the moves are legal.
func VerifyReveal(commit, moves, salt string) error {
	if err := ValidateMoves(moves); err != nil {
		return err
	}
	if len(salt) < 8 || len(salt) > 64 {
		return ErrBadSalt
	}
	if CommitHash(moves, salt) != strings.ToLower(commit) {
		return errors.New("aegis: reveal does not match commitment")
	}
	return nil
}

func ValidateMoves(moves string) error {
	if len(moves) != Rounds {
		return ErrBadMoves
	}
	for i := 0; i < len(moves); i++ {
		c := string(moves[i])
		if c != MoveStrike && c != MoveGuard && c != MoveFeint {
			return ErrBadMoves
		}
	}
	return nil
}

// Beats reports whether move a beats move b.
func Beats(a, b string) bool {
	return (a == MoveStrike && b == MoveFeint) ||
		(a == MoveFeint && b == MoveGuard) ||
		(a == MoveGuard && b == MoveStrike)
}

// RoundResult is one line of the combat log.
type RoundResult struct {
	MoveA, MoveB string
	HPA, HPB     int
}

// ResolveDuel is fully deterministic: same inputs, same outcome, on every node.
// winner: 1 = A, 2 = B, 0 = draw.
func ResolveDuel(movesA, movesB string) (winner int, log []RoundResult) {
	hpA, hpB := StartHP, StartHP
	for i := 0; i < Rounds; i++ {
		a, b := string(movesA[i]), string(movesB[i])
		switch {
		case a == b:
			hpA -= ChipDmg
			hpB -= ChipDmg
		case Beats(a, b):
			hpB -= RoundDmg
		default:
			hpA -= RoundDmg
		}
		if hpA < 0 {
			hpA = 0
		}
		if hpB < 0 {
			hpB = 0
		}
		log = append(log, RoundResult{MoveA: a, MoveB: b, HPA: hpA, HPB: hpB})
	}
	switch {
	case hpA > hpB:
		winner = 1
	case hpB > hpA:
		winner = 2
	}
	return winner, log
}

func MoveName(m string) string {
	switch m {
	case MoveStrike:
		return "Strike"
	case MoveGuard:
		return "Guard"
	case MoveFeint:
		return "Feint"
	}
	return "?"
}
