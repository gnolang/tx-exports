package safe

import (
	"chain/markdown"
	"strconv"
	"strings"
)

// Byte classes as 128-bit bitmaps for the native markdown.MatchCharsetN
// (one call checks a whole string at ~0.7 gas per byte; bytes >= 0x80 never
// match). jsonSafe: printable ASCII that JSONString copies unchanged (not
// '"', '\', '<', '>', '&', DEL). rawSafe: [A-Za-z0-9+/=:;,._-].
const (
	jsonSafeLo = 0xafffffbb00000000
	jsonSafeHi = 0x7fffffffefffffff
	rawSafeLo  = 0x2ffff80000000000
	rawSafeHi  = 0x07fffffe87fffffe
	// jsonFastMin: below this length the byte loop is cheaper than the
	// native call.
	jsonFastMin = 8
)

// JSONString returns s as a quoted JSON string. Beyond the mandatory
// escapes it also escapes U+2028/U+2029 (RA L-12) and '<', '>', '&', so the
// output is safe to inline in HTML as well. Strings that need no escape
// (printable ASCII without '"', '\', '<', '>', '&') take a native fast
// path; the output is the same.
func JSONString(s string) string {
	if len(s) >= jsonFastMin && markdown.MatchCharsetN(s, jsonSafeLo, jsonSafeHi, jsonSafeLo, jsonSafeHi, 0, len(s)) {
		return "\"" + s + "\""
	}
	const hexDigits = "0123456789abcdef"
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '<', '>', '&', 0x2028, 0x2029:
			b.WriteString(`\u`)
			b.WriteString(PadHex(int64(r), 4))
		default:
			if r < 0x20 || r == 0x7f {
				b.WriteString(`\u00`)
				b.WriteByte(hexDigits[(r>>4)&0xf])
				b.WriteByte(hexDigits[r&0xf])
				continue
			}
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// PadHex renders n in lowercase hex, zero-padded to width.
func PadHex(n int64, width int) string {
	s := strconv.FormatInt(n, 16)
	if len(s) >= width {
		return s
	}
	return strings.Repeat("0", width-len(s)) + s
}

// JSONWriter is the single JSON producer of every read API (design
// §2.5: reads return primitives or JSON, never positional text). It tracks
// commas itself, so callers only describe structure:
//
//	w := &safe.JSONWriter{}
//	w.BeginObject(); w.Key("id"); w.Str("1"); w.EndObject()
type JSONWriter struct {
	b        strings.Builder
	hasItems []bool // one entry per open container
	afterKey bool
}

func (w *JSONWriter) BeginObject() { w.open('{') }
func (w *JSONWriter) EndObject()   { w.close('}') }
func (w *JSONWriter) BeginArray()  { w.open('[') }
func (w *JSONWriter) EndArray()    { w.close(']') }

// Key starts an object member; the next value call writes its value.
func (w *JSONWriter) Key(k string) {
	w.separate()
	w.b.WriteString(JSONString(k))
	w.b.WriteByte(':')
	w.afterKey = true
}

func (w *JSONWriter) Str(v string) { w.value(JSONString(v)) }
func (w *JSONWriter) Int(v int64)  { w.value(strconv.FormatInt(v, 10)) }
func (w *JSONWriter) Bool(v bool)  { w.value(strconv.FormatBool(v)) }

// Raw writes v verbatim. Only for JSON produced by another JSONWriter.
func (w *JSONWriter) Raw(v string) { w.value(v) }

// RawStr writes v as a JSON string without escaping. v may only hold
// [A-Za-z0-9+/=:;,._-] (base64, hex, decimal, a data: URI header), which
// JSON never escapes; any other byte panics. One native pass instead of a
// rune loop: a 350 KB data URI costs well under 1M gas (M-4, UP-I1).
func (w *JSONWriter) RawStr(v string) {
	if !markdown.MatchCharsetN(v, rawSafeLo, rawSafeHi, rawSafeLo, rawSafeHi, 0, len(v)) {
		panic("JSONWriter: RawStr value may only hold [A-Za-z0-9+/=:;,._-]")
	}
	w.separate()
	w.b.WriteByte('"')
	w.b.WriteString(v)
	w.b.WriteByte('"')
}

// RawStrField is Key + RawStr.
func (w *JSONWriter) RawStrField(k, v string) { w.Key(k); w.RawStr(v) }

// StrField and IntField are Key+value shorthands.
func (w *JSONWriter) StrField(k, v string) { w.Key(k); w.Str(v) }
func (w *JSONWriter) IntField(k string, v int64) { w.Key(k); w.Int(v) }
func (w *JSONWriter) BoolField(k string, v bool) { w.Key(k); w.Bool(v) }

func (w *JSONWriter) String() string { return w.b.String() }

func (w *JSONWriter) open(c byte) {
	w.separate()
	w.b.WriteByte(c)
	w.hasItems = append(w.hasItems, false)
}

func (w *JSONWriter) close(c byte) {
	if len(w.hasItems) == 0 {
		panic("JSONWriter: close without open")
	}
	w.hasItems = w.hasItems[:len(w.hasItems)-1]
	w.b.WriteByte(c)
}

func (w *JSONWriter) value(v string) {
	w.separate()
	w.b.WriteString(v)
}

// separate writes the comma before an item, except right after a key.
func (w *JSONWriter) separate() {
	if w.afterKey {
		w.afterKey = false
		return
	}
	if n := len(w.hasItems); n > 0 {
		if w.hasItems[n-1] {
			w.b.WriteByte(',')
		}
		w.hasItems[n-1] = true
	}
}
