package profiles

import (
	"strconv"
	"strings"
)

// ProfileJSON is the profile of an address, or null when it has none yet:
//
//	{"addr","name","rank","gamesPlayed","victoryPoints","createdAt"}
//
// name is the address's name in gno.land/r/sys/users, "" if none.
func ProfileJSON(addr string) string {
	v := profiles.Get(addr)
	if v == nil {
		return "null"
	}
	p := v.(*Profile)
	var b strings.Builder
	writeProfile(&b, p, rankOf(p))
	return b.String()
}

// PlayersJSON is one page of the ranking, best first, count at most
// MaxPage:
//
//	{"total","offset","players":[profile...]}
func PlayersJSON(offset, count int) string {
	if offset < 0 {
		offset = 0
	}
	if count < 0 {
		count = 0
	}
	if count > MaxPage {
		count = MaxPage
	}
	var b strings.Builder
	b.WriteString(`{"total":` + strconv.Itoa(ranking.Size()))
	b.WriteString(`,"offset":` + strconv.Itoa(offset))
	b.WriteString(`,"players":[`)
	i := 0
	ranking.IterateByOffset(offset, count, func(_ string, v any) bool {
		if i > 0 {
			b.WriteByte(',')
		}
		writeProfile(&b, v.(*Profile), offset+i+1)
		i++
		return false
	})
	b.WriteString("]}")
	return b.String()
}

func writeProfile(b *strings.Builder, p *Profile, rank int) {
	b.WriteString(`{"addr":` + quote(p.Addr.String()))
	b.WriteString(`,"name":` + quote(Name(p.Addr)))
	b.WriteString(`,"rank":` + strconv.Itoa(rank))
	b.WriteString(`,"gamesPlayed":` + strconv.Itoa(p.GamesPlayed))
	b.WriteString(`,"victoryPoints":` + strconv.Itoa(p.VictoryPoints))
	b.WriteString(`,"createdAt":` + strconv.FormatInt(p.CreatedAt.Unix(), 10))
	b.WriteByte('}')
}

// quote encodes s as a JSON string.
func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte("0123456789abcdef"[c>>4])
			b.WriteByte("0123456789abcdef"[c&0xf])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
