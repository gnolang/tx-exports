package torchbeat

const hexDigits = "0123456789abcdef"

// appendQuoted appends s as a JSON string: quote and backslash are
// backslash-escaped, control characters become \u00XX, other bytes pass
// through unchanged.
func appendQuoted(b []byte, s string) []byte {
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b = append(b, '\\', c)
		case c < 0x20:
			b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&0xf])
		default:
			b = append(b, c)
		}
	}
	return append(b, '"')
}

// appendField appends `"key":` (key must need no escaping), preceded by a comma
// unless it is the object's first field.
func appendField(b []byte, key string, first bool) []byte {
	if !first {
		b = append(b, ',')
	}
	b = append(b, '"')
	b = append(b, key...)
	return append(b, '"', ':')
}

// appendInt appends n in decimal without strconv (much cheaper for the small
// numbers SVG coordinates are).
func appendInt(b []byte, n int) []byte {
	if n < 0 {
		b = append(b, '-')
		n = -n
	}
	switch {
	case n < 10:
		return append(b, byte('0'+n))
	case n < 100:
		return append(b, byte('0'+n/10), byte('0'+n%10))
	case n < 1000:
		return append(b, byte('0'+n/100), byte('0'+n/10%10), byte('0'+n%10))
	}
	r := n % 1000
	return append(appendInt(b, n/1000), byte('0'+r/100), byte('0'+r/10%10), byte('0'+r%10))
}

func appendBool(b []byte, v bool) []byte {
	if v {
		return append(b, "true"...)
	}
	return append(b, "false"...)
}
