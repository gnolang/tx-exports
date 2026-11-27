// Package assurance is the public on-chain agent passport registry on Gno.land and
// RFC 6962 Evidence Anchor for Immaculate SDK Agent Builder.
//
// Any agent built with gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2 can register an owner-bound passport,
// anchor hash-chained evidence checkpoints (paying AnchorFeeUgnot in GNOT), optionally
// subscribe to the Pro Agent Plan in GNOT for 1-block high-frequency anchoring, and let
// any third party verify RFC 6962 inclusion proofs on-chain or offline.
//
// Settlement: service fees are enforced on-chain in GNOT. The deployer becomes operator
// atomically inside init() during deployment (no post-deploy claim race). No payout address
// is hardcoded, rendered in gnoweb, or emitted in events; on a public chain, realm state and
// bank transfers are publicly inspectable.
package assurance

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	sdk "gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2"
	"gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/signals/v2"
	"gno.land/p/nt/avl/v0"
)

const (
	denom = "ugnot"
	// MinBlocksBetween is the standard per-agent anchoring cadence.
	MinBlocksBetween int64 = 5
	// ProMinBlocksBetween is the fast anchoring cadence unlocked by an active Pro Agent Plan.
	ProMinBlocksBetween int64 = 1
	// PlanPeriodBlocks is ~30 days at ~2s/block.
	PlanPeriodBlocks int64 = 1296000
	// DemoAgentID is the built-in live governed agent anyone can test on gno.land.
	DemoAgentID = "immaculate-demo-agent"
)

// AgentPassport is the on-chain identity, plan tier, and checkpoint tip for a governed agent.
type AgentPassport struct {
	AgentID          string
	Owner            address
	DisplayName      string
	PolicyDigest     [32]byte
	MetadataURI      string
	RegisteredHeight int64
	Revoked          bool
	ProExpiresHeight int64
	LastAnchorID     uint64
	LastAnchorHeight int64
	LastRoot         [32]byte
	TotalLeaves      uint64
	TotalReceipts    uint64
	TotalClosures    uint64
	AnchorCount      uint64
}

var (
	// Service pricing in ugnot (configurable by operator; zero hardcoded payout wallets).
	anchorFeeUgnot      int64 = 1000     // 0.001 GNOT per anchored evidence checkpoint
	agentPlanPriceUgnot int64 = 10000000 // 10 GNOT per 30-day Pro Agent Plan

	// Operator and settlement sink. Render and events do not print them; on a public chain
	// realm state and bank transfers remain publicly inspectable. deployer is bound once in init().
	deployer           address
	operator           address
	settlementSink     address
	accruedServiceFees int64

	// Storage whose gas per transaction stays flat as history grows: trees and counters, never a slice
	// appended to on every call (a slice's backing array is loaded and saved in full each time).
	passports   = avl.NewTree() // agentID -> *AgentPassport
	agentCount  uint64         // agents ever registered
	agentSeq    = avl.NewTree() // anchorKey(seq) -> agentID, in registration order
	anchors     = avl.NewTree() // anchorKey(id) -> sdk.AnchorRecord
	anchorCount uint64
	globalAcc   sdk.LedgerAccumulator // grows with every anchor across transactions: leaves in a tree

	// Built-in interactive governed demo agent & Familiar powered directly by gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2.
	demoAgent            *sdk.Agent
	demoDriftGuard       *sdk.DriftGuardPolicy
	demoCoherence        *sdk.CoherenceGuardPolicy
	demoFamiliar         *sdk.Familiar
	demoFamiliarLastOut  string
	demoFamiliarLastErr  string
	demoFamiliarLastRoot string
	demoLastOut          string
	demoLastErr          string
	demoLastRoot         string
)

// ── Operator & Settlement Configuration ──────────────────────────────────────

// init binds the deploying account as deployer and operator atomically inside the
// deployment transaction itself, closing any post-deploy operator front-running window.
func init() {
	initOperatorFromDeployment()
}

