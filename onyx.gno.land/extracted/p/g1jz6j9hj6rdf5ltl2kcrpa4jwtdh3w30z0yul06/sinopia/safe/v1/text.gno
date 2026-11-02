// Package safe holds the pure checks and formulas every platform realm
// shares: text and SVG validation, basis-point math, payee splits, merkle
// proofs, provenance hashes and the one JSON writer. Nothing here has state.
package safe

import (
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Domain separates every hash this platform commits to from hashes of the
// same bytes made for any other purpose. It equals the brand slug and
// changes with it (paths change anyway when the brand is chosen).
const Domain = "art"

// CheckText reports why s may not be stored as user-visible text.
//
// Rejected: invalid UTF-8; C0 and C1 control characters, which include tab,
// newline and carriage return (the record-injection vector of RA H-1); DEL;
// U+2028/U+2029, which end a line in older JavaScript parsers (RA L-12); and
// every bidi control or zero-width character that lets one string render as
// another.
func CheckText(s string, maxLen int) error {
	if len(s) > maxLen {
		return errors.New("too long (max " + strconv.Itoa(maxLen) + " bytes)")
	}
	if !utf8.ValidString(s) {
		return errors.New("invalid UTF-8")
	}
	for _, r := range s {
		if forbiddenRune(r) {
			return errors.New("forbidden character U+" + strings.ToUpper(strconv.FormatInt(int64(r), 16)))
		}
	}
	return nil
}

// AssertText panics with the field name when CheckText rejects s.
func AssertText(field, s string, maxLen int) {
	if err := CheckText(s, maxLen); err != nil {
		panic(field + ": " + err.Error())
	}
}

// AssertNonEmptyText is AssertText that also refuses "".
func AssertNonEmptyText(field, s string, maxLen int) {
	if s == "" {
		panic(field + ": must not be empty")
	}
	AssertText(field, s, maxLen)
}

func forbiddenRune(r rune) bool {
	switch {
	case r < 0x20, r == 0x7f, r >= 0x80 && r <= 0x9f:
		return true
	case r == 0x061c, r == 0xfeff: // Arabic letter mark, zero-width no-break space
		return true
	case r >= 0x200b && r <= 0x200f: // zero-width space/joiners, LRM, RLM
		return true
	case r == 0x2028, r == 0x2029:
		return true
	case r >= 0x202a && r <= 0x202e: // bidi embeddings and overrides
		return true
	case r >= 0x2066 && r <= 0x2069: // bidi isolates
		return true
	}
	return false
}

// AssertSymbol enforces the grc721 symbol alphabet ([A-Za-z0-9_-], 1..11
// bytes) up front, so the error names the field instead of surfacing from
// grc721.NewToken.
func AssertSymbol(field, s string) {
	if s == "" || len(s) > 11 {
		panic(field + ": must be 1-11 characters")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			panic(field + ": only A-Z, a-z, 0-9, '_' and '-' are allowed")
		}
	}
}

// AssertHex checks that s is exactly nBytes of hex and returns it lowercased.
func AssertHex(field, s string, nBytes int) string {
	if len(s) != 2*nBytes {
		panic(field + ": must be " + strconv.Itoa(2*nBytes) + " hex characters")
	}
	low := strings.ToLower(s)
	for i := 0; i < len(low); i++ {
		c := low[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			panic(field + ": must be hex")
		}
	}
	return low
}

// ParseID parses a positive decimal id ("1", "42"). Leading zeros, signs
// and empty strings are refused so every id has exactly one spelling.
func ParseID(field, s string) int64 {
	if s == "" || len(s) > 18 || s[0] == '0' {
		panic(field + ": invalid id " + strconv.Quote(s))
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			panic(field + ": invalid id " + strconv.Quote(s))
		}
		n = n*10 + int64(c-'0')
	}
	return n
}

// PadInt renders n with leading zeros to width digits, so decimal ids and
// prices sort correctly as avl keys. n must be >= 0.
func PadInt(n int64, width int) string {
	s := strconv.FormatInt(n, 10)
	if len(s) >= width {
		return s
	}
	return strings.Repeat("0", width-len(s)) + s
}

// XMLEscape makes s safe as SVG/XML character data or a quoted attribute.
func XMLEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&quot;")
		case '\'':
			b.WriteString("&apos;")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}
