package nftoffers57

import (
	"testing"

	"chain/runtime"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// v5.7 dropped byToken/byBuyer/byCollection and answers every read from the
// single byExpiry index. Same rule as the marketplace: the cheaper shape is
// only acceptable if the answers are identical. The cases most likely to
// break are collection 1 picking up collection 11's bids, collection-wide
// bids being mixed into a token's own bid list, and an expired bid being
// presented as acceptable.

func addTestOffer(id, cid, tid int64, buyer address, amount, expiresAt int64) *Offer {
	o := &Offer{
		id: id, collectionID: cid, tokenID: tid, buyer: buyer,
		amountUgnot: amount, active: true, expiresAtHeight: expiresAt,
	}
	offers.Set(padID(o.id), o)
	indexActive(o)
	return o
}

func dropTestOffer(o *Offer) {
	if o.active {
		deactivate(o)
	}
	offers.Remove(padID(o.id))
}

func live() int64 { return runtime.ChainHeight() + 1_000_000 }

// TestOffersForTokenIsExact keeps the token bid list honest: only bids
// addressed to THAT token of THAT collection.
func TestOffersForTokenIsExact(t *testing.T) {
	buyer := testutils.TestAddress("ibuyer")

	mine := addTestOffer(201, 1, 2, buyer, 500, live())
	defer dropTestOffer(mine)
	otherToken := addTestOffer(202, 1, 3, buyer, 600, live())
	defer dropTestOffer(otherToken)
	// Collection 11, token 2: a string-prefix rewrite would leak this.
	neighbour := addTestOffer(203, 11, 2, buyer, 700, live())
	defer dropTestOffer(neighbour)
	// A collection-wide bid is not "addressed to" token 2.
	wide := addTestOffer(204, 1, 0, buyer, 800, live())
	defer dropTestOffer(wide)

	got := OffersForToken("1", "2")
	uassert.Equal(t, 1, len(got))
	uassert.Equal(t, "201", got[0].ID)

	gotNeighbour := OffersForToken("11", "2")
	uassert.Equal(t, 1, len(gotNeighbour))
	uassert.Equal(t, "203", gotNeighbour[0].ID)

	uassert.Equal(t, 0, len(OffersForToken("1", "99")))
}

// TestCollectionOffersIncludesWideBids: a collection page must show the
// collection-wide bids too, because those are real money any holder can take.
func TestCollectionOffersIncludesWideBids(t *testing.T) {
	buyer := testutils.TestAddress("ibuyer2")

	a := addTestOffer(211, 1, 1, buyer, 100, live())
	defer dropTestOffer(a)
	b := addTestOffer(212, 1, 0, buyer, 200, live())
	defer dropTestOffer(b)
	c := addTestOffer(213, 11, 1, buyer, 300, live())
	defer dropTestOffer(c)

	got := CollectionOffers("1", 0, 10)
	uassert.Equal(t, 2, len(got))
	for _, o := range got {
		uassert.Equal(t, "1", o.CollectionID)
	}
	uassert.Equal(t, 1, len(CollectionOffers("11", 0, 10)))
	uassert.Equal(t, 0, len(CollectionOffers("5", 0, 10)))
}

// TestOffersByBuyerFiltersAndPages covers the "my bids" view, which is how a
// buyer finds where their escrowed GNOT is locked. Interleaved noise proves
// the filtered offset does not drift.
func TestOffersByBuyerFiltersAndPages(t *testing.T) {
	me := testutils.TestAddress("mybids")
	other := testutils.TestAddress("otherbids")

	a := addTestOffer(221, 1, 1, me, 100, live())
	defer dropTestOffer(a)
	n1 := addTestOffer(222, 1, 2, other, 100, live())
	defer dropTestOffer(n1)
	b := addTestOffer(223, 2, 1, me, 200, live())
	defer dropTestOffer(b)
	n2 := addTestOffer(224, 2, 2, other, 100, live())
	defer dropTestOffer(n2)
	c := addTestOffer(225, 3, 1, me, 300, live())
	defer dropTestOffer(c)

	uassert.Equal(t, 3, len(OffersByBuyer(me, 0, 0)))
	uassert.Equal(t, 2, len(OffersByBuyer(other, 0, 0)))

	first := OffersByBuyer(me, 0, 2)
	second := OffersByBuyer(me, 2, 2)
	uassert.Equal(t, 2, len(first))
	uassert.Equal(t, 1, len(second))

	seen := map[string]bool{}
	for _, o := range first {
		seen[o.ID] = true
	}
	for _, o := range second {
		uassert.False(t, seen[o.ID])
		seen[o.ID] = true
	}
	uassert.Equal(t, 3, len(seen))
	uassert.Equal(t, 0, len(OffersByBuyer(me, 3, 2)))
}

// TestBestOfferForTokenPicksTheRealBest is the read a holder actually acts
// on, so it has to consider token-specific AND collection-wide bids, ignore
// expired escrow, and never cross collections.
func TestBestOfferForTokenPicksTheRealBest(t *testing.T) {
	buyer := testutils.TestAddress("bestbuyer")

	lowSpecific := addTestOffer(231, 1, 1, buyer, 1_000, live())
	defer dropTestOffer(lowSpecific)
	highWide := addTestOffer(232, 1, 0, buyer, 5_000, live())
	defer dropTestOffer(highWide)
	expiredHuge := addTestOffer(233, 1, 1, buyer, 99_000, 1)
	defer dropTestOffer(expiredHuge)
	otherCollection := addTestOffer(234, 11, 1, buyer, 50_000, live())
	defer dropTestOffer(otherCollection)
	otherToken := addTestOffer(235, 1, 2, buyer, 7_000, live())
	defer dropTestOffer(otherToken)

	best := BestOfferForToken("1", "1")
	uassert.Equal(t, "232", best.ID)
	uassert.Equal(t, int64(5_000), best.AmountUgnot)

	// Token 2 can take its own 7_000 bid, which beats the 5_000 wide one.
	uassert.Equal(t, "235", BestOfferForToken("1", "2").ID)

	// A token in a collection with no live bids reports nothing.
	uassert.Equal(t, "", BestOfferForToken("5", "1").ID)

	// Closing the wide bid falls back to the token's own live bid, never to
	// the expired one.
	deactivate(highWide)
	uassert.Equal(t, "231", BestOfferForToken("1", "1").ID)
}

// TestClosingAnOfferRemovesItFromEveryRead: with one index, a single removal
// must clear the offer from all reads AND from the sweep queue. Escrow that
// lingered in the sweep queue after being paid out would be a double spend.
func TestClosingAnOfferRemovesItFromEveryRead(t *testing.T) {
	buyer := testutils.TestAddress("closerbid")
	o := addTestOffer(241, 6, 3, buyer, 4_000, live())
	defer dropTestOffer(o)

	uassert.Equal(t, 1, len(OffersForToken("6", "3")))
	uassert.Equal(t, 1, len(OffersByBuyer(buyer, 0, 10)))
	uassert.Equal(t, 1, len(CollectionOffers("6", 0, 10)))
	uassert.Equal(t, "241", BestOfferForToken("6", "3").ID)

	before := activeCount
	deactivate(o)

	uassert.Equal(t, before-1, activeCount)
	uassert.Equal(t, 0, len(OffersForToken("6", "3")))
	uassert.Equal(t, 0, len(OffersByBuyer(buyer, 0, 10)))
	uassert.Equal(t, 0, len(CollectionOffers("6", 0, 10)))
	uassert.Equal(t, "", BestOfferForToken("6", "3").ID)

	// The record survives as history, marked closed.
	uassert.Equal(t, "241", GetOffer("241").ID)
	uassert.False(t, GetOffer("241").Active)
}

// TestExpiredOfferIsStillSweepableButNotAcceptable pins the distinction the
// single index has to keep straight: expired escrow must stay IN the sweep
// queue (so the buyer gets refunded) while being invisible to a holder
// looking for a bid to accept.
func TestExpiredOfferIsStillSweepableButNotAcceptable(t *testing.T) {
	buyer := testutils.TestAddress("rotten")
	o := addTestOffer(251, 7, 1, buyer, 3_000, 1)
	defer dropTestOffer(o)

	uassert.Equal(t, "", BestOfferForToken("7", "1").ID)
	uassert.True(t, ExpiredOfferCount() >= 1)
	// It is still listed as an active (funded) offer, because the money is
	// genuinely still locked until someone sweeps it.
	uassert.Equal(t, 1, len(OffersByBuyer(buyer, 0, 10)))
}
