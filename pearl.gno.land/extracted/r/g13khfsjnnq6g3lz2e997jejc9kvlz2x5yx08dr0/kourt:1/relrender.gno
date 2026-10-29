package kourt
import (
	"strconv"
	"strings"
)
func writeRelations(b *strings.Builder, c *Court, claimID uint64) {
	base := "/r/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/kourt:" + c.id + "/"
	sup := writeSupersedes(b, c, claimID, base)
	arg := writeArguments(b, c, claimID, base)
	if sup || arg {
		b.WriteString("\n")
	}
}
func writeSupersedes(b *strings.Builder, c *Court, claimID uint64, base string) bool {
	wrote := false
	if c.supBy != nil {
		p := beClaimKey(claimID)
		n := 0
		c.supBy.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			from := claimIDFromKey(key[len(p):])
			if from == 0 || from > c.nextID || assocTextGone(c, from) {
				return false
			}
			if n == 0 {
				b.WriteString("> **This question was asked again.** It died here " +
					"without an answer and was re-filed as:\n")
			}
			n++
			cs := mustClaim(c, from)
			b.WriteString(">\n> - [" + claimTitleFor(c, cs) + "](" + base +
				strconv.FormatUint(from, 10) + ") — " + claimStatus(cs) + "\n")
			return n >= renderPageSize
		})
		if n > 0 {
			b.WriteString("\n")
			wrote = true
		}
	}
	if c.supOf != nil {
		if v := c.supOf.Get(beClaimKey(claimID)); v != nil {
			e := v.(*supEdge)
			if e.to != 0 && e.to <= c.nextID && !assocTextGone(c, e.to) {
				cs := mustClaim(c, e.to)
				b.WriteString("_Re-files [" + claimTitleFor(c, cs) + "](" + base +
					strconv.FormatUint(e.to, 10) + "), which died unanswered._\n\n")
				wrote = true
			}
		}
	}
	return wrote
}
func writeArguments(b *strings.Builder, c *Court, claimID uint64, base string) bool {
	var out, in strings.Builder
	nOut := writeEdgeSide(&out, c, claimID, base, true)
	nIn := writeEdgeSide(&in, c, claimID, base, false)
	if nOut+nIn == 0 {
		return false
	}
	b.WriteString("## Related claims\n\n")
	b.WriteString("_Anyone may draw these links, and the court does not rule on " +
		"them — they are what readers have asserted, not findings._\n\n")
	if nOut > 0 {
		b.WriteString("This claim says:\n\n")
		b.WriteString(out.String() + "\n")
	}
	if nIn > 0 {
		b.WriteString("Others say about this claim:\n\n")
		b.WriteString(in.String() + "\n")
	}
	return true
}
func writeEdgeSide(b *strings.Builder, c *Court, claimID uint64, base string, outgoing bool) int {
	t := c.assocIn
	if outgoing {
		t = c.assocOut
	}
	if t == nil {
		return 0
	}
	p := beClaimKey(claimID)
	n := 0
	t.Iterate(p, "", func(key string, v any) bool {
		if !strings.HasPrefix(key, p) {
			return true
		}
		e, ok := v.(*assocEdge)
		if !ok {
			return false
		}
		other := claimIDFromKey(key[len(p):])
		if other == 0 || other > c.nextID || assocTextGone(c, other) {
			return false
		}
		verb := "supports"
		if e.stance == assocContests {
			verb = "contests"
		}
		if !outgoing {
			verb += " it"
		}
		n++
		cs := mustClaim(c, other)
		b.WriteString("- " + verb + " [" + claimTitleFor(c, cs) + "](" + base +
			strconv.FormatUint(other, 10) + ")\n")
		return n >= renderPageSize
	})
	return n
}
