package rooms

import (
	"strconv"
	"strings"
)

// jsonString quotes s as a JSON string. Everything outside printable ASCII
// is written as a \u escape, so the output is plain ASCII.
func jsonString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r >= 0x20 && r < 0x7f:
			b.WriteRune(r)
		case r > 0xffff:
			r -= 0x10000
			writeU16(&b, 0xd800+(r>>10))
			writeU16(&b, 0xdc00+(r&0x3ff))
		default:
			writeU16(&b, r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func writeU16(b *strings.Builder, r rune) {
	const hex = "0123456789abcdef"
	b.WriteString(`\u`)
	b.WriteByte(hex[(r>>12)&0xf])
	b.WriteByte(hex[(r>>8)&0xf])
	b.WriteByte(hex[(r>>4)&0xf])
	b.WriteByte(hex[r&0xf])
}

func jsonUint(v uint64) string {
	return strconv.FormatUint(v, 10)
}

func jsonInt(v int64) string {
	return strconv.FormatInt(v, 10)
}

func jsonBool(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

// jsonObject joins already-encoded key/value pairs.
func jsonObject(pairs ...string) string {
	if len(pairs)%2 != 0 {
		panic("jsonObject needs key/value pairs")
	}
	var b strings.Builder
	b.WriteByte('{')
	for i := 0; i < len(pairs); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsonString(pairs[i]))
		b.WriteByte(':')
		b.WriteString(pairs[i+1])
	}
	b.WriteByte('}')
	return b.String()
}

func jsonArray(items []string) string {
	return "[" + strings.Join(items, ",") + "]"
}
