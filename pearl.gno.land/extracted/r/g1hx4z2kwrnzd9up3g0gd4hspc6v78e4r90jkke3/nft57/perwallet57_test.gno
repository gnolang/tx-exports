package nft57

import (
	"testing"

	"gno.land/p/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/tokens/grc721"
	"gno.land/p/nt/uassert/v0"
)

// The per-wallet mint cap is the whole fairness story of a free-mint drop:
// if one wallet can take 50 of 1000 pieces, the "1 per person" promise on
// the mint page is decoration. So it is enforced in the realm, not in the
// UI, and it is pinned here for the two values a drop actually uses (1 and
// 2) plus the uncapped case.
//
// The cap is chosen at collection creation time (CreateCollection's
// maxPerWallet argument, 0 = unlimited) and counted over LIFETIME mints,
// which is why burning or transferring away cannot buy a wallet a second
// turn.

// TestCreateCollectionTakesTheCapAtCreation proves the cap is a creation-time
// decision that lands on the collection and is readable back, so a mint page
// can display the real rule rather than a hardcoded claim.
func TestCreateCollectionTakesTheCapAtCreation(cur realm, t *testing.T) {
	one := newTestCollection(cur, "620", 0, 1)
	defer dropTestCollection("620")
	two := newTestCollection(cur, "621", 0, 2)
	defer dropTestCollection("621")
	free := newTestCollection(cur, "622", 0, 0)
	defer dropTestCollection("622")

	uassert.Equal(t, int64(1), one.maxPerWallet)
	uassert.Equal(t, int64(2), two.maxPerWallet)
	uassert.Equal(t, int64(0), free.maxPerWallet)

	// Same values through the public read the frontend uses.
	uassert.Equal(t, int64(1), GetCollection("620").MaxPerWallet)
	uassert.Equal(t, int64(2), GetCollection("621").MaxPerWallet)
	uassert.Equal(t, int64(0), GetCollection("622").MaxPerWallet)

	// A nonsense cap is refused at creation rather than silently coerced.
	uassert.PanicsWithMessage(t, cur,
		"maxPerWallet must be >= 0 (0 means unlimited)",
		func() { CreateCollection(cur, "Bad", "BAD", "", "", 10, 0, -1, true) })
}

// TestCapOfOneAllowsExactlyOne is the OG drop's rule: one wallet, one piece.
func TestCapOfOneAllowsExactlyOne(cur realm, t *testing.T) {
	newTestCollection(cur, "623", 0, 1)
	defer dropTestCollection("623")

	mint(cur, testBuyer, "623", "", "")
	uassert.Equal(t, int64(1), MintedByWallet("623", testBuyer))

	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 1",
		func() { mint(cur, testBuyer, "623", "", "") })

	// The cap is per wallet, not per collection: everyone else is unaffected.
	mint(cur, testCreator, "623", "", "")
	uassert.Equal(t, int64(1), MintedByWallet("623", testCreator))
	uassert.Equal(t, int64(2), GetCollection("623").MintedTotal)
}

// TestCapOfTwoAllowsExactlyTwo covers the other value a drop realistically
// picks, including the boundary: the second mint must still be allowed.
func TestCapOfTwoAllowsExactlyTwo(cur realm, t *testing.T) {
	newTestCollection(cur, "624", 0, 2)
	defer dropTestCollection("624")

	mint(cur, testBuyer, "624", "", "")
	mint(cur, testBuyer, "624", "", "") // boundary: allowed
	uassert.Equal(t, int64(2), MintedByWallet("624", testBuyer))

	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 2",
		func() { mint(cur, testBuyer, "624", "", "") })
}

// TestCapSurvivesBurn is the reason the counter exists as its own number
// instead of being derived from the live balance: burning must not hand the
// wallet a fresh turn.
func TestCapSurvivesBurn(cur realm, t *testing.T) {
	c := newTestCollection(cur, "625", 0, 1)
	defer dropTestCollection("625")

	mint(cur, testBuyer, "625", "", "")
	uassert.NoError(t, c.token.Burn(grc721.TokenID("1")))

	// Balance is back to zero, the lifetime count is not.
	uassert.Equal(t, int64(1), MintedByWallet("625", testBuyer))
	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 1",
		func() { mint(cur, testBuyer, "625", "", "") })
}

