package cube3x3

import (
	"errors"
	"strings"
)

const (
	MaxRawMovesBytes = 512
	MaxOBTM          = 80
	MaxTotalMoves    = 120
)

// The letters follow the base constants, with wide moves sharing face letters.
const moveLetters = "UDLRFBxyz"

// Canonicalize parses strict move notation and joins its tokens with single
// ASCII spaces. The solution verifier applies the scoring and token limits.
func Canonicalize(raw string) (string, []Move, error) {
	if len(raw) > MaxRawMovesBytes {
		return "", nil, errors.New("ERR_INPUT_TOO_LONG")
	}
	var moves []Move
	var tokens []string
	start := 0
	for i := 0; i <= len(raw); i++ {
		if i < len(raw) {
			switch raw[i] {
			case ' ', '\t', '\n', '\r':
			default:
				if raw[i] < '!' || raw[i] > '~' {
					return "", nil, errors.New("ERR_INVALID_NOTATION")
				}
				continue
			}
		}
		if start < i {
			token := raw[start:i]
			move, ok := parseMoveToken(token)
			if !ok {
				return "", nil, errors.New("ERR_INVALID_NOTATION")
			}
			moves = append(moves, move)
			tokens = append(tokens, token)
		}
		start = i + 1
	}
	return strings.Join(tokens, " "), moves, nil
}

func parseMoveToken(token string) (Move, bool) {
	letter := strings.IndexByte(moveLetters, token[0])
	if letter < 0 {
		return Move{}, false
	}
	base := uint8(letter)
	suffix := token[1:]
	if base >= Uw {
		base += Uw // Skip the six wide bases to reach X, Y, Z.
	} else if len(suffix) > 0 && suffix[0] == 'w' {
		base += Uw
		suffix = suffix[1:]
	}
	switch suffix {
	case "":
		return Move{base, 1}, true
	case "2":
		return Move{base, 2}, true
	case "'":
		return Move{base, 3}, true
	default:
		return Move{}, false
	}
}

// FormatMoves emits strict notation with one space between moves. Invalid
// moves are skipped, matching the no-op behavior of ApplyMove.
func FormatMoves(moves []Move) string {
	text := make([]byte, 0, len(moves)*4)
	for _, move := range moves {
		if !isValidMove(move) {
			continue
		}
		if len(text) > 0 {
			text = append(text, ' ')
		}
		letter := move.Base
		if letter >= Uw {
			letter -= Uw
		}
		text = append(text, moveLetters[letter])
		if move.Base >= Uw && move.Base < X {
			text = append(text, 'w')
		}
		switch move.Mod {
		case 2:
			text = append(text, '2')
		case 3:
			text = append(text, '\'')
		}
	}
	return string(text)
}

// CountMetrics counts face and wide turns. A half turn contributes one OBTM
// and two QTM. Rotations contribute zero to both metrics.
func CountMetrics(moves []Move) (obtm int, qtm int) {
	for _, move := range moves {
		if move.Base >= X || !isValidMove(move) {
			continue
		}
		obtm++
		qtm++
		if move.Mod == 2 {
			qtm++
		}
	}
	return obtm, qtm
}

// InvertMoves returns the inverse algorithm in a fresh slice.
func InvertMoves(moves []Move) []Move {
	if len(moves) == 0 {
		return nil
	}
	inverse := make([]Move, len(moves))
	for i, move := range moves {
		if isValidMove(move) {
			move.Mod = 4 - move.Mod
		}
		inverse[len(moves)-1-i] = move
	}
	return inverse
}

func isValidMove(move Move) bool {
	return move.Base <= Z && move.Mod >= 1 && move.Mod <= 3
}
