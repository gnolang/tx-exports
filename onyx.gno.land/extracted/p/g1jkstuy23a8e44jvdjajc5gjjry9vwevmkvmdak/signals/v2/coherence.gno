package signals

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

func unitNormalizeInto(dst, vec []int64) error {
	if len(vec) == 0 {
		return errors.New("vector cannot be empty")
	}
	if len(dst) != len(vec) {
		return errors.New("destination vector dimension mismatch")
	}
	// Downscale if max abs coordinate exceeds 1_000_000 to prevent uint64 overflow in sum of squares.
	var maxAbs uint64
	for _, v := range vec {
		a := uint64(Abs64(v))
		if a > maxAbs {
			maxAbs = a
		}
	}
	if maxAbs == 0 {
		return errors.New("zero vector cannot be normalized")
	}

	shift := uint(0)
	for (maxAbs >> shift) > 1000000 {
		shift++
	}

	var sqSum uint64
	for _, v := range vec {
		a := uint64(Abs64(v)) >> shift
		sqSum += a * a
	}
	norm := ISqrt64(sqSum)
	if norm == 0 {
		return errors.New("zero norm after scaling")
	}

	for i, v := range vec {
		neg := v < 0
		a := uint64(Abs64(v)) >> shift
		val := int64((a * uint64(Scale)) / norm)
		if neg {
			val = -val
		}
		dst[i] = val
	}
	return nil
}

// UnitNormalizeFixed projects a non-zero integer/fixed-point vector onto the unit sphere
// of radius Scale (1_000_000), deterministically across all validators.
func UnitNormalizeFixed(vec []int64) ([]int64, error) {
	if len(vec) == 0 {
		return nil, errors.New("vector cannot be empty")
	}
	unit := make([]int64, len(vec))
	if err := unitNormalizeInto(unit, vec); err != nil {
		return nil, err
	}
	return unit, nil
}

func validateVectorSetDimensions(vectors [][]int64) (int, error) {
	if len(vectors) < 2 {
		return 0, errors.New("coherence requires at least 2 vectors")
	}
	dim := len(vectors[0])
	if dim == 0 {
		return 0, errors.New("vectors must have positive dimension")
	}
	for i := 1; i < len(vectors); i++ {
		if len(vectors[i]) != dim {
			return 0, errors.New("all vectors in set must share the same dimension")
		}
	}
	return dim, nil
}

func validateAndNormalizeSet(vectors [][]int64) ([][]int64, error) {
	if _, err := validateVectorSetDimensions(vectors); err != nil {
		return nil, err
	}
	units := make([][]int64, len(vectors))
	for i, v := range vectors {
		u, err := UnitNormalizeFixed(v)
		if err != nil {
			return nil, err
		}
		units[i] = u
	}
	return units, nil
}

// MeanResultantLengthFixed computes ||mean(unit(v_i))|| in [0, Scale].
// Strictly order-invariant and O(n * d): 1.0*Scale when all vectors align, 0 when they cancel.
func MeanResultantLengthFixed(vectors [][]int64) (int64, error) {
	units, err := validateAndNormalizeSet(vectors)
	if err != nil {
		return 0, err
	}
	n := int64(len(units))
	dim := len(units[0])
	var sqSum uint64
	for j := 0; j < dim; j++ {
		var colSum int64
		for i := 0; i < len(units); i++ {
			colSum += units[i][j]
		}
		meanJ := colSum / n
		am := uint64(Abs64(meanJ))
		sqSum += am * am
	}
	res := int64(ISqrt64(sqSum))
	if res > Scale {
		res = Scale
	}
	return res, nil
}

