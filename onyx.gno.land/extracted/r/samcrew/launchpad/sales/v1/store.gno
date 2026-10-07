package sales

import (
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// Per-token, per-buyer and per-claim state lives in AVL trees: a write touches
// one entry and the path to it. A realm-level Go map is stored as one object,
// so each write would cost gas in proportion to everything the map holds, and
// a busy sale could price its own buyers out of their claims. The four
// per-currency liabilities stay maps: they hold one entry per currency, and
// only the config admin gives a currency terms.
var (
	vestings         = avl.NewTree() // "<token id>:<index>" -> VestingRecord
	vestingCounts    = avl.NewTree() // token id -> int
	tokenLiabilities = avl.NewTree() // token id -> int64
	airdrops         = avl.NewTree() // token id -> AirdropRecord
	airdropClaims    = avl.NewTree() // "<token id>:<index>" -> true
	fairSales        = avl.NewTree() // token id -> FairSaleRecord
	fairBuyers       = avl.NewTree() // "<token id>:<buyer>" -> FairBuyerRecord
)

// A token id is "T" and digits, so ":" separates it from what follows.
func indexKey(id string, index int) string { return id + ":" + strconv.Itoa(index) }
func buyerKey(id string, buyer address) string { return id + ":" + string(buyer) }

func vestingCount(id string) int {
	n, _ := vestingCounts.Get(id).(int)
	return n
}

// vestingAt returns record index of a token, which the caller has checked
// to be below vestingCount.
func vestingAt(id string, index int) VestingRecord {
	return vestings.Get(indexKey(id, index)).(VestingRecord)
}

func setVesting(id string, index int, r VestingRecord) { vestings.Set(indexKey(id, index), r) }

func appendVesting(id string, r VestingRecord) {
	n := vestingCount(id)
	vestings.Set(indexKey(id, n), r)
	vestingCounts.Set(id, n+1)
}

func tokenOwed(id string) int64 {
	v, _ := tokenLiabilities.Get(id).(int64)
	return v
}

// A token that is owed nothing has no entry.
func setTokenOwed(id string, amount int64) {
	if amount == 0 {
		tokenLiabilities.Remove(id)
		return
	}
	tokenLiabilities.Set(id, amount)
}

// airdropOf returns the zero record for a token without a campaign.
func airdropOf(id string) AirdropRecord {
	r, _ := airdrops.Get(id).(AirdropRecord)
	return r
}
