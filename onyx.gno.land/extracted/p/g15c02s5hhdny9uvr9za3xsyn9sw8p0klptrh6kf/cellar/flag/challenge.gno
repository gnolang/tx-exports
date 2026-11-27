package flag

import (
	"errors"
	"strings"
)

// Difficulty grades a challenge. It sets the starting value of the
// challenge on the scoring curve.
type Difficulty int

// Difficulty levels, from a first evening in the cellar to a long night.
const (
	Easy Difficulty = iota + 1
	Medium
	Hard
)

// String returns the human name of d.
func (d Difficulty) String() string {
	switch d {
	case Easy:
		return "Easy"
	case Medium:
		return "Medium"
	case Hard:
		return "Hard"
	}
	return "Unknown"
}

// Valid reports whether d is one of the declared levels.
func (d Difficulty) Valid() bool { return d >= Easy && d <= Hard }

// Info describes a challenge to players and to the hall.
type Info struct {
	Slug       string     // unique, lowercase, 3 to 24 chars of [a-z0-9-]
	Title      string     // display name
	Difficulty Difficulty // starting value on the scoring curve
	Category   string     // the Gno semantic it teaches, e.g. "render"
	Brief      string     // the story a player reads first (markdown)
}

// Challenge is what a challenge realm hands to a hall.
//
// Implementations live in the challenge realm, so their methods run with
// that realm's storage. Captured must be a pure read.
type Challenge interface {
	Info() Info
	Captured(player address) bool
}

// Errors returned by Validate.
var (
	ErrBadSlug       = errors.New("flag: slug must be 3-24 chars of [a-z0-9-]")
	ErrNoTitle       = errors.New("flag: title is required")
	ErrBadDifficulty = errors.New("flag: unknown difficulty")
	ErrNoBrief       = errors.New("flag: brief is required")
)

// Validate checks that info can be listed in a hall.
func (info Info) Validate() error {
	if !validSlug(info.Slug) {
		return ErrBadSlug
	}
	if strings.TrimSpace(info.Title) == "" {
		return ErrNoTitle
	}
	if !info.Difficulty.Valid() {
		return ErrBadDifficulty
	}
	if strings.TrimSpace(info.Brief) == "" {
		return ErrNoBrief
	}
	return nil
}

func validSlug(s string) bool {
	if len(s) < 3 || len(s) > 24 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return s[0] != '-' && s[len(s)-1] != '-'
}
