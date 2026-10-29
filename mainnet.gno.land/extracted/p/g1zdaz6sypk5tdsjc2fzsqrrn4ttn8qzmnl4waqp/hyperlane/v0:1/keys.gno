package hyperlane

import (
	"encoding/hex"
	"errors"
	"strings"
)

// The Bitcoin base58 alphabet, which Solana writes its 32-byte keys in.
const b58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

// ParseKey32 reads a 32-byte key the way a person types one: 64 hex digits (with or without 0x), or a Solana
// address in base58.
func ParseKey32(s string) ([32]byte, error) {
	var out [32]byte
	s = strings.TrimSpace(s)
	if h := strings.TrimPrefix(s, "0x"); len(h) == 64 {
		b, err := hex.DecodeString(h)
		if err != nil {
			return out, errors.New("hyperlane: not hex: " + s)
		}
		copy(out[:], b)
		return out, nil
	}
	if len(s) == 0 || len(s) > 44 {
		return out, errors.New("hyperlane: not a 32-byte key in hex or base58: " + s)
	}
	digits := make([]byte, 0, 32) // the number so far, base 256, least significant first
	for i := 0; i < len(s); i++ {
		c := strings.IndexByte(b58, s[i])
		if c < 0 {
			return out, errors.New("hyperlane: not base58: " + s)
		}
		carry := c
		for j := range digits {
			carry += int(digits[j]) * 58
			digits[j] = byte(carry)
			carry >>= 8
		}
		for carry > 0 {
			digits = append(digits, byte(carry))
			carry >>= 8
		}
	}
	zeros := len(s) - len(strings.TrimLeft(s, "1")) // each leading '1' is a leading zero byte
	if zeros+len(digits) != 32 {
		return out, errors.New("hyperlane: base58 key is not 32 bytes: " + s)
	}
	for i, d := range digits {
		out[31-i] = d
	}
	return out, nil
}

// Base58 writes bytes the way Solana writes a key.
func Base58(b []byte) string {
	zeros := 0
	for zeros < len(b) && b[zeros] == 0 {
		zeros++
	}
	digits := make([]byte, 0, len(b)*138/100+1) // base 58, least significant first
	for _, x := range b[zeros:] {
		carry := int(x)
		for j := range digits {
			carry += int(digits[j]) << 8
			digits[j] = byte(carry % 58)
			carry /= 58
		}
		for carry > 0 {
			digits = append(digits, byte(carry%58))
			carry /= 58
		}
	}
	out := make([]byte, zeros+len(digits))
	for i := 0; i < zeros; i++ {
		out[i] = '1'
	}
	for i, d := range digits {
		out[len(out)-1-i] = b58[d]
	}
	return string(out)
}
