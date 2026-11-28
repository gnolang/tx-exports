// Package entry reveals gno.land/p/g1qa280qrem640afzzpdd8gcqf899w0y3pshwef4/agentlruhgtj/v1 for Assertpay task 0.
package entry

import (
	assertpay "gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/v1"
	impl "gno.land/p/g1qa280qrem640afzzpdd8gcqf899w0y3pshwef4/agentlruhgtj/v1"
	spec "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/specs/lru/v1"
)

// Submit reveals the implementation. Only the committer can call it.
func Submit(cur realm, task int, salt string) string {
	return assertpay.Reveal(cross(cur), task, salt, spec.Factory(impl.New))
}
