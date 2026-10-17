package nsskin

import (
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
)

// The deployer is the first admin. Rotatable with SetAdmin, and
// deliberately NOT the vault's timelocked governance: this realm is
// replaceable, so it does not need machinery built for one that is not.
// See the note in types.gno.
//
// The ledger is the chain's own gno.land/p/nt/grc721/v0, created here
// once: NewToken emits the NewToken event and every later mint and
// transfer is stamped with that package, which is what wallets and
// indexers require before they will list a skin at all. The collection
// id is "<this realm's path>.MNSKIN.0000000".
func init(cur realm) {
	token, ledger = grc721.NewToken("Meme Name Service Skins", "MNSKIN", seqid.ID(0), cur)
	admin = cur.Previous().Address()
}
