package cube3x3

// PhaseSegment describes an inclusive range of one-based solution move indices.
type PhaseSegment struct {
	Name      string
	StartMove int
	EndMove   int
	OBTM      int
}

// PhaseReport records the first Cross, F2L, and OLL checkpoints and the PLL
// checkpoint for the terminal solved run. A zero index means absent.
type PhaseReport struct {
	CrossFace   string
	CrossColor  uint8
	CrossAtMove int
	F2LAtMove   int
	OLLAtMove   int
	PLLAtMove   int
	Segments    []PhaseSegment
}

// Each row maps a face in the new frame to its location in the old frame
// after one clockwise quarter rotation. The columns follow move base order.
var priorFrame = [3][6]uint8{
	X - X: {F, B, L, R, D, U},
	Y - X: {U, D, F, B, R, L},
	Z - X: {L, R, D, U, F, B},
}

// ToPureFaceMoves projects each turn onto the starting frame. A wide turn
// emits its opposite-layer turn and changes the frame. Rotations only change
// the frame. Every projected turn keeps its original modifier and order.
func ToPureFaceMoves(moves []Move) []Move {
	frame := [6]uint8{U, D, L, R, F, B}
	pure := make([]Move, 0, len(moves))
	for _, move := range moves {
		if !isValidMove(move) {
			continue
		}
		if move.Base < Uw {
			pure = append(pure, Move{frame[move.Base], move.Mod})
			continue
		}
		if move.Base < X {
			wide := wideTurns[move.Base-Uw]
			pure = append(pure, Move{frame[wide.oppositeFace], move.Mod})
			move.Base = wide.rotation
			if wide.reverseRotation {
				move.Mod = 4 - move.Mod
			}
		}
		for turn := uint8(0); turn < move.Mod; turn++ {
			previous := frame
			for face, oldFace := range priorFrame[move.Base-X] {
				frame[face] = previous[oldFace]
			}
		}
	}
	return pure
}

var parallelFaceOrder = [3][2]uint8{{U, D}, {R, L}, {F, B}}

// NormalizePureFaceMoves reduces contiguous turns of parallel faces. A pass
// that removes a whole axis block can expose another reducible block.
func NormalizePureFaceMoves(moves []Move) []Move {
	current := ToPureFaceMoves(moves)
	if len(current) < 2 {
		return current
	}
	next := make([]Move, 0, len(current))
	for {
		next = next[:0]
		for i := 0; i < len(current); {
			// Opposite faces have consecutive move bases, grouped by axis.
			axis := current[i].Base / 2
			var totals [2]uint8
			for i < len(current) && current[i].Base/2 == axis {
				move := current[i]
				side := move.Base % 2
				totals[side] = (totals[side] + move.Mod) % 4
				i++
			}
			for _, face := range parallelFaceOrder[axis] {
				if mod := totals[face%2]; mod != 0 {
					next = append(next, Move{face, mod})
				}
			}
		}
		if sameMoveSequence(current, next) {
			return next
		}
		current, next = next, current
	}
}

// IsTrivialInverse compares the reduced physical solution with the reduced
// inverse scramble followed by the target algorithm.
func IsTrivialInverse(scramble, solution, targetAlg []Move) bool {
	expected := append(InvertMoves(scramble), targetAlg...)
	return sameMoveSequence(NormalizePureFaceMoves(solution), NormalizePureFaceMoves(expected))
}

func sameMoveSequence(a, b []Move) bool {
	if len(a) != len(b) {
		return false
	}
	for i, move := range a {
		if move != b[i] {
			return false
		}
	}
	return true
}

type phaseSide struct {
	crossEdge int
	sideEdge  int
	stride    int
}

const phaseFaceLetters = "URFDLB"

