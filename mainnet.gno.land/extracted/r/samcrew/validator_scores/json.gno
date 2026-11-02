package validator_scores

import (
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

const hexDigits = "0123456789abcdef"

// quoteSafe quotes a string the realm validated to need no JSON escaping
// (addresses, dates, hashes, arena names). Concatenation is cheap in gas;
// per-byte loops are not.
func quoteSafe(s string) string { return `"` + s + `"` }

// quoteMoniker quotes a validated moniker (valid UTF-8, no control
// characters): only '"' and '\' need escaping.
func quoteMoniker(s string) string {
	if !strings.ContainsAny(s, `"\`) {
		return `"` + s + `"`
	}
	var b strings.Builder
	writeJSONString(&b, s)
	return b.String()
}

// writeJSONString writes any string as a JSON string. Invalid UTF-8 bytes
// become U+FFFD. It costs gas per rune: use it only for short or unvalidated
// input.
func writeJSONString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			b.WriteString(`\ufffd`)
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte(hexDigits[r>>4])
			b.WriteByte(hexDigits[r&0xf])
		default:
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	b.WriteByte('"')
}

func writeStrings(b *strings.Builder, list []string) {
	b.WriteByte('[')
	for i, s := range list {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(quoteSafe(s))
	}
	b.WriteByte(']')
}

// candidate is a stored line split into its fields. Numbers stay in their
// canonical decimal text, which is valid JSON.
type candidate struct {
	operator    string
	moniker     string
	total       string
	rank        int
	rankText    string
	github      string
	arenaScores string // "s1,...,sN"
}

func decode(line string) candidate {
	f := strings.Split(line, "|")
	rank, _ := strconv.Atoi(f[3])
	return candidate{operator: f[0], moniker: f[1], total: f[2], rank: rank, rankText: f[3], github: f[4], arenaScores: f[5]}
}

type byRank []candidate

func (s byRank) Len() int      { return len(s) }
func (s byRank) Swap(i, j int) { s[i], s[j] = s[j], s[i] }
func (s byRank) Less(i, j int) bool {
	if s[i].rank != s[j].rank {
		return s[i].rank < s[j].rank
	}
	if s[i].moniker != s[j].moniker {
		return s[i].moniker < s[j].moniker
	}
	return s[i].operator < s[j].operator
}

// sortedCandidates lists an edition's candidates by rank, then moniker
// (byte order), then operator.
func sortedCandidates(e *edition) []candidate {
	list := make([]candidate, len(e.lines))
	for i, line := range e.lines {
		list[i] = decode(line)
	}
	sort.Sort(byRank(list))
	return list
}

func latestSealed() *edition {
	for i := len(editions) - 1; i >= 0; i-- {
		if editions[i].sealed {
			return editions[i]
		}
	}
	return nil
}

// scoreFields is `"moniker":M,"total":T,"rank":R,"github":G`, shared by
// both JSON shapes.
func scoreFields(c candidate) string {
	return `"moniker":` + quoteMoniker(c.moniker) + `,"total":` + c.total + `,"rank":` + c.rankText + `,"github":` + c.github
}

func editionJSON(e *edition) string {
	var b strings.Builder
	b.WriteString(`{"number":` + strconv.Itoa(e.number) + `,"computedAt":` + quoteSafe(e.computedAt) +
		`,"scorecardSHA256":` + quoteSafe(e.scorecardSHA256) + `,"arenas":`)
	writeStrings(&b, e.arenas)
	b.WriteString(`,"candidates":[`)
	for i, c := range sortedCandidates(e) {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"operator":` + quoteSafe(c.operator) + `,` + scoreFields(c) + `,"arenaScores":[` + c.arenaScores + `]}`)
	}
	b.WriteString(`]}`)
	return b.String()
}

// LatestJSON returns the latest sealed edition, or "null".
func LatestJSON() string {
	e := latestSealed()
	if e == nil {
		return "null"
	}
	return editionJSON(e)
}

// EditionJSON returns sealed edition n, or "null".
func EditionJSON(n int) string {
	if n < 1 || n > len(editions) || !editions[n-1].sealed {
		return "null"
	}
	return editionJSON(editions[n-1])
}

// CandidateJSON returns the operator's entries across sealed editions, in
// edition order; "entries" is [] for an unknown address.
func CandidateJSON(operator string) string {
	var b strings.Builder
	b.WriteString(`{"operator":`)
	writeJSONString(&b, operator)
	b.WriteString(`,"entries":[`)
	first := true
	for _, e := range editions {
		if !e.sealed {
			continue
		}
		line, ok := e.find(operator)
		if !ok {
			continue
		}
		if !first {
			b.WriteByte(',')
		}
		first = false
		c := decode(line)
		b.WriteString(`{"edition":` + strconv.Itoa(e.number) + `,"computedAt":` + quoteSafe(e.computedAt) + `,` + scoreFields(c) + `,"arenas":`)
		writeStrings(&b, e.arenas)
		b.WriteString(`,"arenaScores":[` + c.arenaScores + `]}`)
	}
	b.WriteString(`]}`)
	return b.String()
}

// OpenEditionJSON returns the open edition (number, scorecard hash and the
// operators already added, in the order added), or "null".
func OpenEditionJSON() string {
	e := openEdition()
	if e == nil {
		return "null"
	}
	var b strings.Builder
	b.WriteString(`{"number":` + strconv.Itoa(e.number) + `,"scorecardSHA256":` + quoteSafe(e.scorecardSHA256) + `,"operators":[`)
	for i, line := range e.lines {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(quoteSafe(line[:operatorLen]))
	}
	b.WriteString(`]}`)
	return b.String()
}
