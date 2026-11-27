package verdict

import (
	"strconv"
	"strings"

	pm "gno.land/p/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/parimutuel"
)

// MarketsJSON returns up to limit markets as a JSON array, newest first,
// skipping the first offset. Built for frontends and bots, read it with
// the vm/qeval_json query: "<pkgpath>.MarketsJSON(0, 50)".
func MarketsJSON(offset, limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	var sb strings.Builder
	sb.WriteString("[")
	i, n := 0, 0
	markets.ReverseIterate("", "", func(_ string, v any) bool {
		if i < offset {
			i++
			return false
		}
		if n > 0 {
			sb.WriteString(",")
		}
		writeMarket(&sb, v.(*Market))
		n++
		return n >= limit
	})
	sb.WriteString("]")
	return sb.String()
}

// MarketJSON returns one market as a JSON object, or "null" if not found.
func MarketJSON(id int) string {
	v := markets.Get(idKey(id))
	if v == nil {
		return "null"
	}
	var sb strings.Builder
	writeMarket(&sb, v.(*Market))
	return sb.String()
}

// UserJSON returns addr's record and positions as JSON.
func UserJSON(addr address) string {
	var sb strings.Builder
	sb.WriteString(`{"address":` + jsonStr(addr.String()))
	if v := stats.Get(addr.String()); v != nil {
		s := v.(*Stats)
		sb.WriteString(`,"wagered":` + i64(s.Wagered) + `,"returned":` + i64(s.Returned) +
			`,"profit":` + i64(s.Profit()) + `,"bets":` + strconv.Itoa(s.Bets) + `,"wins":` + strconv.Itoa(s.Wins))
	}
	sb.WriteString(`,"positions":[`)
	n := 0
	markets.ReverseIterate("", "", func(_ string, v any) bool {
		m := v.(*Market)
		pos := m.Pool.Position(addr)
		if pos.Total() == 0 {
			return false
		}
		if n > 0 {
			sb.WriteString(",")
		}
		claimable := int64(0)
		if m.Pool.Outcome() != pm.Pending {
			claimable = m.Pool.Payout(addr)
		}
		sb.WriteString(`{"id":` + strconv.Itoa(m.ID) + `,"yes":` + i64(pos.Yes) + `,"no":` + i64(pos.No) +
			`,"claimed":` + strconv.FormatBool(pos.Claimed) + `,"claimable":` + i64(claimable) + `}`)
		n++
		return n >= 100
	})
	sb.WriteString("]}")
	return sb.String()
}

// LeaderboardJSON returns the top forecasters by realized profit.
func LeaderboardJSON(limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	list := []lbEntry{}
	stats.Iterate("", "", func(k string, v any) bool {
		list = append(list, lbEntry{k, v.(*Stats)})
		return false
	})
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j].s.Profit() > list[j-1].s.Profit(); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
	var sb strings.Builder
	sb.WriteString("[")
	for i, e := range list {
		if i >= limit {
			break
		}
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"address":` + jsonStr(e.who) + `,"profit":` + i64(e.s.Profit()) +
			`,"wagered":` + i64(e.s.Wagered) + `,"bets":` + strconv.Itoa(e.s.Bets) + `,"wins":` + strconv.Itoa(e.s.Wins) + `}`)
	}
	sb.WriteString("]")
	return sb.String()
}

func writeMarket(sb *strings.Builder, m *Market) {
	p := m.Pool
	kind := "community"
	if m.Kind == KindGovDAO {
		kind = "govdao"
	}
	sb.WriteString(`{"id":` + strconv.Itoa(m.ID) +
		`,"kind":` + jsonStr(kind) +
		`,"question":` + jsonStr(m.Question) +
		`,"creator":` + jsonStr(m.Creator.String()) +
		`,"proposalId":` + i64(m.ProposalID) +
		`,"createdAt":` + i64(m.CreatedAt.Unix()) +
		`,"closeAt":` + unixOrZero(m) +
		`,"resolveBy":` + i64(m.ResolveBy.Unix()) +
		`,"resolvedAt":` + resolvedAt(m) +
		`,"outcome":` + jsonStr(p.Outcome().String()) +
		`,"note":` + jsonStr(m.Note) +
		`,"yes":` + i64(p.YesStake()) +
		`,"no":` + i64(p.NoStake()) +
		`,"yesBps":` + i64(p.YesBps()) +
		`,"multYes":` + i64(p.Multiplier(pm.Yes)) +
		`,"multNo":` + i64(p.Multiplier(pm.No)) +
		`,"bettors":` + strconv.Itoa(p.Bettors()) +
		`,"feeBps":` + i64(p.FeeBps()) + `}`)
}

func unixOrZero(m *Market) string {
	if m.Kind == KindGovDAO {
		return "0"
	}
	return i64(m.CloseAt.Unix())
}

func resolvedAt(m *Market) string {
	if m.ResolvedAt.IsZero() {
		return "0"
	}
	return i64(m.ResolvedAt.Unix())
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }

// jsonStr encodes s as a JSON string. Non-ASCII runes are escaped as \uXXXX
// so the output is plain ASCII and safe everywhere.
func jsonStr(s string) string {
	var sb strings.Builder
	sb.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			sb.WriteString(`\"`)
		case r == '\\':
			sb.WriteString(`\\`)
		case r == '\n':
			sb.WriteString(`\n`)
		case r == '\r':
			sb.WriteString(`\r`)
		case r == '\t':
			sb.WriteString(`\t`)
		case r < 0x20 || r > 0x7e:
			if r > 0xffff {
				// encode as a UTF-16 surrogate pair
				r -= 0x10000
				sb.WriteString(u4(0xd800 + (r >> 10)))
				sb.WriteString(u4(0xdc00 + (r & 0x3ff)))
			} else {
				sb.WriteString(u4(r))
			}
		default:
			sb.WriteRune(r)
		}
	}
	sb.WriteByte('"')
	return sb.String()
}

func u4(r rune) string {
	h := strconv.FormatInt(int64(r), 16)
	for len(h) < 4 {
		h = "0" + h
	}
	return `\u` + h
}