// MeanPairwiseCosineFixed computes the exact mean cosine over all n*(n-1) distinct pairs
// in O(n * d) using the resultant identity: (||sum(u_i)||^2 - n) / (n * (n - 1)).
// Returns fixed-point value in [-Scale, +Scale], strictly order-invariant.
func MeanPairwiseCosineFixed(vectors [][]int64) (int64, error) {
	units, err := validateAndNormalizeSet(vectors)
	if err != nil {
		return 0, err
	}
	n := int64(len(units))
	dim := len(units[0])

	// sumNormSqFixed = ||sum(u_i)||^2 / Scale (in Scale units, where each u_i has ||u_i||^2 = Scale^2).
	var sumNormSqFixed int64
	for j := 0; j < dim; j++ {
		var colSum int64
		for i := 0; i < len(units); i++ {
			colSum += units[i][j]
		}
		sumNormSqFixed += MulFixed(colSum, colSum)
	}
	// Result = (sumNormSqFixed - n*Scale) / (n * (n - 1))
	num := sumNormSqFixed - n*Scale
	den := n * (n - 1)
	res := num / den
	if res > Scale {
		res = Scale
	}
	if res < -Scale {
		res = -Scale
	}
	return res, nil
}

// CoherenceGate evaluates whether a retrieved memory / context embedding batch is coherent
// enough to inject into an agent's reasoning window (blocking cross-session memory poisoning).
func CoherenceGate(vectors [][]int64, thresholdFixed int64, usePairwise bool) (bool, int64, SignalEvidence, error) {
	var (
		score int64
		err   error
		mode  int64
	)
	if usePairwise {
		mode = 1
		score, err = MeanPairwiseCosineFixed(vectors)
	} else {
		mode = 0
		score, err = MeanResultantLengthFixed(vectors)
	}
	if err != nil {
		return false, 0, SignalEvidence{}, err
	}
	pass := score >= thresholdFixed

	// Order-invariant digest over sorted vector hashes so input digest matches set semantics.
	inDigest := digestVectorSet(vectors)
	detail := "coherent_pass"
	if !pass {
		detail = "coherence_below_threshold"
	}
	ev := SignalEvidence{
		Primitive:    "signals.coherence_gate",
		Version:      "1",
		ParamsDigest: hashInt64s("coherence_gate", thresholdFixed, mode),
		InputDigest:  inDigest,
		OutputFixed:  score,
		Alarm:        !pass,
		Detail:       detail,
	}
	return pass, score, ev, nil
}

func digestVectorSet(vectors [][]int64) [32]byte {
	// XOR-independent canonical accumulation over vector hashes sorted lexicographically.
	hashes := make([][32]byte, len(vectors))
	for i, v := range vectors {
		buf := make([]byte, 0, 8+len(v)*8)
		buf = binary.BigEndian.AppendUint64(buf, uint64(len(v)))
		for _, x := range v {
			buf = binary.BigEndian.AppendUint64(buf, uint64(x))
		}
		hashes[i] = sha256.Sum256(buf)
	}
	// Simple deterministic insertion sort on 32-byte hashes (no extra imports needed).
	for i := 1; i < len(hashes); i++ {
		key := hashes[i]
		j := i - 1
		for j >= 0 && bytesLess(key, hashes[j]) {
			hashes[j+1] = hashes[j]
			j--
		}
		hashes[j+1] = key
	}
	all := make([]byte, 0, 16+len(hashes)*32)
	all = appendStr(all, "vecset-v1")
	for _, h := range hashes {
		all = append(all, h[:]...)
	}
	return sha256.Sum256(all)
}

