package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"sort"
	"strconv"
)

// Policy evaluates a canonical PolicyInputProjection and emits a fail-closed PolicyDecision.
type Policy interface {
	ID() string
	Digest() [32]byte
	Evaluate(p PolicyInputProjection) PolicyDecision
}

// AllowListPolicy permits only explicitly listed actions (and optional targets).
// Any unlisted action or target fails closed with VerdictDeny.
type AllowListPolicy struct {
	PolicyID       string
	AllowedActions []string
	AllowedTargets []string // empty means any non-empty target is allowed
}

func (p *AllowListPolicy) ID() string {
	if p.PolicyID != "" {
		return p.PolicyID
	}
	return "allowlist-v1"
}

func (p *AllowListPolicy) Digest() [32]byte {
	actions := sortedCopy(p.AllowedActions)
	targets := sortedCopy(p.AllowedTargets)
	out := make([]byte, 0, 128)
	out = appendString(out, "policy:allowlist-v1")
	out = appendString(out, p.ID())
	out = binary.BigEndian.AppendUint32(out, uint32(len(actions)))
	for _, a := range actions {
		out = appendString(out, a)
	}
	out = binary.BigEndian.AppendUint32(out, uint32(len(targets)))
	for _, t := range targets {
		out = appendString(out, t)
	}
	return sha256.Sum256(out)
}

func (p *AllowListPolicy) Evaluate(in PolicyInputProjection) PolicyDecision {
	d := p.Digest()
	if in.Action == "" {
		return PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "ACTION_EMPTY",
			Reason:       "action name is required",
		}
	}
	if !containsString(p.AllowedActions, in.Action) {
		return PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "ACTION_NOT_ALLOWED",
			Reason:       "action " + in.Action + " is not in policy allowlist",
		}
	}
	if len(p.AllowedTargets) > 0 && !containsString(p.AllowedTargets, in.Target) {
		return PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "TARGET_NOT_ALLOWED",
			Reason:       "target " + in.Target + " is not in policy allowlist",
		}
	}
	return PolicyDecision{
		Verdict:       VerdictAllow,
		PolicyID:      p.ID(),
		PolicyDigest:  d,
		ReasonCode:    "ALLOWLIST_MATCH",
		Reason:        "action and target permitted",
		MaxSpendUgnot: in.BudgetUgnot,
	}
}

// BudgetCapPolicy enforces a per-call ugnot spend cap.
type BudgetCapPolicy struct {
	PolicyID        string
	MaxPerCallUgnot int64
}

func (p *BudgetCapPolicy) ID() string {
	if p.PolicyID != "" {
		return p.PolicyID
	}
	return "budget-cap-v1"
}

func (p *BudgetCapPolicy) Digest() [32]byte {
	out := make([]byte, 0, 64)
	out = appendString(out, "policy:budget-cap-v1")
	out = appendString(out, p.ID())
	out = binary.BigEndian.AppendUint64(out, uint64(p.MaxPerCallUgnot))
	return sha256.Sum256(out)
}

func (p *BudgetCapPolicy) Evaluate(in PolicyInputProjection) PolicyDecision {
	d := p.Digest()
	if in.BudgetUgnot < 0 {
		return PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "NEGATIVE_BUDGET",
			Reason:       "budget cannot be negative",
		}
	}
	if p.MaxPerCallUgnot < 0 || in.BudgetUgnot > p.MaxPerCallUgnot {
		return PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "BUDGET_EXCEEDED",
			Reason:       "requested " + strconv.FormatInt(in.BudgetUgnot, 10) + "ugnot exceeds cap " + strconv.FormatInt(p.MaxPerCallUgnot, 10) + "ugnot",
		}
	}
	return PolicyDecision{
		Verdict:       VerdictAllow,
		PolicyID:      p.ID(),
		PolicyDigest:  d,
		ReasonCode:    "BUDGET_OK",
		Reason:        "within budget cap",
		MaxSpendUgnot: in.BudgetUgnot,
	}
}

// RiskGatePolicy gates execution based on RiskTier.
// By default: LOW/MEDIUM -> ALLOW, HIGH -> REQUIRE_APPROVAL, CRITICAL -> ESCALATE.
type RiskGatePolicy struct {
	PolicyID          string
	AllowHigh         bool
	DenyCritical      bool
	RequireApprovalHi bool // default true when AllowHigh is false
}

func (p *RiskGatePolicy) ID() string {
	if p.PolicyID != "" {
		return p.PolicyID
	}
	return "risk-gate-v1"
}

func (p *RiskGatePolicy) Digest() [32]byte {
	out := make([]byte, 0, 64)
	out = appendString(out, "policy:risk-gate-v1")
	out = appendString(out, p.ID())
	out = append(out, boolByte(p.AllowHigh), boolByte(p.DenyCritical), boolByte(p.RequireApprovalHi))
	return sha256.Sum256(out)
}

