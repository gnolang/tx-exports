package semver

// Version represents a parsed semantic version (major.minor.patch),
// optionally with a pre-release identifier (e.g. "1.2.3-beta").
type Version struct {
	Major      int64
	Minor      int64
	Patch      int64
	PreRelease string // empty means a normal release
}

// Parse parses a version string like "1.2.3" or "1.2.3-beta".
func Parse(s string) Version {
	if s == "" {
		panic("semver: empty version string")
	}

	core := s
	pre := ""
	for i := 0; i < len(s); i++ {
		if s[i] == '-' {
			core = s[:i]
			pre = s[i+1:]
			break
		}
	}

	parts := splitDot(core)
	if len(parts) != 3 {
		panic("semver: version must have exactly 3 dot-separated numeric parts")
	}

	return Version{
		Major:      parseUint(parts[0]),
		Minor:      parseUint(parts[1]),
		Patch:      parseUint(parts[2]),
		PreRelease: pre,
	}
}

func splitDot(s string) []string {
	parts := []string{}
	cur := ""
	for i := 0; i < len(s); i++ {
		if s[i] == '.' {
			parts = append(parts, cur)
			cur = ""
		} else {
			cur += string(s[i])
		}
	}
	parts = append(parts, cur)
	return parts
}

func parseUint(s string) int64 {
	if s == "" {
		panic("semver: empty numeric component")
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			panic("semver: invalid numeric component")
		}
		n = n*10 + int64(c-'0')
	}
	return n
}

// Compare returns -1, 0, or 1 if v is less than, equal to, or greater than other.
// A version without a pre-release is considered greater than the same
// major.minor.patch with a pre-release (matches common semver convention).
func (v Version) Compare(other Version) int {
	if v.Major != other.Major {
		return cmpInt(v.Major, other.Major)
	}
	if v.Minor != other.Minor {
		return cmpInt(v.Minor, other.Minor)
	}
	if v.Patch != other.Patch {
		return cmpInt(v.Patch, other.Patch)
	}
	if v.PreRelease == other.PreRelease {
		return 0
	}
	if v.PreRelease == "" {
		return 1
	}
	if other.PreRelease == "" {
		return -1
	}
	if v.PreRelease < other.PreRelease {
		return -1
	}
	return 1
}

func cmpInt(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

// GreaterThan reports whether v is strictly greater than other.
func (v Version) GreaterThan(other Version) bool {
	return v.Compare(other) > 0
}

// LessThan reports whether v is strictly less than other.
func (v Version) LessThan(other Version) bool {
	return v.Compare(other) < 0
}

// Equal reports whether v and other are the same version.
func (v Version) Equal(other Version) bool {
	return v.Compare(other) == 0
}

// String renders the version back to its canonical string form.
func (v Version) String() string {
	s := itoa(v.Major) + "." + itoa(v.Minor) + "." + itoa(v.Patch)
	if v.PreRelease != "" {
		s += "-" + v.PreRelease
	}
	return s
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