func initOperatorFromDeployment() {
	deployer = unsafe.OriginCaller()
	operator = deployer
}

// Operator returns the current operator address.
func Operator() address { return operator }

// TransferOperator transfers operator control to a new address (operator only).
func TransferOperator(cur realm, next address) {
	mustOperator(cur)
	if !next.IsValid() {
		panic("invalid operator address")
	}
	operator = next
}

// SetSettlementSink privately sets an optional direct settlement sink for service fees
// (operator only; never printed in Render() or emitted in public events).
func SetSettlementSink(cur realm, sink address) {
	mustOperator(cur)
	if sink != "" && !sink.IsValid() {
		panic("invalid settlement address")
	}
	settlementSink = sink
}

// SetPricing updates GNOT anchor fee and 30-day Pro Agent Plan pricing (operator only).
func SetPricing(cur realm, newAnchorFeeUgnot, newPlanPriceUgnot int64) {
	mustOperator(cur)
	if newAnchorFeeUgnot < 0 || newPlanPriceUgnot < 0 {
		panic("fees cannot be negative")
	}
	anchorFeeUgnot = newAnchorFeeUgnot
	agentPlanPriceUgnot = newPlanPriceUgnot
}

// CollectServiceFees withdraws accrued GNOT service fees to an operator-chosen destination.
func CollectServiceFees(cur realm, to address) int64 {
	mustOperator(cur)
	if !to.IsValid() {
		panic("invalid destination address")
	}
	amount := accruedServiceFees
	if amount <= 0 {
		return 0
	}
	accruedServiceFees = 0
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin(denom, amount)})
	return amount
}

// Public pricing queries (no payout addresses exposed).
func AnchorFeeUgnot() int64      { return anchorFeeUgnot }
func AgentPlanPriceUgnot() int64 { return agentPlanPriceUgnot }

// AgentOwner returns an agent passport's owner, and whether the passport is active (registered and not revoked).
// It only reads. gno.land/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/effects/v2 uses it to check that whoever starts an agent's effect owns the agent.
func AgentOwner(agentID string) (address, bool) {
	pp, ok := passports.Get(agentID).(*AgentPassport)
	if !ok || pp == nil {
		return "", false
	}
	return pp.Owner, !pp.Revoked
}

// ── Demo Agent Setup ─────────────────────────────────────────────────────────

func ensureDemoAgent() *sdk.Agent {
	if demoAgent == nil {
		initDemoAgent()
	}
	return demoAgent
}

func demoSummarizeHandler(w sdk.EffectWarrant, input []byte) ([]byte, []byte, int64, error) {
	digest := sdk.Hex(sdk.HashBytes(input))
	out := []byte("summarized(" + digest[:16] + ")")
	witness := []byte("warrant:" + strconv.FormatUint(w.ID, 10))
	return out, witness, 0, nil
}

func demoAttestHandler(w sdk.EffectWarrant, input []byte) ([]byte, []byte, int64, error) {
	out := []byte("attested:" + sdk.Hex(sdk.HashBytes(input))[:16])
	witness := []byte("attest-warrant:" + strconv.FormatUint(w.ID, 10))
	return out, witness, 100, nil
}

func demoEscrowHandler(w sdk.EffectWarrant, input []byte) ([]byte, []byte, int64, error) {
	return []byte("transferred"), nil, 500, nil
}

func demoWipeHandler(w sdk.EffectWarrant, input []byte) ([]byte, []byte, int64, error) {
	return []byte("wiped"), nil, 0, nil
}

