package nft

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// NOTE: CreateCollection/Mint/Approve/SetApprovalForAll/Burn derive the
// caller from unsafe.OriginCaller(), which testing.SetOriginCaller(addr)
// correctly overrides for the remainder of the *calling function's own
// stack frame* — so every SetOriginCaller call below is inlined directly
// in the test/t.Run closure body, right before the action it's meant to
// affect. TransferFrom is the one exception that reads
// cur.Previous().Address() instead (see nft.gno), which in a same-package
// test always resolves to this realm's own address (cur.Address()) — so
// its test mints to cur.Address() as a stand-in "owner" rather than to a
// distinct testutils address.

func TestCreateCollectionAndMint(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	var id, tid string

	t.Run("alice creates a collection", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		id = CreateCollection(cross(cur), "Hazen Genesis", "HZNG", "test collection", "ipfs://base/", 10, 5, true)
		uassert.Equal(t, "1", id)

		info := GetCollection(id)
		uassert.Equal(t, "Hazen Genesis", info.Name)
		uassert.Equal(t, int64(10), info.MaxSupply)
		uassert.Equal(t, int64(0), info.Minted)
		uassert.Equal(t, alice, info.Creator)
	})

	t.Run("bob mints into it", func(t *testing.T) {
		testing.SetOriginCaller(bob)
		tid = Mint(cross(cur), id, "ipfs://base/1.json")
		uassert.Equal(t, "1", tid)

		owner, err := OwnerOf(id, tid)
		uassert.NoError(t, err, "OwnerOf should not error")
		uassert.Equal(t, bob, owner)

		uri, err := TokenURI(id, tid)
		uassert.NoError(t, err, "TokenURI should not error")
		uassert.Equal(t, "ipfs://base/1.json", uri)

		toks := TokensOfOwner(bob)
		uassert.Equal(t, 1, len(toks))
		uassert.Equal(t, id+":"+tid, toks[0])
	})

	t.Run("royalty was recorded for the creator", func(t *testing.T) {
		paymentAddr, amount, err := RoyaltyInfo(id, tid, 1000)
		uassert.NoError(t, err, "RoyaltyInfo should not error")
		uassert.Equal(t, alice, paymentAddr)
		uassert.Equal(t, int64(50), amount) // 5% of 1000
	})
}

func TestMintRestrictedToCreator(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice2")
	bob := testutils.TestAddress("bob2")

	var id string
	t.Run("alice creates a private-mint collection", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		id = CreateCollection(cross(cur), "Private Drop", "PRIV", "", "", 3, 0, false)
	})

	t.Run("bob cannot mint into it", func(t *testing.T) {
		testing.SetOriginCaller(bob)
		uassert.AbortsWithMessage(t, cur, "minting into this collection is restricted to its creator", func() {
			Mint(cross(cur), id, "")
		})
	})

	t.Run("alice can mint into it", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		tid := Mint(cross(cur), id, "")
		uassert.Equal(t, "1", tid)
	})
}

func TestMaxSupplyEnforced(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice3")

	var id string
	t.Run("create + mint the only token", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		id = CreateCollection(cross(cur), "Tiny", "TINY", "", "", 1, 0, true)
		Mint(cross(cur), id, "")
	})

	t.Run("second mint is rejected", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		uassert.AbortsWithMessage(t, cur, "collection has reached its max supply", func() {
			Mint(cross(cur), id, "")
		})
	})
}

func TestTransferFrom(cur realm, t *testing.T) {
	bob := testutils.TestAddress("bob4")

	var id, tid string
	self := cur.Address() // stand-in "owner" identity for this same-package test; see NOTE above

	t.Run("mint to self, then transfer to bob", func(t *testing.T) {
		testing.SetOriginCaller(self)
		id = CreateCollection(cross(cur), "Transferable", "TRF", "", "", 5, 0, true)
		tid = Mint(cross(cur), id, "")
		TransferFrom(cross(cur), id, tid, self, bob)
	})

	t.Run("bob is now the owner", func(t *testing.T) {
		owner, err := OwnerOf(id, tid)
		uassert.NoError(t, err, "OwnerOf should not error")
		uassert.Equal(t, bob, owner)
	})
}
