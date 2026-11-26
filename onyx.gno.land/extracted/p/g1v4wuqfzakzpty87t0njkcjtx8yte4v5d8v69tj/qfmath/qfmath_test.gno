package qfmath

import (
	"math"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func sumInt64(xs []int64) int64 {
	var s int64
	for _, v := range xs {
		s += v
	}
	return s
}

func TestISqrt64Basic(t *testing.T) {
	cases := [][2]int64{
		{0, 0},
		{1, 1},
		{2, 1},
		{3, 1},
		{4, 2},
		{8, 2},
		{9, 3},
		{15, 3},
		{16, 4},
		{99, 9},
		{100, 10},
		{1_000_000, 1_000},
		{1_000_000_000_000, 1_000_000},
	}
	for _, tc := range cases {
		got := ISqrt64(tc[0])
		uassert.Equal(t, tc[1], got)
	}
}

func TestISqrt64MaxInt64(t *testing.T) {
	got := ISqrt64(math.MaxInt64)
	// floor(sqrt(2^63 - 1)) = 3037000499
	uassert.Equal(t, int64(3037000499), got)
	uassert.True(t, got*got <= math.MaxInt64)
	// (got+1)^2 would exceed MaxInt64, verify via u128
	nextSq := mul64(uint64(got+1), uint64(got+1))
	uassert.True(t, nextSq.cmp(u128From64(uint64(math.MaxInt64))) > 0)
}

func TestISqrt64NegativePanics(t *testing.T) {
	didPanic := false
	func() {
		defer func() {
			if r := recover(); r != nil {
				didPanic = true
			}
		}()
		ISqrt64(-1)
	}()
	uassert.True(t, didPanic)
}

func TestStandardQFEmptyAndZeroPool(t *testing.T) {
	uassert.Equal(t, 0, len(StandardQF(nil, 1_000_000)))
	uassert.Equal(t, 0, len(StandardQF([][]int64{}, 1_000_000)))

	zeroPool := StandardQF([][]int64{{100, 100}, {50, 50}}, 0)
	uassert.Equal(t, 2, len(zeroPool))
	uassert.Equal(t, int64(0), zeroPool[0])
	uassert.Equal(t, int64(0), zeroPool[1])

	noDonors := StandardQF([][]int64{{0, 0}, {0, 0}}, 10_000)
	uassert.Equal(t, int64(0), noDonors[0])
	uassert.Equal(t, int64(0), noDonors[1])
}

func TestStandardQFWhaleVsGrassroots(t *testing.T) {
	// Project 0: 1 whale gives 1,000,000 ugnot (1 GNOT)
	// Project 1: 10 grassroots donors each give 100,000 ugnot (same total: 1 GNOT)
	whaleRow := make([]int64, 11)
	whaleRow[0] = 1_000_000

	grassRow := make([]int64, 11)
	for i := 1; i <= 10; i++ {
		grassRow[i] = 100_000
	}

	pool := int64(10_000_000)
	alloc := StandardQF([][]int64{whaleRow, grassRow}, pool)
	uassert.Equal(t, int64(0), alloc[0])
	uassert.Equal(t, pool, alloc[1])
	uassert.Equal(t, pool, sumInt64(alloc))
}

func TestStandardQFEqualProjectsExactSplitAndDust(t *testing.T) {
	// 3 identical projects splitting 100 ugnot -> 34, 33, 33 (zero dust lost!)
	contribs := [][]int64{
		{500, 500},
		{500, 500},
		{500, 500},
	}
	alloc := StandardQF(contribs, 100)
	uassert.Equal(t, int64(100), sumInt64(alloc))
	uassert.Equal(t, int64(34), alloc[0])
	uassert.Equal(t, int64(33), alloc[1])
	uassert.Equal(t, int64(33), alloc[2])
}

func TestStandardQFAmplificationRatio(t *testing.T) {
	// Project 0: 2 donors x 100 = 200 direct -> cross-term = 1 pair * 100 = 100
	// Project 1: 5 donors x 40  = 200 direct -> cross-term = C(5,2)=10 pairs * 40 = 400
	// Ratio must be 1:4 -> 20% vs 80% of pool!
	contribs := [][]int64{
		{100, 100, 0, 0, 0, 0, 0},
		{0, 0, 40, 40, 40, 40, 40},
	}
	pool := int64(100_000)
	alloc := StandardQF(contribs, pool)
	uassert.Equal(t, pool, sumInt64(alloc))
	// Exact ratio 1:4 -> 20,000 vs 80,000 (within 1 ugnot rounding)
	uassert.True(t, alloc[0] >= 19_999 && alloc[0] <= 20_001)
	uassert.True(t, alloc[1] >= 79_999 && alloc[1] <= 80_001)
}

func TestStandardQFSingleDonorFallbackConservation(t *testing.T) {
	// When every project only has 1 donor, fallback preserves sum == pool.
	contribs := [][]int64{
		{400, 0},
		{0, 100},
	}
	pool := int64(300)
	alloc := StandardQF(contribs, pool)
	uassert.Equal(t, pool, sumInt64(alloc))
	// sqrt(400)=20 vs sqrt(100)=10 -> 2:1 -> 200 vs 100
	uassert.Equal(t, int64(200), alloc[0])
	uassert.Equal(t, int64(100), alloc[1])
}

func TestStandardQFRaggedMatrixRows(t *testing.T) {
	// Rows of different lengths should work cleanly.
	contribs := [][]int64{
		{100, 100},
		{0, 0, 100, 100},
	}
	alloc := StandardQF(contribs, 1_000)
	uassert.Equal(t, int64(500), alloc[0])
	uassert.Equal(t, int64(500), alloc[1])
}

func TestPairwiseQFSybilCollusionPenalty(t *testing.T) {
	// Project 0 (Collusion target): 2 sybil wallets co-donate 500,000 each -> direct 1,000,000
	//   AND those same 2 sybil wallets also co-donate 500,000 each to Project 1 (another collusion target)
	// Project 2 (Grassroots): 10 distinct organic donors each donate 100,000 -> direct 1,000,000
	//
	// Under StandardQF:
	//   Proj 0 cross-term = 1 * 500,000 = 500,000
	//   Proj 1 cross-term = 1 * 500,000 = 500,000
	//   Proj 2 cross-term = 45 * 100,000 = 4,500,000
	//   Proj 0 share = 500k / 5.5M = 9.09%
	//
	// Under PairwiseQF with M = 200,000:
	//   Sybil pair overlap O = 500,000 + 500,000 = 1,000,000 -> k_sybil = 200k / 1.2M = 0.1667!
	//   Grassroots pair overlap O = 100,000 -> k_grass = 200k / 300k = 0.6667 (4x higher!)
	//   So PairwiseQF slashes Collusion Proj 0 & 1 sharply and boosts Grassroots Proj 2!
	contribs := make([][]int64, 3)
	for p := 0; p < 3; p++ {
		contribs[p] = make([]int64, 12)
	}
	// Sybil wallets 0 & 1 co-donate heavily to projects 0 and 1
	contribs[0][0] = 500_000
	contribs[0][1] = 500_000
	contribs[1][0] = 500_000
	contribs[1][1] = 500_000
	// Organic donors 2..11 support grassroots project 2
	for d := 2; d < 12; d++ {
		contribs[2][d] = 100_000
	}

	pool := int64(10_000_000)
	stdAlloc := StandardQF(contribs, pool)
	pwAlloc := PairwiseQF(contribs, pool, 200_000)

	uassert.Equal(t, pool, sumInt64(stdAlloc))
	uassert.Equal(t, pool, sumInt64(pwAlloc))

	// Collusion projects MUST receive strictly less under PairwiseQF
	uassert.True(t, pwAlloc[0] < stdAlloc[0])
	uassert.True(t, pwAlloc[1] < stdAlloc[1])
	// Grassroots project MUST receive strictly more under PairwiseQF
	uassert.True(t, pwAlloc[2] > stdAlloc[2])

	// Verify magnitude: sybil funding cut by more than 65%!
	uassert.True(t, pwAlloc[0]*3 < stdAlloc[0])

	// Check CollusionDelta sums to zero (pure zero-sum redistribution)
	delta := CollusionDelta(stdAlloc, pwAlloc)
	uassert.Equal(t, int64(0), sumInt64(delta))
	uassert.True(t, delta[0] < 0)
	uassert.True(t, delta[2] > 0)
}

func TestPairwiseQFSybilSplittingVsOrganicParity(t *testing.T) {
	// Project 0: 2 sybil wallets donate 1,000,000 each (2M total, 1 heavy pair)
	// Project 1: 4 organic wallets donate 250,000 each (1M total, 6 light pairs)
	// Under StandardQF:
	//   Proj 0 cross-term = 1 * 1,000,000 = 1,000,000
	//   Proj 1 cross-term = 6 * 250,000   = 1,500,000
	//   Proj 0 gets 40%, Proj 1 gets 60%.
	// Under PairwiseQF (M = 250,000):
	//   Proj 0: O = 1,000,000 -> k = 250k/1.25M = 0.2 -> score = 200,000
	//   Proj 1: O = 250,000   -> k = 250k/500k  = 0.5 -> score = 750,000
	//   Proj 0 slashed from 40% down to ~21%, Proj 1 boosted from 60% to ~79%!
	contribs := [][]int64{
		{1_000_000, 1_000_000, 0, 0, 0, 0},
		{0, 0, 250_000, 250_000, 250_000, 250_000},
	}
	pool := int64(1_000_000)
	stdAlloc := StandardQF(contribs, pool)
	pwAlloc := PairwiseQF(contribs, pool, 250_000)

	uassert.Equal(t, int64(400_000), stdAlloc[0])
	uassert.Equal(t, int64(600_000), stdAlloc[1])
	uassert.Equal(t, pool, sumInt64(pwAlloc))
	// Expected: 200/(200+750) = 210526 and 789474
	uassert.True(t, pwAlloc[0] >= 210_520 && pwAlloc[0] <= 210_532)
	uassert.True(t, pwAlloc[1] >= 789_468 && pwAlloc[1] <= 789_480)
}

func TestPairwiseQFConvergesToStandardQFForLargeM(t *testing.T) {
	contribs := [][]int64{
		{500_000, 500_000, 0, 0, 0},
		{0, 0, 100_000, 100_000, 100_000},
	}
	pool := int64(1_000_000)
	stdAlloc := StandardQF(contribs, pool)
	pwLargeM := PairwiseQF(contribs, pool, 1_000_000_000_000) // M = 10^12 >> O
	uassert.Equal(t, pool, sumInt64(pwLargeM))
	diff0 := stdAlloc[0] - pwLargeM[0]
	if diff0 < 0 {
		diff0 = -diff0
	}
	uassert.True(t, diff0 <= 2)
}

func TestPairwiseQFConservationStressOddPools(t *testing.T) {
	contribs := [][]int64{
		{137, 293, 419, 0, 0},
		{137, 0, 509, 613, 0},
		{0, 293, 0, 613, 733},
		{11, 13, 17, 19, 23},
	}
	pools := []int64{1, 7, 99, 1_000_003, 999_999_999}
	for _, pool := range pools {
		s := StandardQF(contribs, pool)
		p := PairwiseQF(contribs, pool, 500)
		uassert.Equal(t, pool, sumInt64(s))
		uassert.Equal(t, pool, sumInt64(p))
		for i := range s {
			uassert.True(t, s[i] >= 0)
			uassert.True(t, p[i] >= 0)
		}
	}
}

func TestOverflowSafetyLargeContributions(t *testing.T) {
	// Huge ugnot values (~10^15 = 1 billion GNOT) must NOT overflow!
	const huge int64 = 1_000_000_000_000_000
	contribs := [][]int64{
		{huge, huge, 0, 0},
		{0, 0, huge / 4, huge / 4},
	}
	pool := int64(500_000_000_000_000)
	stdAlloc := StandardQF(contribs, pool)
	pwAlloc := PairwiseQF(contribs, pool, huge/2)

	uassert.Equal(t, pool, sumInt64(stdAlloc))
	uassert.Equal(t, pool, sumInt64(pwAlloc))
	uassert.True(t, stdAlloc[0] > stdAlloc[1])
	// Under PairwiseQF, bigger overlap on project 0 narrows its lead over project 1
	uassert.True(t, pwAlloc[1] > stdAlloc[1])
}

func TestNegativeAndInvalidInputsPanic(t *testing.T) {
	assertPanics := func(fn func()) {
		did := false
		func() {
			defer func() {
				if r := recover(); r != nil {
					did = true
				}
			}()
			fn()
		}()
		uassert.True(t, did)
	}

	assertPanics(func() { StandardQF([][]int64{{-1, 10}}, 100) })
	assertPanics(func() { StandardQF([][]int64{{10, 10}}, -1) })
	assertPanics(func() { PairwiseQF([][]int64{{10, 10}}, 100, 0) })
	assertPanics(func() { PairwiseQF([][]int64{{10, 10}}, 100, -50) })
	assertPanics(func() { NakamotoCoeff([]int64{10, -1}) })
	assertPanics(func() { ConcentrationBps([]int64{-5, 10}) })
	assertPanics(func() { CollusionDelta([]int64{1}, []int64{1, 2}) })
}

func TestNakamotoCoeff(t *testing.T) {
	uassert.Equal(t, 0, NakamotoCoeff(nil))
	uassert.Equal(t, 0, NakamotoCoeff([]int64{0, 0}))
	uassert.Equal(t, 1, NakamotoCoeff([]int64{100}))
	uassert.Equal(t, 1, NakamotoCoeff([]int64{60, 20, 20}))
	uassert.Equal(t, 2, NakamotoCoeff([]int64{50, 50}))
	uassert.Equal(t, 2, NakamotoCoeff([]int64{34, 33, 33}))
	// 10 equal donors -> 6 required to exceed 50%
	uassert.Equal(t, 6, NakamotoCoeff([]int64{10, 10, 10, 10, 10, 10, 10, 10, 10, 10}))
	// Unsorted input with zeros mixed in
	uassert.Equal(t, 2, NakamotoCoeff([]int64{0, 10, 40, 0, 35, 15}))
}

func TestConcentrationBps(t *testing.T) {
	uassert.Equal(t, int64(0), ConcentrationBps(nil))
	uassert.Equal(t, int64(0), ConcentrationBps([]int64{0, 0}))
	// Monopoly = 10,000 bps (100%)
	uassert.Equal(t, int64(10_000), ConcentrationBps([]int64{5_000_000}))
	// Two equal donors = 5,000 bps
	uassert.Equal(t, int64(5_000), ConcentrationBps([]int64{250, 250}))
	// Four equal donors = 2,500 bps
	uassert.Equal(t, int64(2_500), ConcentrationBps([]int64{100, 100, 100, 100}))
	// Ten equal donors = 1,000 bps
	uassert.Equal(t, int64(1_000), ConcentrationBps([]int64{10, 10, 10, 10, 10, 10, 10, 10, 10, 10}))
	// Skewed whale (90/10) -> (8100+100)/10000 = 8200 bps
	uassert.Equal(t, int64(8_200), ConcentrationBps([]int64{90, 10}))
}

func TestTopShareBps(t *testing.T) {
	uassert.Equal(t, int64(0), TopShareBps(nil))
	uassert.Equal(t, int64(10_000), TopShareBps([]int64{42}))
	uassert.Equal(t, int64(7_500), TopShareBps([]int64{75, 25}))
	uassert.Equal(t, int64(2_500), TopShareBps([]int64{100, 100, 100, 100}))
}

func TestU128ArithmeticIdentities(t *testing.T) {
	// Verify mul64 + divRem128 roundtrip near uint64 boundaries.
	a := uint64(1_000_000_000_000)
	b := uint64(987_654_321_123)
	prod := mul64(a, b)
	q, r := divRem128(prod, u128From64(a))
	uassert.Equal(t, uint64(0), q.hi)
	uassert.Equal(t, b, q.lo)
	uassert.True(t, r.isZero())

	// Verify isqrt128 exactness on large perfect squares above 2^64.
	x := uint64(10_000_000_000)
	uassert.Equal(t, x, isqrt128(mul64(x, x)))
	uassert.Equal(t, x-1, isqrt128(sub128(mul64(x, x), u128From64(1))))
}
