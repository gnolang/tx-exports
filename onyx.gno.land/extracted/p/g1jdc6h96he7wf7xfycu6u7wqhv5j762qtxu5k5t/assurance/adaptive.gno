package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"strconv"

	"gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/signals"
)

// DriftGuardPolicy is a stateful, deterministic behavioral drift circuit breaker
// powered by gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/signals.
//
// It monitors each action's spend/budget stream (in fixed-point Scale units) through
// either a Hampel-guarded CUSUM detector (default when HampelWindow >= 2, rejecting
// single-tick +/-10sigma spikes) or raw CUSUM. On sustained behavioral drift above
// threshold hFixed, it fails closed with VerdictEscalate (or VerdictDeny if StrictDeny).
type DriftGuardPolicy struct {
	PolicyID     string
	Base         signals.Baseline
	HFixed       int64
	KFixed       int64
	HampelWindow int
	HampelKFixed int64
	StrictDeny   bool
	LatchOnAlarm bool

	latched    bool
	hc         *signals.HampelCusumDetector
	raw        *signals.CusumDetector
	lastEv     signals.SignalEvidence
	hasLastEv  bool
	alarmCount uint64
}

// NewDriftGuardPolicy constructs a deterministic drift circuit breaker policy.
func NewDriftGuardPolicy(
	policyID string,
	base signals.Baseline,
	hFixed int64,
	kFixed int64,
	hampelWindow int,
	hampelKFixed int64,
	strictDeny bool,
	latchOnAlarm bool,
) (*DriftGuardPolicy, error) {
	if policyID == "" {
		policyID = "drift-guard-v1"
	}
	if kFixed <= 0 {
		kFixed = signals.Scale
	}
	p := &DriftGuardPolicy{
		PolicyID:     policyID,
		Base:         base,
		HFixed:       hFixed,
		KFixed:       kFixed,
		HampelWindow: hampelWindow,
		HampelKFixed: hampelKFixed,
		StrictDeny:   strictDeny,
		LatchOnAlarm: latchOnAlarm,
	}
	if hampelWindow >= 2 {
		if hampelKFixed <= 0 {
			hampelKFixed = 3 * signals.Scale
		}
		p.HampelKFixed = hampelKFixed
		hc, err := signals.NewHampelCusum(base, hFixed, kFixed, hampelWindow, hampelKFixed)
		if err != nil {
			return nil, err
		}
		p.hc = hc
	} else {
		cu, err := signals.NewCusum(base, hFixed, kFixed)
		if err != nil {
			return nil, err
		}
		p.raw = cu
	}
	return p, nil
}

func (p *DriftGuardPolicy) ID() string {
	if p.PolicyID != "" {
		return p.PolicyID
	}
	return "drift-guard-v1"
}

func (p *DriftGuardPolicy) Digest() [32]byte {
	out := make([]byte, 0, 112)
	out = appendString(out, "policy:drift-guard-v1")
	out = appendString(out, p.ID())
	out = binary.BigEndian.AppendUint64(out, uint64(p.Base.MeanFixed))
	out = binary.BigEndian.AppendUint64(out, uint64(p.Base.SDFixed))
	out = binary.BigEndian.AppendUint64(out, uint64(p.HFixed))
	out = binary.BigEndian.AppendUint64(out, uint64(p.KFixed))
	out = binary.BigEndian.AppendUint64(out, uint64(p.HampelWindow))
	out = binary.BigEndian.AppendUint64(out, uint64(p.HampelKFixed))
	out = append(out, boolByte(p.StrictDeny), boolByte(p.LatchOnAlarm))
	return sha256.Sum256(out)
}

func (p *DriftGuardPolicy) Evaluate(in PolicyInputProjection) PolicyDecision {
	d := p.Digest()
	verdict := VerdictEscalate
	if p.StrictDeny {
		verdict = VerdictDeny
	}
	if p.latched {
		return PolicyDecision{
			Verdict:      verdict,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "DRIFT_CIRCUIT_BREAKER_LATCHED",
			Reason:       "agent halted by latched behavioral drift circuit breaker; principal reset required",
		}
	}

	xFixed := in.BudgetUgnot * signals.Scale
	var (
		alarm bool
		stat  int64
		ev    signals.SignalEvidence
	)
	if p.hc != nil {
		alarm, stat, _, ev = p.hc.Update(xFixed)
	} else if p.raw != nil {
		alarm, stat, ev = p.raw.Update(xFixed)
	} else {
		return PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "DRIFT_DETECTOR_UNINITIALIZED",
			Reason:       "uninitialized drift detector fails closed",
		}
	}
	p.lastEv = ev
	p.hasLastEv = true

	if alarm {
		p.alarmCount++
		if p.LatchOnAlarm {
			p.latched = true
		}
		return PolicyDecision{
			Verdict:      verdict,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "BEHAVIORAL_DRIFT_ALARM",
			Reason:       "behavioral drift statistic " + strconv.FormatInt(stat, 10) + " exceeded threshold " + strconv.FormatInt(p.HFixed, 10),
		}
	}
	return PolicyDecision{
		Verdict:       VerdictAllow,
		PolicyID:      p.ID(),
		PolicyDigest:  d,
		ReasonCode:    "DRIFT_WITHIN_BOUNDS",
		Reason:        "behavioral telemetry within calibrated baseline",
		MaxSpendUgnot: in.BudgetUgnot,
	}
}

// Reset clears a latched circuit breaker and zeroes the CUSUM accumulator (principal action).
func (p *DriftGuardPolicy) Reset() {
	p.latched = false
	if p.hc != nil {
		p.hc.Reset()
	}
	if p.raw != nil {
		p.raw.Reset()
	}
}

