package gnofly

import (
	"strconv"

	"chain"

	bazaar "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/bazaarv5"

	"gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/nfts/planes"
)

// Bazaar (bazaar.gnomi.fun) lists the collections registered on its factory,
// bazaarv5. This realm registers itself there with Init: the factory takes
// its path as the collection (slug: the last element, "gnofly") and sends the
// site's List, Buy and Cancel here. Its fee on a sale is read from the factory
// at each Buy.

const (
	// What Bazaar shows for the collection: the planes realm's.
	collectionName   = "gnofly planes"
	collectionSymbol = "PLANE"
	collectionCover  = "https://gnofly.xyz/nft/collections/planes/777.png"
	collectionSupply = 777
	// The planes realm's mint price, 77 GNOT: shown by Bazaar, never charged
	// here (planes are minted on the planes realm).
	collectionMintPrice = int64(77_000_000)
)

// registered is set once Init has registered this realm on Bazaar's factory:
// only then does it report its minted count there.
var registered bool

// Init registers this realm on Bazaar's factory. The factory requires the
// slug "gnofly" reserved first, with Reserve, by the wallet calling Init; it
// must be an admin of the game realm here too: the gnofly wallet. Once only.
func Init(cur realm) {
	userOf(0, cur)
	assertAdmin(0, cur)
	if registered {
		panic(errRegistered)
	}
	registered = true
	bazaar.Register(cross(cur), collectionName, collectionSymbol, collectionCover,
		collectionSupply, collectionMintPrice, planes.RoyaltyBps())
	noteMinted(0, cur)
	chain.Emit("Registered", "slug", slug)
}

// noteMinted reports the planes minted so far to Bazaar's factory, which
// shows the count. Nothing before Init: the factory does not know this realm.
func noteMinted(_ int, rlm realm) {
	if registered {
		bazaar.NoteMinted(cross(rlm), Minted())
	}
}

// bazaarFee is what Bazaar takes on a sale at price between seller and
// buyer: its ProtocolBps less the better holder discount of the two, never
// below zero. Of it, GenesisShareBps goes to its genesis sink, the rest to its
// protocol sink. All read from the factory now: its admin sets them.
func bazaarFee(price int64, seller, buyer address) (genesis, protocol int64) {
	discount := bazaar.HolderDiscount(seller.String())
	if d := bazaar.HolderDiscount(buyer.String()); d > discount {
		discount = d
	}
	bps := bazaar.ProtocolBps() - discount
	if bps <= 0 {
		return 0, 0
	}
	fee := price * bps / 10_000
	genesis = fee * bazaar.GenesisShareBps() / 10_000
	return genesis, fee - genesis
}

// Registered reports whether Init has registered this realm on Bazaar.
func Registered() bool { return registered }

// itoa64 is strconv.FormatInt in base 10.
func itoa64(n int64) string { return strconv.FormatInt(n, 10) }
