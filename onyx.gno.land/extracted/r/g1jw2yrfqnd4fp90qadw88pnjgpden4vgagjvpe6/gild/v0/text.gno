package gild

import "strings"

func trimSpace(s string) string { return strings.TrimSpace(s) }

// checkText panics with msg unless s has between min and max characters and
// contains no control characters other than newline and tab.
func checkText(s string, min, max int, msg string) {
	n := 0
	for _, r := range s {
		if r < 0x20 && r != '\n' && r != '\t' {
			panic(msg)
		}
		if r == 0x7f {
			panic(msg)
		}
		n++
	}
	if n < min || n > max {
		panic(msg)
	}
}

// isWorkURL accepts https links with no spaces or control characters.
func isWorkURL(s string) bool {
	if len(s) > MaxURL || !strings.HasPrefix(s, "https://") || len(s) <= len("https://") {
		return false
	}
	for _, r := range s {
		if r <= 0x20 || r == 0x7f || r == '"' || r == '<' || r == '>' || r == '`' {
			return false
		}
	}
	return true
}
