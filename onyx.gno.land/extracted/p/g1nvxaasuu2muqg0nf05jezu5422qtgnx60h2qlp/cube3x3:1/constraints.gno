package cube3x3

import "errors"

const (
	ErrInputTooLong    = "ERR_INPUT_TOO_LONG"
	ErrInvalidNotation = "ERR_INVALID_NOTATION"
	ErrMoveLimit       = "ERR_MOVE_LIMIT"
	ErrNotSolved       = "ERR_NOT_SOLVED"
	ErrTrivialInverse  = "ERR_TRIVIAL_INVERSE"
	ErrRuleViolation   = "ERR_RULE_VIOLATION"
)

// MoveTrace carries the starting state, replay, scores, and checkpoints for a rule.
type MoveTrace struct {
	Scramble      []Move
	ScrambleState Cube
	Moves         []Move
	PureMoves     []Move
	FinalState    Cube
	Phases        PhaseReport
	OBTM          int
	QTM           int
}

// CloneTrace copies the slice data so a rule can inspect or edit its own trace.
func CloneTrace(t MoveTrace) MoveTrace {
	t.Scramble = cloneTraceMoves(t.Scramble)
	t.Moves = cloneTraceMoves(t.Moves)
	t.PureMoves = cloneTraceMoves(t.PureMoves)
	if t.Phases.Segments != nil {
		segments := make([]PhaseSegment, len(t.Phases.Segments))
		copy(segments, t.Phases.Segments)
		t.Phases.Segments = segments
	}
	return t
}

func cloneTraceMoves(moves []Move) []Move {
	if moves == nil {
		return nil
	}
	cloned := make([]Move, len(moves))
	copy(cloned, moves)
	return cloned
}

// ConstraintRule defines a challenge target, scramble alphabet, and replay checks.
// AllowedMoves returns a fresh slice. An empty TargetAlg targets the solved cube.
// Validate returns an error for a rule violation and must not panic.
type ConstraintRule interface {
	ID() string
	Title() string
	Description() string
	AllowedMoves() []Move
	TargetAlg() []Move
	Validate(trace MoveTrace) error
}

// BuiltinRule resolves the five built-in challenge IDs.
func BuiltinRule(id string) (ConstraintRule, bool) {
	switch id {
	case "wca_obtm":
		return wcaOBTMRule{}, true
	case "checkpoint_cross_f2l":
		return checkpointCrossF2LRule{}, true
	case "pattern_checkerboard":
		return checkerboardRule{}, true
	case "no_fb":
		return noFBRule{}, true
	case "no_half_turns":
		return noHalfTurnsRule{}, true
	default:
		return nil, false
	}
}

// DailyTwistedRule selects the daily rule in the fixed four-day cycle.
func DailyTwistedRule(dayID int64) ConstraintRule {
	switch ((dayID % 4) + 4) % 4 {
	case 0:
		return checkpointCrossF2LRule{}
	case 1:
		return checkerboardRule{}
	case 2:
		return noFBRule{}
	default:
		return noHalfTurnsRule{}
	}
}

type wcaOBTMRule struct{}

func (wcaOBTMRule) ID() string    { return "wca_obtm" }
func (wcaOBTMRule) Title() string { return "Classic Fewest Moves" }
func (wcaOBTMRule) Description() string {
	return "Solve the cube in 80 moves or fewer (up to 120 turns including cube rotations). Middle-layer slice turns are not allowed."
}
func (wcaOBTMRule) AllowedMoves() []Move     { return allFaceTurns() }
func (wcaOBTMRule) TargetAlg() []Move        { return nil }
func (wcaOBTMRule) Validate(MoveTrace) error { return nil }

type checkpointCrossF2LRule struct{}

