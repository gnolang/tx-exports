package assurance

import (
	"errors"
	"strconv"
)

// MinSamplesForMeasuredScore mirrors Arobi's measured-assurance discipline:
// never invent fake constant scores when real activity is below threshold.
const MinSamplesForMeasuredScore uint64 = 3

// ToolSpec declares a governed capability exposed by an Agent.
type ToolSpec struct {
	Name           string
	Description    string
	RiskTier       RiskTier
	MaxBudgetUgnot int64
}

// ToolHandler executes a governed effect after receiving a freshly minted EffectWarrant.
// It returns output bytes, optional independent witness bytes, actual ugnot spent, and any error.
type ToolHandler func(w EffectWarrant, input []byte) (output []byte, witness []byte, spentUgnot int64, err error)

type registeredTool struct {
	spec    ToolSpec
	handler ToolHandler
}

// AgentConfig configures an Arobi-assured agent runtime.
type AgentConfig struct {
	AgentID          string
	ChainID          string
	Realm            string
	Principal        string
	WarrantTTLBlocks int64
}

// CheckpointSummary is the compact evidence state submitted to gno.land/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2.
type CheckpointSummary struct {
	AgentID        string
	CheckpointRoot [32]byte
	LastHash       [32]byte
	LeafCount      uint64
	ReceiptCount   uint64
	ClosureCount   uint64
}

// AssuranceMetrics reports strictly measured assurance factors derived from real receipts.
// If Measured is false, the factor has too few samples and must be displayed as UNMEASURED.
type AssuranceMetrics struct {
	Measured            bool
	TotalDecisions      uint64
	AllowedDecisions    uint64
	RefusedDecisions    uint64
	ExecutedClosures    uint64
	FailedClosures      uint64
	GovernanceBps       uint64 // 0..10000: warranted & policy-gated / total
	ClosureIntegrityBps uint64 // 0..10000: cleanly executed closures / allowed decisions
	RefusalIntegrityBps uint64 // 0..10000: clean refusals with zero spend / refused decisions
	AnchorLagBlocks     int64  // -1 if never anchored
}

// Agent is the out-of-the-box Arobi Assurance SDK runtime, built on Gno.land.
// Every action emits a hash-chained DecisionReceipt and EffectClosure inside an
// RFC 6962 Merkle Accumulator ready for anchoring on gno.land.
type Agent struct {
	cfg      AgentConfig
	policy   Policy
	paused   bool
	tools    []registeredTool
	seq      uint64
	warrantN uint64
	lastHash [32]byte
	acc      Accumulator
	receipts []DecisionReceipt
	closures []EffectClosure
	warrants []EffectWarrant
	// Track order of leaf types ("receipt" or "closure") so VerifyChain can walk linearly.
	chainKinds []string
}

// NewAgent creates a governed agent runtime with fail-closed defaults.
func NewAgent(cfg AgentConfig, policy Policy) *Agent {
	if cfg.WarrantTTLBlocks <= 0 {
		cfg.WarrantTTLBlocks = 5
	}
	return &Agent{
		cfg:    cfg,
		policy: policy,
	}
}

// Config returns the agent's configuration.
func (a *Agent) Config() AgentConfig {
	return a.cfg
}

// PolicyDigest returns the current policy's digest, or zero if unset (fail-closed).
func (a *Agent) PolicyDigest() [32]byte {
	if a.policy == nil {
		return ZeroDigest()
	}
	return a.policy.Digest()
}

// SetPolicy updates the agent's active policy.
func (a *Agent) SetPolicy(policy Policy) {
	a.policy = policy
}

// Pause halts all tool execution (new requests record fail-closed refusal receipts).
func (a *Agent) Pause() {
	a.paused = true
}

// Resume re-enables governed tool execution.
func (a *Agent) Resume() {
	a.paused = false
}

// RegisterTool registers a named tool and handler with its RiskTier and spend ceiling.
func (a *Agent) RegisterTool(spec ToolSpec, handler ToolHandler) error {
	if spec.Name == "" {
		return errors.New("tool name is required")
	}
	if handler == nil {
		return errors.New("tool handler is required")
	}
	if spec.RiskTier == "" {
		spec.RiskTier = RiskMedium
	}
	if spec.MaxBudgetUgnot < 0 {
		return errors.New("tool max budget cannot be negative")
	}
	for i := range a.tools {
		if a.tools[i].spec.Name == spec.Name {
			a.tools[i] = registeredTool{spec: spec, handler: handler}
			return nil
		}
	}
	a.tools = append(a.tools, registeredTool{spec: spec, handler: handler})
	return nil
}