func (p *DriftGuardPolicy) Latched() bool                       { return p.latched }
func (p *DriftGuardPolicy) AlarmCount() uint64                  { return p.alarmCount }
func (p *DriftGuardPolicy) LastEvidence() (signals.SignalEvidence, bool) { return p.lastEv, p.hasLastEv }
func (p *DriftGuardPolicy) Statistic() int64 {
	if p.hc != nil {
		return p.hc.Statistic()
	}
	if p.raw != nil {
		return p.raw.Statistic()
	}
	return 0
}

// CoherenceGuardPolicy enforces pre-action memory/context coherence using deterministic
// spherical coherence (MeanResultantLength or MeanPairwiseCosine in gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/signals).
//
// Prevents cross-session memory poisoning and context-injection attacks: if a pending
// context batch scores below ThresholdFixed, execution fails closed before side effects.
type CoherenceGuardPolicy struct {
	PolicyID         string
	ThresholdFixed   int64
	UsePairwise      bool
	StrictDeny       bool
	RequireOnAllCall bool // if true, missing context vectors fails closed

	hasPending bool
	pendingOk  bool
	pendingSc  int64
	lastEv     signals.SignalEvidence
	hasLastEv  bool
}

func NewCoherenceGuardPolicy(policyID string, thresholdFixed int64, usePairwise, strictDeny, requireOnAllCall bool) (*CoherenceGuardPolicy, error) {
	if thresholdFixed < -signals.Scale || thresholdFixed > signals.Scale {
		return nil, errors.New("thresholdFixed out of [-Scale, Scale] range")
	}
	if policyID == "" {
		policyID = "coherence-guard-v1"
	}
	return &CoherenceGuardPolicy{
		PolicyID:         policyID,
		ThresholdFixed:   thresholdFixed,
		UsePairwise:      usePairwise,
		StrictDeny:       strictDeny,
		RequireOnAllCall: requireOnAllCall,
	}, nil
}

// StageContext evaluates contextVectors deterministically and stages the result for the next Execute().
func (c *CoherenceGuardPolicy) StageContext(vectors [][]int64) (bool, int64, signals.SignalEvidence, error) {
	ok, score, ev, err := signals.CoherenceGate(vectors, c.ThresholdFixed, c.UsePairwise)
	if err != nil {
		c.hasPending = true
		c.pendingOk = false
		c.pendingSc = 0
		return false, 0, signals.SignalEvidence{}, err
	}
	c.hasPending = true
	c.pendingOk = ok
	c.pendingSc = score
	c.lastEv = ev
	c.hasLastEv = true
	return ok, score, ev, nil
}

// StageScore stages a pre-computed deterministic coherence score (useful for lightweight on-chain calls).
func (c *CoherenceGuardPolicy) StageScore(scoreFixed int64) {
	c.hasPending = true
	c.pendingSc = scoreFixed
	c.pendingOk = scoreFixed >= c.ThresholdFixed
}

func (c *CoherenceGuardPolicy) ID() string {
	if c.PolicyID != "" {
		return c.PolicyID
	}
	return "coherence-guard-v1"
}

func (c *CoherenceGuardPolicy) Digest() [32]byte {
	out := make([]byte, 0, 80)
	out = appendString(out, "policy:coherence-guard-v1")
	out = appendString(out, c.ID())
	out = binary.BigEndian.AppendUint64(out, uint64(c.ThresholdFixed))
	out = append(out, boolByte(c.UsePairwise), boolByte(c.StrictDeny), boolByte(c.RequireOnAllCall))
	return sha256.Sum256(out)
}

func (c *CoherenceGuardPolicy) Evaluate(in PolicyInputProjection) PolicyDecision {
	d := c.Digest()
	verdict := VerdictRequireApproval
	if c.StrictDeny {
		verdict = VerdictDeny
	}

	// Consume staged context once so stale coherence scores can never be replayed across calls.
	staged := c.hasPending
	ok := c.pendingOk
	score := c.pendingSc
	c.hasPending = false
	c.pendingOk = false
	c.pendingSc = 0

	if !staged {
		if c.RequireOnAllCall {
			return PolicyDecision{
				Verdict:      verdict,
				PolicyID:     c.ID(),
				PolicyDigest: d,
				ReasonCode:   "CONTEXT_COHERENCE_MISSING",
				Reason:       "coherence guard requires staged context embeddings before execution",
			}
		}
		return PolicyDecision{
			Verdict:       VerdictAllow,
			PolicyID:      c.ID(),
			PolicyDigest:  d,
			ReasonCode:    "COHERENCE_NOT_REQUIRED",
			Reason:        "no context batch attached",
			MaxSpendUgnot: in.BudgetUgnot,
		}
	}

	if !ok {
		return PolicyDecision{
			Verdict:      verdict,
			PolicyID:     c.ID(),
			PolicyDigest: d,
			ReasonCode:   "CONTEXT_COHERENCE_LOW",
			Reason:       "context coherence " + strconv.FormatInt(score, 10) + " below threshold " + strconv.FormatInt(c.ThresholdFixed, 10) + " (possible memory poisoning)",
		}
	}
	return PolicyDecision{
		Verdict:       VerdictAllow,
		PolicyID:      c.ID(),
		PolicyDigest:  d,
		ReasonCode:    "CONTEXT_COHERENT",
		Reason:        "retrieved context passed spherical coherence gate",
		MaxSpendUgnot: in.BudgetUgnot,
	}
}

func (c *CoherenceGuardPolicy) LastEvidence() (signals.SignalEvidence, bool) {
	return c.lastEv, c.hasLastEv
}
