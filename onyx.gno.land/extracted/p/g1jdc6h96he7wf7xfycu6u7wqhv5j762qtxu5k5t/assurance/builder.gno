package assurance

import (
	"errors"

	"gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/signals"
)

// AgentBuilder is the fluent Immaculate SDK Agent Builder for constructing governed
// Gno agents with fail-closed policies, single-use warrants, and RFC 6962 evidence
// out of the box.
type AgentBuilder struct {
	cfg            AgentConfig
	policyID       string
	allowedActions []string
	allowedTargets []string
	maxBudgetUgnot int64
	hasBudgetCap   bool
	riskGate       *RiskGatePolicy
	driftGuard     *DriftGuardPolicy
	coherenceGuard *CoherenceGuardPolicy
	extraPolicies  []Policy
	tools          []registeredTool
	buildErr       error
}

// NewAgentBuilder starts building a governed agent with safe fail-closed defaults:
// risk gating enabled (LOW/MEDIUM auto-allow, HIGH requires approval, CRITICAL escalates).
func NewAgentBuilder(agentID string) *AgentBuilder {
	return &AgentBuilder{
		cfg: AgentConfig{
			AgentID:          agentID,
			ChainID:          "gnoland-testnet",
			Realm:            "gno.land/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/assurance",
			WarrantTTLBlocks: 10,
		},
		policyID: agentID + "-policy-v1",
		riskGate: &RiskGatePolicy{
			PolicyID:     agentID + "-risk-gate",
			AllowHigh:    false,
			DenyCritical: false,
		},
	}
}

func (b *AgentBuilder) WithChain(chainID, realmPath string) *AgentBuilder {
	b.cfg.ChainID = chainID
	b.cfg.Realm = realmPath
	return b
}

func (b *AgentBuilder) WithPrincipal(principal string) *AgentBuilder {
	b.cfg.Principal = principal
	return b
}

func (b *AgentBuilder) WithWarrantTTL(blocks int64) *AgentBuilder {
	b.cfg.WarrantTTLBlocks = blocks
	return b
}

func (b *AgentBuilder) WithPolicyID(id string) *AgentBuilder {
	b.policyID = id
	return b
}

func (b *AgentBuilder) AllowActions(actions ...string) *AgentBuilder {
	b.allowedActions = append(b.allowedActions, actions...)
	return b
}

func (b *AgentBuilder) AllowTargets(targets ...string) *AgentBuilder {
	b.allowedTargets = append(b.allowedTargets, targets...)
	return b
}

func (b *AgentBuilder) WithBudgetCap(maxPerCallUgnot int64) *AgentBuilder {
	b.maxBudgetUgnot = maxPerCallUgnot
	b.hasBudgetCap = true
	return b
}

func (b *AgentBuilder) WithRiskGate(allowHigh, denyCritical bool) *AgentBuilder {
	b.riskGate = &RiskGatePolicy{
		PolicyID:     b.cfg.AgentID + "-risk-gate",
		AllowHigh:    allowHigh,
		DenyCritical: denyCritical,
	}
	return b
}

func (b *AgentBuilder) WithPolicy(p Policy) *AgentBuilder {
	if p != nil {
		b.extraPolicies = append(b.extraPolicies, p)
	}
	return b
}

// WithDriftGuard attaches a deterministic Hampel-guarded CUSUM behavioral drift circuit breaker.
func (b *AgentBuilder) WithDriftGuard(base signals.Baseline, hFixed, kFixed int64, hampelWindow int, strictDeny, latchOnAlarm bool) *AgentBuilder {
	dg, err := NewDriftGuardPolicy(b.cfg.AgentID+"-drift-guard", base, hFixed, kFixed, hampelWindow, 3*signals.Scale, strictDeny, latchOnAlarm)
	if err != nil {
		b.buildErr = err
		return b
	}
	b.driftGuard = dg
	return b
}

// WithCoherenceGuard attaches a deterministic spherical context coherence gate to block memory poisoning.
func (b *AgentBuilder) WithCoherenceGuard(thresholdFixed int64, usePairwise, strictDeny, requireOnAllCall bool) *AgentBuilder {
	cg, err := NewCoherenceGuardPolicy(b.cfg.AgentID+"-coherence-guard", thresholdFixed, usePairwise, strictDeny, requireOnAllCall)
	if err != nil {
		b.buildErr = err
		return b
	}
	b.coherenceGuard = cg
	return b
}

