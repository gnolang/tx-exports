package game

// indexFrom returns the index of the first c in s at or after i, or len(s)
// when there is none.
func indexFrom(s string, i int, c byte) int {
	for i < len(s) && s[i] != c {
		i++
	}
	return i
}

// digits parses a non-empty string of decimal digits. Kill counts are never
// negative, so there is no sign to read.
func digits(s string) (int64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n := int64(0)
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
	}
	return n, true
}
