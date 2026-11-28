package rules

import (
	"errors"
	"strconv"
	"strings"
)

// ErrBadMatch is returned for a malformed match string.
var ErrBadMatch = errors.New("rules: bad match string")

// ParseMapKey parses "24x24s7d6".
func ParseMapKey(k string) (Map, error) {
	x := strings.Index(k, "x")
	s := strings.Index(k, "s")
	d := strings.Index(k, "d")
	if x < 1 || s < x+2 || d < s+2 || d == len(k)-1 {
		return Map{}, ErrBadMatch
	}
	w, e1 := strconv.Atoi(k[:x])
	h, e2 := strconv.Atoi(k[x+1 : s])
	seed, e3 := strconv.ParseUint(k[s+1:d], 10, 32)
	den, e4 := strconv.Atoi(k[d+1:])
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
		return Map{}, ErrBadMatch
	}
	if w%2 != 0 || h%2 != 0 || w < MinSize || h < MinSize || w > MaxSize || h > MaxSize || den < 0 || den > w*h/8 {
		return Map{}, ErrBadMatch
	}
	return NewMap(w, h, uint32(seed), den), nil
}

// Decode splits a match string into its map and move symbols.
func Decode(match string) (Map, []byte, error) {
	parts := strings.Split(match, ".")
	if len(parts) != 3 || parts[0] != "v1" {
		return Map{}, nil, ErrBadMatch
	}
	m, err := ParseMapKey(parts[1])
	if err != nil {
		return Map{}, nil, err
	}
	mv := []byte(parts[2])
	for _, c := range mv {
		if c < 'a' || c > 'y' {
			return Map{}, nil, ErrBadMatch
		}
	}
	return m, mv, nil
}

// ReplayTo replays a match string up to turn t (all turns if t < 0) and
// returns the game at that point. It fails if the string has moves after
// the game ended.
func ReplayTo(match string, t int) (*Game, error) {
	m, mv, err := Decode(match)
	if err != nil {
		return nil, err
	}
	g := NewGame(m)
	for i, c := range mv {
		if t >= 0 && i >= t {
			break
		}
		if g.Over() {
			return nil, ErrBadMatch
		}
		v := int(c - 'a')
		g.Apply(v/5, v%5)
	}
	return g, nil
}

// Replay replays a whole match string and returns its result.
func Replay(match string) (Result, error) {
	g, err := ReplayTo(match, -1)
	if err != nil {
		return Result{}, err
	}
	return g.Result(), nil
}