func initDemoAgent() {
	base := signals.Baseline{
		MeanFixed: 100 * signals.Scale,
		SDFixed:   20 * signals.Scale,
	}
	b := sdk.NewAgentBuilder(DemoAgentID).
		WithChain("gnoland-testnet", "gno.land/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2").
		WithPrincipal("demo-governance-principal").
		WithPolicyID("immaculate-demo-policy-v2").
		AllowActions("summarize", "attest", "escrow_transfer", "wipe_state").
		WithBudgetCap(2500).
		WithRiskGate(false, false).
		WithDriftGuard(base, 5*signals.Scale, signals.Scale, 5, false, true).
		WithCoherenceGuard(750000, false, false, false).
		WithTool(sdk.ToolSpec{
			Name:           "summarize",
			Description:    "Low-risk deterministic digest & summary action",
			RiskTier:       sdk.RiskLow,
			MaxBudgetUgnot: 1000,
		}, demoSummarizeHandler).
		WithTool(sdk.ToolSpec{
			Name:           "attest",
			Description:    "Medium-risk attestation with witness digest",
			RiskTier:       sdk.RiskMedium,
			MaxBudgetUgnot: 2500,
		}, demoAttestHandler).
		WithTool(sdk.ToolSpec{
			Name:           "escrow_transfer",
			Description:    "High-risk transfer requiring explicit human approval",
			RiskTier:       sdk.RiskHigh,
			MaxBudgetUgnot: 2500,
		}, demoEscrowHandler).
		WithTool(sdk.ToolSpec{
			Name:           "wipe_state",
			Description:    "Critical destructive operation escalated to governance",
			RiskTier:       sdk.RiskCritical,
			MaxBudgetUgnot: 0,
		}, demoWipeHandler)

	ag, err := b.Build()
	if err != nil {
		panic("init demo agent: " + err.Error())
	}
	demoAgent = ag
	demoDriftGuard = b.DriftGuard()
	demoCoherence = b.CoherenceGuard()
}

// ── Agent Passport, Subscription & Evidence Anchoring ────────────────────────

// RegisterAgent registers a new owner-bound AgentPassport on gno.land.
func RegisterAgent(cur realm, agentID, displayName, policyDigestHex, metadataURI string) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("register agent with a direct user call")
	}
	if !isValidAgentID(agentID) {
		panic("agentID must be 3..48 lowercase alphanumeric, hyphen, or underscore characters")
	}
	if passports.Has(agentID) {
		panic("agentID already registered: " + agentID)
	}
	if len(displayName) == 0 || len(displayName) > 80 {
		panic("displayName must be 1..80 characters")
	}
	if len(metadataURI) > 256 {
		panic("metadataURI too long (max 256)")
	}
	pDigest, err := sdk.ParseDigest(policyDigestHex)
	if err != nil {
		panic("policyDigestHex: " + err.Error())
	}

	owner := prev.Address()
	height := runtime.ChainHeight()
	pp := &AgentPassport{
		AgentID:          agentID,
		Owner:            owner,
		DisplayName:      displayName,
		PolicyDigest:     pDigest,
		MetadataURI:      metadataURI,
		RegisteredHeight: height,
	}
	passports.Set(agentID, pp)
	agentCount++
	agentSeq.Set(anchorKey(agentCount), agentID)

	chain.Emit("ImmaculateAgentRegistered",
		"agent_id", agentID,
		"owner", owner.String(),
		"policy_digest", policyDigestHex,
		"height", strconv.FormatInt(height, 10),
	)
}

// SubscribeAgent upgrades or extends an AgentPassport to the Pro Agent Plan for 30 days
// (1-block high-frequency anchoring cadence) by paying exact AgentPlanPriceUgnot in GNOT.
func SubscribeAgent(cur realm, agentID string) int64 {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("subscribe agent with a direct user call")
	}
	pp := mustOwnedActiveAgent(agentID, prev.Address())
	paid := sentUgnot()
	if paid != agentPlanPriceUgnot {
		panic("send exact plan price " + strconv.FormatInt(agentPlanPriceUgnot, 10) + denom +
			"; got " + strconv.FormatInt(paid, 10) + denom)
	}
	height := runtime.ChainHeight()
	baseExpiry := height
	if pp.ProExpiresHeight > height {
		baseExpiry = pp.ProExpiresHeight
	}
	pp.ProExpiresHeight = baseExpiry + PlanPeriodBlocks
	settleServiceFee(cur, paid)

	chain.Emit("ImmaculateAgentSubscribed",
		"agent_id", agentID,
		"tier", "pro",
		"paid_ugnot", strconv.FormatInt(paid, 10),
		"expires_height", strconv.FormatInt(pp.ProExpiresHeight, 10),
	)
	return pp.ProExpiresHeight
}

