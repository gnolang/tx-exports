// Package qfmath provides deterministic, zero-floating-point Quadratic Funding,
// Pairwise-Bounded Anti-Collusion Quadratic Funding (Buterin 2019), Largest-
// Remainder (Hamilton) dust-free apportionment, and governance decentralization
// metrics in pure integer arithmetic for Gno.land realms.
package qfmath

import "sort"

const (
	// sqrtScale2 scales input contributions by 10^8 prior to taking the square
	// root (yielding 10^4 precision on sqrt(c)), eliminating small-integer
	// truncation drift while staying strictly in exact integer math.
	sqrtScale2 uint64 = 100_000_000

	// kPrecision scales pairwise anti-collusion damping factors k_{i,j} = M / (M + O_{i,j})
	// into fixed-point billionths [0, 1_000_000_000].
	kPrecision uint64 = 1_000_000_000

	// bpsScale represents 100.00% in basis points.
	bpsScale uint64 = 10_000
)

// ISqrt64 returns the exact integer floor square root of n:
// the largest integer r >= 0 such that r*r <= n.
// Panics if n < 0.
func ISqrt64(n int64) int64 {
	if n < 0 {
		panic("qfmath: negative input to ISqrt64")
	}
	return int64(isqrt64u(uint64(n)))
}

// scaledSqrt returns nearest-rounded sqrt(c * 10^8) using exact 128-bit arithmetic.
func scaledSqrt(c int64) uint64 {
	if c < 0 {
		panic("qfmath: negative contribution")
	}
	if c == 0 {
		return 0
	}
	scaled := mul64(uint64(c), sqrtScale2)
	r := isqrt128(scaled)
	// Round to nearest integer: if (r+1)^2 - scaled < scaled - r^2, bump r by 1.
	rem := sub128(scaled, mul64(r, r))
	if rem.cmp(u128From64(r)) > 0 {
		r++
	}
	return r
}

// validateMatrix validates a project x donor contribution matrix and returns
// the maximum donor column width across all projects.
func validateMatrix(contributions [][]int64, matchingPool int64) int {
	if matchingPool < 0 {
		panic("qfmath: negative matching pool")
	}
	maxDonors := 0
	for p := range contributions {
		row := contributions[p]
		if len(row) > maxDonors {
			maxDonors = len(row)
		}
		for d := range row {
			if row[d] < 0 {
				panic("qfmath: negative contribution")
			}
		}
	}
	return maxDonors
}

// precomputeSqrts computes scaled square roots s[p][d] = floor(sqrt(c[p][d] * 10^6))
// alongside per-project direct donation sums and whether any project received funding.
func precomputeSqrts(contributions [][]int64, numDonors int) (sqrts [][]uint64, directSums []u128, anyFunded bool) {
	numProjects := len(contributions)
	sqrts = make([][]uint64, numProjects)
	directSums = make([]u128, numProjects)
	for p := 0; p < numProjects; p++ {
		row := contributions[p]
		sRow := make([]uint64, numDonors)
		var dSum u128
		for d := 0; d < len(row); d++ {
			c := row[d]
			if c > 0 {
				sRow[d] = scaledSqrt(c)
				dSum = add128(dSum, u128From64(uint64(c)))
				anyFunded = true
			}
		}
		sqrts[p] = sRow
		directSums[p] = dSum
	}
	return sqrts, directSums, anyFunded
}

// StandardQF computes classic CLR Quadratic Funding matching allocations:
//
//	score_p = (sum_d sqrt(c_{p,d}))^2 - sum_d c_{p,d} = 2 * sum_{i<j} sqrt(c_{p,i} * c_{p,j})
//
// Allocations are computed in exact 128-bit integer arithmetic with Largest-
// Remainder (Hamilton) dust distribution so sum(alloc) == matchingPool whenever
// at least one project has positive contributions (zero dust lost).
//
// If no project has >= 2 distinct donors (all cross-term QF scores are 0),
// matchingPool is apportioned proportionally to sqrt(direct_p) across funded
// projects so the matching pool conservation invariant still holds cleanly.
func StandardQF(contributions [][]int64, matchingPool int64) []int64 {
	numDonors := validateMatrix(contributions, matchingPool)
	numProjects := len(contributions)
	if numProjects == 0 {
		return []int64{}
	}
	if matchingPool == 0 {
		return make([]int64, numProjects)
	}

	sqrts, directSums, anyFunded := precomputeSqrts(contributions, numDonors)
	if !anyFunded {
		return make([]int64, numProjects)
	}

	scores := make([]u128, numProjects)
	var totalScore u128
	for p := 0; p < numProjects; p++ {
		sRow := sqrts[p]
		var pScore u128
		for i := 0; i < numDonors; i++ {
			si := sRow[i]
			if si == 0 {
				continue
			}
			for j := i + 1; j < numDonors; j++ {
				sj := sRow[j]
				if sj == 0 {
					continue
				}
				pScore = add128(pScore, mul64(si, sj))
			}
		}
		scores[p] = pScore
		totalScore = add128(totalScore, pScore)
	}

	if totalScore.isZero() {
		// All funded projects have only a single donor; fall back to sqrt(direct)
		// weights so conservation sum(alloc) == matchingPool holds cleanly.
		for p := 0; p < numProjects; p++ {
			if !directSums[p].isZero() {
				scores[p] = u128From64(isqrt128(mul128By64(directSums[p], sqrtScale2)))
			}
		}
	}

	return apportionHamilton(scores, matchingPool)
}

