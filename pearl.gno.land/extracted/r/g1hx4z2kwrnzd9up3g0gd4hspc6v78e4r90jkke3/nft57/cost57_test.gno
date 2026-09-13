package nft57

import (
	"testing"

	"gno.land/p/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/tokens/grc721"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/uassert/v0"
)

// These tests pin the v5.4 mint-cost changes. Each one is written the same
// way: the cheaper implementation must give the SAME answer the v5.3
// implementation gave, because "cheaper" is only acceptable here if nothing
// a buyer or a market realm reads changes.

const (
	testCreator = address("g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3")
	testBuyer   = address("g1g67y6n35hx9llakmlpu2pd6tssn48as0gp6f50")
)

// newTestCollection builds a live collection in-realm so the mint paths can
// be exercised without a wallet transaction.
func newTestCollection(cur realm, id string, royaltyPct, maxPerWallet int64) *Collection {
	c := &Collection{
		id:           id,
		name:         "Cost " + id,
		symbol:       "COST",
		creator:      testCreator,
		maxSupply:    MaxCollectionSupply,
		publicMint:   true,
		royaltyPct:   royaltyPct,
		token:        grc721.NewNFTWithRoyalty(0, cur, "Cost "+id, "COST"),
		nextTokenID:  1,
		maxPerWallet: maxPerWallet,
		mintedBy:     avl.NewTree(),
	}
	collections.Set(id, c)
	return c
}

func dropTestCollection(id string) {
	collections.Remove(id)
}

// TestRoyaltyIsDerivedFromCollection covers v5.4 change 1. The per-token
// royalty row is gone, so the only remaining source of truth is the
// collection's own immutable terms - which is what the market realm quotes
// to a buyer.
func TestRoyaltyIsDerivedFromCollection(cur realm, t *testing.T) {
	newTestCollection(cur, "501", 7, 0)
	defer dropTestCollection("501")

	mint(cur, testBuyer, "501", "", "")

	// Paid to the CREATOR, not to the minter or the current holder.
	addr, owed, err := RoyaltyInfo("501", "1", 1000)
	uassert.NoError(t, err)
	uassert.Equal(t, testCreator.String(), addr.String())
	uassert.Equal(t, int64(70), owed)

	// Same percentage applies at any sale price, and it is a floor division
	// so the realm never over-pays a royalty it did not collect.
	_, owed2, _ := RoyaltyInfo("501", "1", 99)
	uassert.Equal(t, int64(6), owed2)

	// A token that does not exist must ERROR rather than quietly report
	// "no royalty owed" - otherwise a sale of a burned token could skip the
	// creator's cut.
	_, _, err = RoyaltyInfo("501", "2", 1000)
	uassert.Error(t, err)
}

// TestZeroRoyaltyCollectionOwesNothing keeps the EIP-2981 "no royalty"
// signal intact: empty address and 0, not the creator with 0.
func TestZeroRoyaltyCollectionOwesNothing(cur realm, t *testing.T) {
	newTestCollection(cur, "502", 0, 0)
	defer dropTestCollection("502")

	mint(cur, testBuyer, "502", "", "")

	addr, owed, err := RoyaltyInfo("502", "1", 1000)
	uassert.NoError(t, err)
	uassert.Equal(t, "", addr.String())
	uassert.Equal(t, int64(0), owed)
}

// TestTokensOfCollectionIsDerived covers v5.4 change 2: no index tree, same
// list. Burned tokens must disappear and their IDs must never come back.
func TestTokensOfCollectionIsDerived(cur realm, t *testing.T) {
	c := newTestCollection(cur, "503", 0, 0)
	defer dropTestCollection("503")

	for i := 0; i < 3; i++ {
		mint(cur, testBuyer, "503", "", "")
	}

	all := TokensOfCollection("503", 0, 0)
	uassert.Equal(t, 3, len(all))
	uassert.Equal(t, "1", all[0])
	uassert.Equal(t, "3", all[2])

	// Burn the middle token directly on the ledger (Burn() itself needs a
	// wallet caller); the derived view must skip the hole.
	uassert.NoError(t, c.token.Burn(grc721.TokenID("2")))

	live := TokensOfCollection("503", 0, 0)
	uassert.Equal(t, 2, len(live))
	uassert.Equal(t, "1", live[0])
	uassert.Equal(t, "3", live[1])

	// A burn must not re-open the ID: the next mint is 4, not 2.
	uassert.Equal(t, "4", mint(cur, testBuyer, "503", "", ""))
}

// TestTokensOfCollectionSortsNumerically is the reason v5.3 needed padded
// keys at all: "10" has to come after "9", not after "1".
func TestTokensOfCollectionSortsNumerically(cur realm, t *testing.T) {
	newTestCollection(cur, "504", 0, 0)
	defer dropTestCollection("504")

	for i := 0; i < 11; i++ {
		mint(cur, testBuyer, "504", "", "")
	}

	ids := TokensOfCollection("504", 0, 0)
	uassert.Equal(t, 11, len(ids))
	uassert.Equal(t, "9", ids[8])
	uassert.Equal(t, "10", ids[9])
	uassert.Equal(t, "11", ids[10])

	// Pagination stays stable across the two-digit boundary.
	page := TokensOfCollection("504", 8, 2)
	uassert.Equal(t, 2, len(page))
	uassert.Equal(t, "9", page[0])
	uassert.Equal(t, "10", page[1])
}

// TestWalletCounterOnlyKeptWhenCapped covers v5.4 change 3: the counter is
// skipped when there is no cap, but the cap itself must still be enforced
// exactly as before when one is set.
func TestWalletCounterOnlyKeptWhenCapped(cur realm, t *testing.T) {
	uncapped := newTestCollection(cur, "505", 0, 0)
	defer dropTestCollection("505")

	mint(cur, testBuyer, "505", "", "")
	mint(cur, testBuyer, "505", "", "")
	// No cap -> no counter written -> the view reports 0 and nothing is
	// enforced against it.
	uassert.Equal(t, int64(0), MintedByWallet("505", testBuyer))
	uassert.Equal(t, int64(0), int64(uncapped.mintedBy.Size()))

	capped := newTestCollection(cur, "506", 0, 2)
	defer dropTestCollection("506")

	mint(cur, testBuyer, "506", "", "")
	uassert.Equal(t, int64(1), MintedByWallet("506", testBuyer))
	mint(cur, testBuyer, "506", "", "")
	uassert.Equal(t, int64(2), MintedByWallet("506", testBuyer))
	uassert.Equal(t, int64(1), int64(capped.mintedBy.Size()))

	// Third mint by the same wallet is refused - the cap survived the
	// optimisation.
	uassert.PanicsWithMessage(t, cur,
		"wallet has reached this collection's per-wallet mint limit of 2",
		func() { mint(cur, testBuyer, "506", "", "") })

	// A different wallet is unaffected by another wallet's usage.
	mint(cur, testCreator, "506", "", "")
	uassert.Equal(t, int64(1), MintedByWallet("506", testCreator))
}
