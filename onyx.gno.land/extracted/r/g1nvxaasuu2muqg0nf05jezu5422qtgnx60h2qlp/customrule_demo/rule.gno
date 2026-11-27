package customrule_demo

import (
	"errors"

	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"
	"gno.land/r/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/bench"
)

type noUFaceRule struct{}

func (noUFaceRule) ID() string    { return "no_u_face" }
func (noUFaceRule) Title() string { return "No Top-Face Turns" }
func (noUFaceRule) Description() string {
	return "Solve without turning the face that starts on top, even after rotating the cube."
}

func (noUFaceRule) AllowedMoves() []cube3x3.Move {
	moves := make([]cube3x3.Move, 0, 15)
	for _, base := range []uint8{cube3x3.D, cube3x3.L, cube3x3.R, cube3x3.F, cube3x3.B} {
		for mod := uint8(1); mod <= 3; mod++ {
			moves = append(moves, cube3x3.Move{Base: base, Mod: mod})
		}
	}
	return moves
}

func (noUFaceRule) TargetAlg() []cube3x3.Move { return nil }

func (noUFaceRule) Validate(trace cube3x3.MoveTrace) error {
	for _, move := range trace.PureMoves {
		if move.Base == cube3x3.U {
			return errors.New("The solution turns the face that started on top.")
		}
	}
	return nil
}

// Register makes No Top-Face Turns available for Quick Rounds.
func Register(cur realm) string {
	return bench.RegisterRule(cross(cur), noUFaceRule{})
}