// The rows follow facelet order. Each entry gives a cross edge sticker, the
// adjoining side sticker, and the stride along that side's parallel strips.
// Centering strips on the side edge and the side center covers the first two
// layers on the side face.
var phaseSides = [6][4]phaseSide{
	{{5, 10, 1}, {7, 19, 1}, {3, 37, 1}, {1, 46, 1}},     // U
	{{10, 5, 3}, {12, 23, 3}, {16, 32, 3}, {14, 48, 3}},  // R
	{{19, 7, 1}, {23, 12, 3}, {25, 28, 1}, {21, 41, 3}},  // F
	{{32, 16, 1}, {28, 25, 1}, {30, 43, 1}, {34, 52, 1}}, // D
	{{37, 3, 3}, {41, 21, 3}, {43, 30, 3}, {39, 50, 3}},  // L
	{{46, 1, 1}, {48, 14, 3}, {52, 34, 1}, {50, 39, 3}},  // B
}

// AnalyzePhases replays the solution from its scramble state. CrossFace is
// the face at the Cross checkpoint. Later phases follow that center's color
// through rotations and wide turns.
func AnalyzePhases(scrambleState Cube, moves []Move) PhaseReport {
	_, report := replayWithPhases(scrambleState, moves)
	return report
}

// replayWithPhases returns both the final cube and the report from one replay.
func replayWithPhases(scrambleState Cube, moves []Move) (Cube, PhaseReport) {
	state := scrambleState
	var report PhaseReport
	lastTurn := 0
	for i, move := range moves {
		if !isValidMove(move) {
			continue
		}
		state = ApplyMove(state, move)
		if move.Base >= X {
			continue // Every phase is invariant under a whole-cube rotation.
		}

		lastTurn = i + 1
		if report.OLLAtMove != 0 {
			continue
		}
		if report.CrossAtMove == 0 {
			face := findCross(&state)
			if face < 0 || IsSolved(state) {
				continue
			}
			report.CrossFace = phaseFaceLetters[face : face+1]
			report.CrossColor = state[face*9+4]
			report.CrossAtMove = lastTurn
		}

		face := findCenter(&state, report.CrossColor)
		if face < 0 || !firstTwoLayersSolved(&state, face) {
			continue
		}
		if report.F2LAtMove == 0 {
			report.F2LAtMove = lastTurn
		}
		if phaseFaceSolved(&state, (face+3)%6) {
			report.OLLAtMove = lastTurn
		}
	}

	if report.CrossAtMove == 0 {
		if IsSolved(state) {
			report.PLLAtMove = len(moves)
		}
		return state, report
	}
	// A face or wide turn changes a solved cube. If replay ends solved,
	// its terminal solved run began at the last turn before any rotations.
	if IsSolved(state) {
		report.PLLAtMove = lastTurn
	}
	end := 0
	for _, phase := range [4]struct {
		name string
		step int
	}{
		{"Cross", report.CrossAtMove}, {"F2L", report.F2LAtMove},
		{"OLL", report.OLLAtMove}, {"PLL", report.PLLAtMove},
	} {
		if phase.step > end {
			obtm, _ := CountMetrics(moves[end:phase.step])
			report.Segments = append(report.Segments, PhaseSegment{phase.name, end + 1, phase.step, obtm})
			end = phase.step
		}
	}
	return state, report
}

func findCross(state *Cube) int {
	for face, sides := range phaseSides {
		color := state[face*9+4]
		matched := 0
		for _, side := range sides {
			if state[side.crossEdge] != color || state[side.sideEdge] != state[side.sideEdge/9*9+4] {
				break
			}
			matched++
		}
		if matched == len(sides) {
			return face
		}
	}
	return -1
}

func findCenter(state *Cube, color uint8) int {
	for face := 0; face < 6; face++ {
		if state[face*9+4] == color {
			return face
		}
	}
	return -1
}

func firstTwoLayersSolved(state *Cube, face int) bool {
	if !phaseFaceSolved(state, face) {
		return false
	}
	for _, side := range phaseSides[face] {
		center := side.sideEdge/9*9 + 4
		color := state[center]
		for offset := -side.stride; offset <= side.stride; offset += side.stride {
			if state[side.sideEdge+offset] != color || state[center+offset] != color {
				return false
			}
		}
	}
	return true
}

func phaseFaceSolved(state *Cube, face int) bool {
	start := face * 9
	color := state[start+4]
	for i := start; i < start+9; i++ {
		if state[i] != color {
			return false
		}
	}
	return true
}
