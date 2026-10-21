package guardians_reveal_bridge_v1

import guardians "gno.land/r/g1nmqhha0ua730vejxqhrelldm4pga5j5ptle5ea/guardians"

const admin address = "g1nmqhha0ua730vejxqhrelldm4pga5j5ptle5ea"
const originalRealm = "gno.land/r/g1nmqhha0ua730vejxqhrelldm4pga5j5ptle5ea/guardians"
const originalCollectionID = originalRealm + ".GUARDIANS.0000000"

func Version() string { return "GUARDIANS_REVEAL_BRIDGE_V1" }
func OriginalRealm() string { return originalRealm }
func OriginalCollectionID() string { return originalCollectionID }

// Only forwards the original deterministic metadata-update operation.
// No init, ledger, mint, transfer, custody, freeze or configuration operation.
func Apply(cur realm, start int64, quantity int) {
	if cur.Previous().Address() != admin || cur.Previous().PkgPath() != "" { panic("reveal bridge: unauthorized caller") }
	if guardians.CollectionID() != originalCollectionID { panic("reveal bridge: unexpected collection") }
	if guardians.TotalSupply() != 3333 || guardians.RevealTarget() != 3333 { panic("reveal bridge: unexpected supply or target") }
	if guardians.RevealState() != "REVEALING" { panic("reveal bridge: reveal is not active") }
	if quantity < 1 || quantity > 20 { panic("reveal bridge: invalid batch quantity") }
	if start != guardians.RevealProcessed()+1 { panic("reveal bridge: stale batch cursor") }
	if start+int64(quantity)-1 > guardians.RevealTarget() { panic("reveal bridge: target exceeded") }
	guardians.ApplyRevealBatch(start, quantity)
	if guardians.RevealProcessed() != start+int64(quantity)-1 { panic("reveal bridge: progress mismatch") }
}
