package oracle

// Quote is a fail-closed price observation. Fields are unexported so callers
// cannot stamp GradeOracle onto a handmade value.
type Quote struct {
	pair       string
	tick       int32
	liquidity  string
	observedAt int64
	windowSec  uint32
	grade      Grade
	source     string
	err        string
}

const (
	SourceNone   = "none"
	SourceManual = "manual"
	SourceGnoswap = "gnoswap"
)

// None returns a Quote that any RequireAtLeast call will reject.
func None(pair, reason string) Quote {
	if reason == "" {
		reason = "no quote"
	}
	return Quote{
		pair:   pair,
		grade:  GradeNone,
		source: SourceNone,
		err:    reason,
	}
}

// Informational returns a non-credit quote. grade is forced to Informational
// even if the caller passes Oracle — v1 never emits credit-grade quotes.
func Informational(pair string, tick int32, liquidity string, observedAt int64, windowSec uint32, source string) Quote {
	if source == "" {
		source = SourceManual
	}
	return Quote{
		pair:       pair,
		tick:       tick,
		liquidity:  liquidity,
		observedAt: observedAt,
		windowSec:  windowSec,
		grade:      GradeInformational,
		source:     source,
	}
}

func (q Quote) Pair() string       { return q.pair }
func (q Quote) Tick() int32        { return q.tick }
func (q Quote) Liquidity() string  { return q.liquidity }
func (q Quote) ObservedAt() int64  { return q.observedAt }
func (q Quote) WindowSec() uint32  { return q.windowSec }
func (q Quote) Grade() Grade       { return q.grade }
func (q Quote) Source() string     { return q.source }
func (q Quote) Err() string        { return q.err }

func (q Quote) OK() bool {
	return q.grade != GradeNone && q.err == ""
}

// RequireAtLeast panics unless q.OK() and q.Grade >= min.
// Lending liquidation must call RequireAtLeast(GradeOracle) — which v1
// cannot satisfy, by construction.
func (q Quote) RequireAtLeast(min Grade) {
	if !min.Valid() || min == GradeNone {
		panic("oracle: invalid minimum grade")
	}
	if q.err != "" {
		panic("oracle: " + q.err)
	}
	if q.grade < min {
		panic("oracle: grade " + q.grade.String() + " below " + min.String())
	}
}

// RequireCredit is RequireAtLeast(GradeOracle).
func RequireCredit(q Quote) {
	q.RequireAtLeast(GradeOracle)
}
