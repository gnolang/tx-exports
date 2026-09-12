package oracle

// Grade is the trust level of a Quote.
//
// None: missing, stale, or error — must not drive any protocol action.
// Informational: a price exists (manual or DEX TWAP) — UI only, not liquidation.
// Oracle: reserved for a future credit-grade feed. This package does not
// assign Oracle in v1; RequireAtLeast(Oracle) therefore fail-closes.
type Grade int

const (
	GradeNone Grade = iota
	GradeInformational
	GradeOracle
)

func (g Grade) String() string {
	switch g {
	case GradeNone:
		return "none"
	case GradeInformational:
		return "informational"
	case GradeOracle:
		return "oracle"
	default:
		return "invalid"
	}
}

func (g Grade) Valid() bool {
	return g == GradeNone || g == GradeInformational || g == GradeOracle
}
