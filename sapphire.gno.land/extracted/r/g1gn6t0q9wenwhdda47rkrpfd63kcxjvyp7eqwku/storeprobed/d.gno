// Storage probe D: compile the regexp inside the call and DISCARD it --
// never assigned to a package-level var, so nothing persists. Measures
// what the no-cache option costs in gas on every single call.
package storeprobed

import "regexp"

func Check(cur realm, s string) bool {
	re := regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	return re.MatchString(s)
}

// And the same rule written out by hand, for comparison.
func CheckPlain(cur realm, s string) bool {
	if s == "" {
		return false
	}
	prevHyphen := true // a leading hyphen is not allowed
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			prevHyphen = false
		case c == '-':
			if prevHyphen {
				return false
			}
			prevHyphen = true
		default:
			return false
		}
	}
	return !prevHyphen // nor a trailing one
}

func Render(path string) string { return "probe d" }
