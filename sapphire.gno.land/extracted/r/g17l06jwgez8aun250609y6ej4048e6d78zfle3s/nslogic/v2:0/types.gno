// Package nslogic is the swappable "business rules" half of the split
// (NOTES.md §9t). It holds every piece of policy that might reasonably
// change — pricing, character validation, payment/refund, freeze rules,
// transfer restrictions — and no persistent records of its own.
//
// Every mutation here ends by calling into nsdata's narrow Record/Raw
// API via cross(cur). nsdata trusts whichever address is currently wired
// up as trustedLogic to have done its own authorization checks
// correctly, so THIS realm is where "is the caller allowed to do this"
// actually lives. If a bug is found here, admin deploys a fixed nslogic
// and re-points nsdata.SetTrustedLogic at it — no data migration,
// records and config untouched.
//
// Deliberately reads config fresh from nsdata on every call rather than
// caching it. The one thing that cannot be read fresh is a COMPILED
// regex — avl trees store the pattern string, not the compiled object —
// so that one value is cached, and the cache is validated against
// nsdata on every use (see currentLabelRe).
package nslogic

import (
	"regexp"

	"gno.land/r/g17l06jwgez8aun250609y6ej4048e6d78zfle3s/nsdata"
)

const (
	ugnot    = "ugnot"
	bpsDenom = 10_000
)

// Cached compile of nsdata's stored labelPattern. Both fields are
// written together and only by currentLabelRe.
var (
	labelPattern string
	reLabel      *regexp.Regexp
)

// Structural, not admin-tunable, so it stays a local constant: anything
// shaped like a real gno.land address is refused as a label, so a name
// can never be mistaken for a raw wallet address in a UI.
var reAddressLookalike = regexp.MustCompile(`^g1[a-z0-9]{20,38}$`)

// currentLabelRe returns the compiled form of whatever pattern nsdata
// currently stores, recompiling only when the string has changed.
//
// This replaces a snapshot taken once in init(). The snapshot was a
// silent-divergence bug: nsdata holds the pattern string, this realm
// held a compiled copy, and nothing kept them in sync across a
// logic-realm swap. A replacement nslogic deployed before the last
// SetLabelPattern would enforce its own stale pattern while every
// reader — GetLabelPattern, the error message, the UI — reported
// nsdata's newer one, so registrations would fail against a rule nobody
// could see. Reading through here on every call makes that impossible
// by construction.
func currentLabelRe() *regexp.Regexp {
	p := nsdata.GetLabelPattern()
	if reLabel == nil || p != labelPattern {
		compiled, err := regexp.Compile(p)
		if err != nil {
			panic("nslogic: stored label pattern does not compile: " + err.Error())
		}
		labelPattern, reLabel = p, compiled
	}
	return reLabel
}
