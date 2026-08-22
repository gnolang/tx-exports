// Package storagea mirrors the CURRENT nsdata record shape, field for
// field, so its on-chain size can be compared against the slim variant
// in storageb. Nothing here is meant to ship.
package storagea

import (
	"time"

	"gno.land/p/nt/avl/v0"
)

type Rec struct {
	label      string // duplicated: the tree key already holds this
	owner      address
	registered time.Time // {sec int64, nsec int32, loc *Location}
	expires    time.Time
	streak     int64
	frozen     bool
	isNFT      bool
	extra      avl.Tree // allocated even when empty
}

var recs avl.Tree

// Add inserts one record under the given key. Called repeatedly to grow
// the tree, since AVL insert cost varies with tree size.
func Add(cur realm, key string) {
	now := time.Now()
	recs.Set(key, &Rec{
		label:      key,
		owner:      cur.Previous().Address(),
		registered: now,
		expires:    now.Add(365 * 24 * time.Hour),
		streak:     0,
		frozen:     false,
		isNFT:      true,
		extra:      avl.Tree{},
	})
}

func Count() int { return recs.Size() }
