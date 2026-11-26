package kylix

import (
	"chain"
	"chain/runtime"
	"strconv"
)

// PruneIntent deletes an expired offer. Anyone may call it, and the storage
// deposit the offer released goes to the caller. It reads only Kylix's own
// storage and calls no collection or token code, so pruning can never cost
// the caller more than the offer's own bytes, and no collection can make an
// expired offer impossible to prune. An offer that has not expired can only
// be cancelled by its owner or settled in a ring.
func PruneIntent(cur realm, id uint64) {
	guard(cur)
	o := mustOpen(id)
	if h := runtime.ChainHeight(); !expired(o, h) {
		panic("kylix: offer " + u64(id) + " has not expired; it can be pruned after height " +
			strconv.FormatInt(o.Expiry, 10))
	}
	removeOffer(o.ID)
	chain.Emit("IntentPruned", "id", u64(id), "owner", o.Owner.String(), "reason", "expired",
		"pruner", cur.Previous().Address().String())
}
