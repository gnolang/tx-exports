package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"strconv"

	"gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/signals/v2"
)

// DriftGuardPolicy is a stateful, deterministic behavioral drift circuit breaker
// powered by gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/signals/v2.
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
	oa         *signals.OpacityAwareHampelCusumDetector
	ar1        *signals.AR1PrewhitenedHampelCusumDetector
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
	if p.ar1 != nil {
		alarm, stat, _, ev = p.ar1.Update(xFixed)
	} else if p.oa != nil {
		alarm, stat, _, ev = p.oa.Update(xFixed)
	} else if p.hc != nil {
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

// EnableOpacityChannel upgrades a Hampel-CUSUM DriftGuardPolicy to Dual-Channel
// OpacityAwareHampelCusumDetector (Experiment E8b) to block periodic filter-evading bursts.
func (p *DriftGuardPolicy) EnableOpacityChannel(clipSigmaFixed int64, clipWindow, minClips int) error {
	w := p.HampelWindow
	if w < 2 {
		w = 5
	}
	hk := p.HampelKFixed
	if hk <= 0 {
		hk = 3 * signals.Scale
	}
	oa, err := signals.NewOpacityAwareHampelCusum(p.Base, p.HFixed, p.KFixed, w, hk, clipSigmaFixed, clipWindow, minClips)
	if err != nil {
		return err
	}
	p.oa = oa
	return nil
}

// EnableAR1Prewhitening upgrades a DriftGuardPolicy to AR1PrewhitenedHampelCusumDetector
// (Experiment E11a) for autocorrelated telemetry streams (rhoFixed in [-900000, +900000]).
func (p *DriftGuardPolicy) EnableAR1Prewhitening(rhoFixed, clipSigmaFixed int64, clipWindow, minClips int) error {
	w := p.HampelWindow
	if w < 2 {
		w = 5
	}
	hk := p.HampelKFixed
	if hk <= 0 {
		hk = 3 * signals.Scale
	}
	ar1, err := signals.NewAR1PrewhitenedHampelCusum(p.Base, rhoFixed, p.HFixed, p.KFixed, w, hk, clipSigmaFixed, clipWindow, minClips)
	if err != nil {
		return err
	}
	p.ar1 = ar1
	return nil
}

// Reset clears a latched circuit breaker and zeroes the CUSUM accumulator (principal action).
func (p *DriftGuardPolicy) Reset() {
	p.latched = false
	if p.ar1 != nil {
		p.ar1.Reset()
	}
	if p.oa != nil {
		p.oa.Reset()
	}
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
	if p.ar1 != nil {
		return p.ar1.Statistic()
	}
	if p.oa != nil {
		return p.oa.Statistic()
	}
	if p.hc != nil {
		return p.hc.Statistic()
	}
	if p.raw != nil {
		return p.raw.Statistic()
	}
	return 0
}

// CoherenceGuardPolicy enforces pre-action memory/context coherence using deterministic
// spherical coherence (MeanResultantLength or MeanPairwiseCosine in gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/signals/v2).
//
// Prevents cross-session memory poisoning and context-injection attacks: if a pending
// context batch scores below ThresholdFixed, execution fails closed before side effects.
type CoherenceGuardPolicy struct {
	PolicyID                 string
	ThresholdFixed           int64
	UsePairwise              bool
	StrictDeny               bool
	RequireOnAllCall         bool // if true, missing context vectors fails closed
	CheckAntipodal           bool // if true, also runs AntipodalSplitGate (Experiment E7b)
	AntipodalNegThreshFixed  int64
	AntipodalMaxFracFixed    int64

	hasPending       bool
	pendingOk        bool
	pendingSc        int64
	pendingAntipodal bool
	lastEv           signals.SignalEvidence
	hasLastEv        bool
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

// EnableAntipodalSplitGuard activates balanced 180-degree split-brain detection alongside
// spherical coherence (Experiment E7b).
func (c *CoherenceGuardPolicy) EnableAntipodalSplitGuard(negThreshFixed, maxFracFixed int64) *CoherenceGuardPolicy {
	if negThreshFixed == 0 {
		negThreshFixed = -500000
	}
	if maxFracFixed <= 0 {
		maxFracFixed = 100000
	}
	c.CheckAntipodal = true
	c.AntipodalNegThreshFixed = negThreshFixed
	c.AntipodalMaxFracFixed = maxFracFixed
	return c
}

// StageContext evaluates contextVectors deterministically and stages the result for the next Execute().
func (c *CoherenceGuardPolicy) StageContext(vectors [][]int64) (bool, int64, signals.SignalEvidence, error) {
	ok, score, ev, err := signals.CoherenceGate(vectors, c.ThresholdFixed, c.UsePairwise)
	if err != nil {
		c.hasPending = true
		c.pendingOk = false
		c.pendingSc = 0
		c.pendingAntipodal = false
		return false, 0, signals.SignalEvidence{}, err
	}
	antipodalAlarm := false
	if c.CheckAntipodal {
		aOk, aFrac, aEv, aErr := signals.AntipodalSplitGate(vectors, c.AntipodalNegThreshFixed, c.AntipodalMaxFracFixed)
		if aErr != nil {
			c.hasPending = true
			c.pendingOk = false
			c.pendingSc = 0
			c.pendingAntipodal = false
			return false, 0, signals.SignalEvidence{}, aErr
		}
		if !aOk {
			ok = false
			antipodalAlarm = true
			score = aFrac
			ev = aEv
		}
	}
	c.hasPending = true
	c.pendingOk = ok
	c.pendingSc = score
	c.pendingAntipodal = antipodalAlarm
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
	antipodal := c.pendingAntipodal
	c.hasPending = false
	c.pendingOk = false
	c.pendingSc = 0
	c.pendingAntipodal = false

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
		if antipodal {
			return PolicyDecision{
				Verdict:      verdict,
				PolicyID:     c.ID(),
				PolicyDigest: d,
				ReasonCode:   "CONTEXT_ANTIPODAL_SPLIT_DETECTED",
				Reason:       "antipodal pair fraction " + strconv.FormatInt(score, 10) + " exceeded split-brain threshold",
			}
		}
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
