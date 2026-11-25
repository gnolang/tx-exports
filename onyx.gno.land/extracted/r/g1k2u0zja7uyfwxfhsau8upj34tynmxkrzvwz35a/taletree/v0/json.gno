package taletree

// JSON read API for web clients. Each function returns one JSON
// document as a string, read with a single `vm/qeval` query:
//
//	gnokey query vm/qeval -data 'gno.land/r/<ns>/taletree/v0.PassageJSON(5)'
//
// Hidden passages (and everything under them) are left out exactly as
// on the Render pages. Every list is bounded.

import (
	"strconv"
	"strings"
	"unicode/utf8"

	"gno.land/p/nt/seqid/v0"
)

const (
	maxPageSize   = 50  // tales per TalesJSON page
	maxTreeNodes  = 300 // passages in a TaleJSON outline
	excerptBytes  = 280 // opening excerpt in TalesJSON
	maxFameJSON   = 50
	maxBardRecent = 20
)

// StatsJSON returns realm totals, limits and the keeper.
func StatsJSON() string {
	var b jsonBuf
	b.open('{')
	b.num("tales", tales.Size())
	b.num("passages", passages.Size())
	b.num("bards", bards.Size())
	b.i64("tipsUgnot", totalTips)
	b.flag("paused", paused)
	b.str("keeper", keeper.Owner().String())
	b.key("limits")
	b.open('{')
	b.num("maxChoices", MaxChoices)
	b.num("maxDepth", MaxDepth)
	b.num("minTitle", MinTitleLen)
	b.num("maxTitle", MaxTitleLen)
	b.num("minChoice", MinChoiceLen)
	b.num("maxChoice", MaxChoiceLen)
	b.num("minBody", MinBodyLen)
	b.num("maxBody", MaxBodyLen)
	b.close('}')
	b.close('}')
	return b.String()
}

// TalesJSON returns one page of tales, newest first. page starts at 1.
func TalesJSON(page, size int) string {
	if page < 1 {
		page = 1
	}
	if size < 1 || size > maxPageSize {
		size = maxPageSize
	}
	var b jsonBuf
	b.open('{')
	b.num("total", tales.Size())
	b.num("page", page)
	b.num("size", size)
	b.key("tales")
	b.open('[')
	tales.ReverseIterateByOffset((page-1)*size, size, func(_ string, v any) bool {
		t := v.(*Tale)
		b.elem()
		b.open('{')
		taleFields(&b, t)
		if root, ok := getPassage(t.Root); ok && !root.Hidden {
			b.str("excerpt", excerpt(root.Body, excerptBytes))
		}
		b.close('}')
		return false
	})
	b.close(']')
	b.close('}')
	return b.String()
}

// TaleJSON returns a tale, its opening passage, its canon and an
// outline of its visible passages (breadth first, no bodies).
func TaleJSON(id int) string {
	t, ok := lookupTale(id)
	if !ok {
		return `{"error":"not_found"}`
	}
	var b jsonBuf
	b.open('{')
	b.key("tale")
	b.open('{')
	taleFields(&b, t)
	b.close('}')
	root, ok := getPassage(t.Root)
	if !ok || root.Hidden {
		b.close('}')
		return b.String()
	}
	b.key("opening")
	b.open('{')
	passageFields(&b, root, true)
	b.close('}')
	b.key("canon")
	canonIDs(&b, t)

	b.key("tree")
	b.open('[')
	queue := []*Passage{root}
	n := 0
	truncated := false
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		if n >= maxTreeNodes {
			truncated = true
			break
		}
		n++
		b.elem()
		b.open('{')
		passageFields(&b, p, false)
		b.close('}')
		queue = append(queue, visibleChildren(p)...)
	}
	b.close(']')
	b.flag("truncated", truncated)
	b.close('}')
	return b.String()
}

