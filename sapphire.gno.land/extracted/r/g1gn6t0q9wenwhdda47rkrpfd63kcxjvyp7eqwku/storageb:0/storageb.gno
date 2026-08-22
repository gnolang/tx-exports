// Package storageb is the SLIM candidate record shape, to be compared
// against storagea. Four changes, each of which should be free of any
// functional cost:
//
//  1. no `label` -- the tree key already is the label, so storing it
//     again is pure duplication (verified: nsdata never reads it)
//  2. int64 unix seconds instead of time.Time -- Time carries an unused
//     nanosecond field and a *Location pointer for values that are
//     always UTC, twice per record
//  3. streak and the booleans packed into one int64
//  4. *avl.Tree instead of avl.Tree -- nil until an extension key is
//     actually written, rather than allocated for every record
package storageb

import (
	"time"

	"gno.land/p/nt/avl/v0"
)

const (
	flagFrozen  = int64(1) << 0
	flagIsNFT   = int64(1) << 1
	streakShift = 8
)

type Rec struct {
	owner      address
	registered int64 // unix seconds
	expires    int64
	flags      int64 // streak << 8 | bools
	extra      *avl.Tree
}

func (r *Rec) Streak() int64 { return r.flags >> streakShift }
func (r *Rec) Frozen() bool  { return r.flags&flagFrozen != 0 }
func (r *Rec) IsNFT() bool   { return r.flags&flagIsNFT != 0 }

var recs avl.Tree

func Add(cur realm, key string) {
	now := time.Now().Unix()
	recs.Set(key, &Rec{
		owner:      cur.Previous().Address(),
		registered: now,
		expires:    now + 365*24*3600,
		flags:      flagIsNFT,
	})
}

func Count() int { return recs.Size() }
