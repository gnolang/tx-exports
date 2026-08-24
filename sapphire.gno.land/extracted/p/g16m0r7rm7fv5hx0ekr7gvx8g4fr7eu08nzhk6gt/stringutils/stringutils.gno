package stringutils

// Contains reports whether substr is within s.
func Contains(s string, substr string) bool {
	return IndexOf(s, substr) >= 0
}

// IndexOf returns the index of the first occurrence of substr in s, or -1.
func IndexOf(s string, substr string) int {
	n := len(s)
	m := len(substr)
	if m == 0 {
		return 0
	}
	if m > n {
		return -1
	}
	for i := 0; i <= n-m; i++ {
		match := true
		for j := 0; j < m; j++ {
			if s[i+j] != substr[j] {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

// Split divides s by every occurrence of sep, returning the resulting parts.
// If sep is empty, returns a slice with s as its only element.
func Split(s string, sep string) []string {
	if sep == "" {
		return []string{s}
	}
	parts := []string{}
	start := 0
	sepLen := len(sep)
	for {
		idx := IndexOf(s[start:], sep)
		if idx < 0 {
			parts = append(parts, s[start:])
			break
		}
		parts = append(parts, s[start:start+idx])
		start = start + idx + sepLen
	}
	return parts
}

// TrimSpace removes leading and trailing ASCII whitespace from s.
func TrimSpace(s string) string {
	start := 0
	end := len(s)
	for start < end && isSpace(s[start]) {
		start++
	}
	for end > start && isSpace(s[end-1]) {
		end--
	}
	return s[start:end]
}

func isSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// HasPrefix reports whether s begins with prefix.
func HasPrefix(s string, prefix string) bool {
	if len(prefix) > len(s) {
		return false
	}
	return s[:len(prefix)] == prefix
}

// HasSuffix reports whether s ends with suffix.
func HasSuffix(s string, suffix string) bool {
	if len(suffix) > len(s) {
		return false
	}
	return s[len(s)-len(suffix):] == suffix
}

// Join concatenates parts, separating each with sep.
func Join(parts []string, sep string) string {
	if len(parts) == 0 {
		return ""
	}
	out := parts[0]
	for i := 1; i < len(parts); i++ {
		out += sep + parts[i]
	}
	return out
}

// Repeat returns s concatenated count times.
func Repeat(s string, count int) string {
	if count <= 0 {
		return ""
	}
	out := ""
	for i := 0; i < count; i++ {
		out += s
	}
	return out
}

// ToUpper converts ASCII lowercase letters in s to uppercase.
func ToUpper(s string) string {
	buf := []byte(s)
	for i, b := range buf {
		if b >= 'a' && b <= 'z' {
			buf[i] = b - 32
		}
	}
	return string(buf)
}

// ToLower converts ASCII uppercase letters in s to lowercase.
func ToLower(s string) string {
	buf := []byte(s)
	for i, b := range buf {
		if b >= 'A' && b <= 'Z' {
			buf[i] = b + 32
		}
	}
	return string(buf)
}