// PassageJSON returns a passage with its tale, the path from the
// opening, the choices under it and the tale's canon.
func PassageJSON(id int) string {
	p, ok := lookupPassage(id)
	if !ok {
		return `{"error":"not_found"}`
	}
	t, _ := getTale(p.Tale)
	var b jsonBuf
	b.open('{')
	b.key("tale")
	b.open('{')
	taleFields(&b, t)
	b.close('}')
	if !isVisible(p) {
		b.key("passage")
		b.open('{')
		b.num("id", int(p.ID))
		b.num("tale", int(p.Tale))
		b.flag("hidden", true)
		if p.Hidden && p.HiddenReason != "" {
			b.str("reason", p.HiddenReason)
		}
		b.close('}')
		b.close('}')
		return b.String()
	}
	b.key("passage")
	b.open('{')
	passageFields(&b, p, true)
	b.close('}')

	b.key("path")
	b.open('[')
	for _, a := range ancestors(p) {
		if a == nil || a.ID == p.ID {
			continue
		}
		b.elem()
		b.open('{')
		b.num("id", int(a.ID))
		b.str("choice", a.Choice)
		b.num("depth", a.Depth)
		b.close('}')
	}
	b.close(']')

	b.key("choices")
	b.open('[')
	for _, c := range visibleChildren(p) {
		b.elem()
		b.open('{')
		passageFields(&b, c, false)
		b.close('}')
	}
	b.close(']')
	b.key("canon")
	canonIDs(&b, t)
	b.close('}')
	return b.String()
}

// CanonJSON returns the canon of a tale with full passages.
func CanonJSON(id int) string {
	t, ok := lookupTale(id)
	if !ok {
		return `{"error":"not_found"}`
	}
	var b jsonBuf
	b.open('{')
	b.key("tale")
	b.open('{')
	taleFields(&b, t)
	b.close('}')
	b.key("passages")
	b.open('[')
	for _, p := range canonPath(t) {
		b.elem()
		b.open('{')
		passageFields(&b, p, true)
		b.close('}')
	}
	b.close(']')
	b.close('}')
	return b.String()
}

// FameJSON returns the bards with the most cheers received.
func FameJSON(limit int) string {
	if limit < 1 || limit > maxFameJSON {
		limit = maxFameJSON
	}
	var b jsonBuf
	b.open('{')
	b.num("total", bards.Size())
	b.key("bards")
	b.open('[')
	n := 0
	fame.Iterate("", "", func(_ string, v any) bool {
		bd, ok := getBard(v.(address))
		if !ok {
			return false
		}
		b.elem()
		b.open('{')
		bardFields(&b, bd)
		b.close('}')
		n++
		return n >= limit
	})
	b.close(']')
	b.close('}')
	return b.String()
}

// BardJSON returns a writer's totals and latest visible passages.
func BardJSON(addr string) string {
	a := address(addr)
	if !a.IsValid() {
		return `{"error":"invalid_address"}`
	}
	var b jsonBuf
	b.open('{')
	bd, ok := getBard(a)
	if !ok {
		b.str("addr", a.String())
		b.str("name", bardName(a))
		b.key("bard")
		b.raw("null")
		b.close('}')
		return b.String()
	}
	b.str("addr", a.String())
	b.str("name", bardName(a))
	b.key("bard")
	b.open('{')
	bardFields(&b, bd)
	b.close('}')
	b.key("passages")
	b.open('[')
	n := 0
	bardPassages.ReverseIterate(a.String()+"/", a.String()+"0", func(_ string, v any) bool {
		p, ok := getPassage(v.(seqid.ID))
		if !ok || !isVisible(p) {
			return false
		}
		t, _ := getTale(p.Tale)
		b.elem()
		b.open('{')
		passageFields(&b, p, false)
		b.str("taleTitle", t.Title)
		b.close('}')
		n++
		return n >= maxBardRecent
	})
	b.close(']')
	b.close('}')
	return b.String()
}

// ----- field writers -----

func taleFields(b *jsonBuf, t *Tale) {
	hidden := false
	if root, ok := getPassage(t.Root); !ok || root.Hidden {
		hidden = true
	}
	b.num("id", int(t.ID))
	if hidden {
		b.str("title", "")
	} else {
		b.str("title", t.Title)
	}
	b.str("narrator", t.Narrator.String())
	b.str("narratorName", bardName(t.Narrator))
	b.num("root", int(t.Root))
	b.num("passages", t.Passages)
	b.num("endings", t.Endings)
	b.num("cheers", t.Cheers)
	b.flag("locked", t.Locked)
	b.flag("hidden", hidden)
	b.i64("height", t.Height)
	b.i64("created", t.CreatedAt.Unix())
	b.i64("updated", t.UpdatedAt.Unix())
}

