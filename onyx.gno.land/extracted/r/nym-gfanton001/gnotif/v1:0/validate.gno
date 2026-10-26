package gnotif

import "strings"

const (
	targetPrefix   = "gno.land/r/"
	maxTarget      = 249
	maxName        = 64
	maxFilterPairs = 8
	maxBody        = 255
	maxLink        = 256
	maxPerTarget   = 64
)

func validate(t Trigger) {
	switch {
	case !validName(t.Event, 1, maxName):
		panic("invalid event")
	case !validFilter(t.Filter):
		panic("invalid filter")
	case !validName(t.Param, 0, maxName):
		panic("invalid param")
	case !sized(t.Title, 1, maxName):
		panic("invalid title")
	case !sized(t.Body, 0, maxBody):
		panic("invalid body")
	case !validLink(t.Link):
		panic("invalid link")
	}
}

// namespaceOf returns the namespace a valid target lives in, and panics on a
// target that is not a valid realm path.
func namespaceOf(target string) string {
	if !validTarget(target) {
		panic("invalid target " + target)
	}
	namespace, _, _ := strings.Cut(target[len(targetPrefix):], "/")
	return namespace
}

func sized(s string, lo, hi int) bool {
	return len(s) >= lo && len(s) <= hi
}

// validTarget accepts a realm path whose segments each match the chain's
// Re_name, so a target names a path where a realm can exist.
func validTarget(target string) bool {
	if !strings.HasPrefix(target, targetPrefix) || len(target) > maxTarget {
		return false
	}
	rest := target[len(targetPrefix):]
	start := 0 // index of the current segment's first byte
	for i := 0; i <= len(rest); i++ {
		if i == len(rest) || rest[i] == '/' {
			if i == start || !isLowerAlnum(rest[i-1]) {
				return false
			}
			start = i + 1
			continue
		}
		c := rest[i]
		switch {
		case i == start:
			if !(c >= 'a' && c <= 'z') {
				return false
			}
		case c == '_' || c == '-':
			if !isLowerAlnum(rest[i-1]) {
				return false
			}
		case !isLowerAlnum(c):
			return false
		}
	}
	return true
}

func isLowerAlnum(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= '0' && c <= '9'
}

// validName accepts identifier bytes only, so a name cannot carry spaces or
// symbols that imitate the verified mark in rendered output.
func validName(s string, lo, hi int) bool {
	if !sized(s, lo, hi) {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

func validFilter(filter string) bool {
	if filter == "" {
		return true
	}
	pairs := strings.Split(filter, ",")
	if len(pairs) > maxFilterPairs {
		return false
	}
	for _, pair := range pairs {
		key, value, ok := strings.Cut(pair, "=")
		if !ok || !validName(key, 1, maxName) || !sized(value, 1, maxName) || strings.Contains(value, "=") {
			return false
		}
	}
	return true
}

// validLink accepts only a path, so a click always stays on the dapp's origin.
// "//host" starts with a slash yet resolves to another host. A URL parser
// drops tab, LF and CR and reads a backslash as a slash, so "/\t/host" and
// "/\host" would do the same; control bytes and backslashes are refused.
func validLink(link string) bool {
	if !sized(link, 1, maxLink) || !strings.HasPrefix(link, "/") || strings.HasPrefix(link, "//") {
		return false
	}
	for i := 0; i < len(link); i++ {
		if c := link[i]; c < 0x20 || c == 0x7f || c == '\\' {
			return false
		}
	}
	return true
}
