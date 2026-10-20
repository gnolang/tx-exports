package game32

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// jsonStr returns s as a quoted, escaped JSON string (game28 concatenated raw
// user strings into JSON, so a guild name with a quote broke every reader).
func jsonStr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				b.WriteByte("0123456789abcdef"[c>>4])
				b.WriteByte("0123456789abcdef"[c&0xf])
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// sanitizeName trims and strips control characters from a display name.
func sanitizeName(s string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(s) {
		if r < 0x20 || r == 0x7f {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// isSafeId reports whether s is a short [a-z0-9_.-] identifier.
func isSafeId(s string, maxLen int) bool {
	if s == "" || len(s) > maxLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

func isHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// parseStringRows parses a JSON array of arrays of strings, e.g.
// [["g1..","grin","10"],["g1..","joy","4"]]. Numbers are accepted unquoted.
// Panics on malformed input.
func parseStringRows(s string) [][]string {
	p := &jparser{s: s}
	p.ws()
	p.expect('[')
	var rows [][]string
	p.ws()
	if p.peek() == ']' {
		p.i++
		return rows
	}
	for {
		p.ws()
		p.expect('[')
		var row []string
		p.ws()
		if p.peek() == ']' {
			p.i++
		} else {
			for {
				p.ws()
				row = append(row, p.value())
				p.ws()
				if p.peek() == ',' {
					p.i++
					continue
				}
				p.expect(']')
				break
			}
		}
		rows = append(rows, row)
		p.ws()
		if p.peek() == ',' {
			p.i++
			continue
		}
		p.expect(']')
		break
	}
	p.ws()
	if p.i != len(p.s) {
		panic("invalid JSON: trailing data")
	}
	return rows
}

// parseStringList parses ["a","b",...].
func parseStringList(s string) []string {
	rows := parseStringRows("[" + s + "]")
	if len(rows) != 1 {
		panic("invalid JSON list")
	}
	return rows[0]
}

type jparser struct {
	s string
	i int
}

func (p *jparser) peek() byte {
	if p.i >= len(p.s) {
		panic("invalid JSON: unexpected end")
	}
	return p.s[p.i]
}

func (p *jparser) ws() {
	for p.i < len(p.s) && (p.s[p.i] == ' ' || p.s[p.i] == '\n' || p.s[p.i] == '\t' || p.s[p.i] == '\r') {
		p.i++
	}
}

func (p *jparser) expect(c byte) {
	if p.peek() != c {
		panic("invalid JSON: expected " + string(c) + " at " + strconv.Itoa(p.i))
	}
	p.i++
}

func (p *jparser) value() string {
	if p.peek() != '"' {
		st := p.i
		for p.i < len(p.s) && (p.s[p.i] >= '0' && p.s[p.i] <= '9' || p.s[p.i] == '-') {
			p.i++
		}
		if st == p.i {
			panic("invalid JSON: expected string or number at " + strconv.Itoa(st))
		}
		return p.s[st:p.i]
	}
	p.i++
	var b strings.Builder
	for {
		c := p.peek()
		p.i++
		if c == '"' {
			return b.String()
		}
		if c == '\\' {
			e := p.peek()
			p.i++
			switch e {
			case '"', '\\', '/':
				b.WriteByte(e)
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			default:
				panic("invalid JSON escape")
			}
			continue
		}
		b.WriteByte(c)
	}
}

// ── avl uint helpers ─────────────────────────────────────────────────────────

func getU(t *avl.Tree, key string) uint64 {
	if !t.Has(key) {
		return 0
	}
	v, _ := strconv.ParseUint(t.Get(key).(string), 10, 64)
	return v
}

func setU(t *avl.Tree, key string, v uint64) {
	t.Set(key, strconv.FormatUint(v, 10))
}

// addU adds d to a stored counter; panics instead of wrapping on overflow.
func addU(t *avl.Tree, key string, d uint64) uint64 {
	old := getU(t, key)
	v := old + d
	if v < old {
		panic("math overflow")
	}
	setU(t, key, v)
	return v
}

func balOf(addr, coin string) uint64 { return getU(&balances, addr+":"+coin) }

func creditBal(addr, coin string, amt uint64) {
	if amt > 0 {
		addU(&balances, addr+":"+coin, amt)
	}
}

func debitBal(addr, coin string, amt uint64) {
	have := balOf(addr, coin)
	if have < amt {
		panic("insufficient " + coin + ": need " + strconv.FormatUint(amt, 10) + " have " + strconv.FormatUint(have, 10))
	}
	setU(&balances, addr+":"+coin, have-amt)
}
