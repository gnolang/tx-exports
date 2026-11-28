// Package solver is the copier key's entry realm in the rehearsal: it
// submits a wrong lru and reverts unless the reveal seed happens to pass
// (seed grinding). Assertpay tolerates this: the challenge window decides.
package solver

import (
	assertpay "gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/v1"
	lrubad "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/specs/lru/bad/v1"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/specs/lru/v1"
)

func Submit(cur realm, task int, salt string) string {
	r := assertpay.Reveal(cross(cur), task, salt, lru.Factory(lrubad.New))
	if r != "20/20" {
		panic("unlucky seed, try next block: " + r)
	}
	return r
}
