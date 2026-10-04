package skins

// The string rules below are what makes the hand-built JSON and the markdown
// of this realm safe: every string that is stored and later printed went
// through one of them, and none of them lets a quote, a backslash, a pipe, a
// bracket or a control character in.

const (
	maxIDLen    = 32
	maxModelLen = 16
	maxNameLen  = 40
)

// validID reports whether s matches [a-z0-9-]{1,32}.
func validID(s string) bool {
	return isSlug(s, maxIDLen)
}

// validModel reports whether s matches [a-z0-9-]{1,16}.
func validModel(s string) bool {
	return isSlug(s, maxModelLen)
}

// validName reports whether s matches [A-Za-z0-9 '.!-]{1,40}. The charset is
// deliberately narrow so that a name can be embedded in JSON and markdown
// without escaping.
func validName(s string) bool {
	if len(s) == 0 || len(s) > maxNameLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == ' ', c == '\'', c == '.', c == '!', c == '-':
		default:
			return false
		}
	}
	return true
}

// validColor reports whether s is "#rrggbb" with lowercase hex digits.
func validColor(s string) bool {
	if len(s) != 7 || s[0] != '#' {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// validAddress reports whether addr is a valid address in its canonical,
// lowercase form.
//
// Bech32 can also be written in all capitals, and address.IsValid accepts
// that. To this realm the capitals would be a second key for the same
// account: a second player record, a second line on a leaderboard, an admin
// who can never be matched to a caller. Bech32 does not allow mixing cases,
// so looking at the first character is enough.
func validAddress(addr address) bool {
	return addr.IsValid() && addr[0] == 'g'
}

// isSlug reports whether s is 1 to max characters of [a-z0-9-].
func isSlug(s string, max int) bool {
	if len(s) == 0 || len(s) > max {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '-' {
			return false
		}
	}
	return true
}
