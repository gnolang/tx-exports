package dao

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

// CutRealmDomain cuts out the Gnoland domain prefix from a URI.
func CutRealmDomain(uri string) string {
	realmPath, _ := strings.CutPrefix(uri, "gno.land")
	return realmPath
}
