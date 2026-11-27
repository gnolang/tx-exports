package hall

import (
	"chain"
	"chain/runtime"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
)

// Status is where a challenge stands in the hall.
type Status int

// Challenge statuses.
const (
	Pending Status = iota // enlisted by a community realm, awaiting review
	Listed                // open for claims
	Retired               // closed for claims; past solves still score
)

// String returns the human name of s.
func (s Status) String() string {
	switch s {
	case Pending:
		return "pending"
	case Listed:
		return "listed"
	case Retired:
		return "retired"
	}
	return "unknown"
}

// entry is a challenge as the hall knows it.
type entry struct {
	path       string
	ch         flag.Challenge
	info       flag.Info
	official   bool
	status     Status
	enlistedAt int64
	solvers    []address // claim order; solvers[0] drew first blood
}

// value is what the challenge is worth to each of its solvers right now.
func (e *entry) value() int { return flag.Value(e.info.Difficulty, len(e.solvers)) }

// Enlist registers the challenge ch for the realm that calls it. Call it
// from your challenge realm's init:
//
//	func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
//
// Official challenges are listed at once; community ones wait for review.
func Enlist(cur realm, ch flag.Challenge) {
	caller := cur.Previous()
	path := caller.PkgPath()
	if path == "" || caller.IsEphemeral() {
		panic(ErrNotRealm)
	}
	if ch == nil {
		panic(ErrNilChallenge)
	}
	info := ch.Info()
	if err := info.Validate(); err != nil {
		panic(err)
	}
	if paths.Has(path) {
		panic(ErrAlreadyEnlisted)
	}
	if entries.Has(info.Slug) {
		panic(ErrSlugTaken)
	}

	e := &entry{
		path:       path,
		ch:         ch,
		info:       info,
		status:     Pending,
		enlistedAt: runtime.ChainHeight(),
	}
	if strings.HasPrefix(path, officialPrefix) {
		e.official = true
		e.status = Listed
	}
	entries.Set(info.Slug, e)
	paths.Set(path, info.Slug)
	order = append(order, info.Slug)
	chain.Emit("Enlisted", "slug", info.Slug, "path", path, "status", e.status.String())
}

// Approve opens a pending community challenge for claims.
func Approve(cur realm, slug string) {
	assertCurator(cur)
	e := mustEntry(slug)
	if e.status != Pending {
		panic(ErrNotPending)
	}
	e.status = Listed
	chain.Emit("Approved", "slug", slug)
}

// Retire closes a challenge for new claims. Existing solves keep scoring.
func Retire(cur realm, slug string) {
	assertCurator(cur)
	e := mustEntry(slug)
	e.status = Retired
	chain.Emit("Retired", "slug", slug)
}

func getEntry(slug string) (*entry, bool) {
	v := entries.Get(slug)
	if v == nil {
		return nil, false
	}
	return v.(*entry), true
}

func mustEntry(slug string) *entry {
	e, ok := getEntry(slug)
	if !ok {
		panic(ErrUnknownChallenge)
	}
	return e
}

// eachEntry calls fn for every challenge in enlistment order.
func eachEntry(fn func(slug string, e *entry)) {
	for _, slug := range order {
		e, _ := getEntry(slug)
		fn(slug, e)
	}
}