// PairwiseQF computes Vitalik Buterin's Pairwise-Bounded Anti-Collusion
// Quadratic Funding allocations in pure deterministic integer arithmetic:
//
//	O_{i,j} = sum_q sqrt(c_{q,i} * c_{q,j})       (total co-funding overlap of donors i & j)
//	k_{i,j} = M / (M + O_{i,j})                   (pairwise anti-collusion damping factor)
//	score_p = sum_{i<j} k_{i,j} * sqrt(c_{p,i} * c_{p,j})
//
// where M = penaltyCoeff (> 0, denominated in the same units as contributions, e.g. ugnot).
// Smaller M imposes stronger penalties on sybil/collusion pairs that co-donate heavily;
// as M grows large, PairwiseQF converges smoothly to StandardQF.
//
// Dust is distributed via Largest-Remainder (Hamilton) apportionment so
// sum(alloc) == matchingPool whenever at least one project is funded.
func PairwiseQF(contributions [][]int64, matchingPool int64, penaltyCoeff int64) []int64 {
	if penaltyCoeff <= 0 {
		panic("qfmath: penaltyCoeff must be positive")
	}
	numDonors := validateMatrix(contributions, matchingPool)
	numProjects := len(contributions)
	if numProjects == 0 {
		return []int64{}
	}
	if matchingPool == 0 {
		return make([]int64, numProjects)
	}

	sqrts, directSums, anyFunded := precomputeSqrts(contributions, numDonors)
	if !anyFunded {
		return make([]int64, numProjects)
	}

	mScaled := mul64(uint64(penaltyCoeff), sqrtScale2)
	mScaledNum := mul128By64(mScaled, kPrecision)

	scores := make([]u128, numProjects)
	var totalScore u128

	// Iterate over every unordered pair of distinct donors (i < j).
	for i := 0; i < numDonors; i++ {
		for j := i + 1; j < numDonors; j++ {
			// Compute pairwise co-funding overlap O_{i,j} across all projects.
			var overlapScaled u128
			for p := 0; p < numProjects; p++ {
				si := sqrts[p][i]
				sj := sqrts[p][j]
				if si != 0 && sj != 0 {
					overlapScaled = add128(overlapScaled, mul64(si, sj))
				}
			}
			if overlapScaled.isZero() {
				continue
			}

			// kFixed = floor((M * 10^6 * 10^9) / (M * 10^6 + overlapScaled))
			denom := add128(mScaled, overlapScaled)
			kFixedQ, _ := divRem128(mScaledNum, denom)
			kFixed := kFixedQ.lo
			if kFixed == 0 {
				// Preserve minimal non-zero weight of 1e-9 for extreme whales so
				// pairwise pairs still dominate zero-donor projects.
				kFixed = 1
			}

			for p := 0; p < numProjects; p++ {
				si := sqrts[p][i]
				sj := sqrts[p][j]
				if si != 0 && sj != 0 {
					pairTerm := mul64(si, sj)
					weighted := mul128By64(pairTerm, kFixed)
					scores[p] = add128(scores[p], weighted)
					totalScore = add128(totalScore, weighted)
				}
			}
		}
	}

	if totalScore.isZero() {
		for p := 0; p < numProjects; p++ {
			if !directSums[p].isZero() {
				scores[p] = u128From64(isqrt128(mul128By64(directSums[p], sqrtScale2)))
			}
		}
	}

	return apportionHamilton(scores, matchingPool)
}

type remItem struct {
	idx int
	rem u128
}

type remItemSort []remItem

func (s remItemSort) Len() int { return len(s) }
func (s remItemSort) Less(i, j int) bool {
	c := s[i].rem.cmp(s[j].rem)
	if c != 0 {
		return c > 0
	}
	return s[i].idx < s[j].idx
}
func (s remItemSort) Swap(i, j int) { s[i], s[j] = s[j], s[i] }

type descUint64Sort []uint64

func (s descUint64Sort) Len() int           { return len(s) }
func (s descUint64Sort) Less(i, j int) bool { return s[i] > s[j] }
func (s descUint64Sort) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }

