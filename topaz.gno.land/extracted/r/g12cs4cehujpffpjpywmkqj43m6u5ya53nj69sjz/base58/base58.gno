// Package base58 ports the core of Bitcoin's Base58 codec (à la mr-tron/base58
// and btcutil/base58) to a gno.land realm.
//
// Base58 is a base conversion from base-256 (raw bytes) to base-58 using an
// alphabet that omits the visually ambiguous characters 0 (zero), O (capital
// o), I (capital i) and l (lower L). The conversion here is done with pure
// byte-slice math — the classic div/mod-by-58 carry loop — so it needs no
// math/big. Leading zero bytes map to leading '1' characters and back, exactly
// like the reference implementations.
package base58

import (
	"encoding/hex"
	"strings"
)

// Alphabet is the Bitcoin Base58 alphabet.
const Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

// Encode converts a byte slice to its Base58 string representation.
//
// Algorithm: treat the input as a big base-256 integer and repeatedly convert
// it into base-58 digits via a carry loop, most-significant digit first. Each
// leading zero byte becomes a leading '1'.
func Encode(input []byte) string {
	// Count leading zero bytes — they encode as '1' and are handled apart.
	zeros := 0
	for zeros < len(input) && input[zeros] == 0 {
		zeros++
	}

	// Upper bound on the base-58 digit count: log(256)/log(58) ≈ 1.365, so
	// 138/100 of the significant byte count (+1) is always enough.
	size := (len(input)-zeros)*138/100 + 1
	digits := make([]byte, size)

	length := 0
	for i := zeros; i < len(input); i++ {
		carry := int(input[i])
		j := 0
		// Walk from the least-significant end, folding the new byte in.
		for k := size - 1; (carry != 0 || j < length) && k >= 0; k-- {
			carry += 256 * int(digits[k])
			digits[k] = byte(carry % 58)
			carry /= 58
			j++
		}
		length = j
	}

	// Skip the leading zero digits produced by the over-allocation.
	it := size - length

	out := make([]byte, 0, zeros+length)
	for i := 0; i < zeros; i++ {
		out = append(out, '1')
	}
	for ; it < size; it++ {
		out = append(out, Alphabet[digits[it]])
	}
	return string(out)
}

// Decode converts a Base58 string back to the original byte slice. It returns
// nil if the string contains a character outside the alphabet.
//
// Algorithm: the mirror of Encode — treat the string as a big base-58 integer
// and convert it back to base-256 bytes with a carry loop. Each leading '1'
// becomes a leading zero byte.
func Decode(s string) []byte {
	// Count leading '1's — they decode to zero bytes.
	zeros := 0
	for zeros < len(s) && s[zeros] == '1' {
		zeros++
	}

	// Upper bound on the byte count: log(58)/log(256) ≈ 0.733.
	size := (len(s)-zeros)*733/1000 + 1
	bytesBuf := make([]byte, size)

	length := 0
	for i := zeros; i < len(s); i++ {
		carry := strings.IndexByte(Alphabet, s[i])
		if carry < 0 {
			return nil // character not in the alphabet
		}
		j := 0
		for k := size - 1; (carry != 0 || j < length) && k >= 0; k-- {
			carry += 58 * int(bytesBuf[k])
			bytesBuf[k] = byte(carry % 256)
			carry /= 256
			j++
		}
		length = j
	}

	it := size - length

	out := make([]byte, 0, zeros+length)
	for i := 0; i < zeros; i++ {
		out = append(out, 0)
	}
	for ; it < size; it++ {
		out = append(out, bytesBuf[it])
	}
	return out
}

// IsValid reports whether every character of s belongs to the Base58 alphabet.
func IsValid(s string) bool {
	for i := 0; i < len(s); i++ {
		if strings.IndexByte(Alphabet, s[i]) < 0 {
			return false
		}
	}
	return true
}

