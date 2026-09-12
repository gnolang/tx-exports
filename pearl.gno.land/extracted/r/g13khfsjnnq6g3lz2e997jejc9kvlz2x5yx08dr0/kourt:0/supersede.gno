package kourt
import (
	"strconv"
	"strings"
	bptree "gno.land/p/nt/bptree/v0"
)
const (
	maxSupIn = 8
	maxSupInPerAuthor = 2
)
type supEdge struct {
	to     uint64
	author address
	at     int64
}
func ensureSup(c *Court) {
	if c.supOf == nil {
		c.supOf = bptree.NewBPTree32()
	}
	if c.supBy == nil {
		c.supBy = bptree.NewBPTree32()
	}
}
func supersedeOrdered(from, to *claimState) bool {
	if from.openedAtTime != 0 && to.openedAtTime != 0 {
		return from.openedAtTime >= to.openedAtTime+deadClaimSecs
	}
	return from.openedAt >= to.openedAt+deadClaimTimeout
}
func SupersedeClaim(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if from == to {
		panic("kourtv2: a claim cannot supersede itself")
	}
	f := mustClaim(c, from)
	t := mustClaim(c, to)
	if f.author != who {
		cm := ensureMod(c)
		if !cm.members.Has(who.String()) {
			panic("kourtv2: only the re-filing claim's author or a court moderator may record it")
		}
		requireActiveMod(cm, who)
	}
	if !t.closed {
		panic("kourtv2: only a claim that died unanswered can be superseded")
	}
	if !supersedeOrdered(f, t) {
		panic("kourtv2: a re-filing must come after the claim it re-files could have died")
	}
	ensureSup(c)
	if c.supOf.Get(beClaimKey(from)) != nil {
		panic("kourtv2: that claim already re-files one; remove that edge first")
	}
	inN, mine := 0, 0
	p := beClaimKey(to)
	c.supBy.Iterate(p, "", func(key string, v any) bool {
		if !strings.HasPrefix(key, p) {
			return true
		}
		inN++
		if e, ok := v.(*supEdge); ok && e.author == who {
			mine++
		}
		return false
	})
	if inN >= maxSupIn {
		panic("kourtv2: that claim has already been re-filed " + strconv.Itoa(maxSupIn) + " times")
	}
	if mine >= maxSupInPerAuthor {
		panic("kourtv2: you already record " + strconv.Itoa(maxSupInPerAuthor) +
			" re-filings of that claim")
	}
	e := &supEdge{to: to, author: who, at: heightNow()}
	c.supOf.Set(beClaimKey(from), e)
	c.supBy.Set(beClaimKey(to)+beClaimKey(from), e)
}
func RemoveSupersede(cur realm, courtSlug string, from uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if c.supOf == nil {
		panic("kourtv2: that claim re-files nothing")
	}
	v := c.supOf.Get(beClaimKey(from))
	if v == nil {
		panic("kourtv2: that claim re-files nothing")
	}
	e := v.(*supEdge)
	requireEdgeRemover(c, e.author, who)
	c.supOf.Remove(beClaimKey(from))
	c.supBy.Remove(beClaimKey(e.to) + beClaimKey(from))
}
func ClaimSupersedes(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	mustClaim(c, claimID)
	var b strings.Builder
	b.WriteString("of:")
	if c.supOf != nil {
		if v := c.supOf.Get(beClaimKey(claimID)); v != nil {
			e := v.(*supEdge)
			if !assocTextGone(c, e.to) {
				b.WriteString(strconv.FormatUint(e.to, 10))
			}
		}
	}
	b.WriteString(";by:")
	if c.supBy != nil {
		p := beClaimKey(claimID)
		n := 0
		c.supBy.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			other := claimIDFromKey(key[8:])
			if assocTextGone(c, other) {
				return false
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(strconv.FormatUint(other, 10))
			n++
			return false
		})
	}
	return b.String()
}
