// Package engine is the honest engine of spike (a): a stateless realm that
// registers a zero-size value with spike/registry, exactly like
// r/moul/x/upgrade/selfreg/impl/v1 registers greeter{} with its facade.
package engine

import (
	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/spike/registry"
)

type impl struct{}

func (impl) Name() string { return "spike-honest" }

// Render is deterministic in the seed and touches no state.
func (impl) Render(seed string) string {
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" fill="#0b7"/><desc>` +
		seed + `</desc></svg>`
}

// Register is an explicit call rather than init: under the inert package
// policy init runs inside the approver's transaction (RA B-1).
func Register(cur realm) string {
	return registry.Register(cross(cur), impl{})
}
