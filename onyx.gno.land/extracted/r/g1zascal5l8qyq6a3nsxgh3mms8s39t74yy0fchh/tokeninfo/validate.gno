package tokeninfo

import (
	"chain/runtime"
	"strings"
	"unicode/utf8"

	"gno.land/p/nt/fqname/v0"
)

// parseToken splits a token path like gno.land/r/name/token.SYMBOL into its
// realm path and namespace. Segments are [a-z0-9_-]+ and the symbol is
// [A-Za-z0-9_-], 1 to 32 long, so a valid path is safe to put in a link.
func parseToken(token string) (pkg, ns string, ok bool) {
	if len(token) > maxToken {
		return "", "", false
	}
	pkg, symbol := fqname.Parse(token)
	if len(symbol) < 1 || len(symbol) > 32 || !charsIn(symbol, true) {
		return "", "", false
	}
	prefix := runtime.ChainDomain() + "/r/"
	if !strings.HasPrefix(pkg, prefix) {
		return "", "", false
	}
	segments := strings.Split(pkg[len(prefix):], "/")
	for _, s := range segments {
		if s == "" || !charsIn(s, false) {
			return "", "", false
		}
	}
	return pkg, segments[0], true
}

// charsIn reports whether s has only [a-z0-9_-], plus A-Z when upper is set.
func charsIn(s string, upper bool) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-' || upper && c >= 'A' && c <= 'Z'
		if !ok {
			return false
		}
	}
	return true
}

const (
	maxToken       = 200
	maxDescription = 280 // characters
	maxURL         = 200
	maxReason      = 200
)

// mustText rejects control characters and anything over max characters. The
// stored text is plain; Render escapes it, and apps must escape it too.
func mustText(field, s string, max int) string {
	s = strings.TrimSpace(s)
	if !utf8.ValidString(s) {
		panic("tokeninfo: " + field + " is not valid UTF-8")
	}
	if utf8.RuneCountInString(s) > max {
		panic("tokeninfo: " + field + " is longer than the limit")
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029 {
			panic("tokeninfo: " + field + " has a control character or line break")
		}
	}
	return s
}

func mustDescription(s string) string { return mustText("description", s, maxDescription) }

// mustURL accepts an https URL with a host and no characters that could break
// out of a link or an HTML attribute. Empty clears the field.
func mustURL(field, s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if len(s) > maxURL {
		panic("tokeninfo: " + field + " URL is longer than the limit")
	}
	if !strings.HasPrefix(s, "https://") || len(s) == len("https://") || s[len("https://")] == '/' {
		panic("tokeninfo: " + field + " must be an https:// URL")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c <= ' ' || c >= 0x7f || strings.IndexByte("\"'<>\\`()[]{}|^", c) >= 0 {
			panic("tokeninfo: " + field + " URL has a character that is not allowed")
		}
	}
	return s
}

// mustDiscord accepts only Discord invite links.
func mustDiscord(s string) string {
	s = mustURL("discord", s)
	if s != "" && !strings.HasPrefix(s, "https://discord.gg/") && !strings.HasPrefix(s, "https://discord.com/invite/") {
		panic("tokeninfo: discord must be an invite link (https://discord.gg/...)")
	}
	return s
}

// mustHandle accepts letters, digits and underscores (plus hyphens when
// dash is set), between min and max long. A leading @ is dropped.
func mustHandle(field, s string, min, max int, dash bool) string {
	s = strings.TrimPrefix(strings.TrimSpace(s), "@")
	if s == "" {
		return ""
	}
	if len(s) < min || len(s) > max {
		panic("tokeninfo: " + field + " handle has the wrong length")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || dash && c == '-'
		if !ok {
			panic("tokeninfo: " + field + " handle has a character that is not allowed")
		}
	}
	return s
}

// mustGitHub accepts "owner" or "owner/repo".
func mustGitHub(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	owner, repo, hasRepo := strings.Cut(s, "/")
	owner = mustHandle("github", owner, 1, 39, true)
	if owner == "" || strings.HasPrefix(owner, "-") || strings.HasPrefix(s, "@") {
		panic("tokeninfo: github must be owner or owner/repo")
	}
	if !hasRepo {
		return owner
	}
	if repo == "" || len(repo) > 100 || repo == "." || repo == ".." {
		panic("tokeninfo: github repo name is not valid")
	}
	for i := 0; i < len(repo); i++ {
		c := repo[i]
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == '.'
		if !ok {
			panic("tokeninfo: github repo name has a character that is not allowed")
		}
	}
	return owner + "/" + repo
}