// passageFields writes a visible passage. withBody adds the body.
func passageFields(b *jsonBuf, p *Passage, withBody bool) {
	b.num("id", int(p.ID))
	b.num("tale", int(p.Tale))
	b.num("parent", int(p.Parent))
	b.str("author", p.Author.String())
	b.str("authorName", bardName(p.Author))
	b.str("choice", p.Choice)
	if withBody {
		b.str("body", p.Body)
	}
	b.num("depth", p.Depth)
	b.num("cheers", p.Cheers)
	b.i64("tipsUgnot", p.Tips)
	b.flag("ending", p.Ending)
	b.num("choices", len(visibleChildren(p)))
	b.num("slots", MaxChoices-len(p.Children))
	b.i64("height", p.Height)
	b.i64("created", p.CreatedAt.Unix())
}

func bardFields(b *jsonBuf, bd *Bard) {
	b.str("addr", bd.Addr.String())
	b.str("name", bardName(bd.Addr))
	b.num("passages", bd.Passages)
	b.num("tales", bd.Tales)
	b.num("cheers", bd.Cheers)
	b.i64("tipsUgnot", bd.Tips)
}

func canonIDs(b *jsonBuf, t *Tale) {
	b.open('[')
	for _, p := range canonPath(t) {
		b.elem()
		b.raw(strconv.Itoa(int(p.ID)))
	}
	b.close(']')
}

func lookupTale(id int) (*Tale, bool) {
	if id <= 0 {
		return nil, false
	}
	return getTale(seqidOf(id))
}

func lookupPassage(id int) (*Passage, bool) {
	if id <= 0 {
		return nil, false
	}
	return getPassage(seqidOf(id))
}

// excerpt cuts s to at most max bytes on a rune boundary.
func excerpt(s string, max int) string {
	if len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return strings.TrimSpace(s[:cut]) + "…"
}

// ----- a tiny JSON writer -----

// jsonBuf writes JSON objects and arrays. It tracks whether a comma is
// needed before the next member or element.
type jsonBuf struct {
	sb    strings.Builder
	first bool // nothing written yet in the current container
}

func (b *jsonBuf) String() string { return b.sb.String() }

func (b *jsonBuf) open(c byte) {
	b.sb.WriteByte(c)
	b.first = true
}

func (b *jsonBuf) close(c byte) {
	b.sb.WriteByte(c)
	b.first = false
}

// elem starts an array element.
func (b *jsonBuf) elem() {
	if !b.first {
		b.sb.WriteByte(',')
	}
	b.first = false
}

// key starts an object member.
func (b *jsonBuf) key(k string) {
	b.elem()
	writeJSONString(&b.sb, k)
	b.sb.WriteByte(':')
	b.first = false
}

func (b *jsonBuf) raw(s string) {
	b.sb.WriteString(s)
	b.first = false
}

func (b *jsonBuf) str(k, v string) {
	b.key(k)
	writeJSONString(&b.sb, v)
}

func (b *jsonBuf) num(k string, v int) {
	b.key(k)
	b.sb.WriteString(strconv.Itoa(v))
}

func (b *jsonBuf) i64(k string, v int64) {
	b.key(k)
	b.sb.WriteString(strconv.FormatInt(v, 10))
}

func (b *jsonBuf) flag(k string, v bool) {
	b.key(k)
	b.sb.WriteString(strconv.FormatBool(v))
}

const hexDigits = "0123456789abcdef"

// writeJSONString writes s as a JSON string. Control characters, quotes
// and backslashes are escaped; so are <, > and & (as in Go's
// encoding/json), so the output is also safe to embed in HTML. Invalid
// UTF-8 becomes U+FFFD.
func writeJSONString(sb *strings.Builder, s string) {
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
		case r < 0x20 || r == '<' || r == '>' || r == '&' || r == 0x2028 || r == 0x2029:
			sb.WriteString(`\u`)
			sb.WriteByte(hexDigits[(r>>12)&0xf])
			sb.WriteByte(hexDigits[(r>>8)&0xf])
			sb.WriteByte(hexDigits[(r>>4)&0xf])
			sb.WriteByte(hexDigits[r&0xf])
		default:
			sb.WriteRune(r) // range yields U+FFFD for invalid bytes
		}
	}
	sb.WriteByte('"')
}
