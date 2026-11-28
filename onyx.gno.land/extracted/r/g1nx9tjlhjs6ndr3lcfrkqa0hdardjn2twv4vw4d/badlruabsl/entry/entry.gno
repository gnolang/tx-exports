// Package entry reveals gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/badlruabsl/v1 for Assertpay task 2.
package entry

import (
	assertpay "gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/v1"
	impl "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/badlruabsl/v1"
	spec "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/specs/lru/v1"
)

// Submit reveals the implementation. Only the committer can call it.
func Submit(cur realm, task int, salt string) string {
	return assertpay.Reveal(cross(cur), task, salt, spec.Factory(impl.New))
}
