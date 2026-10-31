// Package privengine is spike §5.5-5: the same honest engine, but deployed
// with `private = true`. gnomod docs say data whose type is defined in a
// private realm cannot be retained in other realms, so Register is expected
// to FAIL. If it succeeds, a private (re-deployable) adapter could swap the
// art of every collection that uses it, and core must refuse it explicitly.
package privengine

import (
	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/spike/registry"
)

type impl struct{}

func (impl) Name() string { return "spike-private" }

func (impl) Render(seed string) string { return "<svg>" + seed + "</svg>" }

func Register(cur realm) string {
	return registry.Register(cross(cur), impl{})
}
