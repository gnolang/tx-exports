// Package daoauth writes the arguments of a governed action as one typed,
// canonical string. memba_gov stores that string with the proposal and the
// target realm rebuilds it from its real arguments when it consumes the
// approval: the two must be equal byte for byte. Each value has exactly one
// spelling, so equal actions always encode to equal strings.
//
// Fields are joined by "|":
//
//	u:<uint64>        decimal, no sign, no leading zero
//	i:<int64>         decimal, "-" only when negative, no leading zero
//	b:0 or b:1        bool
//	a:<address>       the lowercase bech32 text the chain gives a caller
//	s:<len>:<text>    length-prefixed printable ASCII (0x20-0x7E)
//
// Strings are compared as raw bytes, with no Unicode normalisation; text is
// printable ASCII so that what a voter reads is exactly what executes.
package daoauth

import (
	"errors"
	"strconv"
	"strings"
)

const (
	MaxArgs = 1024 // bytes of one encoded argument string
	MaxText = 512  // bytes of one string field
)

var (
	ErrSyntax  = errors.New("daoauth: malformed argument string")
	ErrAddress = errors.New("daoauth: address is not lowercase bech32")
	ErrText    = errors.New("daoauth: text must be printable ASCII of at most 512 bytes")
	ErrLength  = errors.New("daoauth: arguments exceed 1024 bytes")
)

// Args accumulates fields in order. Methods panic on a value that has no
// canonical form, so a realm can never build an approval nobody can match.
type Args struct{ fields []string }

func New() *Args { return &Args{} }

func (a *Args) Uint(v uint64) *Args { return a.add("u:" + strconv.FormatUint(v, 10)) }
func (a *Args) Int(v int64) *Args   { return a.add("i:" + strconv.FormatInt(v, 10)) }

func (a *Args) Bool(v bool) *Args {
	if v {
		return a.add("b:1")
	}
	return a.add("b:0")
}

func (a *Args) Addr(v address) *Args {
	if !ValidAddress(v) {
		panic(ErrAddress.Error())
	}
	return a.add("a:" + string(v))
}

func (a *Args) Str(v string) *Args {
	if !ValidText(v) {
		panic(ErrText.Error())
	}
	return a.add("s:" + strconv.Itoa(len(v)) + ":" + v)
}

func (a *Args) add(f string) *Args {
	a.fields = append(a.fields, f)
	return a
}

// String returns the encoding. It panics past MaxArgs.
func (a *Args) String() string {
	s := strings.Join(a.fields, "|")
	if len(s) > MaxArgs {
		panic(ErrLength.Error())
	}
	return s
}

// Field is one decoded value: Tag is 'u', 'i', 'b', 'a' or 's', and Value
// is its text, without the length prefix for strings.
type Field struct {
	Tag   byte
	Value string
}

// Parse decodes s and refuses any text that is not the canonical encoding of
// its own fields. The empty string is the encoding of no fields.
func Parse(s string) ([]Field, error) {
	if len(s) > MaxArgs {
		return nil, ErrLength
	}
	var out []Field
	for len(s) > 0 {
		if len(s) < 2 || s[1] != ':' {
			return nil, ErrSyntax
		}
		tag, rest := s[0], s[2:]
		var v string
		if tag == 's' {
			i := strings.IndexByte(rest, ':')
			if i < 1 {
				return nil, ErrSyntax
			}
			n, err := strconv.Atoi(rest[:i])
			if err != nil || n < 0 || strconv.Itoa(n) != rest[:i] || n > len(rest)-i-1 {
				return nil, ErrSyntax
			}
			v, rest = rest[i+1:i+1+n], rest[i+1+n:]
			if !ValidText(v) {
				return nil, ErrText
			}
		} else {
			i := strings.IndexByte(rest, '|')
			if i < 0 {
				i = len(rest)
			}
			v, rest = rest[:i], rest[i:]
			if err := checkScalar(tag, v); err != nil {
				return nil, err
			}
		}
		out = append(out, Field{Tag: tag, Value: v})
		if len(rest) > 0 {
			if rest[0] != '|' || len(rest) == 1 {
				return nil, ErrSyntax
			}
			rest = rest[1:]
		}
		s = rest
	}
	return out, nil
}

func checkScalar(tag byte, v string) error {
	switch tag {
	case 'u':
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil || strconv.FormatUint(n, 10) != v {
			return ErrSyntax
		}
	case 'i':
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || strconv.FormatInt(n, 10) != v {
			return ErrSyntax
		}
	case 'b':
		if v != "0" && v != "1" {
			return ErrSyntax
		}
	case 'a':
		if !ValidAddress(address(v)) {
			return ErrAddress
		}
	default:
		return ErrSyntax
	}
	return nil
}

// ValidText reports whether s is at most MaxText bytes of printable ASCII
// (0x20 to 0x7E): no control, invisible, combining or direction-changing
// character can make a value read differently from what executes.
func ValidText(s string) bool {
	if len(s) > MaxText {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7e {
			return false
		}
	}
	return true
}

// The chain decodes four texts to one address: the lowercase bech32 text it
// gives a caller, that text in capitals, and the bech32m checksum in either
// case. Only the first ever equals cur.Previous().Address(). The check below
// is the one of launchpad meta/v1, copied rather than imported so governance
// does not depend on the Launchpad release. It reads the text instead of
// decoding it.

// bech32Value holds, for each character of the bech32 alphabet, its 5-bit
// value plus one. Zero marks every other byte, capitals included.
var bech32Value = [256]byte{
	'q': 1, 'p': 2, 'z': 3, 'r': 4, 'y': 5, '9': 6, 'x': 7, '8': 8,
	'g': 9, 'f': 10, '2': 11, 't': 12, 'v': 13, 'd': 14, 'w': 15, '0': 16,
	's': 17, '3': 18, 'j': 19, 'n': 20, '5': 21, '4': 22, 'k': 23, 'h': 24,
	'c': 25, 'e': 26, '6': 27, 'm': 28, 'u': 29, 'a': 30, '7': 31, 'l': 32,
}

// bech32Gen[t] is the XOR of the BIP-173 generators selected by the bits of t.
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

// bech32PrefixState is the checksum state after the prefix "g" (3, 0, 7).
const bech32PrefixState uint32 = 0x8c07

// ValidAddress reports whether a is "g1" and 38 lowercase bech32 characters
// whose checksum is the original bech32 one.
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
	return chk == 1
}
