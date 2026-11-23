package signals

import "errors"

// Baseline holds fixed-point reference mean and standard deviation estimated from a quiet window.
type Baseline struct {
	MeanFixed int64
	SDFixed   int64
}

// BaselineFromSlice computes the sample mean and unbiased sample SD (ddof=1) in fixed-point.
func BaselineFromSlice(quiet []int64) (Baseline, error) {
	n := len(quiet)
	if n < 10 {
		return Baseline{}, errors.New("baseline requires at least 10 samples")
	}
	var sum int64
	for _, v := range quiet {
		sum += v
	}
	mean := sum / int64(n)

	var sqSum uint64
	for _, v := range quiet {
		d := Abs64(v - mean)
		// Compute (d*d)/Scale carefully in uint64 to retain full fixed-point variance precision.
		ud := uint64(d)
		s := uint64(Scale)
		dh, dl := ud/s, ud%s
		sqFixed := dh*dh*s + 2*dh*dl + (dl*dl)/s
		sqSum += sqFixed
	}
	varFixed := int64(sqSum / uint64(n-1))
	sd := SqrtFixed(varFixed)
	if sd < MinSDFixed {
		sd = MinSDFixed
	}
	return Baseline{MeanFixed: mean, SDFixed: sd}, nil
}

// CusumDetector implements deterministic one-sided upper CUSUM on standardized fixed-point samples:
//   z = (x - mean) / sd
//   S = max(0, S + z - k)
//   alarm when S > h
// Default k = 1*Scale targets 2-sigma upward shifts.
type CusumDetector struct {
	base   Baseline
	hFixed int64
	kFixed int64
	stat   int64
	alarms uint64
	steps  uint64
}

func NewCusum(base Baseline, hFixed, kFixed int64) (*CusumDetector, error) {
	if base.SDFixed <= 0 {
		return nil, errors.New("baseline SDFixed must be > 0")
	}
	if hFixed <= 0 {
		return nil, errors.New("threshold hFixed must be > 0")
	}
	if kFixed <= 0 {
		kFixed = Scale // default 1.0 sigma
	}
	return &CusumDetector{
		base:   base,
		hFixed: hFixed,
		kFixed: kFixed,
	}, nil
}

func (c *CusumDetector) Update(xFixed int64) (bool, int64, SignalEvidence) {
	c.steps++
	z := DivFixed(xFixed-c.base.MeanFixed, c.base.SDFixed)
	next := c.stat + z - c.kFixed
	if next < 0 {
		next = 0
	}
	c.stat = next
	alarm := c.stat > c.hFixed
	detail := "within_bound"
	if alarm {
		c.alarms++
		detail = "cusum_drift_alarm"
	}
	ev := SignalEvidence{
		Primitive:    "signals.cusum",
		Version:      "1",
		ParamsDigest: hashInt64s("cusum", c.base.MeanFixed, c.base.SDFixed, c.hFixed, c.kFixed),
		InputDigest:  hashInt64s("in", xFixed),
		OutputFixed:  c.stat,
		Alarm:        alarm,
		Detail:       detail,
	}
	return alarm, c.stat, ev
}

func (c *CusumDetector) Statistic() int64 { return c.stat }
func (c *CusumDetector) Alarms() uint64   { return c.alarms }
func (c *CusumDetector) Reset()           { c.stat = 0 }

// PageHinkleyDetector implements deterministic Page-Hinkley upward shift detection:
//   runningMean += (z - runningMean) / n
//   m += z - runningMean - delta
//   mMin = min(mMin, m)
//   alarm when (m - mMin) > lambda
type PageHinkleyDetector struct {
	base        Baseline
	lambdaFixed int64
	deltaFixed  int64
	n           int64
	runningMean int64
	m           int64
	mMin        int64
	alarms      uint64
}

func NewPageHinkley(base Baseline, lambdaFixed, deltaFixed int64) (*PageHinkleyDetector, error) {
	if base.SDFixed <= 0 {
		return nil, errors.New("baseline SDFixed must be > 0")
	}
	if lambdaFixed <= 0 {
		return nil, errors.New("lambdaFixed must be > 0")
	}
	if deltaFixed <= 0 {
		deltaFixed = 500000 // default 0.5 sigma
	}
	return &PageHinkleyDetector{
		base:        base,
		lambdaFixed: lambdaFixed,
		deltaFixed:  deltaFixed,
	}, nil
}

func (p *PageHinkleyDetector) Update(xFixed int64) (bool, int64, SignalEvidence) {
	z := DivFixed(xFixed-p.base.MeanFixed, p.base.SDFixed)
	p.n++
	p.runningMean += (z - p.runningMean) / p.n
	p.m += z - p.runningMean - p.deltaFixed
	if p.m < p.mMin {
		p.mMin = p.m
	}
	stat := p.m - p.mMin
	alarm := stat > p.lambdaFixed
	detail := "within_bound"
	if alarm {
		p.alarms++
		detail = "page_hinkley_drift_alarm"
	}
	ev := SignalEvidence{
		Primitive:    "signals.page_hinkley",
		Version:      "1",
		ParamsDigest: hashInt64s("page_hinkley", p.base.MeanFixed, p.base.SDFixed, p.lambdaFixed, p.deltaFixed),
		InputDigest:  hashInt64s("in", xFixed),
		OutputFixed:  stat,
		Alarm:        alarm,
		Detail:       detail,
	}
	return alarm, stat, ev
}

func (p *PageHinkleyDetector) Statistic() int64 { return p.m - p.mMin }
func (p *PageHinkleyDetector) Reset() {
	p.n, p.runningMean, p.m, p.mMin = 0, 0, 0, 0
}

// HampelCusumDetector composes a causal Hampel spike filter ahead of a standardized CUSUM
// detector. Isolated +/-10sigma oracle or sensor spikes are clamped before entering CUSUM,
// eliminating transient false circuit-breaker trips while still catching sustained shifts.
type HampelCusumDetector struct {
	smoother *RobustSmoother
	cusum    *CusumDetector
}

func NewHampelCusum(base Baseline, hFixed, kFixed int64, window int, hampelKFixed int64) (*HampelCusumDetector, error) {
	sm, err := NewRobustSmoother(window, hampelKFixed, Scale)
	if err != nil {
		return nil, err
	}
	cu, err := NewCusum(base, hFixed, kFixed)
	if err != nil {
		return nil, err
	}
	return &HampelCusumDetector{smoother: sm, cusum: cu}, nil
}

func (hc *HampelCusumDetector) Update(xFixed int64) (alarm bool, stat int64, spikeClamped bool, ev SignalEvidence) {
	cleaned, replaced := hc.smoother.HampelOnly(xFixed)
	alarm, stat, ev = hc.cusum.Update(cleaned)
	ev.Primitive = "signals.hampel_cusum"
	ev.InputDigest = hashInt64s("in", xFixed)
	if replaced && !alarm {
		ev.Detail = "spike_clamped_no_drift"
	}
	return alarm, stat, replaced, ev
}

func (hc *HampelCusumDetector) Statistic() int64     { return hc.cusum.Statistic() }
func (hc *HampelCusumDetector) SpikesClamped() uint64 { return hc.smoother.Replaced() }
func (hc *HampelCusumDetector) Reset()               { hc.cusum.Reset() }