// Render produces the gnoweb Markdown view.
//
//   - "/"        → the alphabet + a small gallery of worked examples.
//   - "/<hex>"   → decode the hex input to bytes, show its Base58, and the
//     hex-encoded decoded round-trip to prove Encode/Decode are inverse.
func Render(path string) string {
	arg := strings.TrimPrefix(path, "/")
	arg = strings.TrimSpace(arg)

	if arg == "" {
		return renderHome()
	}
	return renderHex(arg)
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Base58 (Bitcoin alphabet)\n\n")
	b.WriteString("Base conversion from raw bytes (base-256) to base-58, using the ")
	b.WriteString("Bitcoin alphabet — no `0`, `O`, `I`, `l`. Implemented with pure ")
	b.WriteString("byte-slice math (div/mod-by-58 carry loop), no `math/big`.\n\n")

	b.WriteString("## Alphabet\n\n")
	b.WriteString("```\n")
	b.WriteString(Alphabet)
	b.WriteString("\n```\n\n")
	b.WriteString("58 characters, index 0…57.\n\n")

	b.WriteString("## Examples\n\n")
	b.WriteString("| input (utf-8) | hex | Base58 |\n")
	b.WriteString("|---|---|---|\n")
	examples := []string{"", "hello world", "gno.land", "Bitcoin"}
	for _, e := range examples {
		h := hex.EncodeToString([]byte(e))
		if h == "" {
			h = "(empty)"
		}
		label := e
		if label == "" {
			label = "(empty)"
		}
		b.WriteString("| `" + label + "` | `" + h + "` | `" + Encode([]byte(e)) + "` |\n")
	}
	b.WriteString("\n")

	b.WriteString("Leading zero bytes → leading `1`s:\n\n")
	b.WriteString("| bytes | Base58 |\n|---|---|\n")
	b.WriteString("| `[0x00]` | `" + Encode([]byte{0}) + "` |\n")
	b.WriteString("| `[0x00 0x00 0x00]` | `" + Encode([]byte{0, 0, 0}) + "` |\n\n")

	b.WriteString("## Try it\n\n")
	b.WriteString("Append a hex string to the path to encode/round-trip it:\n\n")
	b.WriteString("- `/68656c6c6f` — the bytes for \"hello\"\n")
	b.WriteString("- `/00000000` — four zero bytes\n")
	b.WriteString("- `/deadbeef`\n")
	return b.String()
}

func renderHex(arg string) string {
	var b strings.Builder
	b.WriteString("# Base58 — round-trip\n\n")
	b.WriteString("[← alphabet & examples](/r/moul/x/daily/base58/v1)\n\n")

	raw, err := hex.DecodeString(arg)
	if err != nil {
		b.WriteString("**Invalid hex input.**\n\n")
		b.WriteString("`" + arg + "` is not a valid hex string. ")
		b.WriteString("Provide an even number of hex digits, e.g. `/deadbeef`.\n")
		return b.String()
	}

	encoded := Encode(raw)
	decoded := Decode(encoded)
	roundTrip := hex.EncodeToString(decoded)

	inHex := arg
	if inHex == "" {
		inHex = "(empty)"
	}
	outHex := roundTrip
	if outHex == "" {
		outHex = "(empty)"
	}
	enc := encoded
	if enc == "" {
		enc = "(empty)"
	}

	b.WriteString("| step | value |\n|---|---|\n")
	b.WriteString("| hex input | `" + inHex + "` |\n")
	b.WriteString("| bytes | `" + byteList(raw) + "` |\n")
	b.WriteString("| **Base58** | `" + enc + "` |\n")
	b.WriteString("| decoded (hex) | `" + outHex + "` |\n\n")

	if roundTrip == arg {
		b.WriteString("✓ Round-trip matches: `Decode(Encode(x)) == x`.\n")
	} else {
		b.WriteString("✗ Round-trip mismatch.\n")
	}
	return b.String()
}

// byteList renders a byte slice as a compact space-separated hex list.
func byteList(b []byte) string {
	if len(b) == 0 {
		return "(none)"
	}
	const digits = "0123456789abcdef"
	out := make([]byte, 0, len(b)*3)
	for i, c := range b {
		if i > 0 {
			out = append(out, ' ')
		}
		out = append(out, digits[c>>4], digits[c&0x0f])
	}
	return string(out)
}