func bytesLess(a, b [32]byte) bool {
	for i := 0; i < 32; i++ {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

func hashSingleVec(v []int64) [32]byte {
	buf := make([]byte, 0, 8+len(v)*8)
	buf = binary.BigEndian.AppendUint64(buf, uint64(len(v)))
	for _, x := range v {
		buf = binary.BigEndian.AppendUint64(buf, uint64(x))
	}
	return sha256.Sum256(buf)
}

// discreteMedoidIndex returns the index of the strictly order-invariant discrete L1 medoid
// of a unit vector set (minimizing sum_j ||u_i - u_j||, breaking exact-distance ties
// deterministically by canonical vector SHA-256). Eliminates the exact 180-degree cancellation
// order-dependence discovered in Experiment E7a (cross-referencing @frintroper/Symmetry-No-Symmetry).
func discreteMedoidIndex(units [][]int64) int {
	n := len(units)
	dim := len(units[0])
	bestIdx := 0
	var bestSum uint64
	var bestHash [32]byte
	haveBest := false

	for i := 0; i < n; i++ {
		var sumDist uint64
		for j := 0; j < n; j++ {
			if i == j {
				continue
			}
			var sq uint64
			for d := 0; d < dim; d++ {
				ds := uint64(Abs64(units[i][d]-units[j][d]) / 1000)
				sq += ds * ds
			}
			sumDist += ISqrt64(sq)
		}
		h := hashSingleVec(units[i])
		if !haveBest || sumDist < bestSum || (sumDist == bestSum && bytesLess(h, bestHash)) {
			haveBest = true
			bestSum = sumDist
			bestHash = h
			bestIdx = i
		}
	}
	return bestIdx
}

func geometricMedianOnUnits(units [][]int64, iters int) ([]int64, error) {
	if _, err := validateVectorSetDimensions(units); err != nil {
		return nil, err
	}
	if iters <= 0 {
		iters = 8
	}
	dim := len(units[0])
	n := len(units)

	// Allocate working buffers once outside the Weiszfeld loop.
	num := make([]int64, dim)
	med := make([]int64, dim)
	copy(med, units[discreteMedoidIndex(units)])

	const epsDist int64 = 1000 // 0.001 in Scale units prevents 0/0 singularity
	for it := 0; it < iters; it++ {
		for j := 0; j < dim; j++ {
			num[j] = 0
		}
		var den int64
		for i := 0; i < n; i++ {
			var sq uint64
			for j := 0; j < dim; j++ {
				d := Abs64(units[i][j] - med[j])
				// Scale down by 1000 so d^2 fits safely inside uint64 for high dimensions.
				ds := uint64(d / 1000)
				sq += ds * ds
			}
			dist := int64(ISqrt64(sq)) * 1000
			if dist < epsDist {
				dist = epsDist
			}
			// Inverse-distance weight w = Scale^2 / dist (clamped via epsDist <= 1e9)
			w := (Scale * 1000) / (dist / 1000)
			if w <= 0 {
				w = 1
			}
			den += w
			for j := 0; j < dim; j++ {
				num[j] += (w * units[i][j]) / Scale
			}
		}
		if den == 0 {
			break
		}
		if err := unitNormalizeInto(med, num); err != nil {
			break
		}
	}
	return med, nil
}

// GeometricMedianFixed computes the deterministic fixed-point L1 Geometric Median on the
// unit sphere via Weiszfeld's iterative reweighting initialized at the order-invariant
// discrete L1 medoid (50% breakdown point against coordinated outlier clusters; pure integer
// arithmetic, zero floats, strictly order-invariant even under exact 180-degree cancellation).
//
// Mathematical basis: Weiszfeld (1937) / Vardi & Zhang (2000), solving sum_j (u_j - m)/||u_j - m|| = 0,
// independently validated in Experiments E5 & E7 after cross-referencing pairwise unit-difference
// relational fields and 180-degree symmetry stasis (Johannes Geisen / @frintroper).
func GeometricMedianFixed(vectors [][]int64, iters int) ([]int64, error) {
	units, err := validateAndNormalizeSet(vectors)
	if err != nil {
		return nil, err
	}
	return geometricMedianOnUnits(units, iters)
}

// GeometricMedianNormalizedFixed computes the deterministic fixed-point L1 Geometric Median
// directly over pre-normalized unit vectors (each scaled to Scale), skipping redundant
// UnitNormalizeFixed allocations and square-root passes.
func GeometricMedianNormalizedFixed(units [][]int64, iters int) ([]int64, error) {
	if _, err := validateVectorSetDimensions(units); err != nil {
		return nil, err
	}
	return geometricMedianOnUnits(units, iters)
}

// AntipodalFractionFixed computes the strictly order-invariant fraction (in [0, Scale]) of
// distinct unit vector pairs whose cosine similarity is <= negThresholdFixed (default -500000 = -0.50).
// Validated in Experiment E7b (100% TPR on balanced antipodal split-brain attacks at 0% clean FPR).
func AntipodalFractionFixed(vectors [][]int64, negThresholdFixed int64) (int64, error) {
	units, err := validateAndNormalizeSet(vectors)
	if err != nil {
		return 0, err
	}
	if negThresholdFixed == 0 {
		negThresholdFixed = -500000 // -0.50 cosine floor
	}
	n := len(units)
	dim := len(units[0])
	var antipodal int64
	var pairs int64
	for i := 0; i < n; i++ {
		for j := i + 1; j < n; j++ {
			pairs++
			var dot int64
			for d := 0; d < dim; d++ {
				dot += MulFixed(units[i][d], units[j][d])
			}
			if dot <= negThresholdFixed {
				antipodal++
			}
		}
	}
	if pairs == 0 {
		return 0, nil
	}
	return (antipodal * Scale) / pairs, nil
}

// AntipodalSplitGate flags coordinated 180-degree / opposing split-brain poisoning batches
// when AntipodalFractionFixed exceeds maxFractionFixed (default 100000 = 10% of pairs).
func AntipodalSplitGate(vectors [][]int64, negThresholdFixed, maxFractionFixed int64) (bool, int64, SignalEvidence, error) {
	if negThresholdFixed == 0 {
		negThresholdFixed = -500000
	}
	if maxFractionFixed <= 0 {
		maxFractionFixed = 100000 // 0.10
	}
	frac, err := AntipodalFractionFixed(vectors, negThresholdFixed)
	if err != nil {
		return false, 0, SignalEvidence{}, err
	}
	pass := frac < maxFractionFixed
	detail := "no_antipodal_split"
	if !pass {
		detail = "antipodal_split_brain_detected"
	}
	ev := SignalEvidence{
		Primitive:    "signals.antipodal_split_gate",
		Version:      "1",
		ParamsDigest: hashInt64s("antipodal_split_gate", negThresholdFixed, maxFractionFixed),
		InputDigest:  digestVectorSet(vectors),
		OutputFixed:  frac,
		Alarm:        !pass,
		Detail:       detail,
	}
	return pass, frac, ev, nil
}

// CommonAverageReferenceDebiasFixed removes a shared anisotropic common-cone component from
// an embedding vector in pure fixed-point integer arithmetic: unit(unit(vec) - coneWeight*unit(coneRef)).
// Validated in Experiment E9 (+76.5 pts poison quarantine TPR & -87.7 pts Top-3 contamination
// under anisotropic common-cone collapse, cross-referencing Arobi Labs embedding anisotropy findings).
func CommonAverageReferenceDebiasFixed(vec, coneRef []int64, coneWeightFixed int64) ([]int64, error) {
	u, err := UnitNormalizeFixed(vec)
	if err != nil {
		return nil, err
	}
	if len(coneRef) == 0 || coneWeightFixed <= 0 {
		return u, nil
	}
	if len(coneRef) != len(u) {
		return nil, errors.New("cone reference dimension mismatch")
	}
	cUnit, err := UnitNormalizeFixed(coneRef)
	if err != nil {
		return nil, err
	}
	if coneWeightFixed > Scale {
		coneWeightFixed = Scale
	}
	debiased := make([]int64, len(u))
	for i := range u {
		debiased[i] = u[i] - MulFixed(coneWeightFixed, cUnit[i])
	}
	out, err := UnitNormalizeFixed(debiased)
	if err != nil {
		// Vector was strictly collinear with coneRef; fall back safely to unit vector.
		return u, nil
	}
	return out, nil
}

// SignedQuadranceCosSqFixed computes Wildberger's signed rational cosine-squared:
//   C_2(u, v) = sgn(u . v) * ((u . v)^2 * Scale) / (||u||^2 * ||v||^2) in [-Scale, +Scale]
// using pure integer arithmetic with ZERO square roots (ISqrt64) and ZERO slice allocations.
// By Cauchy-Schwarz, |u . v| <= max(||u||^2, ||v||^2), guaranteeing overflow-free evaluation.
// Validated in Experiment E10 (cross-referencing @frintroper/wildberger-math & Wildberger 2005).
func SignedQuadranceCosSqFixed(u, v []int64) (int64, error) {
	if len(u) == 0 || len(u) != len(v) {
		return 0, errors.New("vectors must be non-empty and share the same dimension")
	}
	var maxAbs uint64
	for i := range u {
		au := uint64(Abs64(u[i]))
		av := uint64(Abs64(v[i]))
		if au > maxAbs {
			maxAbs = au
		}
		if av > maxAbs {
			maxAbs = av
		}
	}
	if maxAbs == 0 {
		return 0, errors.New("zero vector in quadrance evaluation")
	}
	shift := uint(0)
	for (maxAbs >> shift) > 1000000 {
		shift++
	}

	var dot int64
	var qu, qv uint64
	for i := range u {
		ui := u[i] >> shift
		vi := v[i] >> shift
		dot += ui * vi
		qu += uint64(Abs64(ui)) * uint64(Abs64(ui))
		qv += uint64(Abs64(vi)) * uint64(Abs64(vi))
	}
	if qu == 0 || qv == 0 {
		return 0, errors.New("zero quadrance after scaling")
	}
	if dot == 0 {
		return 0, nil
	}

	absDot := uint64(Abs64(dot))
	qMax, qMin := qu, qv
	if qv > qu {
		qMax, qMin = qv, qu
	}
	for qMax > 100000000000 {
		absDot >>= 1
		qMax >>= 1
		qMin >>= 1
	}
	if qMin == 0 {
		return 0, nil
	}
	// By Cauchy-Schwarz, absDot <= sqrt(qu*qv) <= qMax, so ratio1 <= 10_000_000.
	const interScale uint64 = 10000000
	ratio1 := (absDot * interScale) / qMax
	c2 := int64((ratio1 * absDot) / (qMin * (interScale / uint64(Scale))))
	if c2 > Scale {
		c2 = Scale
	}
	if dot < 0 {
		return -c2, nil
	}
	return c2, nil
}

// RationalSpreadFixed computes Wildberger's Rational Spread S(u, v) = 1 - cos^2(theta)
// in [0, Scale] without square roots or trig functions (0 = collinear/antipodal, Scale = orthogonal).
func RationalSpreadFixed(u, v []int64) (int64, error) {
	c2, err := SignedQuadranceCosSqFixed(u, v)
	if err != nil {
		return 0, err
	}
	return Scale - Abs64(c2), nil
}

// RationalCosGateFixed evaluates cos(u, v) >= thresholdFixed in O(d) integer arithmetic
// with zero ISqrt64 calls and zero heap allocations by testing C_2(u, v) >= sgn(tau)*tau^2.
func RationalCosGateFixed(u, v []int64, thresholdFixed int64) (bool, int64, error) {
	c2, err := SignedQuadranceCosSqFixed(u, v)
	if err != nil {
		return false, 0, err
	}
	tauSq := MulFixed(Abs64(thresholdFixed), Abs64(thresholdFixed))
	if thresholdFixed < 0 {
		tauSq = -tauSq
	}
	return c2 >= tauSq, c2, nil
}

// CalibrateThresholdYoudenFixed finds the optimal fixed-point decision threshold maximizing
// Youden's J = TPR - FPR (where cleanScores >= threshold and attackScores < threshold) and
// computes the exact Mann-Whitney / Wilcoxon ROC-AUC in [0, Scale] with zero floats.
// Validated in Experiment E11b (cross-referencing Arobi Labs arobi-primitives/coherence.py).
func CalibrateThresholdYoudenFixed(cleanScores, attackScores []int64) (bestThresholdFixed, youdenJFixed, rocAucFixed int64, err error) {
	nc := len(cleanScores)
	na := len(attackScores)
	if nc == 0 || na == 0 {
		return 0, 0, 0, errors.New("calibration requires non-empty clean and attack score slices")
	}

	// 1. Exact Mann-Whitney ROC-AUC: P(clean > attack) + 0.5*P(clean == attack)
	var halfWins int64
	for i := 0; i < nc; i++ {
		cs := cleanScores[i]
		for j := 0; j < na; j++ {
			as := attackScores[j]
			if cs > as {
				halfWins += 2
			} else if cs == as {
				halfWins += 1
			}
		}
	}
	rocAucFixed = (halfWins * Scale) / int64(2*nc*na)

	// 2. Evaluate Youden's J(t) = TPR(t) - FPR(t) across all candidate thresholds.
	bestJ := int64(-2 * Scale)
	bestT := cleanScores[0]
	for idx := 0; idx < nc+na; idx++ {
		var t int64
		if idx < nc {
			t = cleanScores[idx]
		} else {
			t = attackScores[idx-nc]
		}
		var cHits, aFalse int64
		for i := 0; i < nc; i++ {
			if cleanScores[i] >= t {
				cHits++
			}
		}
		for j := 0; j < na; j++ {
			if attackScores[j] >= t {
				aFalse++
			}
		}
		tpr := (cHits * Scale) / int64(nc)
		fpr := (aFalse * Scale) / int64(na)
		jStat := tpr - fpr
		if jStat > bestJ || (jStat == bestJ && t > bestT) {
			bestJ = jStat
			bestT = t
		}
	}
	return bestT, bestJ, rocAucFixed, nil
}

// CosineFixed computes the deterministic fixed-point dot product of two unit-normalized
// vectors (each scaled to Scale), clamped to [-Scale, +Scale].
func CosineFixed(u, w []int64) (int64, error) {
	if len(u) == 0 || len(u) != len(w) {
		return 0, errors.New("vectors must be non-empty and have matching dimensions")
	}
	var sum int64
	for i := range u {
		sum += MulFixed(u[i], w[i])
	}
	if sum > Scale {
		sum = Scale
	}
	if sum < -Scale {
		sum = -Scale
	}
	return sum, nil
}

// HubStatsFixed stores a memory record's background cosine affinity distribution (mean, std)
// over a calibration query block (Radovanovic et al., JMLR 2010; Arobi Labs Utah P3 primitive).
// Validated in Experiment E13a.
type HubStatsFixed struct {
	MeanFixed int64
	StdFixed  int64
	Samples   int
}

// FitHubStatsFixed computes deterministic fixed-point mean and standard deviation of
// cosine similarity between memoryUnit and a calibration block of unit query vectors.
// If excludeSelfIdx >= 0, calibrationUnits[excludeSelfIdx] is omitted (leave-one-out).
func FitHubStatsFixed(calibrationUnits [][]int64, memoryUnit []int64, excludeSelfIdx int, minStdFixed int64) (HubStatsFixed, error) {
	if len(memoryUnit) == 0 {
		return HubStatsFixed{}, errors.New("empty memory vector")
	}
	if minStdFixed <= 0 {
		minStdFixed = 50000 // 0.05 floor prevents division-by-zero on degenerate hubs
	}
	scores := make([]int64, 0, len(calibrationUnits))
	var sum int64
	for i, cu := range calibrationUnits {
		if i == excludeSelfIdx {
			continue
		}
		if len(cu) != len(memoryUnit) {
			return HubStatsFixed{}, errors.New("calibration vector dimension mismatch")
		}
		c, err := CosineFixed(cu, memoryUnit)
		if err != nil {
			return HubStatsFixed{}, err
		}
		scores = append(scores, c)
		sum += c
	}
	n := len(scores)
	if n == 0 {
		return HubStatsFixed{MeanFixed: 0, StdFixed: minStdFixed, Samples: 0}, nil
	}
	mean := sum / int64(n)
	var varSum uint64
	for _, s := range scores {
		d := s - mean
		if d < 0 {
			d = -d
		}
		varSum += uint64(d) * uint64(d)
	}
	std := int64(ISqrt64(varSum / uint64(n)))
	if std < minStdFixed {
		std = minStdFixed
	}
	return HubStatsFixed{
		MeanFixed: mean,
		StdFixed:  std,
		Samples:   n,
	}, nil
}

// HubNormalizeScoreFixed returns the standardized hubness z-score in Scale units:
//
//	z(q, m) = ((cos(q, m) - mean) * Scale) / max(std, minStdFixed)
//
// Universal hubs with high background similarity (high mean, tiny variance) collapse to z ~ 0,
// while query-specific target memories spike to z >> 2*Scale.
func HubNormalizeScoreFixed(queryUnit, memoryUnit []int64, stats HubStatsFixed, minStdFixed int64) (int64, error) {
	cos, err := CosineFixed(queryUnit, memoryUnit)
	if err != nil {
		return 0, err
	}
	if minStdFixed <= 0 {
		minStdFixed = 50000
	}
	denom := stats.StdFixed
	if denom < minStdFixed {
		denom = minStdFixed
	}
	return ((cos - stats.MeanFixed) * Scale) / denom, nil
}

