package spike_probe

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/nt/svg/v0"
)

// CubeState stores nine stickers per face in U, R, F, D, L, B order.
type CubeState [54]uint8

// ProbeRule is the interface used by the cross-realm ownership probe.
type ProbeRule interface {
	ID() string
	Check(steps int) error
}

func SolvedState() CubeState {
	var state CubeState
	for i := range state {
		state[i] = uint8(i / 9)
	}
	return state
}

// ApplyMovesKernel simulates per-move work with a cyclic permutation and six face cross checks.
func ApplyMovesKernel(n int) CubeState {
	state := SolvedState()
	offset := 1
	for step := 0; step < n; step++ {
		var next CubeState
		for i := range next {
			next[i] = state[(i+offset)%len(state)]
		}
		state = next

		// Each completed cross adds one to the next cyclic offset.
		offset = 1
		for face := 0; face < len(state)/9; face++ {
			start := face * 9
			center := state[start+4]
			if state[start+1] == center && state[start+3] == center &&
				state[start+5] == center && state[start+7] == center {
				offset++
			}
		}
	}
	return state
}

func CommitHash(domain, roundKey, caller, payload, salt string) string {
	preimage := lengthPrefix(domain) + "|" + lengthPrefix(roundKey) + "|" +
		lengthPrefix(caller) + "|" + lengthPrefix(payload) + "|" + lengthPrefix(salt)
	hash := sha256.Sum256([]byte(preimage))
	return hex.EncodeToString(hash[:])
}

func lengthPrefix(s string) string {
	return strconv.Itoa(len(s)) + ":" + s
}

// EscapeJSONString escapes the contents of a JSON string, excluding the enclosing quotes.
func EscapeJSONString(s string) string {
	const digits = "0123456789abcdef"
	var escaped strings.Builder
	for i := 0; i < len(s); i++ {
		b := s[i]
		switch b {
		case '"', '\\':
			escaped.WriteByte('\\')
			escaped.WriteByte(b)
		case '\b':
			escaped.WriteString(`\b`)
		case '\f':
			escaped.WriteString(`\f`)
		case '\n':
			escaped.WriteString(`\n`)
		case '\r':
			escaped.WriteString(`\r`)
		case '\t':
			escaped.WriteString(`\t`)
		default:
			if b < 0x20 {
				escaped.WriteString(`\u00`)
				escaped.WriteByte(digits[b>>4])
				escaped.WriteByte(digits[b&0x0f])
			} else {
				escaped.WriteByte(b)
			}
		}
	}
	return escaped.String()
}

func RenderNetMarkdown(c CubeState, alt string) string {
	const stickerSize = 12
	const faceSize = 3 * stickerSize
	const width, height = 4 * faceSize, 3 * faceSize
	canvas := svg.NewCanvas(width, height).WithViewBox(0, 0, width, height)

	facePositions := [6][2]int{{1, 0}, {2, 1}, {1, 1}, {1, 2}, {0, 1}, {3, 1}}
	colors := [6]string{"#f5f5f5", "#b91c1c", "#15803d", "#facc15", "#f97316", "#1d4ed8"}
	for i, color := range c {
		face := facePositions[i/9]
		sticker := i % 9
		x := face[0]*faceSize + sticker%3*stickerSize
		y := face[1]*faceSize + sticker/3*stickerSize
		fill := "#6b7280"
		if int(color) < len(colors) {
			fill = colors[color]
		}
		canvas.Append(svg.NewRectangle(x, y, stickerSize-1, stickerSize-1, fill))
	}
	return canvas.Render(alt)
}
