package rankpay

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestParseSplits(cur realm, t *testing.T) {
	uassert.Equal(t, "50/30/20", Format(ParseSplits("50, 30, 20")))
	uassert.Equal(t, "100", Format(ParseSplits("100")))
	uassert.PanicsWithMessage(t, cur, "splits must sum to 100", func() { ParseSplits("50,30") })
	uassert.PanicsWithMessage(t, cur, "splits: a lower place cannot pay more than a higher one", func() { ParseSplits("30,70") })
	uassert.PanicsWithMessage(t, cur, "splits: each place must be a positive integer percent", func() { ParseSplits("50,x,50") })
	uassert.PanicsWithMessage(t, cur, "splits: each place must be a positive integer percent", func() { ParseSplits("100,0") })
	uassert.PanicsWithMessage(t, cur, "splits: 1 to 10 places, e.g. 50,30,20", func() { ParseSplits("") })
	uassert.PanicsWithMessage(t, cur, "splits: 1 to 10 places, e.g. 50,30,20", func() { ParseSplits("10,10,10,10,10,10,10,10,10,5,5") })
}

func TestSharesConserve(t *testing.T) {
	for _, pot := range []int64{1, 7, 999_999, 3_000_001, 10_000_000, 123_456_789} {
		for _, sp := range []string{"100", "50,30,20", "34,33,33", "40,20,10,10,10,10"} {
			sh := Shares(pot, ParseSplits(sp))
			sum := int64(0)
			for _, s := range sh {
				sum += s
			}
			uassert.Equal(t, pot, sum)
		}
	}
	sh := Shares(3_000_001, []int{50, 30, 20})
	uassert.Equal(t, int64(1_500_001), sh[0])
	uassert.Equal(t, int64(900_000), sh[1])
	// only 2 of 3 places filled: 50/30 re-weighted to 62.5%/37.5%
	two := Shares(8_000_000, []int{50, 30})
	uassert.Equal(t, int64(5_000_000), two[0])
	uassert.Equal(t, int64(3_000_000), two[1])
	eq := EqualShares(2_000_001, 2)
	uassert.Equal(t, int64(1_000_001), eq[0])
	uassert.Equal(t, int64(1_000_000), eq[1])
	uassert.Equal(t, 0, len(EqualShares(5, 0)))
}

func TestRankStableTies(t *testing.T) {
	// lower is better, ties keep input (submission) order
	r := Rank([]int64{120, 90, 90, 150}, false)
	uassert.Equal(t, 1, r[0])
	uassert.Equal(t, 2, r[1])
	uassert.Equal(t, 0, r[2])
	uassert.Equal(t, 3, r[3])
	h := Rank([]int64{5, 9, 9, 1}, true)
	uassert.Equal(t, 1, h[0])
	uassert.Equal(t, 2, h[1])
	uassert.Equal(t, 0, h[2])
	uassert.Equal(t, 0, len(Rank(nil, true)))
}
