// Package core holds the shared Remix Lab contracts: error categories, roles,
// inert view records and the small read interfaces that blocks and adapters
// implement.
//
// Nothing in this package holds state. View records are plain values that
// never alias a block's internal storage, so returning them from a realm does
// not hand out mutation capability.
package core

import (
	"errors"
	"strings"
	"unicode/utf8"
)

// ViewSchemaVersion is the version of the view/action shapes defined here.
// Bump it whenever an exported view struct changes shape.
const ViewSchemaVersion = 1

// Error categories. Blocks wrap these so that clients can classify failures
// by prefix without parsing free-form text.
var (
	ErrUnauthorized  = errors.New("remix: unauthorized")
	ErrNotFound      = errors.New("remix: not found")
	ErrInvalidInput  = errors.New("remix: invalid input")
	ErrLimitExceeded = errors.New("remix: limit exceeded")
	ErrInvalidState  = errors.New("remix: invalid state")
	ErrConflict      = errors.New("remix: conflict")
)

// Errorf returns an error whose message starts with the category's message,
// e.g. "remix: invalid input: title is empty".
func Errorf(category error, detail string) error {
	return errors.New(category.Error() + ": " + detail)
}

// Is reports whether err belongs to category.
func Is(err, category error) bool {
	if err == nil || category == nil {
		return false
	}
	msg := err.Error()
	cat := category.Error()
	return msg == cat || strings.HasPrefix(msg, cat+": ")
}

// Role is an address's standing inside a membership set. Roles are ordered:
// a higher role satisfies any requirement for a lower one.
type Role int

const (
	RoleNone Role = iota
	RoleMember
	RoleReviewer
	RoleOwner
)

func (r Role) String() string {
	switch r {
	case RoleNone:
		return "none"
	case RoleMember:
		return "member"
	case RoleReviewer:
		return "reviewer"
	case RoleOwner:
		return "owner"
	}
	return "unknown"
}

// Valid reports whether r is one of the defined roles.
func (r Role) Valid() bool {
	return r >= RoleNone && r <= RoleOwner
}

// AtLeast reports whether r satisfies a requirement of min.
func (r Role) AtLeast(min Role) bool {
	return r >= min
}

// ParseRole converts the canonical role name to a Role.
func ParseRole(s string) (Role, error) {
	switch s {
	case "none":
		return RoleNone, nil
	case "member":
		return RoleMember, nil
	case "reviewer":
		return RoleReviewer, nil
	case "owner":
		return RoleOwner, nil
	}
	return RoleNone, Errorf(ErrInvalidInput, "unknown role")
}

// CheckText validates user-supplied text: valid UTF-8, between minBytes and
// maxBytes long, not blank when minBytes > 0, and free of control
// characters (other than newline when multiline is set) and of invisible or
// direction-changing format characters (see IsHiddenFormat). It does not
// escape; rendering is the render block's job.
func CheckText(field, s string, minBytes, maxBytes int, multiline bool) error {
	if len(s) < minBytes || (minBytes > 0 && strings.TrimSpace(s) == "") {
		if minBytes == 1 || len(s) >= minBytes {
			return Errorf(ErrInvalidInput, field+" is required")
		}
		return Errorf(ErrInvalidInput, field+" is too short")
	}
	if len(s) > maxBytes {
		return Errorf(ErrLimitExceeded, field+" is too long")
	}
	if !utf8.ValidString(s) {
		return Errorf(ErrInvalidInput, field+" is not valid UTF-8")
	}
	for _, r := range s {
		if r == '\n' && multiline {
			continue
		}
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029 {
			return Errorf(ErrInvalidInput, field+" contains control characters")
		}
		if IsHiddenFormat(r) {
			return Errorf(ErrInvalidInput, field+" contains invisible or direction-changing characters")
		}
	}
	return nil
}

// IsHiddenFormat reports whether r is an invisible or direction-changing
// format character that could make text display differently from its
// content: soft hyphen, Arabic letter mark, Mongolian vowel separator,
// zero-width space, LRM/RLM, bidi embeddings, overrides and isolates,
// invisible operators, the byte order mark and interlinear annotations.
// ZWNJ and ZWJ (U+200C, U+200D) are allowed because several scripts and
// emoji sequences need them.
func IsHiddenFormat(r rune) bool {
	switch {
	case r == 0x00ad, r == 0x061c, r == 0x180e, r == 0x200b, r == 0x200e, r == 0x200f, r == 0xfeff:
		return true
	case r >= 0x202a && r <= 0x202e:
		return true
	case r >= 0x2060 && r <= 0x206f:
		return true
	case r >= 0xfff9 && r <= 0xfffb:
		return true
	}
	return false
}
