package nftmarket

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft"
)

// NOTE: testing.SetOriginCaller overrides unsafe.OriginCaller() for the
// remainder of the *calling function's own stack frame* — so every call
// below is inlined directly in the test/t.Run closure body, right before
// the action(s) it's meant to affect (see nft_test.gno for more detail on
// why factoring this into a shared helper function breaks it).

func TestListAndBuy(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mkt-alice")
	bob := testutils.TestAddress("mkt-bob")

	var collID, tid, listingID string
	marketAddr := cur.Address()

	t.Run("alice creates, mints, approves and lists", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID = nft.CreateCollection(cross(cur), "Market Test", "MKT", "", "", 5, 10, true)
		tid = nft.Mint(cross(cur), collID, "")
		nft.Approve(cross(cur), collID, tid, marketAddr)
		listingID = List(cross(cur), collID, tid, 1_000_000) // 1 GNOT

		info := GetListing(listingID)
		uassert.True(t, info.Active, "listing should be active")
		uassert.Equal(t, int64(1_000_000), info.PriceUgnot)
	})

	t.Run("bob buys it", func(t *testing.T) {
		testing.SetOriginCaller(bob)
		// On real chain, a --send amount is credited to the CALLED
		// REALM's account before the function runs; gno test doesn't do
		// this automatically, so IssueCoins simulates that deposit onto
		// the marketplace realm itself (not bob) to match what Buy's
		// banker.SendCoins calls actually need.
		testing.IssueCoins(marketAddr, chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))

		Buy(cross(cur), listingID)

		owner, err := nft.OwnerOf(collID, tid)
		uassert.NoError(t, err, "OwnerOf should not error")
		uassert.Equal(t, bob, owner)

		sold := GetListing(listingID)
		uassert.False(t, sold.Active, "listing should be inactive after sale")
	})
}

func TestCancelListing(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mkt-alice2")
	marketAddr := cur.Address()

	var listingID string
	t.Run("alice lists then cancels", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID := nft.CreateCollection(cross(cur), "Cancel Test", "CNCL", "", "", 5, 0, true)
		tid := nft.Mint(cross(cur), collID, "")
		nft.Approve(cross(cur), collID, tid, marketAddr)

		listingID = List(cross(cur), collID, tid, 500_000)
		Cancel(cross(cur), listingID)
	})

	t.Run("listing is inactive", func(t *testing.T) {
		info := GetListing(listingID)
		uassert.False(t, info.Active, "listing should be inactive after cancel")
	})
}

func TestListRequiresApproval(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mkt-alice3")

	t.Run("listing without approval aborts", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID := nft.CreateCollection(cross(cur), "NoApprove", "NOAP", "", "", 5, 0, true)
		tid := nft.Mint(cross(cur), collID, "")

		uassert.AbortsWithMessage(t, cur,
			"marketplace is not approved to transfer this token yet; call nft.Approve or nft.SetApprovalForAll first",
			func() {
				List(cross(cur), collID, tid, 1)
			},
		)
	})
}

func TestCannotBuyOwnListing(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mkt-alice4")
	marketAddr := cur.Address()

	var listingID string
	t.Run("alice lists", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID := nft.CreateCollection(cross(cur), "SelfBuy", "SELF", "", "", 5, 0, true)
		tid := nft.Mint(cross(cur), collID, "")
		nft.Approve(cross(cur), collID, tid, marketAddr)
		listingID = List(cross(cur), collID, tid, 100)
	})

	t.Run("alice cannot buy it back", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		testing.IssueCoins(alice, chain.NewCoins(chain.NewCoin("ugnot", 1_000)))
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 100)))

		uassert.AbortsWithMessage(t, cur, "cannot buy your own listing", func() {
			Buy(cross(cur), listingID)
		})
	})
}
