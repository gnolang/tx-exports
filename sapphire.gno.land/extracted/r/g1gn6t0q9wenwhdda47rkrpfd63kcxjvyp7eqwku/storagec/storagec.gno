// Package storagec isolates ONE change from the slim variant: int64
// unix seconds instead of time.Time. Everything else matches storagea
// exactly -- the duplicated label stays, the booleans stay separate,
// the extension tree is still allocated by value.
//
// storageb changed four things at once and saved ~1,615 bytes. This
// says how much of that was the timestamps alone, which decides whether
// the other three are worth making at all.
package storagec

import (
	"time"

	"gno.land/p/nt/avl/v0"
)

type Rec struct {
	label      string   // kept, same as storagea
	owner      address
	registered int64    // CHANGED: was time.Time
	expires    int64    // CHANGED: was time.Time
	streak     int64
	frozen     bool     // kept separate
	isNFT      bool     // kept separate
	extra      avl.Tree // kept by value
}

var recs avl.Tree

func Add(cur realm, key string) {
	now := time.Now().Unix()
	recs.Set(key, &Rec{
		label:      key,
		owner:      cur.Previous().Address(),
		registered: now,
		expires:    now + 365*24*3600,
		streak:     0,
		frozen:     false,
		isNFT:      true,
		extra:      avl.Tree{},
	})
}

func Count() int { return recs.Size() }
