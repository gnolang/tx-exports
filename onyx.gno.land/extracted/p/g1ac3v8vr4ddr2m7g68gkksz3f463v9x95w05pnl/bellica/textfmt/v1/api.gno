package textfmt

import (
	"strconv"
	"strings"
)

func JsonErr(msg string) string { return `{"error":` + Jq(msg) + `}` }

// jq quotes s as a JSON string: escapes quotes, backslashes and control
// characters, and replaces invalid UTF-8 with U+FFFD, so output always parses.
func Jq(s string) string {
	const hex = "0123456789abcdef"
	var sb strings.Builder
	sb.WriteByte('"')
	for _, r := range s { // ranging a string yields U+FFFD for invalid bytes
		switch {
		case r == '"':
			sb.WriteString(`\"`)
		case r == '\\':
			sb.WriteString(`\\`)
		case r == '\n':
			sb.WriteString(`\n`)
		case r < 0x20 || r == 0x2028 || r == 0x2029:
			sb.WriteString(`\u`)
			sb.WriteByte(hex[(r>>12)&0xf])
			sb.WriteByte(hex[(r>>8)&0xf])
			sb.WriteByte(hex[(r>>4)&0xf])
			sb.WriteByte(hex[r&0xf])
		default:
			sb.WriteRune(r)
		}
	}
	sb.WriteByte('"')
	return sb.String()
}

func I64(n int64) string { return strconv.FormatInt(n, 10) }
