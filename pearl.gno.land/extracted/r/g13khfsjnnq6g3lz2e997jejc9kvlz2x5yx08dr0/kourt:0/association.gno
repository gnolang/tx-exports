package kourt
import (
	"strconv"
	"strings"
	bptree "gno.land/p/nt/bptree/v0"
)
const (
	assocSupports = int8(0)
	assocContests = int8(1)
	maxAssocOut = 32
	maxAssocIn  = 64
	maxAssocInPerAuthor = 4
)
const assocBondDefaultInit = int64(1_000_000)
var assocBondDefault = assocBondDefaultInit
func assocBondFor(c *Court) int64 {
	if c.assocBond > 0 {
		return c.assocBond
	}
	return assocBondDefault
}
func SetAssociationBondDefault(cur realm, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the default association bond")
	}
	if amount < 0 {
		panic("kourtv2: an association bond cannot be negative")
	}
	assocBondDefault = amount
}
func SetCourtAssociationBond(cur realm, courtSlug string, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireActiveMod(ensureMod(c), who)
	if amount < 0 {
		panic("kourtv2: an association bond cannot be negative")
	}
	c.assocBond = amount
}
func AssociationBond(courtSlug string) int64 { return assocBondFor(mustCourt(courtSlug)) }
func AssociationBondDefault() int64 { return assocBondDefault }
const assocBondWindowSecs = int64(14 * 86400)
func mustAssocEdge(c *Court, from, to uint64) *assocEdge {
	if c.assocOut == nil {
		panic("kourtv2: no such association")
	}
	v := c.assocOut.Get(assocKey(from, to))
	if v == nil {
		panic("kourtv2: no such association")
	}
	return v.(*assocEdge)
}
func dropAssocEdge(c *Court, from, to uint64) {
	c.assocOut.Remove(assocKey(from, to))
	c.assocIn.Remove(assocKey(to, from))
}
func burnAssocBond(c *Court, e *assocEdge) {
	amt := e.bond
	e.bond = 0
	c.coin.Burn(c.escrow, amt)
}
func releaseAssocBond(c *Court, e *assocEdge) {
	if e.bond <= 0 {
		return
	}
	amt := e.bond
	e.bond = 0
	c.coin.Transfer(c.escrow, e.author, amt)
}
func ApproveAssociation(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireActiveMod(ensureMod(c), who)
	e := mustAssocEdge(c, from, to)
	if e.bond <= 0 {
		panic("kourtv2: no bond is held on that edge")
	}
	releaseAssocBond(c, e)
}
func DisapproveAssociation(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireActiveMod(ensureMod(c), who)
	e := mustAssocEdge(c, from, to)
	if e.bond <= 0 {
		panic("kourtv2: no bond is held on that edge; remove it instead")
	}
	burnAssocBond(c, e)
	dropAssocEdge(c, from, to)
}
func ClaimAssociationBond(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	e := mustAssocEdge(c, from, to)
	if e.bond <= 0 {
		panic("kourtv2: no bond is held on that edge")
	}
	if e.author != who {
		panic("kourtv2: only the edge's author may take its bond back")
	}
	if nowTime() < e.bondUntil {
		panic("kourtv2: the moderation window on that bond has not closed yet")
	}
	releaseAssocBond(c, e)
}
func pendingIncident(c *Court, claimID uint64) ([]uint64, []uint64) {
	outs, ins := []uint64{}, []uint64{}
	if c.assocOut == nil {
		return outs, ins
	}
	p := beClaimKey(claimID)
	c.assocOut.Iterate(p, "", func(key string, v any) bool {
		if !strings.HasPrefix(key, p) {
			return true
		}
		if e := v.(*assocEdge); e.bond > 0 {
			outs = append(outs, claimIDFromKey(key[8:]))
		}
		return false
	})
	c.assocIn.Iterate(p, "", func(key string, v any) bool {
		if !strings.HasPrefix(key, p) {
			return true
		}
		if e := v.(*assocEdge); e.bond > 0 {
			ins = append(ins, claimIDFromKey(key[8:]))
		}
		return false
	})
	return outs, ins
}
func ApproveAllAssociations(cur realm, courtSlug string, claimID uint64) int {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireActiveMod(ensureMod(c), who)
	mustClaim(c, claimID)
	outs, ins := pendingIncident(c, claimID)
	n := 0
	for _, to := range outs {
		releaseAssocBond(c, mustAssocEdge(c, claimID, to))
		n++
	}
	for _, from := range ins {
		releaseAssocBond(c, mustAssocEdge(c, from, claimID))
		n++
	}
	return n
}
func DisapproveAllAssociations(cur realm, courtSlug string, claimID uint64, reason string) int {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	checkReason(reason)
	mustClaim(c, claimID)
	key := "assocburn:" + strconv.FormatUint(claimID, 10)
	opened := pendingOpenedAt(cm.pending, key)
	fire, _ := approveAction(cm.pending, key, who, reason, cm.m)
	if !fire {
		return 0
	}
	if opened == 0 {
		opened = heightNow()
	}
	outs, ins := pendingIncident(c, claimID)
	n := 0
	for _, to := range outs {
		n += burnIfOlder(c, claimID, to, opened)
	}
	for _, from := range ins {
		n += burnIfOlder(c, from, claimID, opened)
	}
	return n
}
func burnIfOlder(c *Court, from, to uint64, opened int64) int {
	e := mustAssocEdge(c, from, to)
	if e.bond <= 0 || e.at > opened {
		return 0
	}
	burnAssocBond(c, e)
	dropAssocEdge(c, from, to)
	return 1
}
type assocEdge struct {
	bond int64
	bondUntil int64
	stance int8
	author address
	at int64
}
func ensureAssocs(c *Court) {
	if c.assocOut == nil {
		c.assocOut = bptree.NewBPTree32()
	}
	if c.assocIn == nil {
		c.assocIn = bptree.NewBPTree32()
	}
}
func assocKey(a, b uint64) string { return beClaimKey(a) + beClaimKey(b) }
func assocTextGone(c *Court, id uint64) bool {
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, id)
	return clm != nil && (clm.purged || clm.global)
}
func AddAssociation(cur realm, courtSlug string, from, to uint64, stance string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if from == to {
		panic("kourtv2: a claim cannot bear on itself")
	}
	var st int8
	switch stance {
	case "supports":
		st = assocSupports
	case "contests":
		st = assocContests
	default:
		panic("kourtv2: a stance is \"supports\" or \"contests\"")
	}
	f := mustClaim(c, from)
	mustClaim(c, to)
	bond := int64(0)
	if f.author != who && !isActiveMod(ensureMod(c), who) {
		bond = assocBondFor(c)
	}
	ensureAssocs(c)
	k := assocKey(from, to)
	if c.assocOut.Get(k) != nil {
		panic("kourtv2: that edge already exists; remove it to change its stance")
	}
	outN := 0
	c.assocOut.Iterate(beClaimKey(from), "", func(key string, _ any) bool {
		if !strings.HasPrefix(key, beClaimKey(from)) {
			return true
		}
		outN++
		return outN > maxAssocOut
	})
	if outN >= maxAssocOut {
		panic("kourtv2: this claim already asserts " + strconv.Itoa(maxAssocOut) + " associations")
	}
	inN, mine := 0, 0
	c.assocIn.Iterate(beClaimKey(to), "", func(key string, v any) bool {
		if !strings.HasPrefix(key, beClaimKey(to)) {
			return true
		}
		inN++
		if e, ok := v.(*assocEdge); ok && e.author == who {
			mine++
		}
		return false
	})
	if inN >= maxAssocIn {
		panic("kourtv2: that claim already carries " + strconv.Itoa(maxAssocIn) + " associations")
	}
	if mine >= maxAssocInPerAuthor {
		panic("kourtv2: you already hold " + strconv.Itoa(maxAssocInPerAuthor) +
			" associations on that claim")
	}
	if bond > 0 {
		mustSpendable(c, who, bond)
		c.coin.Transfer(who, c.escrow, bond)
	}
	e := &assocEdge{stance: st, author: who, at: heightNow(), bond: bond}
	if bond > 0 {
		e.bondUntil = nowTime() + assocBondWindowSecs
	}
	c.assocOut.Set(k, e)
	c.assocIn.Set(assocKey(to, from), e)
}
func RemoveAssociation(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if c.assocOut == nil {
		panic("kourtv2: no such association")
	}
	v := c.assocOut.Get(assocKey(from, to))
	if v == nil {
		panic("kourtv2: no such association")
	}
	e := v.(*assocEdge)
	requireEdgeRemover(c, e.author, who)
	if e.bond > 0 {
		if e.author == who {
			releaseAssocBond(c, e)
		} else {
			burnAssocBond(c, e)
		}
	}
	dropAssocEdge(c, from, to)
}
func ClaimAssociations(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	mustClaim(c, claimID)
	var b strings.Builder
	b.WriteString("out:")
	if c.assocOut != nil {
		p := beClaimKey(claimID)
		n := 0
		c.assocOut.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			e := v.(*assocEdge)
			other := claimIDFromKey(key[8:])
			if assocTextGone(c, other) {
				return false
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(strconv.FormatUint(other, 10) + ":" + stanceCode(e.stance))
			n++
			return false
		})
	}
	b.WriteString(";in:")
	if c.assocIn != nil {
		p := beClaimKey(claimID)
		n := 0
		c.assocIn.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			e := v.(*assocEdge)
			other := claimIDFromKey(key[8:])
			if assocTextGone(c, other) {
				return false
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(strconv.FormatUint(other, 10) + ":" + stanceCode(e.stance))
			n++
			return false
		})
	}
	return b.String()
}
func stanceCode(s int8) string {
	if s == assocContests {
		return "c"
	}
	return "s"
}
func claimIDFromKey(k string) uint64 {
	if len(k) < 8 {
		return 0
	}
	var id uint64
	for i := 0; i < 8; i++ {
		id = id<<8 | uint64(k[i])
	}
	return id
}
