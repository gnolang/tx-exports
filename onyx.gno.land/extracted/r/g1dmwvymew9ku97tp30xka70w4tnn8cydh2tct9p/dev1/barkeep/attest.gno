package barkeep

import (
	"chain"
	"strings"
	"time"

	"gno.land/p/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/dev1/renown"
)

// RegisterSource registers the calling code realm as an attestation source
// in one category. Registration is permissionless; new sources start
// unverified with weight 0 until an admin verifies them. It returns false
// when the caller is not a realm, the category or description is invalid,
// or the realm is already registered.
func RegisterSource(cur realm, category, desc string) bool {
	prev := cur.Previous()
	if !prev.IsCode() {
		return false
	}
	path := prev.PkgPath()
	if !strings.Contains(path, "/r/") || sourceIDs.Has(path) {
		return false
	}
	if !renown.ValidCategory(category) || len(desc) > MaxDescLen {
		return false
	}
	s := &source{
		id:           nextID,
		path:         path,
		category:     category,
		desc:         desc,
		tier:         TierUnverified,
		capacity:     params.DefaultCap,
		registeredAt: time.Now().Unix(),
	}
	nextID++
	sourceIDs.Set(path, s.id)
	sourcesByID.Set(idKey(s.id), s)
	chain.Emit("SourceRegistered", "source", path, "category", category, "id", itoa(int64(s.id)))
	return true
}

// Attest credits units to subject on behalf of the calling source realm.
//
// It never panics for ordinary conditions, so Barkeep cannot fail a source
// realm's transaction: it returns false when the caller is not a registered
// realm, the source is revoked or paused, Barkeep is paused, the subject is
// the source itself or invalid, the kind is malformed, or units is outside
// 1..MaxUnitsPerAttest. Attestations from unverified sources are recorded
// but weigh 0 until the source is verified.
func Attest(cur realm, subject address, kind string, units int64) bool {
	prev := cur.Previous()
	if !prev.IsCode() || pausedAll {
		return false
	}
	s := sourceByPath(prev.PkgPath())
	if s == nil || s.paused || s.tier == TierRevoked {
		return false
	}
	if !subject.IsValid() || subject == prev.Address() {
		return false
	}
	if !renown.ValidKind(kind) || units <= 0 || units > params.MaxUnitsPerAttest {
		return false
	}

	now := time.Now().Unix()
	key := subject.String()
	p := profileOf(subject)
	if p == nil {
		p = &profile{}
		profiles.Set(key, p)
	}
	if !p.accrue(s, units*renown.Milli, now) {
		return false
	}
	if p.firstSeen == 0 && s.effectiveWeight() > 0 {
		p.firstSeen = now
	}
	p.pushRecent(recentEntry{src: s.id, kind: kind, units: units, ts: now})
	p.attestations++
	s.attestations++
	attestations++

	updateTop(subject, computeScore(subject, p, now).total)
	chain.Emit("Attested",
		"subject", key,
		"source", s.path,
		"kind", kind,
		"units", itoa(units),
	)
	return true
}

// accrue adds milli-points to the bucket of source s. When the profile
// already holds MaxBuckets sources, the lowest-ranked bucket is replaced
// only if it ranks below the new one, so unverified spam cannot evict
// verified history. It returns false when nothing was stored.
func (p *profile) accrue(s *source, add, now int64) bool {
	for i := range p.buckets {
		if p.buckets[i].src == s.id {
			p.buckets[i].b = p.buckets[i].b.Accrue(add, now, params.HalfLife, s.capacity)
			return true
		}
	}
	nb := bucket{src: s.id, b: renown.Bucket{}.Accrue(add, now, params.HalfLife, s.capacity)}
	if len(p.buckets) < MaxBuckets {
		p.buckets = append(p.buckets, nb)
		return true
	}
	worst := 0
	for i := 1; i < len(p.buckets); i++ {
		if bucketLess(p.buckets[i], p.buckets[worst], now) {
			worst = i
		}
	}
	if !bucketLess(p.buckets[worst], nb, now) {
		return false
	}
	p.buckets[worst] = nb
	return true
}

// bucketLess ranks buckets: weightless before weighted, then by value.
func bucketLess(a, b bucket, now int64) bool {
	wa, wb := bucketWeight(a) > 0, bucketWeight(b) > 0
	if wa != wb {
		return !wa
	}
	return a.b.At(now, params.HalfLife) < b.b.At(now, params.HalfLife)
}

func bucketWeight(b bucket) int64 {
	if s := sourceByID(b.src); s != nil {
		return s.effectiveWeight()
	}
	return 0
}

func (p *profile) pushRecent(e recentEntry) {
	if len(p.recent) < MaxRecent {
		p.recent = append(p.recent, e)
		return
	}
	for i := 1; i < len(p.recent); i++ {
		p.recent[i-1] = p.recent[i]
	}
	p.recent[len(p.recent)-1] = e
}

// updateTop keeps the top-MaxTop addresses by score snapshot.
func updateTop(addr address, score int64) {
	for i := range top {
		if top[i].addr == addr {
			top[i].snap = score
			return
		}
	}
	if score <= 0 {
		return
	}
	if len(top) < MaxTop {
		top = append(top, topEntry{addr: addr, snap: score})
		return
	}
	worst := 0
	for i := 1; i < len(top); i++ {
		if top[i].snap < top[worst].snap {
			worst = i
		}
	}
	if score > top[worst].snap {
		top[worst] = topEntry{addr: addr, snap: score}
	}
}