func (checkpointCrossF2LRule) ID() string    { return "checkpoint_cross_f2l" }
func (checkpointCrossF2LRule) Title() string { return "Step-by-Step: Cross then First Two Layers" }
func (checkpointCrossF2LRule) Description() string {
	return "Complete a cross on any face first, then finish the first two layers on a later move."
}
func (checkpointCrossF2LRule) AllowedMoves() []Move { return allFaceTurns() }
func (checkpointCrossF2LRule) TargetAlg() []Move    { return nil }
func (checkpointCrossF2LRule) Validate(trace MoveTrace) error {
	if trace.Phases.CrossAtMove > 0 && trace.Phases.F2LAtMove > trace.Phases.CrossAtMove {
		return nil
	}
	return errors.New("Complete a cross first, then finish the first two layers on a later move.")
}

type checkerboardRule struct{}

func (checkerboardRule) ID() string    { return "pattern_checkerboard" }
func (checkerboardRule) Title() string { return "Checkerboard Pattern" }
func (checkerboardRule) Description() string {
	return "Finish with a checkerboard pattern from any cube angle."
}
func (checkerboardRule) AllowedMoves() []Move { return allFaceTurns() }
func (checkerboardRule) TargetAlg() []Move {
	return []Move{{R, 2}, {L, 2}, {U, 2}, {D, 2}, {F, 2}, {B, 2}}
}
func (checkerboardRule) Validate(MoveTrace) error { return nil }

type noFBRule struct{}

func (noFBRule) ID() string    { return "no_fb" }
func (noFBRule) Title() string { return "No Front or Back Turns" }
func (noFBRule) Description() string {
	return "Solve using only Right, Up, Left, and Down face turns. Front and Back face turns stay locked even after rotating the cube."
}
func (noFBRule) AllowedMoves() []Move {
	return faceTurnAlphabet([]uint8{U, D, L, R}, []uint8{1, 2, 3})
}
func (noFBRule) TargetAlg() []Move { return nil }
func (noFBRule) Validate(trace MoveTrace) error {
	for _, move := range trace.PureMoves {
		switch move.Base {
		case R, U, L, D:
		default:
			return errors.New("Only Right (R), Up (U), Left (L), and Down (D) face turns are allowed in this challenge.")
		}
	}
	return nil
}

type noHalfTurnsRule struct{}

func (noHalfTurnsRule) ID() string    { return "no_half_turns" }
func (noHalfTurnsRule) Title() string { return "Quarter Turns Only" }
func (noHalfTurnsRule) Description() string {
	return "Use 90-degree single turns on alternating faces. 180-degree face turns and repeated turns on the same face are not allowed."
}
func (noHalfTurnsRule) AllowedMoves() []Move {
	return faceTurnAlphabet([]uint8{U, D, L, R, F, B}, []uint8{1, 3})
}
func (noHalfTurnsRule) TargetAlg() []Move { return nil }
func (noHalfTurnsRule) Validate(trace MoveTrace) error {
	for i, move := range trace.PureMoves {
		if move.Mod == 2 || (i > 0 && move.Base == trace.PureMoves[i-1].Base) {
			return errors.New("180-degree face turns and back-to-back turns on the same face are not allowed in Quarter Turns Only.")
		}
	}
	return nil
}

func allFaceTurns() []Move {
	return faceTurnAlphabet([]uint8{U, D, L, R, F, B}, []uint8{1, 2, 3})
}

// VerifyResult contains the verdict and metrics. Solved reports whether the
// target was reached. Phases is present only for an accepted solution.
type VerifyResult struct {
	Valid          bool
	ErrorCode      string
	ErrorMessage   string
	CanonicalMoves string
	OBTM           int
	QTM            int
	Solved         bool
	Phases         *PhaseReport
}

func (result VerifyResult) withError(code, message string) VerifyResult {
	result.ErrorCode = code
	result.ErrorMessage = message
	return result
}