func (a *Agent) findTool(name string) (registeredTool, bool) {
	for i := range a.tools {
		if a.tools[i].spec.Name == name {
			return a.tools[i], true
		}
	}
	return registeredTool{}, false
}

// Execute runs a governed tool invocation through the complete Arobi Assurance pipeline:
// projection -> fail-closed policy gate -> hash-chained DecisionReceipt -> single-use
// EffectWarrant -> execution -> EffectClosure -> RFC 6962 proofs in EvidenceBundle.
func (a *Agent) Execute(
	caller string,
	action string,
	target string,
	input []byte,
	contextBytes []byte,
	budgetUgnot int64,
	height int64,
) ([]byte, EvidenceBundle, error) {
	tool, hasTool := a.findTool(action)
	risk := RiskHigh
	if hasTool {
		risk = tool.spec.RiskTier
	}

	proj := PolicyInputProjection{
		ChainID:       a.cfg.ChainID,
		Realm:         a.cfg.Realm,
		AgentID:       a.cfg.AgentID,
		Principal:     a.cfg.Principal,
		Caller:        caller,
		Action:        action,
		Target:        target,
		InputDigest:   HashBytes(input),
		ContextDigest: HashBytes(contextBytes),
		BudgetUgnot:   budgetUgnot,
		RiskTier:      risk,
		Height:        height,
	}
	projDigest := proj.Digest()

	// Step 1: Fail-closed policy evaluation.
	var dec PolicyDecision
	switch {
	case a.paused:
		dec = PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     "runtime-killswitch",
			PolicyDigest: a.PolicyDigest(),
			ReasonCode:   "AGENT_PAUSED",
			Reason:       "agent is paused by governance kill switch",
		}
	case !hasTool:
		dec = PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     "runtime-registry",
			PolicyDigest: a.PolicyDigest(),
			ReasonCode:   "TOOL_UNREGISTERED",
			Reason:       "tool " + action + " is not registered",
		}
	case a.policy == nil:
		dec = PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     "runtime-fail-closed",
			PolicyDigest: ZeroDigest(),
			ReasonCode:   "POLICY_UNSET",
			Reason:       "no policy configured; failing closed",
		}
	case budgetUgnot > tool.spec.MaxBudgetUgnot:
		dec = PolicyDecision{
			Verdict:      VerdictDeny,
			PolicyID:     "tool-spec-cap",
			PolicyDigest: a.policy.Digest(),
			ReasonCode:   "TOOL_BUDGET_EXCEEDED",
			Reason:       "budget exceeds tool spec ceiling",
		}
	default:
		dec = a.policy.Evaluate(proj)
	}

	// Step 2: If allowed, mint a single-use EffectWarrant bound to exact projection + policy.
	var warrant EffectWarrant
	hasWarrant := false
	warrantIdx := -1
	warrantDigest := ZeroDigest()
	if dec.Verdict == VerdictAllow {
		a.warrantN++
		capUgnot := budgetUgnot
		if dec.MaxSpendUgnot >= 0 && dec.MaxSpendUgnot < capUgnot {
			capUgnot = dec.MaxSpendUgnot
		}
		warrant = EffectWarrant{
			ID:               a.warrantN,
			AgentID:          a.cfg.AgentID,
			ProjectionDigest: projDigest,
			PolicyDigest:     dec.PolicyDigest,
			Action:           action,
			Target:           target,
			MaxSpendUgnot:    capUgnot,
			IssuedHeight:     height,
			ExpiryHeight:     height + a.cfg.WarrantTTLBlocks,
			Consumed:         false,
		}
		warrantIdx = len(a.warrants)
		a.warrants = append(a.warrants, warrant)
		hasWarrant = true
		warrantDigest = warrant.Digest()
	}

	// Step 3: Record immutable hash-chained DecisionReceipt into RFC 6962 Accumulator.
	a.seq++
	rec := DecisionReceipt{
		Seq:              a.seq,
		PrevHash:         a.lastHash,
		ChainID:          a.cfg.ChainID,
		Realm:            a.cfg.Realm,
		AgentID:          a.cfg.AgentID,
		Caller:           caller,
		ProjectionDigest: projDigest,
		PolicyDigest:     dec.PolicyDigest,
		Verdict:          dec.Verdict,
		ReasonCode:       dec.ReasonCode,
		WarrantDigest:    warrantDigest,
		Height:           height,
	}
	recLeaf := rec.LeafHash()
	recIndex := a.acc.Append(recLeaf)
	a.receipts = append(a.receipts, rec)
	a.chainKinds = append(a.chainKinds, "receipt")
	a.lastHash = recLeaf

	// Step 4: Execute ONLY when warranted; otherwise record an immutable REFUSED closure.
	var (
		output     []byte
		witness    []byte
		spentUgnot int64
		outcome    Outcome
		execErr    error
	)

	if !hasWarrant {
		outcome = OutcomeRefused
		execErr = errors.New("action refused (" + string(dec.Verdict) + ": " + dec.ReasonCode + "): " + dec.Reason)
	} else {
		if warrantIdx < 0 || warrantIdx >= len(a.warrants) || a.warrants[warrantIdx].Consumed {
			outcome = OutcomeFailed
			execErr = errors.New("warrant already consumed or missing")
		} else if height > a.warrants[warrantIdx].ExpiryHeight {
			outcome = OutcomeFailed
			execErr = errors.New("warrant expired before execution")
		} else {
			// Mark warrant consumed BEFORE handler runs (single-use, reentrancy-safe).
			a.warrants[warrantIdx].Consumed = true
			warrant.Consumed = true
			out, wit, spent, err := tool.handler(warrant, input)
			output = out
			witness = wit
			spentUgnot = spent
			switch {
			case err != nil:
				outcome = OutcomeFailed
				execErr = err
			case spent < 0 || spent > warrant.MaxSpendUgnot:
				outcome = OutcomeFailed
				execErr = errors.New("tool handler violated warrant spend ceiling: spent " +
					strconv.FormatInt(spent, 10) + "ugnot > max " + strconv.FormatInt(warrant.MaxSpendUgnot, 10) + "ugnot")
			default:
				outcome = OutcomeExecuted
			}
		}
	}

	// Step 5: Record immutable hash-chained EffectClosure into RFC 6962 Accumulator.
	a.seq++
	closure := EffectClosure{
		Seq:              a.seq,
		PrevHash:         a.lastHash,
		AgentID:          a.cfg.AgentID,
		WarrantDigest:    warrantDigest,
		DecisionLeafHash: recLeaf,
		OutputDigest:     HashBytes(output),
		WitnessDigest:    HashBytes(witness),
		Outcome:          outcome,
		SpentUgnot:       spentUgnot,
		Height:           height,
	}
	closureLeaf := closure.LeafHash()
	closureIndex := a.acc.Append(closureLeaf)
	a.closures = append(a.closures, closure)
	a.chainKinds = append(a.chainKinds, "closure")
	a.lastHash = closureLeaf

	// Step 6: Build self-verifying EvidenceBundle with RFC 6962 inclusion proofs.
	size := a.acc.Size()
	root := a.acc.Root()
	recProof, _ := a.acc.Proof(recIndex, size)
	closureProof, _ := a.acc.Proof(closureIndex, size)

	bundle := EvidenceBundle{
		Projection:       proj,
		Decision:         dec,
		HasWarrant:       hasWarrant,
		Warrant:          warrant,
		Receipt:          rec,
		Closure:          closure,
		ReceiptLeafIndex: recIndex,
		ClosureLeafIndex: closureIndex,
		AccumulatorSize:  size,
		AccumulatorRoot:  root,
		ReceiptProof:     recProof,
		ClosureProof:     closureProof,
	}

	return output, bundle, execErr
}

