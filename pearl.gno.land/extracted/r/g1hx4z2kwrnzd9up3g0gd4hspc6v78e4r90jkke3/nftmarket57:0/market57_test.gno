package nftmarket57

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// NOTE: List/Buy/Cancel need a funded chain and a direct wallet MsgCall, so
// those paths are verified on-chain on Pearl. The pure logic that v5 changed
// (int64 records, index keys, the exported string wire format) is tested here.

func TestSplitPayment(t *testing.T) {
	// Exact payment, royalty to a third party.
	royalty, seller, refund := splitPayment(1000, 1000, 50, false)
	uassert.Equal(t, int64(50), royalty)
	uassert.Equal(t, int64(950), seller)
	uassert.Equal(t, int64(0), refund)

	// Overpayment is refunded, never kept by the realm.
	royalty, seller, refund = splitPayment(1000, 1500, 50, false)
	uassert.Equal(t, int64(500), refund)
	uassert.Equal(t, int64(1000), royalty+seller)

	// No royalty when it would just pay the seller their own money.
	royalty, seller, refund = splitPayment(1000, 1000, 50, true)
	uassert.Equal(t, int64(0), royalty)
	uassert.Equal(t, int64(1000), seller)

	// A royalty at or above the price is ignored rather than zeroing the seller.
	royalty, seller, _ = splitPayment(1000, 1000, 1000, false)
	uassert.Equal(t, int64(0), royalty)
	uassert.Equal(t, int64(1000), seller)
}

// TestParseIDRejectsGarbage guards the v5 record shrinking: ids now live as
// int64, so anything that is not a positive decimal must be refused at the
// door instead of silently becoming 0.
func TestParseIDRejectsGarbage(cur realm, t *testing.T) {
	uassert.Equal(t, int64(7), parseID("7", "token id"))

	uassert.PanicsWithMessage(t, cur, "invalid token id: 0", func() {
		parseID("0", "token id")
	})
	uassert.PanicsWithMessage(t, cur, "invalid collection id: x1", func() {
		parseID("x1", "collection id")
	})
}

func TestPadIDSortsNumerically(t *testing.T) {
	uassert.Equal(t, "000000000002", padID(2))
	uassert.Equal(t, "000000000010", padID(10))
	uassert.True(t, padID(2) < padID(10))
}

// TestToInfoKeepsStringWireFormat: records shrank to int64 internally, but the
// exported view must still speak the exact same strings the frontend decoder
// expects, in the same field order.
func TestToInfoKeepsStringWireFormat(t *testing.T) {
	seller := testutils.TestAddress("seller")
	info := toInfo(&Listing{id: 2, collectionID: 3, tokenID: 11, seller: seller, priceUgnot: 5_000_000, active: true, createdAt: 42})
	uassert.Equal(t, "2", info.ID)
	uassert.Equal(t, "3", info.CollectionID)
	uassert.Equal(t, "11", info.TokenID)
	uassert.Equal(t, seller, info.Seller)
	uassert.Equal(t, int64(5_000_000), info.PriceUgnot)
	uassert.True(t, info.Active)
	uassert.Equal(t, int64(42), info.CreatedAt)
}

// TestIndexLifecycle checks that a listing enters every index it should and
// leaves all of them on deactivate, so ListActive can never serve a sold item.
func TestIndexLifecycle(t *testing.T) {
	seller := testutils.TestAddress("seller2")
	l := &Listing{id: 5, collectionID: 1, tokenID: 4, seller: seller, priceUgnot: 1000, active: true}
	listings.Set(padID(l.id), l)
	byToken.Set("1:4", l.id)
	indexActive(l)

	uassert.Equal(t, int64(1), activeCount)
	uassert.Equal(t, "5", ListingForToken("1", "4").ID)
	uassert.Equal(t, 1, len(ListActive(0, 10)))
	uassert.Equal(t, 1, len(ListBySeller(seller, 0, 10)))
	uassert.Equal(t, 1, len(ListByCollection("1", 0, 10)))
	uassert.Equal(t, int64(1000), FloorPrice("1"))

	deactivate(l)

	uassert.Equal(t, int64(0), activeCount)
	uassert.Equal(t, "", ListingForToken("1", "4").ID)
	uassert.Equal(t, 0, len(ListActive(0, 10)))
	uassert.Equal(t, 0, len(ListBySeller(seller, 0, 10)))
	uassert.Equal(t, int64(0), FloorPrice("1"))
	listings.Remove(padID(5))
}