// DriftGuard returns the configured DriftGuardPolicy (nil if unset).
func (b *AgentBuilder) DriftGuard() *DriftGuardPolicy { return b.driftGuard }

// CoherenceGuard returns the configured CoherenceGuardPolicy (nil if unset).
func (b *AgentBuilder) CoherenceGuard() *CoherenceGuardPolicy { return b.coherenceGuard }

func (b *AgentBuilder) WithTool(spec ToolSpec, handler ToolHandler) *AgentBuilder {
	if spec.Name == "" || handler == nil {
		b.buildErr = errors.New("tool requires non-empty name and handler")
		return b
	}
	if spec.RiskTier == "" {
		spec.RiskTier = RiskMedium
	}
	b.tools = append(b.tools, registeredTool{spec: spec, handler: handler})
	return b
}

// Build validates configuration, assembles a fail-closed CompositePolicy, registers all
// tools, and returns a ready-to-execute governed Agent.
func (b *AgentBuilder) Build() (*Agent, error) {
	if b.buildErr != nil {
		return nil, b.buildErr
	}
	if b.cfg.AgentID == "" {
		return nil, errors.New("agentID is required")
	}
	if b.cfg.Principal == "" {
		return nil, errors.New("principal address is required")
	}

	var rules []Policy
	if len(b.allowedActions) > 0 || len(b.allowedTargets) > 0 {
		rules = append(rules, &AllowListPolicy{
			PolicyID:       b.cfg.AgentID + "-allowlist",
			AllowedActions: b.allowedActions,
			AllowedTargets: b.allowedTargets,
		})
	}
	if b.hasBudgetCap {
		rules = append(rules, &BudgetCapPolicy{
			PolicyID:        b.cfg.AgentID + "-budget",
			MaxPerCallUgnot: b.maxBudgetUgnot,
		})
	}
	if b.riskGate != nil {
		rules = append(rules, b.riskGate)
	}
	if b.driftGuard != nil {
		rules = append(rules, b.driftGuard)
	}
	if b.coherenceGuard != nil {
		rules = append(rules, b.coherenceGuard)
	}
	rules = append(rules, b.extraPolicies...)

	policy := &CompositePolicy{
		PolicyID: b.policyID,
		Rules:    rules,
	}

	ag := NewAgent(b.cfg, policy)
	for _, t := range b.tools {
		if err := ag.RegisterTool(t.spec, t.handler); err != nil {
			return nil, err
		}
	}
	return ag, nil
}

// BuildFamiliar builds the governed Agent and wraps it as an owner-bonded Familiar with
// a poison-resistant Hybrid RRF MemoryVault, attenuated CapabilityToken, and Wilson TrustLedger.
func (b *AgentBuilder) BuildFamiliar(
	capMask uint32,
	maxSpendUgnot int64,
	maxCallsPerWindow uint64,
	windowBlocks int64,
	issuedHeight int64,
	expiryHeight int64,
	quarantineThresholdFixed int64,
	minTrustFloorFixed int64,
) (*Familiar, error) {
	ag, err := b.Build()
	if err != nil {
		return nil, err
	}
	vault := NewMemoryVault(MemoryVaultConfig{
		VaultID:                  b.cfg.AgentID + "-memory",
		QuarantineThresholdFixed: quarantineThresholdFixed,
		MinTrustedAnchors:        2,
		HalfLifeBlocks:           1000,
		RRFK:                     DefaultRRFK,
	})
	tok := CapabilityToken{
		ID:                1,
		FamiliarID:        b.cfg.AgentID,
		Owner:             b.cfg.Principal,
		GrantMask:         capMask,
		MaxSpendUgnot:     maxSpendUgnot,
		MaxCallsPerWindow: maxCallsPerWindow,
		WindowBlocks:      windowBlocks,
		IssuedHeight:      issuedHeight,
		ExpiryHeight:      expiryHeight,
	}
	return NewFamiliar(b.cfg.AgentID, b.cfg.Principal, ag, vault, b.coherenceGuard, tok, minTrustFloorFixed)
}
