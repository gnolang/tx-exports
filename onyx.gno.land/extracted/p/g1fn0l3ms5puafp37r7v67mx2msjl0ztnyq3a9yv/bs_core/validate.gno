package bs_core

import (
	"errors"
	"strings"
)

// ValidateText checks byte length, optional emptiness, and rejects unsafe control chars.
// Newlines (\n, \r) and tabs (\t) are permitted only when allowMultiline is true.
func ValidateText(s string, maxBytes int, required bool, allowMultiline bool) error {
	trimmed := strings.TrimSpace(s)
	if required && len(trimmed) == 0 {
		return errors.New("text field is required")
	}
	if len(s) > maxBytes {
		return errors.New("text field exceeds max byte length")
	}
	for i := 0; i < len(s); i++ {
		b := s[i]
		if b == 0x7f {
			return errors.New("text contains invalid control character")
		}
		if b < 0x20 {
			if allowMultiline && (b == '\n' || b == '\r' || b == '\t') {
				continue
			}
			return errors.New("text contains disallowed control character")
		}
	}
	return nil
}

// ValidateHTTPSURL enforces an https:// URL with no whitespace, control characters,
// or Markdown/HTML link-breakout characters.
func ValidateHTTPSURL(u string) error {
	if len(u) == 0 {
		return errors.New("URL is required")
	}
	if len(u) > MaxURLBytes {
		return errors.New("URL exceeds max byte length")
	}
	if !strings.HasPrefix(u, "https://") {
		return errors.New("URL must start with https://")
	}
	rest := u[len("https://"):]
	if len(rest) < 3 || !strings.Contains(rest, ".") {
		return errors.New("URL must contain a valid host")
	}
	for i := 0; i < len(u); i++ {
		b := u[i]
		if b <= 0x20 || b >= 0x7f {
			return errors.New("URL contains invalid or whitespace character")
		}
		switch b {
		case '<', '>', '"', '\'', '(', ')', '[', ']', '`', '\\':
			return errors.New("URL contains disallowed character")
		}
	}
	return nil
}

// EscapeMarkdown neutralizes Markdown/HTML injection in gnoweb Render() output.
func EscapeMarkdown(s string) string {
	var sb strings.Builder
	sb.Grow(len(s) + 16)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '!', '|':
			sb.WriteByte('\\')
			sb.WriteByte(c)
		case '<':
			sb.WriteString("&lt;")
		case '>':
			sb.WriteString("&gt;")
		case '&':
			sb.WriteString("&amp;")
		default:
			sb.WriteByte(c)
		}
	}
	return sb.String()
}

// EscapeJSON escapes a string safely for embedding inside JSON double quotes.
func EscapeJSON(s string) string {
	var sb strings.Builder
	sb.Grow(len(s) + 16)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '\\':
			sb.WriteString(`\\`)
		case '"':
			sb.WriteString(`\"`)
		case '\n':
			sb.WriteString(`\n`)
		case '\r':
			sb.WriteString(`\r`)
		case '\t':
			sb.WriteString(`\t`)
		case '<':
			sb.WriteString(`\u003c`)
		case '>':
			sb.WriteString(`\u003e`)
		default:
			if c < 0x20 {
				sb.WriteString(" ")
			} else {
				sb.WriteByte(c)
			}
		}
	}
	return sb.String()
}
