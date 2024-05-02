package gnome

import (
	"regexp"
	"strings"
)

var reSlug = regexp.MustCompile("^[a-zA-Z]+[a-zA-Z0-9-_]*$")

// IsSlug checks if a string is a valid slug.
func IsSlug(s string) bool {
	return reSlug.MatchString(s)
}

// SplitRealmURI splits a Gnoland URI into Realm URI and render path.
func SplitRealmURI(uri string) (realmURI, renderPath string) {
	if uri == "" {
		return
	}

	parts := strings.SplitN(uri, ":", 2)
	realmURI = parts[0]
	if len(parts) > 1 {
		renderPath = parts[1]
	}
	return
}

// JoinRealmURI joins a Realm URI to render paths.
// It is assumed that the first argument is the Realm URI
// and the rest of the arguments are render path elements.
func JoinRealmURI(paths ...string) string {
	count := len(paths)
	if count == 0 {
		return ""
	}

	realmURI := paths[0]
	if count == 1 {
		return realmURI
	}
	return realmURI + ":" + strings.Join(paths[1:], "/")
}

// CutRealmDomain cuts out the Gnoland domain prefix from a URI.
func CutRealmDomain(uri string) string {
	realmPath, _ := strings.CutPrefix(uri, "gno.land")
	return realmPath
}
