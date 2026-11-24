package shiplog

// SemVer 2.0.0 (https://semver.org) parsing and precedence, implemented in
// pure Gno inside this realm so the ledger has no external package dependency
// that could be re-published under it.
//
// Names are prefixed with `sv` because a realm file shares one package
// namespace with shiplog.gno.

import (
	"errors"
	"strconv"
	"strings"
)

// svVersion is a parsed semantic version.
type svVersion struct {
	Major      int
	Minor      int
	Patch      int
	Prerelease string // without the leading '-'; empty when absent
	Build      string // without the leading '+'
}

var (
	errSvEmpty     = errors.New("empty version")
	errSvTooLong   = errors.New("version string too long")
	errSvZero      = errors.New("numeric identifier with leading zero")
	errSvParts     = errors.New("version must be major.minor.patch")
	errSvNegative  = errors.New("negative numeric identifier")
	errSvIdent     = errors.New("invalid identifier character")
	errSvEmptyPart = errors.New("empty dot-separated identifier")
)

const svMaxLen = 128

// parseSemver parses "1.4.2", "0.9.0-rc.1", "2.0.0+build.7" and rejects
// anything SemVer calls invalid — notably a leading zero in a numeric part.
func parseSemver(s string) (svVersion, error) {
	var v svVersion
	if s == "" {
		return v, errSvEmpty
	}
	if len(s) > svMaxLen {
		return v, errSvTooLong
	}

	rest := s
	// Build metadata is split first: it may legitimately contain '-' itself.
	if i := strings.IndexByte(rest, '+'); i >= 0 {
		v.Build = rest[i+1:]
		rest = rest[:i]
		if err := svValidateIdentifiers(v.Build, false); err != nil {
			return svVersion{}, err
		}
	}
	if i := strings.IndexByte(rest, '-'); i >= 0 {
		v.Prerelease = rest[i+1:]
		rest = rest[:i]
		if v.Prerelease == "" {
			return svVersion{}, errSvIdent
		}
		if err := svValidateIdentifiers(v.Prerelease, true); err != nil {
			return svVersion{}, err
		}
	}

	parts := strings.Split(rest, ".")
	if len(parts) != 3 {
		return svVersion{}, errSvParts
	}
	nums := [3]int{}
	for i := 0; i < 3; i++ {
		n, err := svParseNumeric(parts[i])
		if err != nil {
			return svVersion{}, err
		}
		nums[i] = n
	}
	v.Major, v.Minor, v.Patch = nums[0], nums[1], nums[2]
	return v, nil
}

func svParseNumeric(s string) (int, error) {
	if s == "" {
		return 0, errSvEmptyPart
	}
	if len(s) > 1 && s[0] == '0' {
		return 0, errSvZero
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			if s[i] == '-' {
				return 0, errSvNegative
			}
			return 0, errSvIdent
		}
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return 0, errSvNegative
	}
	return n, nil
}

func svValidateIdentifiers(s string, noLeadingZero bool) error {
	if s == "" {
		return errSvIdent
	}
	for _, id := range strings.Split(s, ".") {
		if id == "" {
			return errSvEmptyPart
		}
		numeric := true
		for i := 0; i < len(id); i++ {
			c := id[i]
			if !svIsAlnumHyphen(c) {
				return errSvIdent
			}
			if c < '0' || c > '9' {
				numeric = false
			}
		}
		if noLeadingZero && numeric && len(id) > 1 && id[0] == '0' {
			return errSvZero
		}
	}
	return nil
}

func svIsAlnumHyphen(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-'
}

// String renders the version back in canonical form.
func (v svVersion) String() string {
	s := strconv.Itoa(v.Major) + "." + strconv.Itoa(v.Minor) + "." + strconv.Itoa(v.Patch)
	if v.Prerelease != "" {
		s += "-" + v.Prerelease
	}
	if v.Build != "" {
		s += "+" + v.Build
	}
	return s
}

// svCompare returns -1, 0 or +1 as a is lower than, equal to, or higher than b.
// Build metadata is ignored, as SemVer §10 requires.
func svCompare(a, b svVersion) int {
	if c := svCmpInt(a.Major, b.Major); c != 0 {
		return c
	}
	if c := svCmpInt(a.Minor, b.Minor); c != 0 {
		return c
	}
	if c := svCmpInt(a.Patch, b.Patch); c != 0 {
		return c
	}
	return svComparePrerelease(a.Prerelease, b.Prerelease)
}

func svCmpInt(a, b int) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

// svComparePrerelease implements SemVer §11: a prerelease ranks below the
// same version without one; numeric identifiers compare numerically and rank
// below alphanumeric ones.
func svComparePrerelease(a, b string) int {
	if a == b {
		return 0
	}
	if a == "" {
		return 1
	}
	if b == "" {
		return -1
	}
	as := strings.Split(a, ".")
	bs := strings.Split(b, ".")
	for i := 0; i < len(as) && i < len(bs); i++ {
		if c := svCompareIdentifier(as[i], bs[i]); c != 0 {
			return c
		}
	}
	return svCmpInt(len(as), len(bs))
}

func svCompareIdentifier(a, b string) int {
	an, aNum := svAsNumber(a)
	bn, bNum := svAsNumber(b)
	if aNum && bNum {
		return svCmpInt(an, bn)
	}
	if aNum {
		return -1
	}
	if bNum {
		return 1
	}
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

func svAsNumber(s string) (int, bool) {
	if s == "" {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, false
	}
	return n, true
}

// svBumpPrefix classifies the move a -> b as "major", "minor" or "patch";
// empty string means b is not strictly greater than a.
//
// This is the heart of the ledger: the shipment class is *derived* from the
// two version numbers, so a builder cannot label a breaking change as a patch.
func svBumpPrefix(a, b svVersion) string {
	if svCompare(a, b) >= 0 {
		return ""
	}
	if b.Major != a.Major {
		return "major"
	}
	if b.Minor != a.Minor {
		return "minor"
	}
	return "patch"
}