// UpdateAgentPolicy updates the registered policy digest for an active agent (owner only).
func UpdateAgentPolicy(cur realm, agentID, newPolicyDigestHex string) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("update agent policy with a direct user call")
	}
	pp := mustOwnedActiveAgent(agentID, prev.Address())
	pDigest, err := sdk.ParseDigest(newPolicyDigestHex)
	if err != nil {
		panic("newPolicyDigestHex: " + err.Error())
	}
	pp.PolicyDigest = pDigest
	chain.Emit("ImmaculateAgentPolicyUpdated",
		"agent_id", agentID,
		"policy_digest", newPolicyDigestHex,
		"height", strconv.FormatInt(runtime.ChainHeight(), 10),
	)
}

// RevokeAgent permanently revokes an agent passport so it can no longer anchor new checkpoints.
func RevokeAgent(cur realm, agentID string) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("revoke agent with a direct user call")
	}
	pp := mustOwnedActiveAgent(agentID, prev.Address())
	pp.Revoked = true
	chain.Emit("ImmaculateAgentRevoked",
		"agent_id", agentID,
		"owner", prev.Address().String(),
		"height", strconv.FormatInt(runtime.ChainHeight(), 10),
	)
}

// AnchorCheckpoint anchors an agent's RFC 6962 evidence accumulator root on gno.land.
//
// Enforces:
//   - Direct user call by the registered, non-revoked agent owner
//   - Exact service fee AnchorFeeUgnot in GNOT (routed privately; zero payout disclosure)
//   - Strict prevRoot chaining (prevents rollback / equivocation)
//   - Monotonic leaf, receipt, and closure counters
//   - Per-agent block rate limit (5 blocks standard, 1 block for Pro Agent Plan)
func AnchorCheckpoint(
	cur realm,
	agentID string,
	checkpointRootHex string,
	prevRootHex string,
	leafCount uint64,
	receiptCount uint64,
	closureCount uint64,
) uint64 {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("anchor with a direct user call")
	}
	caller := prev.Address()
	pp := mustOwnedActiveAgent(agentID, caller)

	cpRoot, err := sdk.ParseDigest(checkpointRootHex)
	if err != nil {
		panic("checkpointRootHex: " + err.Error())
	}
	prevRoot, err := sdk.ParseDigest(prevRootHex)
	if err != nil {
		panic("prevRootHex: " + err.Error())
	}
	if prevRoot != pp.LastRoot {
		panic("prevRoot mismatch: expected " + sdk.Hex(pp.LastRoot) + ", got " + prevRootHex)
	}
	if leafCount == 0 || leafCount < pp.TotalLeaves {
		panic("leafCount must be positive and non-decreasing")
	}
	if receiptCount < pp.TotalReceipts || closureCount < pp.TotalClosures {
		panic("receiptCount and closureCount must be non-decreasing")
	}
	if leafCount == pp.TotalLeaves && cpRoot == pp.LastRoot {
		panic("checkpoint has no new evidence leaves since last anchor")
	}

	height := runtime.ChainHeight()
	minGap := MinBlocksBetween
	if pp.ProExpiresHeight > height {
		minGap = ProMinBlocksBetween
	}
	if pp.AnchorCount > 0 && height-pp.LastAnchorHeight < minGap {
		panic("rate limit: wait " + strconv.FormatInt(minGap, 10) + " blocks between anchors for " + agentID)
	}

	sent := sentUgnot()
	if sent != anchorFeeUgnot {
		panic("send exact anchor fee " + strconv.FormatInt(anchorFeeUgnot, 10) + denom +
			"; got " + strconv.FormatInt(sent, 10) + denom)
	}

	rec := sdk.AnchorRecord{
		ChainID:        runtime.ChainID(),
		Realm:          cur.PkgPath(),
		AnchorID:       anchorCount + 1,
		AgentID:        agentID,
		Caller:         caller.String(),
		Height:         height,
		PrevRoot:       prevRoot,
		CheckpointRoot: cpRoot,
		LeafCount:      leafCount,
		ReceiptCount:   receiptCount,
		ClosureCount:   closureCount,
	}

	leaf := rec.LeafHash()
	anchors.Set(anchorKey(rec.AnchorID), rec)
	anchorCount = rec.AnchorID
	globalAcc.Append(leaf)

	pp.LastAnchorID = rec.AnchorID
	pp.LastAnchorHeight = height
	pp.LastRoot = cpRoot
	pp.TotalLeaves = leafCount
	pp.TotalReceipts = receiptCount
	pp.TotalClosures = closureCount
	pp.AnchorCount++

	settleServiceFee(cur, sent)

	chain.Emit("ImmaculateAssuranceAnchor",
		"id", strconv.FormatUint(rec.AnchorID, 10),
		"agent_id", agentID,
		"checkpoint_root", checkpointRootHex,
		"leaf", sdk.Hex(leaf),
		"size", strconv.FormatUint(globalAcc.Size(), 10),
		"global_root", sdk.Hex(globalAcc.Root()),
		"height", strconv.FormatInt(height, 10),
		"service_fee_ugnot", strconv.FormatInt(sent, 10),
	)

	return rec.AnchorID
}

