// Package solver is the sponsor key's entry realm in the rehearsal: it
// submits a correct lru.
package solver

import (
	assertpay "gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/v1"
	lrugood "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/demo/lrugood"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/specs/lru/v1"
)

func Submit(cur realm, task int, salt string) string {
	return assertpay.Reveal(cross(cur), task, salt, lru.Factory(lrugood.New))
}
