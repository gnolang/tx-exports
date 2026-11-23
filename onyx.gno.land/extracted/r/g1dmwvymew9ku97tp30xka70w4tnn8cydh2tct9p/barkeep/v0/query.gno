package barkeep

import (
	"strconv"
	"time"

	"gno.land/p/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/renown/v0"
	"gno.land/r/sys/users"
)

// breakdown is the score of one address at one instant, in milli-points.
type breakdown struct {
	total     int64
	base      int64
	cats      [renown.NumCategories]int64
	active    int
	identity  int64
	maturity  int64
	diversity int64
}

func hasName(addr address) bool {
	return users.ResolveAddress(addr) != nil
}

// computeScore applies the Barkeep formula:
//
//	Score = M_identity * M_maturity * M_diversity * sum_s(w_s * decay(bucket_s))
func computeScore(addr address, p *profile, now int64) breakdown {
	var r breakdown
	r.identity = renown.Identity(hasName(addr), params)
	if p == nil {
		r.maturity, r.diversity = params.MaturityStart, renown.Permille
		return r
	}
	for _, bk := range p.buckets {
		s := sourceByID(bk.src)
		if s == nil {
			continue
		}
		w := s.effectiveWeight()
		if w == 0 {
			continue
		}
		v := renown.Weighted(bk.value(s, now), w)
		ci := renown.CategoryIndex(s.category)
		r.cats[ci] = renown.SatAdd(r.cats[ci], v)
		r.base = renown.SatAdd(r.base, v)
	}
	for _, c := range r.cats {
		if c >= renown.Milli { // a category counts once it holds a whole point
			r.active++
		}
	}
	r.maturity = renown.Maturity(p.firstSeen, now, params)
	r.diversity = renown.Diversity(r.active, params)
	r.total = renown.Composite(r.base, r.identity, r.maturity, r.diversity)
	return r
}

func now() int64 { return time.Now().Unix() }

// ScoreOf returns the composite score of addr in whole points.
func ScoreOf(addr address) int64 {
	return renown.ToPoints(computeScore(addr, profileOf(addr), now()).total)
}

// CategoryScoreOf returns the weighted, decayed points addr holds in one
// category, before multipliers. Unknown categories return 0.
func CategoryScoreOf(addr address, category string) int64 {
	ci := renown.CategoryIndex(category)
	if ci < 0 {
		return 0
	}
	return renown.ToPoints(computeScore(addr, profileOf(addr), now()).cats[ci])
}

// SourceScoreOf returns the decayed, unweighted points addr holds from one
// source, so unverified sources are visible too.
func SourceScoreOf(addr address, path string) int64 {
	p, s := profileOf(addr), sourceByPath(path)
	if p == nil || s == nil {
		return 0
	}
	for _, bk := range p.buckets {
		if bk.src == s.id {
			return renown.ToPoints(bk.value(s, now()))
		}
	}
	return 0
}

// TierOf returns the tier name of addr.
func TierOf(addr address) string {
	return renown.TierOf(ScoreOf(addr))
}

// HasMinScore reports whether addr has at least min whole points. Consumer
// realms gate on it: if !barkeep.HasMinScore(caller, 100) { panic(...) }.
func HasMinScore(addr address, min int64) bool {
	return ScoreOf(addr) >= min
}

// HasMinCategoryScore reports whether addr has at least min weighted points
// in one category.
func HasMinCategoryScore(addr address, category string, min int64) bool {
	return CategoryScoreOf(addr, category) >= min
}

// IsPaused reports whether every attestation is paused.
func IsPaused() bool { return pausedAll }

// SourceTier returns the tier of a source, or "" when unknown.
func SourceTier(path string) string {
	if s := sourceByPath(path); s != nil {
		return s.tier
	}
	return ""
}

// ranked is one leaderboard row.
type ranked struct {
	addr  address
	score int64 // milli-points
}

// leaderboard recomputes the cached top entries at now, sorted by score
// descending, then address for stability.
func leaderboard(t int64) []ranked {
	rows := make([]ranked, 0, len(top))
	for _, e := range top {
		s := computeScore(e.addr, profileOf(e.addr), t).total
		if s >= renown.Milli {
			rows = append(rows, ranked{addr: e.addr, score: s})
		}
	}
	for i := 1; i < len(rows); i++ {
		for j := i; j > 0 && rankedBefore(rows[j], rows[j-1]); j-- {
			rows[j], rows[j-1] = rows[j-1], rows[j]
		}
	}
	return rows
}

func rankedBefore(a, b ranked) bool {
	if a.score != b.score {
		return a.score > b.score
	}
	return a.addr < b.addr
}

func page(n, offset, limit int) (int, int) {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > MaxPageLimit {
		limit = MaxPageLimit
	}
	if offset > n {
		offset = n
	}
	end := offset + limit
	if end > n {
		end = n
	}
	return offset, end
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// milliStr formats milli-points or permille as a decimal with 3 digits.
func milliStr(v int64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	frac := itoa(v % 1000)
	for len(frac) < 3 {
		frac = "0" + frac
	}
	s := itoa(v/1000) + "." + frac
	if neg {
		return "-" + s
	}
	return s
}
