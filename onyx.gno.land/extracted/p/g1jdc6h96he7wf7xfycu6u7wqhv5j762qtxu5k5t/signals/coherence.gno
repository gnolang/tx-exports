package signals

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

// UnitNormalizeFixed projects a non-zero integer/fixed-point vector onto the unit sphere
// of radius Scale (1_000_000), deterministically across all validators.
func UnitNormalizeFixed(vec []int64) ([]int64, error) {
	if len(vec) == 0 {
		return nil, errors.New("vector cannot be empty")
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
		return nil, errors.New("zero vector cannot be normalized")
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
		return nil, errors.New("zero norm after scaling")
	}

	unit := make([]int64, len(vec))
	for i, v := range vec {
		neg := v < 0
		a := uint64(Abs64(v)) >> shift
		val := int64((a * uint64(Scale)) / norm)
		if neg {
			val = -val
		}
		unit[i] = val
	}
	return unit, nil
}

func validateAndNormalizeSet(vectors [][]int64) ([][]int64, error) {
	if len(vectors) < 2 {
		return nil, errors.New("coherence requires at least 2 vectors")
	}
	dim := len(vectors[0])
	if dim == 0 {
		return nil, errors.New("vectors must have positive dimension")
	}
	units := make([][]int64, len(vectors))
	for i, v := range vectors {
		if len(v) != dim {
			return nil, errors.New("all vectors in set must share the same dimension")
		}
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

// GeometricMedianFixed computes the deterministic fixed-point L1 Geometric Median on the
// unit sphere via Weiszfeld's iterative reweighting (50% breakdown point against coordinated
// outlier clusters; pure integer arithmetic, zero floats, strictly order-invariant).
//
// Mathematical basis: Weiszfeld (1937) / Vardi & Zhang (2000), solving sum_j (u_j - m)/||u_j - m|| = 0,
// independently validated in Experiment E5 after cross-referencing pairwise unit-difference
// relational fields (Johannes Geisen / @frintroper, Relational-Jerk-Dynamics).
func GeometricMedianFixed(vectors [][]int64, iters int) ([]int64, error) {
	units, err := validateAndNormalizeSet(vectors)
	if err != nil {
		return nil, err
	}
	if iters <= 0 {
		iters = 8
	}
	dim := len(units[0])
	n := len(units)

	// Initialize from the normalized arithmetic mean.
	sum := make([]int64, dim)
	for i := 0; i < n; i++ {
		for j := 0; j < dim; j++ {
			sum[j] += units[i][j]
		}
	}
	med, err := UnitNormalizeFixed(sum)
	if err != nil {
		// Symmetric cancellation fallback: start from first unit vector.
		med = make([]int64, dim)
		copy(med, units[0])
	}

	const epsDist int64 = 1000 // 0.001 in Scale units prevents 0/0 singularity
	for it := 0; it < iters; it++ {
		num := make([]int64, dim)
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
		next, nErr := UnitNormalizeFixed(num)
		if nErr != nil {
			break
		}
		med = next
	}
	return med, nil
}
