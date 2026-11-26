package cube3x3

import (
	"crypto/sha256"
	"errors"
)

const subgroupScrambleLength = 35

// GenerateWCAScramble wraps 24 random face turns in the FMC padding.
// The body starts and ends on axes different from their neighboring padding.
func GenerateWCAScramble(seed [32]byte) []Move {
	const bodyLength = 24
	padding := []Move{{R, 3}, {U, 3}, {F, 1}}
	moves := make([]Move, 0, bodyLength+2*len(padding))
	moves = append(moves, padding...)
	allowed := faceTurnAlphabet([]uint8{U, D, L, R, F, B}, []uint8{1, 2, 3})
	moves = extendScramble(seed, moves, allowed, bodyLength, true)
	return append(moves, padding...)
}

// GenerateSubgroupScramble samples the valid non-rotation moves in allowed.
// The alphabet is sorted by base and modifier so ordering and duplicates have
// no effect. A zero length requests the default 35 moves.
func GenerateSubgroupScramble(seed [32]byte, allowed []Move, length int) ([]Move, error) {
	if length < 0 {
		return nil, errors.New("ERR_RULE_VIOLATION: scramble length cannot be negative")
	}
	if length == 0 {
		length = subgroupScrambleLength
	}

	var seen [X][4]bool
	var axes [3]bool
	axisCount := 0
	for _, move := range allowed {
		if move.Base < X && isValidMove(move) {
			seen[move.Base][move.Mod] = true
			axis := scrambleFace(move.Base) / 2
			if !axes[axis] {
				axes[axis] = true
				axisCount++
			}
		}
	}
	if axisCount < 2 {
		return nil, errors.New("ERR_RULE_VIOLATION: scramble needs moves on at least two axes")
	}

	var alphabet []Move
	for base := U; base < X; base++ {
		for mod := uint8(1); mod <= 3; mod++ {
			if seen[base][mod] {
				alphabet = append(alphabet, Move{base, mod})
			}
		}
	}
	return extendScramble(seed, make([]Move, 0, length), alphabet, length, false), nil
}

// ScrambleForRule selects the fixed alphabet for a built-in rule or the
// supplied alphabet for a custom rule.
func ScrambleForRule(seed [32]byte, ruleID string, allowed []Move) ([]Move, error) {
	switch ruleID {
	case "wca_obtm", "checkpoint_cross_f2l", "pattern_checkerboard":
		return GenerateWCAScramble(seed), nil
	case "no_fb":
		allowed = faceTurnAlphabet([]uint8{U, D, L, R}, []uint8{1, 2, 3})
	case "no_half_turns":
		allowed = faceTurnAlphabet([]uint8{U, D, L, R, F, B}, []uint8{1, 3})
	}
	return GenerateSubgroupScramble(seed, allowed, subgroupScrambleLength)
}

func faceTurnAlphabet(faces, mods []uint8) []Move {
	allowed := make([]Move, 0, len(faces)*len(mods))
	for _, face := range faces {
		for _, mod := range mods {
			allowed = append(allowed, Move{face, mod})
		}
	}
	return allowed
}

// scrambleFace groups a wide turn with the face named by its token.
func scrambleFace(base uint8) uint8 {
	if base >= Uw {
		return base - Uw
	}
	return base
}

func extendScramble(seed [32]byte, moves, allowed []Move, length int, padded bool) []Move {
	rng := scrambleRNG{next: sha256.Size}
	copy(rng.input[:32], seed[:])
	var candidates [X * 3]Move
	for i := 0; i < length; i++ {
		// Opposing faces are consecutive in the base constants and share an axis.
		lastFace, blockedAxis := X, X
		n := len(moves)
		if n > 0 {
			lastFace = scrambleFace(moves[n-1].Base)
			if n > 1 && scrambleFace(moves[n-2].Base)/2 == lastFace/2 {
				blockedAxis = lastFace / 2
			}
		}
		if padded && i == 0 {
			blockedAxis = F / 2
		}

		count := 0
		for _, move := range allowed {
			face := scrambleFace(move.Base)
			if face == lastFace || face/2 == blockedAxis ||
				(padded && i == length-1 && face/2 == R/2) {
				continue
			}
			candidates[count] = move
			count++
		}
		// Each subgroup has at least two axes. The padded form has three,
		// so the two axis exclusions at its final step leave a candidate.
		moves = append(moves, candidates[rng.uniform(count)])
	}
	return moves
}

// scrambleRNG streams SHA-256(seed || big-endian uint64 counter) from counter 0.
type scrambleRNG struct {
	input   [40]byte
	counter uint64
	block   [sha256.Size]byte
	next    int
}

func (rng *scrambleRNG) nextByte() byte {
	if rng.next == len(rng.block) {
		counter := rng.counter
		for i := len(rng.input) - 1; i >= 32; i-- {
			rng.input[i] = byte(counter)
			counter >>= 8
		}
		rng.block = sha256.Sum256(rng.input[:])
		rng.counter++
		rng.next = 0
	}
	value := rng.block[rng.next]
	rng.next++
	return value
}

func (rng *scrambleRNG) uniform(count int) int {
	// Discard the incomplete tail so every index has equal probability.
	limit := 256 - 256%count
	for {
		value := int(rng.nextByte())
		if value < limit {
			return value % count
		}
	}
}
