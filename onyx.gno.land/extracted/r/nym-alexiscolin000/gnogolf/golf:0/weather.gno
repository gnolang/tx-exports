package golf

import (
	"strconv"
	"time"

	"gno.land/p/nym-alexiscolin000/gnogolf/course"
	"gno.land/p/nt/ufmt/v0"
)

// The weather changes every five minutes of chain time, differs from hole to
// hole and is the same for everyone (course.ForecastFor hashes hole and
// period). A round is played in the weather of the period it started in, and
// records it, so anyone can replay it.

// PeriodSeconds is how long one weather lasts.
const PeriodSeconds = 5 * 60

// Period is the weather period of the chain's current block time.
func Period() int64 { return time.Now().Unix() / PeriodSeconds }

// weatherOf is the hole's weather in a period: seeded by its id, so each
// version of a slot has weather of its own.
func weatherOf(e *entry, h *course.Simple, period int64) course.Forecast {
	return course.ForecastFor(e.id, e.world, h, period)
}

// forecastJSON is a forecast as an object, head its first fields if any
// (as `"version":1,`). Zones' air and capped are not printed: only the wind
// has them, always.
func forecastJSON(head string, f course.Forecast) string {
	return "{" + head + `"period":` + strconv.FormatInt(f.Period, 10) + `,"kind":` + jstr(f.Kind) +
		`,"wind":` + jvec(f.Wind) + `,"zones":` + zonesJSON(f.Zones, false) + "}"
}

// Weather is a hole's weather in a period, as JSON: the zones a client draws
// and the chain plays under. Its "gas" is what a commit there spends before
// its first shot (decoding and forecast), counted against the commit's
// budget: a client adds it to its shots' estimate. A future period panics.
func Weather(hole string, period int64) string {
	notAhead(period)
	e := readHole(hole)
	fc := weatherOf(e, e.hole(), period)
	return forecastJSON(versionJSON+`,"gas":`+strconv.FormatInt(fixedGas(e, fc), 10)+",", fc)
}

// notAhead refuses a period still to come. It is no secret (ForecastFor is
// pure): this only keeps reads to the weather a round can be played in.
func notAhead(period int64) {
	if period > Period() {
		panic("golf: that weather has not come yet")
	}
}

// notOver refuses a round's weather two periods or more behind: a round left
// for later cannot be finished days on in the weather it picked.
func notOver(period int64) {
	if period < Period()-1 {
		panic(ufmt.Sprintf("golf: this round's weather (period %d) is over: Reset to play again", period))
	}
}

// playablePeriod checks the period a round starts under: the current one, or
// the one just gone, for a round that ran over the turn of the period.
func playablePeriod(period int64) {
	now := Period()
	if period != now && period != now-1 {
		panic(ufmt.Sprintf("golf: period %d is not the current weather (%d) or the one before", period, now))
	}
}
