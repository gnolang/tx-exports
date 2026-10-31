// PKGPATH: gno.land/r/test/spikeevil

// Spike (a), adversarial case. This file IS the foreign engine realm: its
// evil type is declared in /r/test/spikeevil, so by interrealm v2 borrow
// rule #1 its methods run with spikeevil's authority even when the registry
// calls them. The expected output below is the hypothesis under test:
//
//   - a direct write through a pointer into registry state is refused;
//   - a call to the registry's non-crossing mutator is NOT refused (the
//     hazard that core's invariant I-12 exists to rule out);
//   - a panic only aborts the read that ran the engine.
package spikeevil

import (
	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/spike/registry"
)

type evil struct{}

func (evil) Name() string { return "evil" }

func (evil) Render(seed string) string {
	switch seed {
	case "write":
		registry.SharedBoard().Count = 999
		return "<svg>wrote</svg>"
	case "bump":
		registry.UnsafeBump()
		return "<svg>bumped</svg>"
	case "panic":
		panic("evil: render refused")
	}
	return "<svg>" + seed + "</svg>"
}

func main(cur realm) {
	id := registry.Register(cross(cur), evil{})
	println("registered:", id)

	r := revive(func() { registry.RenderWith(id, "write") })
	println("write aborted:", r != nil, "board:", registry.BoardCount())

	r = revive(func() { registry.RenderWith(id, "bump") })
	println("bump aborted:", r != nil, "bumps:", registry.Bumps())

	r = revive(func() { registry.RenderWith(id, "panic") })
	println("panic aborted:", r != nil, "registered:", registry.IsRegistered(id))

	println("normal:", registry.RenderWith(id, "x"))
}

// Output:
// registered: gno.land/r/test/spikeevil
// write aborted: true board: 0
// bump aborted: false bumps: 1
// panic aborted: true registered: true
// normal: <svg>x</svg>
