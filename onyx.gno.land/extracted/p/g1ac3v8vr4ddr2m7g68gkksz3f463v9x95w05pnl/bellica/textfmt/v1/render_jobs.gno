package textfmt

import (
	"strings"
)

// queryCat reads "cat=<category>" from a render query string ("" if absent or unknown).
func QueryCat(q string) string {
	for _, kv := range strings.Split(q, "&") {
		if strings.HasPrefix(kv, "cat=") {
			c := strings.ToLower(kv[4:])
			if InList(c, Categories) {
				return c
			}
		}
	}
	return ""
}

func IndentQuote(s string) string {
	var sb strings.Builder
	for _, l := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		sb.WriteString("  " + l + "\n")
	}
	return sb.String()
}

func OrDash(s string) string {
	if s == "" {
		return "–"
	}
	return s
}
