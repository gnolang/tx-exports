// Package splitpoc (deployed at path .../splitpoc/v2 -- same version-
// suffix convention as v1, see that package's doc comment) exists
// purely to test the version-switch itself: approve v1, mint, approve
// v2, confirm v1 can no longer write and v2 can, then switch back to
// v1 and confirm it works again (no stale-approval bug). Its IDs are
// prefixed "v2-" so it's obvious at a glance, in stable.MintedIDs(),
// which version actually minted which token -- see ../stable/stable.gno
// for the design this proves.
package splitpoc

import (
	"strconv"

	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
	stable "gno.land/r/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/splitpoc/stable"
)

var nextID int64

func MintTest(cur realm, to address) grc721.TokenID {
	tid := grc721.TokenID("v2-" + strconv.FormatInt(nextID, 10))
	stable.RecordMint(cross(cur), to, tid) // see v1's doc comment on cross(cur)
	nextID++
	return tid
}

func NextID() int64 { return nextID }