// RunDemoAction executes a live action through the built-in Immaculate SDK demo agent (zero service fee).
func RunDemoAction(cur realm, action, target, payload string, budgetUgnot int64) string {
	caller := cur.Previous().Address().String()
	height := runtime.ChainHeight()
	out, bundle, err := ensureDemoAgent().Execute(caller, action, target, []byte(payload), []byte("gno-live-demo"), budgetUgnot, height)
	if vErr := bundle.Verify(); vErr != nil {
		panic("internal evidence bundle verification failed: " + vErr.Error())
	}

	demoLastRoot = sdk.Hex(bundle.AccumulatorRoot)
	if err != nil {
		demoLastOut = ""
		demoLastErr = err.Error()
	} else {
		demoLastOut = string(out)
		demoLastErr = ""
	}

	chain.Emit("ImmaculateDemoEvidence",
		"agent_id", DemoAgentID,
		"action", action,
		"verdict", string(bundle.Decision.Verdict),
		"outcome", string(bundle.Closure.Outcome),
		"receipt_leaf", sdk.Hex(bundle.Receipt.LeafHash()),
		"closure_leaf", sdk.Hex(bundle.Closure.LeafHash()),
		"acc_root", demoLastRoot,
		"acc_size", strconv.FormatUint(bundle.AccumulatorSize, 10),
	)

	return string(bundle.Decision.Verdict) + "|" + string(bundle.Closure.Outcome) + "|" + demoLastRoot
}

// RunAdaptiveDemoAction stages a spherical coherence score (in fixed-point Scale=1_000_000)
// and executes through the Hampel-guarded CUSUM + Coherence + RiskGate demo agent.
func RunAdaptiveDemoAction(cur realm, action, target, payload string, budgetUgnot, coherenceScoreFixed int64) string {
	_ = ensureDemoAgent()
	if demoCoherence != nil {
		demoCoherence.StageScore(coherenceScoreFixed)
	}
	return RunDemoAction(cur, action, target, payload, budgetUgnot)
}

// ResetDemoCircuitBreaker resets a latched drift circuit breaker on the live demo agent.
func ResetDemoCircuitBreaker(cur realm) {
	_ = ensureDemoAgent()
	if demoDriftGuard != nil {
		demoDriftGuard.Reset()
	}
}

func demoFamiliarHandle(w sdk.EffectWarrant, input []byte) ([]byte, []byte, int64, error) {
	return []byte("familiar:" + w.Action + ":" + string(input)), []byte("warrant:" + strconv.FormatUint(w.ID, 10)), w.MaxSpendUgnot, nil
}

