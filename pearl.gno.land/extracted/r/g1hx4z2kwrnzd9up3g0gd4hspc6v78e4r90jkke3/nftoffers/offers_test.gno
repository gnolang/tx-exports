package nftoffers

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft"
)

// NOTE: see market_test.gno in nftmarket for why testing.SetOriginCaller
// calls are inlined directly in each t.Run closure rather than factored
// into a shared helper.

func TestMakeAndAcceptOffer(cur realm, t *testing.T) {
	alice := testutils.TestAddress("off-alice")
	bob := testutils.TestAddress("off-bob")
	realmAddr := cur.Address()

	var collID, tid, offerID string

	t.Run("alice mints", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID = nft.CreateCollection(cross(cur), "Offer Test", "OFR", "", "", 5, 10, true)
		tid = nft.Mint(cross(cur), collID, "")
	})

	t.Run("bob makes an offer", func(t *testing.T) {
		testing.SetOriginCaller(bob)
		// See nftmarket's TestListAndBuy: on real chain --send lands on
		// the called realm's own balance before the function body runs;
		// gno test needs that simulated explicitly.
		testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 750_000)))
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 750_000)))

		offerID = MakeOffer(cross(cur), collID, tid)

		info := GetOffer(offerID)
		uassert.True(t, info.Active, "offer should be active")
		uassert.Equal(t, int64(750_000), info.AmountUgnot)
		uassert.Equal(t, bob, info.Buyer)
	})

	t.Run("alice approves and accepts", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		nft.Approve(cross(cur), collID, tid, realmAddr)

		AcceptOffer(cross(cur), offerID)

		owner, err := nft.OwnerOf(collID, tid)
		uassert.NoError(t, err, "OwnerOf should not error")
		uassert.Equal(t, bob, owner)

		resolved := GetOffer(offerID)
		uassert.False(t, resolved.Active, "offer should be inactive after acceptance")
	})
}

func TestCancelOffer(cur realm, t *testing.T) {
	alice := testutils.TestAddress("off-alice2")
	bob := testutils.TestAddress("off-bob2")
	realmAddr := cur.Address()

	var collID, tid, offerID string

	t.Run("alice mints, bob offers then cancels", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID = nft.CreateCollection(cross(cur), "Cancel Offer Test", "COFR", "", "", 5, 0, true)
		tid = nft.Mint(cross(cur), collID, "")

		testing.SetOriginCaller(bob)
		testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 200_000)))
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 200_000)))
		offerID = MakeOffer(cross(cur), collID, tid)

		CancelOffer(cross(cur), offerID)
	})

	t.Run("offer is inactive", func(t *testing.T) {
		info := GetOffer(offerID)
		uassert.False(t, info.Active, "offer should be inactive after cancel")
	})
}

func TestCannotOfferOnOwnToken(cur realm, t *testing.T) {
	alice := testutils.TestAddress("off-alice3")

	t.Run("alice cannot offer on her own token", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID := nft.CreateCollection(cross(cur), "SelfOffer", "SOFR", "", "", 5, 0, true)
		tid := nft.Mint(cross(cur), collID, "")

		testing.IssueCoins(alice, chain.NewCoins(chain.NewCoin("ugnot", 1_000)))
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 100)))

		uassert.AbortsWithMessage(t, cur, "cannot make an offer on your own token", func() {
			MakeOffer(cross(cur), collID, tid)
		})
	})
}

func TestAcceptRequiresApproval(cur realm, t *testing.T) {
	alice := testutils.TestAddress("off-alice4")
	bob := testutils.TestAddress("off-bob4")
	realmAddr := cur.Address()

	var collID, tid, offerID string
	t.Run("bob offers without alice approving first", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		collID = nft.CreateCollection(cross(cur), "NoApproveOffer", "NAO", "", "", 5, 0, true)
		tid = nft.Mint(cross(cur), collID, "")

		testing.SetOriginCaller(bob)
		testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 300_000)))
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 300_000)))
		offerID = MakeOffer(cross(cur), collID, tid)
	})

	t.Run("accept aborts without approval", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		uassert.AbortsWithMessage(t, cur,
			"nftoffers is not approved to transfer this token yet; call nft.Approve or nft.SetApprovalForAll first",
			func() {
				AcceptOffer(cross(cur), offerID)
			},
		)
	})
}
