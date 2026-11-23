package barkeep

import (
	"chain"
	"strings"
	"time"

	"gno.land/p/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/renown/v0"
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
	if !strings.HasPrefix(path, "gno.land/r/") || sourceIDs.Has(path) {
		return false
	}
	if !renown.ValidCategory(category) || !ValidDesc(desc) {
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

// ValidDesc reports whether desc fits a source description: at most
// MaxDescLen bytes of printable ASCII without the markdown/HTML
// metacharacters [ ] ( ) < > ` | # * _ & and without URLs ("://" or
// "www."), so it cannot form links even before render escaping. Empty is
// allowed.
func ValidDesc(desc string) bool {
	if len(desc) > MaxDescLen {
		return false
	}
	lower := strings.ToLower(desc)
	if strings.Contains(lower, "://") || strings.Contains(lower, "www.") {
		return false
	}
	for i := 0; i < len(desc); i++ {
		c := desc[i]
		if c < 0x20 || c > 0x7e {
			return false
		}
		switch c {
		case '[', ']', '(', ')', '<', '>', '`', '|', '#', '*', '_', '&':
			return false
		}
	}
	return true
}

// Attest credits units to subject on behalf of the calling source realm.
//
// It never panics for ordinary conditions, so Barkeep cannot fail a source
// realm's transaction: it returns false when the caller is not a registered
// realm, the source is revoked or paused, Barkeep is paused, the subject is
// the source itself or invalid, the kind is malformed, or units is outside
// 1..MaxUnitsPerAttest. Attestations from unverified sources are recorded
// on existing profiles but weigh 0 until the source is verified; a source
// with no effective weight cannot create a profile, so an unverified realm
// cannot make signers pay storage for profiles of arbitrary addresses.
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
		if s.effectiveWeight() == 0 {
			return false
		}
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

	updateTop(subject, computeScore(subject, p, now).total, now)
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

// bucketLess ranks buckets: weightless before weighted, then by weighted
// value, then by raw value.
func bucketLess(a, b bucket, now int64) bool {
	wa, va := bucketRank(a, now)
	wb, vb := bucketRank(b, now)
	if (wa > 0) != (wb > 0) {
		return wa == 0
	}
	if xa, xb := renown.Weighted(va, wa), renown.Weighted(vb, wb); xa != xb {
		return xa < xb
	}
	return va < vb
}

// bucketRank returns the effective weight and capped value of b; a bucket
// whose source is gone ranks lowest.
func bucketRank(b bucket, now int64) (int64, int64) {
	s := sourceByID(b.src)
	if s == nil {
		return 0, 0
	}
	return s.effectiveWeight(), b.value(s, now)
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

// updateTop keeps the top-MaxTop addresses by score snapshot. Snapshots go
// stale as points decay, sources are revoked or names are registered. A
// full refresh costs MaxTop score computations (~70M gas on chain, each
// one reads r/sys/users), so the work is bounded per call instead: when a
// newcomer meets a full board, TopRefreshBatch snapshots are refreshed in
// rotation (every entry within MaxTop/TopRefreshBatch newcomers), and the
// eviction candidate is re-scored before it is replaced, so a snapshot
// that is too low never costs a member its slot.
func updateTop(addr address, score, now int64) {
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
	for j := 0; j < TopRefreshBatch; j++ {
		topCursor %= len(top)
		refreshSnap(topCursor, now)
		topCursor++
	}
	// Only a candidate whose snapshot was just recomputed is evicted.
	worst, fresh := worstTop(), -1
	for j := 0; j < TopConfirmMax && worst != fresh && score > top[worst].snap; j++ {
		refreshSnap(worst, now)
		fresh, worst = worst, worstTop()
	}
	if worst == fresh && score > top[worst].snap {
		top[worst] = topEntry{addr: addr, snap: score}
	}
}

func refreshSnap(i int, now int64) {
	top[i].snap = computeScore(top[i].addr, profileOf(top[i].addr), now).total
}

func worstTop() int {
	worst := 0
	for i := range top {
		if top[i].snap < top[worst].snap {
			worst = i
		}
	}
	return worst
}