// apportionHamilton distributes pool across scores using the Largest-Remainder
// (Hamilton) method with deterministic tie-breaking by ascending index.
// Guarantees sum(alloc) == pool whenever sum(scores) > 0, and |alloc[i] - exact_i| < 1.
func apportionHamilton(scores []u128, pool int64) []int64 {
	n := len(scores)
	alloc := make([]int64, n)
	if n == 0 || pool == 0 {
		return alloc
	}

	var total u128
	for i := 0; i < n; i++ {
		total = add128(total, scores[i])
	}
	if total.isZero() {
		return alloc
	}

	poolU := uint64(pool)
	// Ensure scores[i] * poolU never overflows 128 bits by symmetrically
	// right-shifting all scores when total.bitLen() + poolU.bitLen() > 126.
	norm := make([]u128, n)
	copy(norm, scores)
	poolBits := bitLen64(poolU)
	if total.bitLen()+poolBits > 126 {
		shift := uint(total.bitLen() + poolBits - 126)
		total = u128{}
		for i := 0; i < n; i++ {
			if !norm[i].isZero() {
				shifted := norm[i].rsh(shift)
				if shifted.isZero() {
					shifted = u128From64(1)
				}
				norm[i] = shifted
				total = add128(total, shifted)
			}
		}
	}

	rems := make([]remItem, n)
	var allocated int64
	for i := 0; i < n; i++ {
		if norm[i].isZero() {
			rems[i] = remItem{idx: i}
			continue
		}
		num := mul128By64(norm[i], poolU)
		q, r := divRem128(num, total)
		alloc[i] = int64(q.lo)
		allocated += alloc[i]
		rems[i] = remItem{idx: i, rem: r}
	}

	dust := pool - allocated
	if dust > 0 {
		sort.Sort(remItemSort(rems))
		for k := int64(0); k < dust && int(k) < n; k++ {
			alloc[rems[k].idx]++
		}
	}
	return alloc
}

// CollusionDelta returns pairwiseAlloc[i] - standardAlloc[i] for each project.
// Negative values indicate matching subsidy suppressed from collusive/whale pairs;
// positive values indicate matching subsidy redirected to grassroots projects.
func CollusionDelta(standardAlloc, pairwiseAlloc []int64) []int64 {
	if len(standardAlloc) != len(pairwiseAlloc) {
		panic("qfmath: allocation length mismatch")
	}
	delta := make([]int64, len(standardAlloc))
	for i := range standardAlloc {
		delta[i] = pairwiseAlloc[i] - standardAlloc[i]
	}
	return delta
}

// NakamotoCoeff returns the minimum number of entities required to control
// strictly more than 50% of the total weight.
// Returns 0 if weights are empty or all zero. Panics if any weight is negative.
func NakamotoCoeff(weights []int64) int {
	pos := make([]uint64, 0, len(weights))
	var total u128
	for _, w := range weights {
		if w < 0 {
			panic("qfmath: negative weight")
		}
		if w > 0 {
			pos = append(pos, uint64(w))
			total = add128(total, u128From64(uint64(w)))
		}
	}
	if len(pos) == 0 {
		return 0
	}

	sort.Sort(descUint64Sort(pos))

	var acc u128
	for i, w := range pos {
		acc = add128(acc, u128From64(w))
		// Strictly greater than 50%: 2*acc > total
		if mul128By64(acc, 2).cmp(total) > 0 {
			return i + 1
		}
	}
	return len(pos)
}

// ConcentrationBps computes the Herfindahl-Hirschman Index (HHI) in basis
// points (0..10000): floor(10000 * sum(w_i^2) / (sum(w_i))^2).
//   - 10000 bps = single-entity monopoly (100% concentrated)
//   - 5000 bps  = two equal entities
//   - 1000 bps  = ten equal entities
//   - 0 bps     = empty or all-zero weights
//
// Panics if any weight is negative.
func ConcentrationBps(weights []int64) int64 {
	var total u128
	var sumSq u128
	for _, w := range weights {
		if w < 0 {
			panic("qfmath: negative weight")
		}
		if w > 0 {
			u := uint64(w)
			total = add128(total, u128From64(u))
			sumSq = add128(sumSq, mul64(u, u))
		}
	}
	if total.isZero() {
		return 0
	}
	// If total fits in uint64, compute exact total^2 directly in u128.
	// If total > MaxUint64 (huge slice of large int64s), shift down both terms
	// symmetrically so total^2 fits in u128 without overflow.
	if total.hi == 0 {
		totSq := mul64(total.lo, total.lo)
		q, _ := divRem128(mul128By64(sumSq, bpsScale), totSq)
		return int64(q.lo)
	}
	shift := uint(total.bitLen() - 63)
	tShifted := total.rsh(shift)
	totSq := mul64(tShifted.lo, tShifted.lo)
	sShifted := sumSq.rsh(shift * 2)
	q, _ := divRem128(mul128By64(sShifted, bpsScale), totSq)
	if q.lo > bpsScale {
		return int64(bpsScale)
	}
	return int64(q.lo)
}

// TopShareBps returns the largest single entity's share of total weight in
// basis points (0..10000). Panics if any weight is negative.
func TopShareBps(weights []int64) int64 {
	var total u128
	var maxW uint64
	for _, w := range weights {
		if w < 0 {
			panic("qfmath: negative weight")
		}
		if w > 0 {
			u := uint64(w)
			total = add128(total, u128From64(u))
			if u > maxW {
				maxW = u
			}
		}
	}
	if total.isZero() {
		return 0
	}
	q, _ := divRem128(mul64(maxW, bpsScale), total)
	return int64(q.lo)
}
