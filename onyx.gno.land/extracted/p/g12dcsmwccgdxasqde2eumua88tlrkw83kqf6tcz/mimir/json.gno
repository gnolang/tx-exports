package mimir

import "strings"

const hexDigits = "0123456789abcdef"

// Quote returns s as a JSON string literal.
func Quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
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

// Escape makes user text safe to place in gnoweb markdown: it cannot open
// links, images, HTML or headings.
func Escape(s string) string {
	r := strings.NewReplacer(
		"\\", "\\\\", "[", "\\[", "]", "\\]", "(", "\\(", ")", "\\)",
		"<", "&lt;", ">", "&gt;", "*", "\\*", "_", "\\_", "`", "\\`",
		"#", "\\#", "|", "\\|", "\n", " ", "\r", " ",
	)
	return r.Replace(s)
}

// FormatUSD renders 6-decimal units as a dollar amount with two decimals, rounded down.
func FormatUSD(units int64) string {
	sign := ""
	if units < 0 {
		sign = "-"
		units = -units
	}
	cents := units / 10_000
	frac := cents % 100
	s := sign + itoa(cents/100) + "."
	if frac < 10 {
		s += "0"
	}
	return s + itoa(frac)
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
