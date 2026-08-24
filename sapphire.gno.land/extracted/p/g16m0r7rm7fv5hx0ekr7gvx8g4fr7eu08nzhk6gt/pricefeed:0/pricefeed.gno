package pricefeed

// Observation is a single price sample at a given block height.
type Observation struct {
	Height int64
	Price  int64 // fixed-point-agnostic raw price, caller defines scale
}

// WeightedAverage computes a simple time-weighted average price (TWAP-style)
// across a series of observations. Weight of each observation is the number
// of blocks it was in effect for (until the next observation, or until
// `uptoHeight` for the last one). Observations must be sorted ascending by Height.
func WeightedAverage(obs []Observation, uptoHeight int64) int64 {
	if len(obs) == 0 {
		panic("pricefeed: no observations")
	}
	if len(obs) == 1 {
		return obs[0].Price
	}

	var weightedSum int64
	var totalWeight int64
	for i := 0; i < len(obs); i++ {
		var weight int64
		if i+1 < len(obs) {
			weight = obs[i+1].Height - obs[i].Height
		} else {
			weight = uptoHeight - obs[i].Height
		}
		if weight < 0 {
			panic("pricefeed: observations must be sorted ascending and uptoHeight must not precede last observation")
		}
		weightedSum += obs[i].Price * weight
		totalWeight += weight
	}
	if totalWeight == 0 {
		return obs[len(obs)-1].Price
	}
	return weightedSum / totalWeight
}

// WithinSlippage reports whether actualPrice is within toleranceBps (basis
// points, 1/100 of a percent) of referencePrice.
func WithinSlippage(referencePrice int64, actualPrice int64, toleranceBps int64) bool {
	if referencePrice <= 0 {
		panic("pricefeed: referencePrice must be positive")
	}
	if toleranceBps < 0 {
		panic("pricefeed: toleranceBps must be non-negative")
	}
	diff := actualPrice - referencePrice
	if diff < 0 {
		diff = -diff
	}
	// diff / referencePrice <= toleranceBps / 10000
	return diff*10000 <= referencePrice*toleranceBps
}

// ApplySlippage returns the minimum acceptable output amount given an
// expected amount and a tolerance in basis points.
func ApplySlippage(expectedAmount int64, toleranceBps int64) int64 {
	if expectedAmount < 0 {
		panic("pricefeed: expectedAmount must be non-negative")
	}
	if toleranceBps < 0 || toleranceBps > 10000 {
		panic("pricefeed: toleranceBps must be between 0 and 10000")
	}
	return expectedAmount * (10000 - toleranceBps) / 10000
}
