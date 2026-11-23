package barkeep

import (
	"strings"
	"unicode/utf8"

	"gno.land/p/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/renown/v0"
)

const hexDigits = "0123456789abcdef"

// jsonStr quotes s as a JSON string. It is safe for any byte sequence:
// control bytes, DEL, < > & and U+2028/U+2029 are \u-escaped, and invalid
// UTF-8 becomes U+FFFD, so the output is always valid JSON that can be
// embedded in HTML or JavaScript.
func jsonStr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); {
		c := s[i]
		if c >= utf8.RuneSelf {
			r, size := utf8.DecodeRuneInString(s[i:])
			switch {
			case r == utf8.RuneError && size == 1:
				b.WriteString("\\ufffd")
			case r == ' ':
				b.WriteString("\\u2028")
			case r == ' ':
				b.WriteString("\\u2029")
			default:
				b.WriteString(s[i : i+size])
			}
			i += size
			continue
		}
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString("\\n")
		case c < 0x20 || c == 0x7f || c == '<' || c == '>' || c == '&':
			b.WriteString("\\u00")
			b.WriteByte(hexDigits[c>>4])
			b.WriteByte(hexDigits[c&0xf])
		default:
			b.WriteByte(c)
		}
		i++
	}
	b.WriteByte('"')
	return b.String()
}

// jsonObj builds an object from alternating keys and raw JSON values.
func jsonObj(kv ...string) string {
	var b strings.Builder
	b.WriteByte('{')
	for i := 0; i+1 < len(kv); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsonStr(kv[i]))
		b.WriteByte(':')
		b.WriteString(kv[i+1])
	}
	b.WriteByte('}')
	return b.String()
}

func jsonArr(items []string) string {
	return "[" + strings.Join(items, ",") + "]"
}

func sourceJSON(s *source) string {
	return jsonObj(
		"id", itoa(int64(s.id)),
		"path", jsonStr(s.path),
		"category", jsonStr(s.category),
		"desc", jsonStr(s.desc),
		"tier", jsonStr(s.tier),
		"weight", itoa(s.weight),
		"effectiveWeight", itoa(s.effectiveWeight()),
		"capPoints", itoa(renown.ToPoints(s.capacity)),
		"paused", boolStr(s.paused),
		"registeredAt", itoa(s.registeredAt),
		"attestations", itoa(s.attestations),
	)
}

func sourcePath(id int) string {
	if s := sourceByID(id); s != nil {
		return s.path
	}
	return ""
}

// ProfileJSON returns the full score breakdown of addr as JSON. Point
// values are decimals with three fraction digits.
func ProfileJSON(addr address) string {
	t := now()
	p := profileOf(addr)
	r := computeScore(addr, p, t)
	cats := make([]string, 0, renown.NumCategories)
	for i, c := range renown.Categories() {
		cats = append(cats, jsonStr(c)+":"+milliStr(r.cats[i]))
	}
	var buckets, recent []string
	firstSeen, count := int64(0), int64(0)
	if p != nil {
		firstSeen, count = p.firstSeen, p.attestations
		for _, bk := range p.buckets {
			s := sourceByID(bk.src)
			if s == nil {
				continue
			}
			v := bk.value(s, t)
			buckets = append(buckets, jsonObj(
				"source", jsonStr(s.path),
				"category", jsonStr(s.category),
				"tier", jsonStr(s.tier),
				"points", milliStr(v),
				"weighted", milliStr(renown.Weighted(v, s.effectiveWeight())),
				"lastTs", itoa(bk.b.LastTs),
			))
		}
		for i := len(p.recent) - 1; i >= 0; i-- {
			e := p.recent[i]
			recent = append(recent, jsonObj(
				"source", jsonStr(sourcePath(e.src)),
				"kind", jsonStr(e.kind),
				"units", itoa(e.units),
				"ts", itoa(e.ts),
			))
		}
	}
	score := renown.ToPoints(r.total)
	return jsonObj(
		"address", jsonStr(addr.String()),
		"score", itoa(score),
		"tier", jsonStr(renown.TierOf(score)),
		"total", milliStr(r.total),
		"base", milliStr(r.base),
		"multipliers", jsonObj(
			"identity", milliStr(r.identity),
			"maturity", milliStr(r.maturity),
			"diversity", milliStr(r.diversity),
		),
		"named", boolStr(r.identity > renown.Permille),
		"activeCategories", itoa(int64(r.active)),
		"categories", "{"+strings.Join(cats, ",")+"}",
		"firstSeen", itoa(firstSeen),
		"attestations", itoa(count),
		"buckets", jsonArr(buckets),
		"recent", jsonArr(recent),
		"now", itoa(t),
	)
}

// LeaderboardJSON returns a page of the top-50 leaderboard, recomputed at
// read time. limit is capped at MaxPageLimit.
func LeaderboardJSON(offset, limit int) string {
	t := now()
	rows := leaderboard(t)
	start, end := page(len(rows), offset, limit)
	items := make([]string, 0, end-start)
	for i := start; i < end; i++ {
		score := renown.ToPoints(rows[i].score)
		items = append(items, jsonObj(
			"rank", itoa(int64(i+1)),
			"address", jsonStr(rows[i].addr.String()),
			"score", itoa(score),
			"tier", jsonStr(renown.TierOf(score)),
		))
	}
	return jsonObj(
		"total", itoa(int64(len(rows))),
		"offset", itoa(int64(start)),
		"profiles", itoa(int64(profiles.Size())),
		"attestations", itoa(attestations),
		"items", jsonArr(items),
		"now", itoa(t),
	)
}

// SourcesJSON returns a page of registered sources in registration order.
// limit is capped at MaxPageLimit.
func SourcesJSON(offset, limit int) string {
	n := sourcesByID.Size()
	start, end := page(n, offset, limit)
	items := make([]string, 0, end-start)
	sourcesByID.IterateByOffset(start, end-start, func(_ string, v any) bool {
		items = append(items, sourceJSON(v.(*source)))
		return false
	})
	return jsonObj(
		"total", itoa(int64(n)),
		"offset", itoa(int64(start)),
		"items", jsonArr(items),
	)
}

// ParamsJSON returns the live algorithm parameters.
func ParamsJSON() string {
	p := params
	return jsonObj(
		"halfLifeSeconds", itoa(p.HalfLife),
		"maturityPeriodSeconds", itoa(p.MaturityPeriod),
		"maturityStart", milliStr(p.MaturityStart),
		"identityBonus", milliStr(p.IdentityBonus),
		"diversityStep", milliStr(p.DiversityStep),
		"diversityMax", milliStr(p.DiversityMax),
		"defaultWeight", milliStr(p.DefaultWeight),
		"maxWeight", milliStr(p.MaxWeight),
		"defaultCapPoints", itoa(renown.ToPoints(p.DefaultCap)),
		"maxUnitsPerAttest", itoa(p.MaxUnitsPerAttest),
		"maxBuckets", itoa(MaxBuckets),
		"maxRecent", itoa(MaxRecent),
		"maxTop", itoa(MaxTop),
		"tiers", jsonObj(
			"Regular", itoa(renown.RegularMin),
			"Patron", itoa(renown.PatronMin),
			"Legend", itoa(renown.LegendMin),
		),
		"paused", boolStr(pausedAll),
		"admin", jsonStr(admin.String()),
	)
}
