package blog

import (
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"regexp"
	"strings"
)

var (
	hostnameRe = regexp.MustCompile(`^(?i)[a-z0-9-]+(\.[a-z0-9-]+)+\.?$`)
	sha256Re   = regexp.MustCompile(`^[a-f0-9]{64}$`)
	slugRe     = regexp.MustCompile(`^[a-z0-9\p{L}]+(?:-[a-z0-9\p{L}]+)*$`)
)

// AssertIsSlug asserts that a URL slug is valid.
func AssertIsSlug(slug string) {
	if !IsSlug(slug) {
		panic("URL slug is not valid")
	}
}

// AssertContentSha256Hash asserts that a hex hash is a valid SHA256 hash.
func AssertIsSha256Hash(hexHash string) {
	if !IsSha256Hash(hexHash) {
		panic("invalid sha256 hash")
	}
}

// AssertIsContentURL asserts that a URL is a valid link to a content.
// URL must have a path to ve valid. Website URLs will fail.
func AssertIsContentURL(url string) {
	if !IsURL(url, true) {
		panic("content URL is not valid, make sure path to content is specified")
	}
}

// AssertTitleIsNotEmpty asserts that a title is not an empty string.
func AssertTitleIsNotEmpty(title string) {
	if strings.TrimSpace(title) == "" {
		panic("title is empty")
	}
}

// AssertContentSha256Hash asserts that the SHA256 hash of a content matches a hash.
func AssertContentSha256Hash(content, hash string) {
	if hash != GetHexSha256Hash(content) {
		panic("content sha256 checksum is not valid")
	}
}

// IsSlug checks if a string is a valid URL slug.
func IsSlug(slug string) bool {
	return slugRe.MatchString(slug)
}

// IsSha256Hash checks is a hex hash is a valid SHA256 hash.
func IsSha256Hash(hexHash string) bool {
	return sha256Re.MatchString(strings.ToLower(hexHash))
}

// IsURL checks if a URL is valid.
// URL path availability can optionally be enforced.
func IsURL(rawURL string, requirePath bool) bool {
	u, err := url.ParseRequestURI(rawURL)
	if err != nil {
		return false
	}

	if requirePath && u.Path == "" || u.Path == "/" {
		return false
	}

	if u.Scheme != "https" && u.Scheme != "http" {
		return false
	}

	hostname := u.Hostname()
	return hostname != "" && hostnameRe.MatchString(hostname)
}

// GetHexSha256Hash returns the hexadecimal encoding of the string's SHA256 hash.
// An empty string is returned when the argument is an empty string.
func GetHexSha256Hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}
