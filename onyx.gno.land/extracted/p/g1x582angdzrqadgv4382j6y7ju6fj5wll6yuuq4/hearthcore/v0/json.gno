package hearthcore

import (
	"strconv"
	"strings"
)

// JSONBuilder constructs deterministic, RFC-8259-compliant JSON objects without
// reflection or external dependencies so realms can expose structured queries
// to AI agents and MCP servers via vm/qeval.
type JSONBuilder struct {
	b     strings.Builder
	count int
}

// NewJSONObject starts a new JSON object builder.
func NewJSONObject() *JSONBuilder {
	jb := &JSONBuilder{}
	jb.b.WriteByte('{')
	return jb
}

func (jb *JSONBuilder) writeKey(key string) {
	if jb.count > 0 {
		jb.b.WriteByte(',')
	}
	jb.b.WriteString(QuoteJSON(key))
	jb.b.WriteByte(':')
	jb.count++
}

// Str appends a string field.
func (jb *JSONBuilder) Str(key, val string) *JSONBuilder {
	jb.writeKey(key)
	jb.b.WriteString(QuoteJSON(val))
	return jb
}

// Int64 appends a signed 64-bit integer field.
func (jb *JSONBuilder) Int64(key string, val int64) *JSONBuilder {
	jb.writeKey(key)
	jb.b.WriteString(strconv.FormatInt(val, 10))
	return jb
}

// Uint64 appends an unsigned 64-bit integer field.
func (jb *JSONBuilder) Uint64(key string, val uint64) *JSONBuilder {
	jb.writeKey(key)
	jb.b.WriteString(strconv.FormatUint(val, 10))
	return jb
}

// Bool appends a boolean field.
func (jb *JSONBuilder) Bool(key string, val bool) *JSONBuilder {
	jb.writeKey(key)
	if val {
		jb.b.WriteString("true")
	} else {
		jb.b.WriteString("false")
	}
	return jb
}

// Raw appends a pre-encoded JSON value (array or nested object).
func (jb *JSONBuilder) Raw(key, rawJSON string) *JSONBuilder {
	jb.writeKey(key)
	jb.b.WriteString(rawJSON)
	return jb
}

// String closes and returns the encoded JSON object.
func (jb *JSONBuilder) String() string {
	return jb.b.String() + "}"
}

// JoinJSONArray joins pre-encoded JSON elements into a JSON array.
func JoinJSONArray(items []string) string {
	if len(items) == 0 {
		return "[]"
	}
	var b strings.Builder
	b.WriteByte('[')
	for i, item := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(item)
	}
	b.WriteByte(']')
	return b.String()
}

// QuoteJSON encodes s as a valid RFC-8259 JSON string literal.
func QuoteJSON(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				b.WriteByte(hexDigit(c >> 4))
				b.WriteByte(hexDigit(c & 0x0f))
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func hexDigit(n byte) byte {
	if n < 10 {
		return '0' + n
	}
	return 'a' + (n - 10)
}
