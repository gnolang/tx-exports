package soup

// Flavor model: one layer, 2048 hashed buckets -> 5 flavors, tanh, softmax(4x).
// Weights are a constant string (weights.gno). Only the buckets a text uses are
// read, so nothing is parsed at package load.
// Tek katman. Agirliklar sabit metin; yalniz metnin kullandigi kovalar okunur.

import "math"

const (
	bucketCount = 2048
	flavorCount = 5
	wScale      = 50000.0
	wOffset     = 1 << 15
	wDigits     = 4
)

var hexVal = [256]int8{
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, 10, 11, 12, 13, 14, 15, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
}

// predict: best flavor index (-1 = no words) and shares (sum 1).
func predict(s string) (int, [flavorCount]float64) {
	var share [flavorCount]float64
	kv := bucketsOf(s)
	if len(kv) == 0 {
		return -1, share
	}
	// integer sums first (exact), one float step at the end
	var sum [flavorCount]int64
	for _, i := range kv {
		p := i * flavorCount * wDigits
		for j := 0; j < flavorCount; j++ {
			h := weightsHex[p : p+wDigits]
			v := int64(hexVal[h[0]])<<12 | int64(hexVal[h[1]])<<8 | int64(hexVal[h[2]])<<4 | int64(hexVal[h[3]])
			sum[j] += v - wOffset
			p += wDigits
		}
	}
	scale := 2.0 / math.Sqrt(float64(len(kv)))
	total := 0.0
	for j := 0; j < flavorCount; j++ {
		t := float64(biasQ[j])/wScale + scale*float64(sum[j])/wScale
		share[j] = math.Exp(4.0 * math.Tanh(t))
		total += share[j]
	}
	best := 0
	for j := 0; j < flavorCount; j++ {
		share[j] /= total
		if share[j] > share[best] {
			best = j
		}
	}
	return best, share
}
