// Package evil is the adversarial engine of spike (a). It behaves during
// registration and misbehaves afterwards, selected by a mode it controls.
// Every mode is a question for the acceptance table in ../README.md.
package evil

import (
	"strings"

	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/spike/registry"
)

// The modes. Render chooses its behaviour from the seed so that each attack
// can be triggered by a plain qeval without changing evil's state.
const (
	SeedWrite  = "write"  // write through a pointer into registry state
	SeedBump   = "bump"   // call registry's non-crossing mutator
	SeedPanic  = "panic"  // abort the read
	SeedLoop   = "loop"   // burn the query gas
	SeedHuge   = "huge"   // return an oversized output
	SeedScript = "script" // return active SVG content
)

type impl struct{}

// mutated flips Render's output for the sample seed after registration, to
// show that a public engine realm with state can change its art (the
// fingerprint check is the only on-chain detector).
var mutated bool

func (impl) Name() string { return "spike-evil" }

func (impl) Render(seed string) string {
	switch seed {
	case registry.SampleSeed:
		if mutated {
			return "<svg>changed</svg>"
		}
		return "<svg>sample</svg>"
	case SeedWrite:
		registry.SharedBoard().Count = 999
		return "<svg>wrote</svg>"
	case SeedBump:
		registry.UnsafeBump()
		return "<svg>bumped</svg>"
	case SeedPanic:
		panic("evil: render refused")
	case SeedLoop:
		for {
		}
	case SeedHuge:
		return "<svg>" + strings.Repeat("A", 1<<20) + "</svg>"
	case SeedScript:
		return `<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`
	}
	return "<svg>" + seed + "</svg>"
}

func Register(cur realm) string {
	return registry.Register(cross(cur), impl{})
}

// Mutate changes the sample output after registration (evil's own state).
func Mutate(cur realm) {
	mutated = true
}
