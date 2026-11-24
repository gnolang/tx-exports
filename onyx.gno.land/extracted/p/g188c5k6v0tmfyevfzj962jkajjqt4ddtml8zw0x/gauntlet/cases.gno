package gauntlet

import (
	"errors"
	"strings"
)

// Case is one fixed test: Solve(In) must return exactly Want.
type Case struct {
	In   string
	Want string
}

// Solver is the function a solution exposes.
type Solver func(in string) string

// Judge lets a poster define correctness with code instead of fixed answers.
// Inputs returns fresh inputs for a seed; Check reports whether out is a
// correct answer for in. Checking is usually far cheaper than solving.
type Judge struct {
	Inputs func(seed uint64) []string
	Check  func(in, out string) bool
}

const (
	MaxCases    = 64
	MaxFieldLen = 2048
)

var (
	ErrNoCases     = errors.New("gauntlet: no test cases")
	ErrTooManyCase = errors.New("gauntlet: too many test cases")
	ErrBadCaseLine = errors.New("gauntlet: each case line must be `input => want`")
	ErrFieldTooBig = errors.New("gauntlet: test case too large")
)

// ParseCases reads one case per line in the form `input => want`.
// Inside a field, `\n` is a newline, `\t` a tab and `\\` a backslash.
// Blank lines and lines starting with `#` are ignored.
func ParseCases(src string) ([]Case, error) {
	var out []Case
	for _, line := range strings.Split(src, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		idx := strings.Index(line, " => ")
		if idx < 0 {
			return nil, ErrBadCaseLine
		}
		c := Case{In: Unescape(line[:idx]), Want: Unescape(line[idx+4:])}
		if len(c.In) > MaxFieldLen || len(c.Want) > MaxFieldLen {
			return nil, ErrFieldTooBig
		}
		out = append(out, c)
		if len(out) > MaxCases {
			return nil, ErrTooManyCase
		}
	}
	if len(out) == 0 {
		return nil, ErrNoCases
	}
	return out, nil
}

// Escape makes a value safe to place on one case line.
func Escape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	s = strings.ReplaceAll(s, "\t", `\t`)
	return s
}

// Unescape reverses Escape.
func Unescape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			switch s[i+1] {
			case 'n':
				b.WriteByte('\n')
				i++
				continue
			case 't':
				b.WriteByte('\t')
				i++
				continue
			case '\\':
				b.WriteByte('\\')
				i++
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