// ExecuteDelegated runs a sub-agent action under a strictly attenuated DelegatedWarrant.
// Enforces child identity binding, spend ceiling, expiry height, and single-use replay
// protection, while chaining the parent warrant digest into the child's ContextDigest so
// multi-agent provenance is cryptographically verifiable end-to-end.
func (a *Agent) ExecuteDelegated(
	delegated DelegatedWarrant,
	caller string,
	input []byte,
	contextBytes []byte,
	budgetUgnot int64,
	height int64,
) ([]byte, EvidenceBundle, error) {
	if delegated.ChildAgentID != a.cfg.AgentID {
		return nil, EvidenceBundle{}, errors.New("delegated warrant is bound to child agent " + delegated.ChildAgentID + ", not " + a.cfg.AgentID)
	}
	if height > delegated.ExpiryHeight {
		return nil, EvidenceBundle{}, errors.New("delegated warrant expired at height " + strconv.FormatInt(delegated.ExpiryHeight, 10))
	}
	if budgetUgnot < 0 || budgetUgnot > delegated.MaxSpendUgnot {
		return nil, EvidenceBundle{}, errors.New("requested budget exceeds delegated warrant ceiling")
	}
	// Bind the delegated warrant digest into contextBytes so the child's DecisionReceipt
	// cryptographically links back to the coordinator's parent EffectWarrant.
	dDigest := delegated.Digest()
	boundCtx := make([]byte, 0, len(contextBytes)+64)
	boundCtx = append(boundCtx, delegated.ParentWarrantDigest[:]...)
	boundCtx = append(boundCtx, dDigest[:]...)
	boundCtx = append(boundCtx, contextBytes...)
	return a.Execute(caller, delegated.Action, delegated.Target, input, boundCtx, budgetUgnot, height)
}

