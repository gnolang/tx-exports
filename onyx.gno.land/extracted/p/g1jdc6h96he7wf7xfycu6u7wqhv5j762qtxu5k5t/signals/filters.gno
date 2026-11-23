package signals

import "errors"

// CausalMedian computes the trailing-window median causally (each output depends only
// on the current and past samples; initial samples warm up using the first value).
type CausalMedian struct {
	window int
	buf    []int64
}

func NewCausalMedian(window int) (*CausalMedian, error) {
	if window < 1 {
		return nil, errors.New("window must be >= 1")
	}
	return &CausalMedian{window: window}, nil
}

func (m *CausalMedian) Update(x int64) (int64, SignalEvidence) {
	if len(m.buf) == 0 {
		m.buf = make([]int64, m.window)
		for i := range m.buf {
			m.buf[i] = x
		}
	} else {
		copy(m.buf, m.buf[1:])
		m.buf[len(m.buf)-1] = x
	}
	y := MedianFixed(m.buf)
	ev := SignalEvidence{
		Primitive:    "signals.causal_median",
		Version:      "1",
		ParamsDigest: hashInt64s("causal_median", int64(m.window)),
		InputDigest:  hashInt64s("in", x),
		OutputFixed:  y,
		Alarm:        false,
		Detail:       "ok",
	}
	return y, ev
}

// RobustSmoother implements Arobi's measured-best causal filter for spiky telemetry:
// Hampel outlier rejection (default window=5, k=3.0*Scale) followed by EMA (alpha=0.2*Scale).
// Streaming Update() is bit-for-bit identical to batch Hampel -> EMA.
type RobustSmoother struct {
	window     int
	kFixed     int64
	alphaFixed int64
	buf        []int64
	hasY       bool
	y          int64
	replaced   uint64
	count      uint64
}

// NewRobustSmoother creates a deterministic causal Hampel + EMA filter.
// Defaults when zeros are passed: window=5, k=3*Scale, alpha=200_000 (0.2).
func NewRobustSmoother(window int, kFixed, alphaFixed int64) (*RobustSmoother, error) {
	if window == 0 {
		window = 5
	}
	if kFixed == 0 {
		kFixed = 3 * Scale
	}
	if alphaFixed == 0 {
		alphaFixed = 200000 // 0.2
	}
	if window < 2 {
		return nil, errors.New("window must be >= 2")
	}
	if kFixed <= 0 {
		return nil, errors.New("kFixed must be > 0")
	}
	if alphaFixed <= 0 || alphaFixed > Scale {
		return nil, errors.New("alphaFixed must be in (0, Scale]")
	}
	return &RobustSmoother{
		window:     window,
		kFixed:     kFixed,
		alphaFixed: alphaFixed,
	}, nil
}

// Update processes one fixed-point sample x and returns (smoothedY, wasOutlier, SignalEvidence).
func (r *RobustSmoother) Update(x int64) (int64, bool, SignalEvidence) {
	if len(r.buf) == 0 {
		r.buf = make([]int64, r.window)
		for i := range r.buf {
			r.buf[i] = x
		}
	} else {
		copy(r.buf, r.buf[1:])
		r.buf[len(r.buf)-1] = x
	}
	r.count++

	med := MedianFixed(r.buf)
	absDevs := make([]int64, len(r.buf))
	for i, v := range r.buf {
		absDevs[i] = Abs64(v - med)
	}
	mad := MulFixed(MADScale, MedianFixed(absDevs))
	if mad < MinSDFixed {
		mad = MinSDFixed
	}
	thresh := MulFixed(r.kFixed, mad)

	cleaned := x
	outlier := Abs64(x-med) > thresh
	if outlier {
		cleaned = med
		r.replaced++
	}

	if !r.hasY {
		r.y = cleaned
		r.hasY = true
	} else {
		// y_t = alpha*cleaned + (1 - alpha)*y_{t-1}
		r.y = MulFixed(r.alphaFixed, cleaned) + MulFixed(Scale-r.alphaFixed, r.y)
	}

	detail := "clean"
	if outlier {
		detail = "spike_replaced"
	}
	ev := SignalEvidence{
		Primitive:    "signals.robust_smooth",
		Version:      "1",
		ParamsDigest: hashInt64s("robust_smooth", int64(r.window), r.kFixed, r.alphaFixed),
		InputDigest:  hashInt64s("in", x),
		OutputFixed:  r.y,
		Alarm:        outlier,
		Detail:       detail,
	}
	return r.y, outlier, ev
}

// HampelOnly processes one sample through the Hampel spike gate without EMA lag.
// Ideal as a spike-resistant pre-filter ahead of CUSUM drift detection.
func (r *RobustSmoother) HampelOnly(x int64) (int64, bool) {
	if len(r.buf) == 0 {
		r.buf = make([]int64, r.window)
		for i := range r.buf {
			r.buf[i] = x
		}
	} else {
		copy(r.buf, r.buf[1:])
		r.buf[len(r.buf)-1] = x
	}
	r.count++
	med := MedianFixed(r.buf)
	absDevs := make([]int64, len(r.buf))
	for i, v := range r.buf {
		absDevs[i] = Abs64(v - med)
	}
	mad := MulFixed(MADScale, MedianFixed(absDevs))
	if mad < MinSDFixed {
		mad = MinSDFixed
	}
	if Abs64(x-med) > MulFixed(r.kFixed, mad) {
		r.replaced++
		return med, true
	}
	return x, false
}

// Replaced returns how many spike samples were replaced so far.
func (r *RobustSmoother) Replaced() uint64 {
	return r.replaced
}

// Value returns the latest smoothed output.
func (r *RobustSmoother) Value() int64 {
	return r.y
}

// BatchRobustSmooth applies RobustSmoother across an entire slice and returns the smoothed series.
func BatchRobustSmooth(series []int64, window int, kFixed, alphaFixed int64) ([]int64, uint64, error) {
	if len(series) == 0 {
		return nil, 0, errors.New("series cannot be empty")
	}
	sm, err := NewRobustSmoother(window, kFixed, alphaFixed)
	if err != nil {
		return nil, 0, err
	}
	out := make([]int64, len(series))
	for i, v := range series {
		y, _, _ := sm.Update(v)
		out[i] = y
	}
	return out, sm.Replaced(), nil
}
