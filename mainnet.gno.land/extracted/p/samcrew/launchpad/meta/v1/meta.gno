// Package meta validates launch metadata and addresses, and encodes text
// safely for JSON and Markdown.
package meta

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

var (
	ErrName        = errors.New("launchpad/meta: name must be 1-32 bytes of printable text without markup characters")
	ErrTicker      = errors.New("launchpad/meta: ticker must be 1-10 characters A-Z or 0-9")
	ErrDescription = errors.New("launchpad/meta: description must be at most 280 bytes of printable text without markup characters")
	ErrImage       = errors.New("launchpad/meta: image must be an ipfs:// or https:// URI of at most 200 bytes")
	ErrWebsite     = errors.New("launchpad/meta: website must be an https:// URL of at most 200 bytes")
	ErrHandle      = errors.New("launchpad/meta: handle must be 1-32 characters A-Z, a-z, 0-9 or _")
)

const hexDigits = "0123456789abcdef"

// The chain decodes four texts to the same address: the bech32 form it gives
// a caller, that form in capitals, and the bech32m checksum in either case.
// State keyed by the text, such as a token balance or a role, recorded under
// any of the other three is something no caller can ever reach.

// bech32Value holds, for each character of the bech32 alphabet
// "qpzry9x8gf2tvdw0s3jn54khce6mua7l", its 5-bit value plus one. Zero marks
// every other byte, capitals included.
var bech32Value = [256]byte{
	'q': 1, 'p': 2, 'z': 3, 'r': 4, 'y': 5, '9': 6, 'x': 7, '8': 8,
	'g': 9, 'f': 10, '2': 11, 't': 12, 'v': 13, 'd': 14, 'w': 15, '0': 16,
	's': 17, '3': 18, 'j': 19, 'n': 20, '5': 21, '4': 22, 'k': 23, 'h': 24,
	'c': 25, 'e': 26, '6': 27, 'm': 28, 'u': 29, 'a': 30, '7': 31, 'l': 32,
}

// bech32Gen[t] is the XOR of the BIP-173 generators selected by the five
// bits of t: one table read per character instead of five tests.
var bech32Gen = [32]uint32{
	0x00000000, 0x3b6a57b2, 0x26508e6d, 0x1d3ad9df,
	0x1ea119fa, 0x25cb4e48, 0x38f19797, 0x039bc025,
	0x3d4233dd, 0x0628646f, 0x1b12bdb0, 0x2078ea02,
	0x23e32a27, 0x18897d95, 0x05b3a44a, 0x3ed9f3f8,
	0x2a1462b3, 0x117e3501, 0x0c44ecde, 0x372ebb6c,
	0x34b57b49, 0x0fdf2cfb, 0x12e5f524, 0x298fa296,
	0x1756516e, 0x2c3c06dc, 0x3106df03, 0x0a6c88b1,
	0x09f74894, 0x329d1f26, 0x2fa7c6f9, 0x14cd914b,
}

// The checksum state once the address prefix "g" has been absorbed, which
// BIP-173 expands to the values 3, 0, 7.
const bech32PrefixState uint32 = 0x8c07

// ValidAddress reports whether a is an account or realm address written the
// one way the chain gives it to a caller: "g1", then 38 lowercase bech32
// characters whose checksum is the original bech32 one. It reads the text
// itself: decoding and re-encoding it costs far more gas.
func ValidAddress(a address) bool {
	s := string(a)
	if len(s) != 40 || s[0] != 'g' || s[1] != '1' {
		return false
	}
	chk := bech32PrefixState
	for i := 2; i < 40; i++ {
		v := bech32Value[s[i]]
		if v == 0 {
			return false
		}
		chk = (chk&0x1ffffff)<<5 ^ uint32(v-1) ^ bech32Gen[chk>>25]
	}
	return chk == 1 // 1 is bech32; bech32m ends on 0x2bc830a3
}

func printable(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if !unicode.IsPrint(r) {
			return false
		}
	}
	return true
}

func Name(s string) error {
	if len(s) < 1 || len(s) > 32 || !printable(s) || strings.ContainsAny(s, "[]()*#<>`|\\") || strings.TrimSpace(s) != s {
		return ErrName
	}
	return nil
}

func Ticker(s string) error {
	if len(s) < 1 || len(s) > 10 {
		return ErrTicker
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') {
			return ErrTicker
		}
	}
	return nil
}

func Description(s string) error {
	if len(s) > 280 || !printable(s) || strings.ContainsAny(s, "[]()<>") {
		return ErrDescription
	}
	return nil
}

func safeURI(s string, schemes []string) bool {
	if len(s) > 200 {
		return false
	}
	matched := false
	for _, p := range schemes {
		if strings.HasPrefix(s, p) && len(s) > len(p) {
			matched = true
		}
	}
	if !matched {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c <= 0x20 || c >= 0x7f || strings.IndexByte("\"'<>\\`()[]{}|^", c) >= 0 {
			return false
		}
	}
	return true
}

func Image(s string) error {
	if s == "" || safeURI(s, []string{"ipfs://", "https://"}) {
		return nil
	}
	return ErrImage
}

func Website(s string) error {
	if s == "" || safeURI(s, []string{"https://"}) {
		return nil
	}
	return ErrWebsite
}

func Handle(s string) error {
	if s == "" {
		return nil
	}
	if len(s) > 32 {
		return ErrHandle
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_' {
			return ErrHandle
		}
	}
	return nil
}

// JSONString quotes s as a JSON string. Control bytes become \u00XX so the
// value survives the frontend's qeval double decode.
func JSONString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte(hexDigits[c>>4])
			b.WriteByte(hexDigits[c&0xf])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// EscapeMarkdown backslash-escapes every Markdown control character.
func EscapeMarkdown(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if strings.IndexByte("\\`*_{}[]()#+-.!|<>~", c) >= 0 {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}
