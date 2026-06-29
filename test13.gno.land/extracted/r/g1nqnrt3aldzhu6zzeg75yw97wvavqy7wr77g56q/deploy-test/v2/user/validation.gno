package user

import (
	"regexp"
	"strconv"
	"strings"
)

// Validation helpers in this file are for value-level checks at public API boundaries.
//
// Add helpers here when they validate a parameter or payload value without
// depending on mutable contract state or call flow. Good examples are address
// format, nickname format, string-map shape, allowed key shape, and page/count limits.
//
// Do not add helpers here when the assertion depends on store contents,
// ownership, permissions, freeze/migration state, uniqueness, or the order of a
// specific operation. Keep those assertions close to the domain flow that owns
// the state transition.
//
// As a rule of thumb: validation.gno owns "is this value shaped correctly?";
// domain files own "is this action allowed right now?".

var reURLLikeNickname = regexp.MustCompile(`(?i)([a-z][a-z0-9+.-]*://|www\.|([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,})`)

// Address assertions.
// Used by user public entry points and batch address query payloads.
func assertIsValidAddress(addr address) {
	if !addr.IsValid() {
		panic("invalid address: " + addr.String())
	}
}

func assertValidAddresses(addrs []address) {
	for _, addr := range addrs {
		assertIsValidAddress(addr)
	}
}

// Nickname assertions.
// Used by create/update/query entry points before touching nickname indexes.
func assertValidNickname(nickname string) {
	if len(nickname) == 0 {
		panic("nickname cannot be empty")
	}

	if len(nickname) > 20 {
		panic("nickname too long (max 20)")
	}

	trimmed := strings.TrimSpace(nickname)
	if len(trimmed) == 0 {
		panic("nickname cannot be only whitespace")
	}

	if nickname != trimmed {
		panic("nickname cannot have leading or trailing whitespace")
	}

	if isURLLikeNickname(nickname) {
		panic("nickname must not be a URL")
	}

	if hasControlChar(nickname) {
		panic("nickname must not contain control characters")
	}
}

func isURLLikeNickname(nickname string) bool {
	return reURLLikeNickname.MatchString(strings.TrimSpace(nickname))
}

// hasControlChar rejects ASCII control bytes, including DEL (0x7f).
func hasControlChar(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 || c == 0x7f {
			return true
		}
	}
	return false
}

// Query limit assertions.
// Used by public list and batch query entry points.
func assertListLimit(field string, count int) {
	if count > listLimit {
		panic(field + " exceeds listLimit (max: " + strconv.Itoa(listLimit) + ")")
	}
}

func assertListPageCount(page int, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 {
		panic("count must be at least 1")
	}
	assertListLimit("count", count)
}