// Checkpoint returns the compact root and counters ready to anchor on gno.land.
func (a *Agent) Checkpoint() CheckpointSummary {
	return CheckpointSummary{
		AgentID:        a.cfg.AgentID,
		CheckpointRoot: a.acc.Root(),
		LastHash:       a.lastHash,
		LeafCount:      a.acc.Size(),
		ReceiptCount:   uint64(len(a.receipts)),
		ClosureCount:   uint64(len(a.closures)),
	}
}

// Accumulator returns a read-oriented pointer to the underlying RFC 6962 accumulator.
func (a *Agent) Accumulator() *Accumulator {
	return &a.acc
}

// Receipts returns a copy of all DecisionReceipts recorded by this agent.
func (a *Agent) Receipts() []DecisionReceipt {
	out := make([]DecisionReceipt, len(a.receipts))
	copy(out, a.receipts)
	return out
}

// Closures returns a copy of all EffectClosures recorded by this agent.
func (a *Agent) Closures() []EffectClosure {
	out := make([]EffectClosure, len(a.closures))
	copy(out, a.closures)
	return out
}

// Metrics computes strictly measured assurance metrics from real recorded evidence.
func (a *Agent) Metrics(currentHeight, lastAnchoredHeight int64) AssuranceMetrics {
	total := uint64(len(a.receipts))
	var allowed, refused, governed, executed, failed, cleanRefusals uint64
	for i, r := range a.receipts {
		if r.PolicyDigest != ZeroDigest() {
			governed++
		}
		if r.Verdict == VerdictAllow {
			allowed++
		} else {
			refused++
		}
		if i < len(a.closures) {
			c := a.closures[i]
			switch c.Outcome {
			case OutcomeExecuted:
				executed++
			case OutcomeFailed:
				failed++
			case OutcomeRefused:
				if c.SpentUgnot == 0 && c.WarrantDigest == ZeroDigest() {
					cleanRefusals++
				}
			}
		}
	}

	lag := int64(-1)
	if lastAnchoredHeight > 0 && currentHeight >= lastAnchoredHeight {
		lag = currentHeight - lastAnchoredHeight
	}

	m := AssuranceMetrics{
		Measured:         total >= MinSamplesForMeasuredScore,
		TotalDecisions:   total,
		AllowedDecisions: allowed,
		RefusedDecisions: refused,
		ExecutedClosures: executed,
		FailedClosures:   failed,
		AnchorLagBlocks:  lag,
	}
	if !m.Measured {
		return m
	}

	m.GovernanceBps = (governed * 10000) / total
	if allowed > 0 {
		m.ClosureIntegrityBps = (executed * 10000) / allowed
	} else {
		m.ClosureIntegrityBps = 10000
	}
	if refused > 0 {
		m.RefusalIntegrityBps = (cleanRefusals * 10000) / refused
	} else {
		m.RefusalIntegrityBps = 10000
	}
	return m
}

// VerifyChain walks the entire hash chain and recomputes the RFC 6962 accumulator from leaf 0.
func (a *Agent) VerifyChain() error {
	var checkAcc Accumulator
	prev := ZeroDigest()
	rIdx, cIdx := 0, 0
	for i, kind := range a.chainKinds {
		var leaf [32]byte
		switch kind {
		case "receipt":
			if rIdx >= len(a.receipts) {
				return errors.New("receipt slice truncated")
			}
			r := a.receipts[rIdx]
			if r.PrevHash != prev {
				return errors.New("broken receipt hash chain at leaf " + strconv.Itoa(i))
			}
			leaf = r.LeafHash()
			rIdx++
		case "closure":
			if cIdx >= len(a.closures) {
				return errors.New("closure slice truncated")
			}
			c := a.closures[cIdx]
			if c.PrevHash != prev {
				return errors.New("broken closure hash chain at leaf " + strconv.Itoa(i))
			}
			leaf = c.LeafHash()
			cIdx++
		default:
			return errors.New("unknown leaf kind: " + kind)
		}
		accLeaf, ok := a.acc.Leaf(uint64(i))
		if !ok || accLeaf != leaf {
			return errors.New("accumulator leaf mismatch at index " + strconv.Itoa(i))
		}
		checkAcc.Append(leaf)
		prev = leaf
	}
	if checkAcc.Root() != a.acc.Root() {
		return errors.New("recomputed Merkle root does not match accumulator root")
	}
	if prev != a.lastHash {
		return errors.New("chain tip hash mismatch")
	}
	return nil
}
