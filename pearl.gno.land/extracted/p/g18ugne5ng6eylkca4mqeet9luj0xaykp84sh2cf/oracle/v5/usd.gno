package oracle

// UsdScale is micro-USD: 1 USD = 1_000_000. Structural, not a credit param.
const UsdScale int64 = 1_000_000

const SourcePush = "push"

// UsdQuote is a fail-closed USD observation. Not a Uniswap tick.
// v1 never stamps GradeOracle.
type UsdQuote struct {
	symbol     string
	usdMicro   int64
	observedAt int64
	nFresh     int
	grade      Grade
	source     string
	err        string
}

func UsdNone(symbol, reason string) UsdQuote {
	if reason == "" {
		reason = "no quote"
	}
	return UsdQuote{
		symbol: symbol,
		grade:  GradeNone,
		source: SourceNone,
		err:    reason,
	}
}

func UsdInformational(symbol string, usdMicro, observedAt int64, nFresh int) UsdQuote {
	return UsdQuote{
		symbol:     symbol,
		usdMicro:   usdMicro,
		observedAt: observedAt,
		nFresh:     nFresh,
		grade:      GradeInformational,
		source:     SourcePush,
	}
}

func (q UsdQuote) Symbol() string    { return q.symbol }
func (q UsdQuote) UsdMicro() int64   { return q.usdMicro }
func (q UsdQuote) ObservedAt() int64 { return q.observedAt }
func (q UsdQuote) NFresh() int       { return q.nFresh }
func (q UsdQuote) Grade() Grade      { return q.grade }
func (q UsdQuote) Source() string    { return q.source }
func (q UsdQuote) Err() string       { return q.err }

func (q UsdQuote) OK() bool {
	return q.grade != GradeNone && q.err == ""
}

func (q UsdQuote) RequireAtLeast(min Grade) {
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

func RequireUsdCredit(q UsdQuote) {
	q.RequireAtLeast(GradeOracle)
}
