package nsskin

import "gno.land/p/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/grc721"

// The deployer is the first admin. Rotatable with SetAdmin, and
// deliberately NOT the vault's timelocked governance: this realm is
// replaceable, so it does not need machinery built for one that is not.
// See the note in types.gno.
func init(cur realm) {
	nft = grc721.NewBasicNFT(0, cur, "Meme Name Service Skins", "MNSKIN")
	admin = cur.Previous().Address()
}
