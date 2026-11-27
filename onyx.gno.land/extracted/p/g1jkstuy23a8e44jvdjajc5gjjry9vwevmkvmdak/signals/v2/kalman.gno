package signals

import "errors"

// KalmanRWGainFixed computes the exact steady-state algebraic Riccati Kalman gain K*
// in fixed-point units [0, Scale] for a scalar random-walk state-space model:
//
//	x_t = x_{t-1} + w_t,  Var(w_t) = qFixed / Scale
//	y_t = x_t     + v_t,  Var(v_t) = rFixed / Scale
//
// Closed-form solution (Kalman 1960; Wu et al. NeurIPS 2002; Arobi Labs Utah P6 primitive):
//
//	P^+ = (q + sqrt(q^2 + 4*q*r)) / 2
//	K*  = P^+ / (P^+ + r)
//
// Solved once in pure integer arithmetic via ISqrt64 (zero floats, zero per-step roots).
// Validated in Experiment E13b.
func KalmanRWGainFixed(qFixed, rFixed int64) (int64, error) {
	if qFixed <= 0 || rFixed <= 0 {
		return 0, errors.New("kalman variances qFixed and rFixed must be positive")
	}
	// Scale down (q, r) if necessary so q^2 + 4*q*r fits comfortably inside uint64 without overflow.
	// Note that K*(q, r) depends only on the ratio q/r, so scaling q and r by the same factor is exact!
	q := uint64(qFixed)
	r := uint64(rFixed)
	// Multiply up to preserve precision for tiny q, or shift down for huge q/r.
	// Target max(q, r) in [10^6, 10^8] so disc = q^2 + 4*q*r <= 5*10^16 << 1.8*10^19 (uint64 max).
	for q < 1000000 && r < 1000000 {
		q *= 10
		r *= 10
	}
	for q > 100000000 || r > 100000000 {
		q /= 2
		r /= 2
		if q == 0 {
			q = 1
		}
		if r == 0 {
			r = 1
		}
	}
	disc := q*q + 4*q*r
	root := ISqrt64(disc)
	// P^+ = (q + root) / 2; compute K* = (P^+ * Scale) / (P^+ + r) using 2*P^+ = q + root
	// to avoid losing the 0.5 truncation bit: K* = ((q + root) * Scale) / (q + root + 2*r).
	num := q + root
	den := num + 2*r
	if den == 0 {
		return Scale, nil
	}
	// Multiply num * Scale safely (num <= ~4.5*10^8, num * 10^6 <= 4.5*10^14 << uint64 max).
	k := (num * uint64(Scale) + den/2) / den
	if k > uint64(Scale) {
		k = uint64(Scale)
	}
	return int64(k), nil
}

// KalmanRWTracker is a deterministic O(1) fixed-point scalar random-walk Kalman tracker
// for noisy latent agent telemetry (cost-per-turn, latency, gas drift).
// After initialization, each Update uses one subtraction, one multiply, and one shift/div
// (zero ISqrt64 calls and zero heap allocations per step).
type KalmanRWTracker struct {
	gainFixed   int64
	stateFixed  int64
	initialized bool
	steps       int64
}

// NewKalmanRWTracker constructs a steady-state random-walk Kalman tracker with exact
// integer Riccati gain K*(qFixed, rFixed).
func NewKalmanRWTracker(qFixed, rFixed int64) (*KalmanRWTracker, error) {
	k, err := KalmanRWGainFixed(qFixed, rFixed)
	if err != nil {
		return nil, err
	}
	return &KalmanRWTracker{
		gainFixed: k,
	}, nil
}

// Update ingests one fixed-point observation obsFixed and returns the filtered state estimate
// and its innovation (obsFixed - priorState).
func (t *KalmanRWTracker) Update(obsFixed int64) (stateFixed, innovationFixed int64) {
	t.steps++
	if !t.initialized {
		t.stateFixed = obsFixed
		t.initialized = true
		return t.stateFixed, 0
	}
	innov := obsFixed - t.stateFixed
	t.stateFixed += MulFixed(t.gainFixed, innov)
	return t.stateFixed, innov
}

// GainFixed returns the steady-state Riccati Kalman gain in [0, Scale].
func (t *KalmanRWTracker) GainFixed() int64 { return t.gainFixed }

// StateFixed returns the current filtered state estimate in Scale units.
func (t *KalmanRWTracker) StateFixed() int64 { return t.stateFixed }

// Steps returns the number of ingested observations.
func (t *KalmanRWTracker) Steps() int64 { return t.steps }