func ensureDemoFamiliar() *sdk.Familiar {
	if demoFamiliar != nil {
		return demoFamiliar
	}
	b := sdk.NewAgentBuilder("immaculate-demo-familiar").
		WithChain(runtime.ChainID(), "gno.land/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2").
		WithPrincipal("g1familiar0000000000000000000000000000000").
		AllowActions("rebalance", "recall_brief").
		AllowTargets("pool:gnot-usdc", "workspace:main").
		WithBudgetCap(5000).
		WithCoherenceGuard(650000, false, false, false).
		WithTool(sdk.ToolSpec{Name: "rebalance", RiskTier: sdk.RiskLow, MaxBudgetUgnot: 5000}, demoFamiliarHandle).
		WithTool(sdk.ToolSpec{Name: "recall_brief", RiskTier: sdk.RiskLow, MaxBudgetUgnot: 1000}, demoFamiliarHandle)
	fam, err := b.BuildFamiliar(
		sdk.CapReadMemory|sdk.CapWriteMemory|sdk.CapInvokeTool|sdk.CapDelegate|sdk.CapSendWhisper,
		2000,
		50,
		100,
		0,
		999999999,
		600000,
		200000,
	)
	if err != nil {
		panic("failed to initialize demo familiar: " + err.Error())
	}
	_, _ = fam.Remember(sdk.MemoryKindEpisodic, []byte("pool gnot-usdc target ratio 50-50"), []int64{980000, 199000, 10000, 0}, signals.Scale, 1)
	_, _ = fam.Remember(sdk.MemoryKindSemantic, []byte("treasury policy cap 5000ugnot max slippage 50bps"), []int64{990000, 140000, 15000, 0}, signals.Scale, 2)
	demoFamiliar = fam
	return demoFamiliar
}

// RunFamiliarDemoMemory ingests a memory into the built-in Familiar's MemoryVault through
// the spherical poisoning firewall (pass negative xFixed to test adversarial quarantine!).
func RunFamiliarDemoMemory(cur realm, note string, xFixed, yFixed int64) string {
	fam := ensureDemoFamiliar()
	rec, err := fam.Remember(sdk.MemoryKindEpisodic, []byte(note), []int64{xFixed, yFixed, 10000, 0}, signals.Scale, runtime.ChainHeight())
	if err != nil {
		panic(err.Error())
	}
	chain.Emit("ImmaculateFamiliarMemory",
		"familiar_id", fam.ID,
		"record_id", strconv.FormatUint(rec.RecordID, 10),
		"reason", rec.ReasonCode,
		"admitted", strconv.FormatBool(rec.Admitted),
		"quarantined", strconv.FormatBool(rec.Quarantined),
	)
	return rec.ReasonCode + "|" + strconv.FormatUint(rec.RecordID, 10) + "|" + strconv.Itoa(fam.Memory.QuarantinedCount())
}

// RunFamiliarDemoAction executes a memory-grounded, capability-checked action on the built-in Familiar.
func RunFamiliarDemoAction(cur realm, action, target, queryText string, budgetUgnot int64) string {
	fam := ensureDemoFamiliar()
	caller := cur.Previous().Address().String()
	out, bundle, proof, err := fam.ExecuteWithCapability(
		sdk.CapReadMemory,
		caller,
		action,
		target,
		[]byte(queryText),
		[]int64{985000, 170000, 12000, 0},
		queryText,
		2,
		budgetUgnot,
		runtime.ChainHeight(),
	)
	if err != nil {
		demoFamiliarLastOut = ""
		demoFamiliarLastErr = err.Error()
		return "DENY|" + err.Error()
	}
	if vErr := bundle.Verify(); vErr != nil {
		panic("familiar evidence verify failed: " + vErr.Error())
	}
	demoFamiliarLastOut = string(out)
	demoFamiliarLastErr = ""
	demoFamiliarLastRoot = sdk.Hex(bundle.AccumulatorRoot)
	chain.Emit("ImmaculateFamiliarAction",
		"familiar_id", fam.ID,
		"action", action,
		"recall_digest", sdk.Hex(proof.Digest()),
		"acc_root", demoFamiliarLastRoot,
		"trust_lb_fixed", strconv.FormatInt(fam.Trust.LowerBoundFixed(), 10),
	)
	return "ALLOW|" + sdk.Hex(proof.Digest())[:16] + "|" + demoFamiliarLastRoot
}