func (p *RiskGatePolicy) Evaluate(in PolicyInputProjection) PolicyDecision {
	d := p.Digest()
	switch in.RiskTier {
	case RiskLow, RiskMedium:
		return PolicyDecision{
			Verdict:       VerdictAllow,
			PolicyID:      p.ID(),
			PolicyDigest:  d,
			ReasonCode:    "RISK_WITHIN_THRESHOLD",
			Reason:        "risk tier " + string(in.RiskTier) + " permitted for autonomous execution",
			MaxSpendUgnot: in.BudgetUgnot,
		}
	case RiskHigh:
		if p.AllowHigh {
			return PolicyDecision{
				Verdict:       VerdictAllow,
				PolicyID:      p.ID(),
				PolicyDigest:  d,
				ReasonCode:    "RISK_HIGH_ALLOWED",
				Reason:        "high risk explicitly permitted by policy",
				MaxSpendUgnot: in.BudgetUgnot,
			}
		}
		return PolicyDecision{
			Verdict:      VerdictRequireApproval,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "HIGH_RISK_APPROVAL_REQUIRED",
			Reason:       "high risk actions require explicit principal approval",
		}
	case RiskCritical:
		if p.DenyCritical {
			return PolicyDecision{
				Verdict:      VerdictDeny,
				PolicyID:     p.ID(),
				PolicyDigest: d,
				ReasonCode:   "CRITICAL_RISK_DENIED",
				Reason:       "critical risk actions are denied",
			}
		}
		return PolicyDecision{
			Verdict:      VerdictEscalate,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "CRITICAL_RISK_ESCALATED",
			Reason:       "critical risk actions must escalate to human governance",
		}
	default:
		return PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     p.ID(),
			PolicyDigest: d,
			ReasonCode:   "UNKNOWN_RISK_TIER",
			Reason:       "unrecognized risk tier fails closed",
		}
	}
}

// CompositePolicy evaluates all child policies in order and fails closed:
// the strictest verdict wins (DENY > ESCALATE > REQUIRE_APPROVAL > ALLOW).
// An empty CompositePolicy always fails closed with DENY.
type CompositePolicy struct {
	PolicyID string
	Rules    []Policy
}

func (c *CompositePolicy) ID() string {
	if c.PolicyID != "" {
		return c.PolicyID
	}
	return "composite-v1"
}

func (c *CompositePolicy) Digest() [32]byte {
	out := make([]byte, 0, 64+len(c.Rules)*32)
	out = appendString(out, "policy:composite-v1")
	out = appendString(out, c.ID())
	out = binary.BigEndian.AppendUint32(out, uint32(len(c.Rules)))
	for _, r := range c.Rules {
		if r == nil {
			z := ZeroDigest()
			out = append(out, z[:]...)
			continue
		}
		d := r.Digest()
		out = append(out, d[:]...)
	}
	return sha256.Sum256(out)
}

func (c *CompositePolicy) Evaluate(in PolicyInputProjection) PolicyDecision {
	cd := c.Digest()
	if len(c.Rules) == 0 {
		return PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     c.ID(),
			PolicyDigest: cd,
			ReasonCode:   "EMPTY_POLICY",
			Reason:       "composite policy with zero rules fails closed",
		}
	}
	worst := PolicyDecision{
		Verdict:       VerdictAllow,
		PolicyID:      c.ID(),
		PolicyDigest:  cd,
		ReasonCode:    "ALL_RULES_PASSED",
		Reason:        "all composite rules permitted execution",
		MaxSpendUgnot: in.BudgetUgnot,
	}
	for _, rule := range c.Rules {
		if rule == nil {
			return PolicyDecision{
				Verdict:      VerdictDeny,
				PolicyID:     c.ID(),
				PolicyDigest: cd,
				ReasonCode:   "NIL_RULE",
				Reason:       "nil policy rule fails closed",
			}
		}
		res := rule.Evaluate(in)
		if VerdictSeverity(res.Verdict) > VerdictSeverity(worst.Verdict) {
			worst = PolicyDecision{
				Verdict:       res.Verdict,
				PolicyID:      c.ID(),
				PolicyDigest:  cd,
				ReasonCode:    res.ReasonCode,
				Reason:        res.Reason,
				MaxSpendUgnot: 0,
			}
		} else if res.Verdict == VerdictAllow && worst.Verdict == VerdictAllow {
			if res.MaxSpendUgnot < worst.MaxSpendUgnot {
				worst.MaxSpendUgnot = res.MaxSpendUgnot
			}
		}
	}
	return worst
}

func containsString(list []string, target string) bool {
	for _, s := range list {
		if s == target {
			return true
		}
	}
	return false
}

func sortedCopy(in []string) []string {
	out := make([]string, len(in))
	copy(out, in)
	sort.Strings(out)
	return out
}

func boolByte(b bool) byte {
	if b {
		return 1
	}
	return 0
}
