// Package splitpoc (deployed at path .../splitpoc/v1 -- gno's own
// tooling treats a trailing /vN as a version suffix and expects the
// package to be named after what comes before it, exactly the
// convention flagged in the design discussion this spike exists to
// validate) is the first "version" realm in the split-realm spike --
// disposable, redeployable, and holds no irreplaceable state of its
// own (this spike skips price/trait/reveal logic entirely; its only
// job is proving that a version realm can successfully call into the
// stable realm's gated RecordMint, and that the gate actually rejects
// everyone else). See ../stable/stable.gno for the design this proves.
package splitpoc

import (
	"strconv"

	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
	stable "gno.land/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/splitpoc/stable"
)

var nextID int64

// MintTest mints the next sequential token ID into the stable realm.
// No payment, no trait logic -- this spike is testing the realm-to-
// realm authorization boundary, nothing else. Public on purpose: the
// gate that matters is stable.RecordMint's, not this function's.
func MintTest(cur realm, to address) grc721.TokenID {
	tid := grc721.TokenID(strconv.FormatInt(nextID, 10))
	// Cross-realm call: gno requires `cross(cur)` (not bare `cur`) as
	// the first arg when calling ANOTHER realm's crossing function --
	// this is the actual compiler-enforced version of the caller-
	// identity boundary the whole spike exists to validate. Bare `cur`
	// is only for calling a crossing function in your OWN package.
	stable.RecordMint(cross(cur), to, tid)
	nextID++
	return tid
}

func NextID() int64 { return nextID }