// ── Public Read & Proof Queries ──────────────────────────────────────────────

func Size() uint64     { return globalAcc.Size() }
func Root() string     { return sdk.Hex(globalAcc.Root()) }
func DemoRoot() string { return sdk.Hex(ensureDemoAgent().Checkpoint().CheckpointRoot) }

func ProofFor(anchorID, treeSize uint64) string {
	if anchorID == 0 || anchorID > anchorCount {
		panic("no anchor " + strconv.FormatUint(anchorID, 10))
	}
	proof, err := globalAcc.Proof(anchorID-1, treeSize)
	if err != nil {
		panic(err.Error())
	}
	parts := make([]string, len(proof))
	for i, h := range proof {
		parts[i] = sdk.Hex(h)
	}
	return strings.Join(parts, ",")
}

func VerifyCheckpointProof(anchorID, treeSize uint64, leafHex, proofCSV string) bool {
	if anchorID == 0 || anchorID > treeSize || treeSize > globalAcc.Size() {
		return false
	}
	leaf, err := sdk.ParseDigest(leafHex)
	if err != nil {
		return false
	}
	rootAt, err := globalAcc.RootAt(treeSize)
	if err != nil {
		return false
	}
	var proof [][32]byte
	if strings.TrimSpace(proofCSV) != "" {
		for _, tok := range strings.Split(proofCSV, ",") {
			d, err := sdk.ParseDigest(strings.TrimSpace(tok))
			if err != nil {
				return false
			}
			proof = append(proof, d)
		}
	}
	return sdk.VerifyInclusion(anchorID-1, treeSize, leaf, proof, rootAt)
}

func AnchorLeafHex(anchorID uint64) string {
	if anchorID == 0 || anchorID > anchorCount {
		panic("no anchor " + strconv.FormatUint(anchorID, 10))
	}
	return sdk.Hex(anchors.Get(anchorKey(anchorID)).(sdk.AnchorRecord).LeafHash())
}

// anchorKey is the anchor id in fixed-width decimal, so the tree's key order is id order.
func anchorKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	return strings.Repeat("0", 20-len(s)) + s
}

// ── Internal Helpers ─────────────────────────────────────────────────────────

func settleServiceFee(cur realm, amount int64) {
	if amount <= 0 {
		return
	}
	if settlementSink != "" {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(cur.Address(), settlementSink, chain.Coins{chain.NewCoin(denom, amount)})
		return
	}
	accruedServiceFees += amount
}

func mustOperator(cur realm) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("operator action requires a direct user call")
	}
	if operator == "" {
		panic("operator not initialized")
	}
	if prev.Address() != operator {
		panic("unauthorized: operator only")
	}
}

func mustOwnedActiveAgent(agentID string, caller address) *AgentPassport {
	pp, ok := passports.Get(agentID).(*AgentPassport)
	if !ok || pp == nil {
		panic("agent not registered: " + agentID)
	}
	if pp.Owner != caller {
		panic("only agent owner " + pp.Owner.String() + " may act for " + agentID)
	}
	if pp.Revoked {
		panic("agent passport is revoked: " + agentID)
	}
	return pp
}

func isValidAgentID(id string) bool {
	if len(id) < 3 || len(id) > 48 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

func sentUgnot() int64 {
	var total int64
	for _, c := range unsafe.OriginSend() {
		if c.Amount == 0 {
			continue
		}
		if c.Denom != denom || c.Amount < 0 {
			panic("only " + denom + " is accepted")
		}
		total += c.Amount
	}
	return total
}
