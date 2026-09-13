package nftoffers57

import (
	"strconv"
	"testing"

	"chain/runtime"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// NOTE: MakeOffer/AcceptOffer/CancelOffer/RejectOffer/SweepExpired move real
// escrowed coins and are gated on a direct wallet MsgCall, so the money paths
// are verified on-chain on Pearl. Everything that does not require a funded
// chain (payout split, expiry selection, index keys, id parsing, the
// collection-wide rejection rule) is factored out and tested here.

func TestSplitPayment(t *testing.T) {
	// Royalty comes out of the escrowed amount.
	royalty, seller := splitPayment(1000, 50, false)
	uassert.Equal(t, int64(50), royalty)
	uassert.Equal(t, int64(950), seller)

	// No royalty when the creator is the one selling.
	royalty, seller = splitPayment(1000, 50, true)
	uassert.Equal(t, int64(0), royalty)
	uassert.Equal(t, int64(1000), seller)

	// A royalty at or above the amount is ignored rather than zeroing the seller.
	royalty, seller = splitPayment(1000, 1000, false)
	uassert.Equal(t, int64(0), royalty)
	uassert.Equal(t, int64(1000), seller)

	// The split always conserves the escrow.
	royalty, seller = splitPayment(7777, 13, false)
	uassert.Equal(t, int64(7777), royalty+seller)
}

// TestResolveToken covers collection-wide offers: a token-specific offer stays
// pinned to its token, while a collection-wide bid requires the accepting
// holder to name which token they are selling.
func TestResolveToken(cur realm, t *testing.T) {
	tokenOffer := &Offer{id: 1, collectionID: 1, tokenID: 7}
	collOffer := &Offer{id: 2, collectionID: 1, tokenID: 0}

	uassert.Equal(t, "7", resolveToken(tokenOffer, ""))
	uassert.Equal(t, "7", resolveToken(tokenOffer, "7"))
	uassert.Equal(t, "3", resolveToken(collOffer, "3"))

	uassert.PanicsWithMessage(t, cur, "this offer is for token 7, not 9", func() {
		resolveToken(tokenOffer, "9")
	})
	uassert.PanicsWithMessage(t, cur, "this is a collection-wide offer: pass the tokenID you want to sell", func() {
		resolveToken(collOffer, "")
	})
}

// TestParseIDRejectsGarbage guards the v5 record shrinking: ids now live as
// int64, so anything that is not a positive decimal must be refused at the
// door instead of silently becoming 0.
func TestParseIDRejectsGarbage(cur realm, t *testing.T) {
	uassert.Equal(t, int64(12), parseID("12", "token id"))

	uassert.PanicsWithMessage(t, cur, "invalid token id: 0", func() {
		parseID("0", "token id")
	})
	uassert.PanicsWithMessage(t, cur, "invalid token id: -3", func() {
		parseID("-3", "token id")
	})
	uassert.PanicsWithMessage(t, cur, "invalid collection id: abc", func() {
		parseID("abc", "collection id")
	})
}

// TestPadIDSortsNumerically is why the indexes use padded keys: without
// padding "10" would sort before "2" and pagination would jump around.
func TestPadIDSortsNumerically(t *testing.T) {
	uassert.Equal(t, "000000000002", padID(2))
	uassert.Equal(t, "000000000010", padID(10))
	uassert.True(t, padID(2) < padID(10))
	uassert.True(t, padID(999) < padID(1000))
}

// TestToInfoKeepsStringWireFormat: records shrank to int64 internally, but the
// exported view must still speak the exact same strings the frontend decoder
// expects, with "" for a collection-wide offer's token.
func TestToInfoKeepsStringWireFormat(t *testing.T) {
	info := toInfo(&Offer{id: 3, collectionID: 4, tokenID: 9, amountUgnot: 500, active: true})
	uassert.Equal(t, "3", info.ID)
	uassert.Equal(t, "4", info.CollectionID)
	uassert.Equal(t, "9", info.TokenID)
	uassert.Equal(t, int64(500), info.AmountUgnot)
	uassert.True(t, info.Active)

	wide := toInfo(&Offer{id: 4, collectionID: 4, tokenID: 0})
	uassert.Equal(t, "", wide.TokenID)
}

// TestExpiryIndexFindsOnlyExpired is the selection half of SweepExpired: the
// byExpiry walk must pick up offers whose deadline has passed and stop at the
// first one that is still alive.
func TestExpiryIndexFindsOnlyExpired(t *testing.T) {
	buyer := testutils.TestAddress("obuyer")
	height := runtime.ChainHeight()

	stale := &Offer{id: 1, collectionID: 1, tokenID: 1, buyer: buyer, amountUgnot: 100, active: true, expiresAtHeight: 1}
	alsoStale := &Offer{id: 2, collectionID: 1, tokenID: 2, buyer: buyer, amountUgnot: 200, active: true, expiresAtHeight: height}
	live := &Offer{id: 3, collectionID: 1, tokenID: 3, buyer: buyer, amountUgnot: 300, active: true, expiresAtHeight: height + 1_000_000}

	for _, o := range []*Offer{stale, alsoStale, live} {
		offers.Set(padID(o.id), o)
		indexActive(o)
	}

	// An offer expiring exactly at the current height is sweepable.
	uassert.Equal(t, int64(2), ExpiredOfferCount())

	// Closing one removes it from every index, including byExpiry.
	deactivate(stale)
	uassert.Equal(t, int64(1), ExpiredOfferCount())
	uassert.Equal(t, int64(2), activeCount)

	// The live offer is never picked up.
	deactivate(alsoStale)
	uassert.Equal(t, int64(0), ExpiredOfferCount())
	uassert.True(t, live.active)

	deactivate(live)
	uassert.Equal(t, int64(0), activeCount)
	offers.Remove(padID(1))
	offers.Remove(padID(2))
	offers.Remove(padID(3))
}

// TestSweepLimitIsClamped keeps one sweep inside the block gas limit no matter
// how many offers rotted at once.
func TestSweepLimitIsClamped(t *testing.T) {
	uassert.Equal(t, "50", strconv.FormatInt(int64(MaxSweepLimit), 10))
}

// TestRejectRefusesCollectionWideOffers: a collection-wide bid is addressed to
// every holder at once, so no single holder may kill it for everyone else.
func TestRejectRefusesCollectionWideOffers(cur realm, t *testing.T) {
	buyer := testutils.TestAddress("obuyer2")
	wide := &Offer{id: 90, collectionID: 1, tokenID: 0, buyer: buyer, amountUgnot: 100, active: true, expiresAtHeight: runtime.ChainHeight() + 1000}
	offers.Set(padID(wide.id), wide)
	indexActive(wide)

	uassert.PanicsWithMessage(t, cur,
		"collection-wide offers cannot be rejected; they are not addressed to a single owner",
		func() {
			RejectOffer(cur, "90")
		})

	// A closed offer cannot be rejected either.
	deactivate(wide)
	uassert.PanicsWithMessage(t, cur, "offer is not active", func() {
		RejectOffer(cur, "90")
	})
	uassert.PanicsWithMessage(t, cur, "offer not found: 12345", func() {
		RejectOffer(cur, "12345")
	})
	offers.Remove(padID(90))
}