// TestCapSurvivesTransferAway closes the same hole from the other side: a
// wallet that moves its piece to a friend has still used its allocation.
func TestCapSurvivesTransferAway(cur realm, t *testing.T) {
	c := newTestCollection(cur, "626", 0, 1)
	defer dropTestCollection("626")

	mint(cur, testBuyer, "626", "", "")
	uassert.NoError(t, c.token.TransferFrom(testBuyer, testBuyer, testCreator, grc721.TokenID("1")))

	uassert.Equal(t, int64(1), MintedByWallet("626", testBuyer))
	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 1",
		func() { mint(cur, testBuyer, "626", "", "") })
}

// TestUncappedCollectionWritesNoCounter is the fee half of the feature: a
// collection with no cap must not pay for a per-wallet AVL node nothing ever
// reads (v5.4 change 3). This is what keeps an uncapped mint cheap.
func TestUncappedCollectionWritesNoCounter(cur realm, t *testing.T) {
	c := newTestCollection(cur, "627", 0, 0)
	defer dropTestCollection("627")

	mint(cur, testBuyer, "627", "", "")
	mint(cur, testBuyer, "627", "", "")
	mint(cur, testBuyer, "627", "", "")

	uassert.Equal(t, 0, c.mintedBy.Size())
	uassert.Equal(t, int64(0), MintedByWallet("627", testBuyer))
	uassert.Equal(t, int64(3), c.mintedTotal)
}

// TestCapAppliesToGenerativeMints makes sure the OG (generative) path is
// capped by the same rule as a hand/IPFS mint - the free-mint drop runs on
// exactly this path.
func TestCapAppliesToGenerativeMints(cur realm, t *testing.T) {
	c := newTestCollection(cur, "628", 0, 1)
	defer dropTestCollection("628")
	c.generative = true
	c.engine = Engine

	mintGenerativeOne(cur, testBuyer, "628")
	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 1",
		func() { mintGenerativeOne(cur, testBuyer, "628") })
}

// TestCapBoundsMintBatch is the one that matters most for v5.7: batching
// must not be a way to buy 25 pieces of a 1-per-wallet drop.
func TestCapBoundsMintBatch(cur realm, t *testing.T) {
	newTestCollection(cur, "629", 0, 1)
	defer dropTestCollection("629")
	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 1",
		func() { mintBatch(cur, testBuyer, "629", 2) })

	// A cap of 2 permits a batch of exactly 2, and nothing beyond it.
	c := newTestCollection(cur, "630", 0, 2)
	defer dropTestCollection("630")
	uassert.Equal(t, "1,2", mintBatch(cur, testBuyer, "630", 2))
	uassert.Equal(t, int64(2), c.mintedTotal)
	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 2",
		func() { mintBatch(cur, testBuyer, "630", 1) })
}

// TestSetMaxPerWalletCanTightenLater covers the creator who launches
// uncapped and then wants a cap: already-minted wallets keep their pieces,
// but the new rule applies from that moment on.
func TestSetMaxPerWalletCanTightenLater(cur realm, t *testing.T) {
	c := newTestCollection(cur, "631", 0, 0)
	defer dropTestCollection("631")
	c.creator = callerOf(cur)

	mint(cur, testBuyer, "631", "", "")
	mint(cur, testBuyer, "631", "", "")

	SetMaxPerWallet(cur, "631", 1)
	uassert.Equal(t, int64(1), GetCollection("631").MaxPerWallet)

	// The two existing tokens are untouched...
	uassert.Equal(t, int64(2), c.mintedTotal)
	// ...but the counter was never written while uncapped, so this wallet
	// still has its allocation. That is a deliberate, documented trade-off:
	// a cap added after the fact is forward-looking only.
	mint(cur, testBuyer, "631", "", "")
	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 1",
		func() { mint(cur, testBuyer, "631", "", "") })
}
