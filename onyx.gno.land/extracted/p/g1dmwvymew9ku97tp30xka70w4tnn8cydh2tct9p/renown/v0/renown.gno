// Package renown holds Barkeep's pure scoring math: categories, decay,
// multipliers and tiers. It has no state, no floats and no callbacks, so the
// algorithm is fixed for every version path and any realm can reuse it.
//
// Units: points are stored as milli-points (1 point = 1000 milli-points).
// Multipliers are expressed in permille (1000 = x1.0).
package renown

// Category names. A source realm declares exactly one. There is no
// balance-based category on purpose.
const (
	Governance   = "governance"
	Contribution = "contribution"
	DeFi         = "defi"
	Building     = "building"
	Community    = "community"
)

// NumCategories is the number of known categories.
const NumCategories = 5

var categories = [NumCategories]string{Governance, Contribution, DeFi, Building, Community}

// Categories returns the known categories in a stable order.
func Categories() []string {
	out := make([]string, NumCategories)
	for i, c := range categories {
		out[i] = c
	}
	return out
}

// CategoryIndex returns the stable index of c, or -1 when c is unknown.
func CategoryIndex(c string) int {
	for i, k := range categories {
		if k == c {
			return i
		}
	}
	return -1
}

// ValidCategory reports whether c is a known category.
func ValidCategory(c string) bool {
	return CategoryIndex(c) >= 0
}

// MaxKindLen bounds the length of an attestation kind.
const MaxKindLen = 32

// ValidKind reports whether kind is 1..MaxKindLen chars of [a-z0-9._-].
// The charset keeps kinds safe to print in markdown and JSON.
func ValidKind(kind string) bool {
	if len(kind) == 0 || len(kind) > MaxKindLen {
		return false
	}
	for i := 0; i < len(kind); i++ {
		c := kind[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}
