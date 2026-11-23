// Package barkeep is a cross-realm reputation registry for gno.land.
//
// Registered source realms attest activity with a crossing call:
//
//	barkeep.Attest(cross(cur), subject, "quest.completed", 1)
//
// The source is identified by cur.Previous().PkgPath(), which the VM sets and
// a caller cannot forge. Scores decay over time, are capped per source and
// only count sources an admin has verified. All math lives in
// gno.land/p/<ns>/renown/v0. Reads are non-crossing and return values or
// strings, never pointers into realm state.
package barkeep

import (
	"gno.land/p/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/renown/v0"
	"gno.land/p/nt/avl/v0"
)

// Source tiers.
const (
	TierUnverified = "unverified"
	TierVerified   = "verified"
	TierRevoked    = "revoked"
)

// Limits.
const (
	MaxBuckets   = 32  // sources tracked per profile
	MaxRecent    = 10  // recent attestations kept per profile
	MaxTop       = 50  // leaderboard size
	MaxDescLen   = 140 // source description length, printable ASCII
	MaxAdminLog  = 20  // admin log entries kept on chain
	MaxPageLimit = 50  // largest page served by the JSON readers

	TopRefreshBatch = 2 // leaderboard snapshots refreshed per newcomer on a full board
	TopConfirmMax   = 2 // eviction candidates re-scored before one is replaced
)

type source struct {
	id           int
	path         string
	category     string
	desc         string
	tier         string
	weight       int64 // permille, effective only while verified
	capacity     int64 // milli-points a bucket may hold
	paused       bool
	registeredAt int64
	attestations int64
}

// effectiveWeight is the weight that counts toward scores.
func (s *source) effectiveWeight() int64 {
	if s.tier != TierVerified {
		return 0
	}
	return s.weight
}

type bucket struct {
	src int
	b   renown.Bucket
}

// value is the decayed milli-points of bk at now, clamped to the source's
// current cap so a lowered cap applies at once, not only on the next
// attestation.
func (bk bucket) value(s *source, now int64) int64 {
	return renown.Min(bk.b.At(now, params.HalfLife), s.capacity)
}

type recentEntry struct {
	src   int
	kind  string
	units int64
	ts    int64
}

type profile struct {
	firstSeen    int64 // first attestation from a verified source, 0 if none
	buckets      []bucket
	recent       []recentEntry // oldest first
	attestations int64
}

type topEntry struct {
	addr address
	snap int64 // milli-points when last updated; reads recompute
}

type logEntry struct {
	ts     int64
	height int64
	action string
}

var (
	params = renown.DefaultParams()

	admin        address = "g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p"
	pendingAdmin address
	pausedAll    bool

	sourceIDs     = avl.NewTree() // pkgpath -> int id
	sourcesByID   = avl.NewTree() // padded id -> *source
	nextID        = 1
	verifiedCount int             // sources currently in TierVerified
	profiles      = avl.NewTree() // address string -> *profile

	top          []topEntry
	topCursor    int // next snapshot refreshed by the rolling refresh
	attestations int64
	adminLog     []logEntry
)

func idKey(id int) string {
	s := itoa(int64(id))
	for len(s) < 8 {
		s = "0" + s
	}
	return s
}

func sourceByID(id int) *source {
	if v := sourcesByID.Get(idKey(id)); v != nil {
		return v.(*source)
	}
	return nil
}

func sourceByPath(path string) *source {
	if v := sourceIDs.Get(path); v != nil {
		return sourceByID(v.(int))
	}
	return nil
}

func profileOf(addr address) *profile {
	if v := profiles.Get(addr.String()); v != nil {
		return v.(*profile)
	}
	return nil
}
