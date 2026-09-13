package nftmarket57

import (
	"strconv"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// v5.7 replaced three duplicated index trees with filtered walks over the
// one active-only index. That is a fee win, but it is only acceptable if
// every read still returns EXACTLY what it returned before. These tests pin
// the answers, including the two cases a prefix/filter rewrite is most
// likely to get wrong: collection 1 leaking collection 11's listings, and
// paging a filtered view skipping rows.

func addTestListing(id, cid, tid int64, seller address, price int64) *Listing {
	l := &Listing{id: id, collectionID: cid, tokenID: tid, seller: seller, priceUgnot: price, active: true}
	listings.Set(padID(l.id), l)
	byToken.Set(strconv.FormatInt(cid, 10)+":"+strconv.FormatInt(tid, 10), l.id)
	indexActive(l)
	return l
}

func dropTestListing(l *Listing) {
	if l.active {
		deactivate(l)
	}
	listings.Remove(padID(l.id))
}

// TestListByCollectionDoesNotLeakNeighbours is the prefix test. byToken is
// keyed "collectionId:tokenId", so collection "1" must match "1:*" and never
// "11:*" - a naive prefix range would hand a buyer the wrong collection's
// floor price.
func TestListByCollectionDoesNotLeakNeighbours(t *testing.T) {
	seller := testutils.TestAddress("c1seller")
	one := addTestListing(101, 1, 1, seller, 5_000_000)
	defer dropTestListing(one)
	oneAgain := addTestListing(102, 1, 2, seller, 3_000_000)
	defer dropTestListing(oneAgain)
	eleven := addTestListing(103, 11, 1, seller, 1_000_000)
	defer dropTestListing(eleven)

	gotOne := ListByCollection("1", 0, 10)
	uassert.Equal(t, 2, len(gotOne))
	for _, li := range gotOne {
		uassert.Equal(t, "1", li.CollectionID)
	}

	gotEleven := ListByCollection("11", 0, 10)
	uassert.Equal(t, 1, len(gotEleven))
	uassert.Equal(t, "11", gotEleven[0].CollectionID)

	// The floor must be the collection's own cheapest listing, not the
	// cheapest listing on the whole marketplace.
	uassert.Equal(t, int64(3_000_000), FloorPrice("1"))
	uassert.Equal(t, int64(1_000_000), FloorPrice("11"))
	uassert.Equal(t, int64(0), FloorPrice("7"))
}

// TestListBySellerFiltersAcrossCollections covers the read that lost its
// dedicated tree: a seller's page must gather their listings from every
// collection and include nobody else's.
func TestListBySellerFiltersAcrossCollections(t *testing.T) {
	me := testutils.TestAddress("mine")
	other := testutils.TestAddress("theirs")

	a := addTestListing(111, 1, 5, me, 1_000)
	defer dropTestListing(a)
	b := addTestListing(112, 2, 5, me, 2_000)
	defer dropTestListing(b)
	c := addTestListing(113, 3, 5, me, 3_000)
	defer dropTestListing(c)
	d := addTestListing(114, 2, 6, other, 9_000)
	defer dropTestListing(d)

	mine := ListBySeller(me, 0, 10)
	uassert.Equal(t, 3, len(mine))
	for _, li := range mine {
		uassert.Equal(t, me, li.Seller)
	}
	uassert.Equal(t, 1, len(ListBySeller(other, 0, 10)))
	uassert.Equal(t, 0, len(ListBySeller(testutils.TestAddress("nobody"), 0, 10)))
}

// TestFilteredPagingCoversEveryRow is the subtle one: offset now counts
// MATCHED rows, so walking a filtered view page by page must visit each
// listing exactly once - no skips, no repeats.
func TestFilteredPagingCoversEveryRow(t *testing.T) {
	me := testutils.TestAddress("pager")
	noise := testutils.TestAddress("noise")

	// Interleave another seller's listings so a buggy offset would drift.
	a := addTestListing(121, 1, 21, me, 1_000)
	defer dropTestListing(a)
	n1 := addTestListing(122, 1, 22, noise, 1_000)
	defer dropTestListing(n1)
	b := addTestListing(123, 1, 23, me, 2_000)
	defer dropTestListing(b)
	n2 := addTestListing(124, 1, 24, noise, 1_000)
	defer dropTestListing(n2)
	c := addTestListing(125, 1, 25, me, 3_000)
	defer dropTestListing(c)

	first := ListBySeller(me, 0, 2)
	second := ListBySeller(me, 2, 2)
	uassert.Equal(t, 2, len(first))
	uassert.Equal(t, 1, len(second))

	seen := map[string]bool{}
	for _, li := range first {
		seen[li.ID] = true
	}
	for _, li := range second {
		uassert.False(t, seen[li.ID]) // no repeats across pages
		seen[li.ID] = true
	}
	uassert.Equal(t, 3, len(seen))
	uassert.True(t, seen["121"])
	uassert.True(t, seen["123"])
	uassert.True(t, seen["125"])

	// Paging past the end is empty, not a panic or a wrapped page.
	uassert.Equal(t, 0, len(ListBySeller(me, 3, 2)))
	// limit 0 means "no limit", as before.
	uassert.Equal(t, 3, len(ListBySeller(me, 0, 0)))
}

// TestClosingAListingRemovesItFromEveryRead is the safety half: with one
// index, a single removal has to take the listing out of all four reads at
// once. If it did not, the marketplace could sell a token twice.
func TestClosingAListingRemovesItFromEveryRead(t *testing.T) {
	seller := testutils.TestAddress("closer")
	l := addTestListing(131, 4, 9, seller, 7_000)
	defer dropTestListing(l)

	uassert.Equal(t, "131", ListingForToken("4", "9").ID)
	uassert.Equal(t, 1, len(ListActive(0, 10)))
	uassert.Equal(t, 1, len(ListBySeller(seller, 0, 10)))
	uassert.Equal(t, 1, len(ListByCollection("4", 0, 10)))
	uassert.Equal(t, int64(7_000), FloorPrice("4"))

	deactivate(l)

	uassert.Equal(t, "", ListingForToken("4", "9").ID)
	uassert.Equal(t, 0, len(ListActive(0, 10)))
	uassert.Equal(t, 0, len(ListBySeller(seller, 0, 10)))
	uassert.Equal(t, 0, len(ListByCollection("4", 0, 10)))
	uassert.Equal(t, int64(0), FloorPrice("4"))

	// The record itself survives for history/receipts, just not as active.
	uassert.Equal(t, "131", GetListing("131").ID)
	uassert.False(t, GetListing("131").Active)

	// And the token is free to be listed again: the guard entry is gone.
	uassert.Equal(t, nil, avlGet(byToken, "4:9"))
}