// VerifySolution parses raw notation and verifies it for the supplied rule.
func VerifySolution(scrambleMoves []Move, rawMoves string, rule ConstraintRule) VerifyResult {
	if len(rawMoves) > MaxRawMovesBytes {
		return VerifyResult{ErrorCode: ErrInputTooLong, ErrorMessage: "Move notation is too long (maximum 512 bytes)."}
	}
	canonical, moves, err := Canonicalize(rawMoves)
	if err != nil {
		return VerifyResult{ErrorCode: ErrInvalidNotation, ErrorMessage: "Use standard face turns, wide turns, and cube rotations (middle-layer slices are not allowed)."}
	}
	return VerifyCanonicalMoves(scrambleMoves, canonical, moves, rule)
}

// VerifyCanonicalMoves verifies a canonical string and moves from Canonicalize
// without parsing them again.
func VerifyCanonicalMoves(scrambleMoves []Move, canonical string, moves []Move, rule ConstraintRule) VerifyResult {
	obtm, qtm := CountMetrics(moves)
	result := VerifyResult{CanonicalMoves: canonical, OBTM: obtm, QTM: qtm}
	if obtm < 1 || obtm > MaxOBTM || len(moves) > MaxTotalMoves {
		return result.withError(ErrMoveLimit, "Solutions must use 1 to 80 moves (maximum 120 turns including cube rotations).")
	}

	scrambleState := ApplyMoves(SolvedCube(), scrambleMoves)
	finalState, phases := replayWithPhases(scrambleState, moves)
	pureMoves := ToPureFaceMoves(moves)

	if rule == nil {
		return result.withError(ErrRuleViolation, "A challenge rule is required.")
	}
	targetAlg := rule.TargetAlg()
	if len(targetAlg) == 0 {
		result.Solved = IsSolved(finalState)
	} else {
		targetState := ApplyMoves(SolvedCube(), targetAlg)
		result.Solved = NormalizeOrientation(finalState) == NormalizeOrientation(targetState)
	}
	if !result.Solved {
		return result.withError(ErrNotSolved, "These moves do not reach the target cube state.")
	}
	if IsTrivialInverse(scrambleMoves, reduceReplayTurns(pureMoves), targetAlg) {
		return result.withError(ErrTrivialInverse, "This solution simply reverses the scramble. Find an original solve instead.")
	}

	trace := MoveTrace{
		Scramble:      scrambleMoves,
		ScrambleState: scrambleState,
		Moves:         moves,
		PureMoves:     pureMoves,
		FinalState:    finalState,
		Phases:        phases,
		OBTM:          obtm,
		QTM:           qtm,
	}
	if err := rule.Validate(CloneTrace(trace)); err != nil {
		return result.withError(ErrRuleViolation, err.Error())
	}
	result.Valid = true
	result.Phases = &phases
	return result
}

// reduceReplayTurns computes the same parallel-axis reduction used by
// IsTrivialInverse. Processing the replay once also bounds the cost when
// many nested blocks disappear. The trace retains the unreduced turns.
func reduceReplayTurns(pureMoves []Move) []Move {
	type axisBlock struct {
		axis  uint8
		turns [2]uint8
	}
	blocks := make([]axisBlock, 0, len(pureMoves))
	for _, move := range pureMoves {
		axis := move.Base / 2
		n := len(blocks)
		if n == 0 || blocks[n-1].axis != axis {
			blocks = append(blocks, axisBlock{axis: axis})
			n++
		}
		last := &blocks[n-1]
		side := move.Base % 2
		last.turns[side] = (last.turns[side] + move.Mod) % 4
		if last.turns[0] == 0 && last.turns[1] == 0 {
			blocks = blocks[:n-1]
		}
	}

	reduced := make([]Move, 0, len(pureMoves))
	for _, block := range blocks {
		for _, face := range parallelFaceOrder[block.axis] {
			if mod := block.turns[face%2]; mod != 0 {
				reduced = append(reduced, Move{face, mod})
			}
		}
	}
	return reduced
}
