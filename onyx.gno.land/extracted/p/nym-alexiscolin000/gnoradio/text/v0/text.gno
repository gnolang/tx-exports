// Package text holds the small string helpers shared by the GnoRadio realms.
package text

import (
	"strconv"
	"strings"
	"unicode"
)

// Str quotes a value as a JSON string without escaping. Use it only for values
// whose validator already refuses `"`, `\` and control characters (Valid text,
// validated URLs, hashes, addresses, constants): escaping costs about 1M gas
// per field in the VM.
func Str(s string) string { return `"` + s + `"` }

// Valid accepts min..max runes of letters (any script), digits, spaces and
// . , ' - ! ? : / &. Markdown, HTML and JSON specials are refused, so the text
// is safe in markdown and JSON as is (SVG still escapes '&'). Fullwidth and
// mathematical letters (which dodge word filters) and the blank Hangul fillers
// are refused too.
func Valid(s string, min, max int) bool {
	n := 0
	for _, r := range s {
		n++
		if r >= 0xFF01 && r <= 0xFF5E || r >= 0x1D400 && r <= 0x1D7FF || r == 0x115F || r == 0x1160 || r == 0x3164 || r == 0xFFA0 {
			return false
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			continue
		}
		switch r {
		case ' ', '.', ',', '\'', '-', '!', '?', ':', '/', '&':
			continue
		}
		return false
	}
	return n >= min && n <= max
}

// Digits reports whether s is a non-empty run of ASCII digits.
func Digits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// GNOT formats ugnot as GNOT with up to 6 decimals.
func GNOT(u int64) string {
	const ugnot = 1_000_000
	whole := strconv.FormatInt(u/ugnot, 10)
	frac := u % ugnot
	if frac == 0 {
		return whole + " GNOT"
	}
	f := strconv.FormatInt(frac, 10)
	f = strings.TrimRight(strings.Repeat("0", 6-len(f))+f, "0")
	return whole + "." + f + " GNOT"
}

// Itoa and Itoa64 skip strconv for the frequent zero: every conversion
// costs gas.
func Itoa(n int) string {
	if n == 0 {
		return "0"
	}
	return strconv.Itoa(n)
}

func Itoa64(n int64) string {
	if n == 0 {
		return "0"
	}
	return strconv.FormatInt(n, 10)
}

// Atoi and Atoi64 read a stored decimal; anything else is 0.
func Atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func Atoi64(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}

// MustAtoi and MustAtoi64 read a stored number on a money or authority path:
// a corrupt record panics (the transaction reverts) instead of reading as 0.
func MustAtoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		panic("text: not a number: " + s)
	}
	return n
}

func MustAtoi64(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("text: not a number: " + s)
	}
	return n
}

// Flag is a stored boolean: "1" or "".
func Flag(b bool) string {
	if b {
		return "1"
	}
	return ""
}

// URLChars accepts only URL-safe characters (A-Z a-z 0-9 - . _ ~ : / ? # =
// & % + @): safe in markdown link destinations and JSON as is.
func URLChars(s string) bool {
	for _, c := range s {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case strings.ContainsRune("-._~:/?#=&%+@", c):
		default:
			return false
		}
	}
	return true
}

// HTTPS accepts an https link of URL-safe characters, 11 to max bytes.
func HTTPS(s string, max int) bool {
	return strings.HasPrefix(s, "https://") && len(s) > 10 && len(s) <= max && URLChars(s)
}
