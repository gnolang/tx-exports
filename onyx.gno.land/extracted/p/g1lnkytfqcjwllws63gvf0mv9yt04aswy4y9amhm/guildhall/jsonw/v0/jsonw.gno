// Package jsonw builds JSON text for realm query endpoints.
//
// Values are plain strings holding encoded JSON, composed with Obj and Arr:
//
//	jsonw.Obj(
//		"id", jsonw.Uint(b.ID),
//		"title", jsonw.String(b.Title),
//		"tags", jsonw.Strings(b.Tags),
//	)
//
// String escapes everything JSON requires and replaces invalid UTF-8, so
// user-supplied text can never break the document.
package jsonw

import (
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const Null = "null"

// String encodes s as a JSON string.
func String(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			b.WriteString(`\ufffd`)
			i++
			continue
		}
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f || r == 0x2028 || r == 0x2029:
			b.WriteString(`\u`)
			h := strconv.FormatInt(int64(r), 16)
			for j := len(h); j < 4; j++ {
				b.WriteByte('0')
			}
			b.WriteString(h)
		default:
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	b.WriteByte('"')
	return b.String()
}

// Int encodes n. Values beyond JavaScript's safe integer range are encoded
// as strings so clients never lose precision.
func Int(n int64) string {
	if n > 9007199254740991 || n < -9007199254740991 {
		return `"` + strconv.FormatInt(n, 10) + `"`
	}
	return strconv.FormatInt(n, 10)
}

// Uint encodes n, as a string beyond JavaScript's safe integer range.
func Uint(n uint64) string {
	if n > 9007199254740991 {
		return `"` + strconv.FormatUint(n, 10) + `"`
	}
	return strconv.FormatUint(n, 10)
}

// Bool encodes v.
func Bool(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

// Time encodes t as RFC 3339 in UTC, or null when zero.
func Time(t time.Time) string {
	if t.IsZero() {
		return Null
	}
	return String(t.UTC().Format(time.RFC3339))
}

// Obj builds an object from alternating keys and encoded values.
func Obj(kv ...string) string {
	if len(kv)%2 != 0 {
		panic("jsonw: Obj needs key/value pairs")
	}
	var b strings.Builder
	b.WriteByte('{')
	for i := 0; i < len(kv); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(String(kv[i]))
		b.WriteByte(':')
		b.WriteString(kv[i+1])
	}
	b.WriteByte('}')
	return b.String()
}

// Arr builds an array from encoded values.
func Arr(items []string) string {
	return "[" + strings.Join(items, ",") + "]"
}

// Strings encodes a list of strings.
func Strings(ss []string) string {
	out := make([]string, len(ss))
	for i, s := range ss {
		out[i] = String(s)
	}
	return Arr(out)
}

// Addresses encodes a list of addresses as strings.
func Addresses(as []address) string {
	out := make([]string, len(as))
	for i, a := range as {
		out[i] = String(a.String())
	}
	return Arr(out)
}
