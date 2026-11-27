package assurance

import (
	"chain/runtime"
	"strconv"
	"strings"

	sdk "gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2"
)

// Render serves the gnoweb explorer for the Arobi Assurance Agent SDK realm.
//
// Routes:
//   /                  Overview, global RFC 6962 root, agents, recent anchors
//   /agent/<agentID>   Agent passport, policy digest, chain tip, anchor history
//   /checkpoint/<id>   Anchored checkpoint details + RFC 6962 inclusion proof
//   /demo              Built-in live governed demo agent metrics & evidence log
func Render(path string) string {
	clean := strings.Trim(path, "/")
	if clean == "" {
		return renderHome()
	}
	if clean == "demo" {
		return renderDemo()
	}
	if clean == "familiar" {
		return renderFamiliar()
	}
	if clean == "benchmarks" {
		return renderBenchmarks()
	}
	if strings.HasPrefix(clean, "agent/") {
		return renderAgent(strings.TrimPrefix(clean, "agent/"))
	}
	if strings.HasPrefix(clean, "checkpoint/") {
		return renderCheckpoint(strings.TrimPrefix(clean, "checkpoint/"))
	}
	return "# Not Found\n\nUnknown path: `" + clean + "`\n\n[Back to Arobi Assurance Hub](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2)"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Arobi Assurance Agent SDK — Evidence Anchor\n\n")
	b.WriteString("Out-of-the-box governed agent framework, built on Gno.land: every agent action passes through a fail-closed ")
	b.WriteString("`PolicyEngine`, mints a single-use `EffectWarrant`, emits a hash-chained `DecisionReceipt` + ")
	b.WriteString("`EffectClosure`, and anchors RFC 6962 Merkle roots directly on Gno.land.\n\n")

	b.WriteString("| Metric | Value |\n| --- | --- |\n")
	b.WriteString("| Registered Agents | " + strconv.FormatUint(agentCount, 10) + " |\n")
	b.WriteString("| Anchored Checkpoints | " + strconv.FormatUint(globalAcc.Size(), 10) + " |\n")
	b.WriteString("| Global RFC 6962 Root | `" + sdk.Hex(globalAcc.Root()) + "` |\n")
	b.WriteString("| Checkpoint Anchor Service Fee | `" + strconv.FormatInt(anchorFeeUgnot, 10) + "ugnot` per checkpoint |\n")
	b.WriteString("| Pro Agent Plan (30 days) | `" + strconv.FormatInt(agentPlanPriceUgnot, 10) + "ugnot` (1-block anchor cadence) |\n")
	b.WriteString("| Built-In Demo Agent | [Inspect Live Demo Evidence](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2:demo) |\n")
	b.WriteString("| Built-In Familiar & Governed Memory | [Inspect Familiar Vault & Capabilities](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2:familiar) |\n")
	b.WriteString("| Scientific Benchmarks | [Measured Evaluation (E1–E4)](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2:benchmarks) |\n\n")

	b.WriteString("## Registered Agent Passports\n\n")
	if agentCount == 0 {
		b.WriteString("_No external agents registered yet. Call `RegisterAgent` to mint a passport._\n\n")
	} else {
		b.WriteString("| Agent ID | Display Name | Status | Anchors | Total Leaves | Tip Root |\n")
		b.WriteString("| --- | --- | --- | ---: | ---: | --- |\n")
		// The latest 20, newest first: a page stays the same size however many agents exist.
		var ids []string
		agentSeq.ReverseIterate("", "", func(_ string, v any) bool {
			ids = append(ids, v.(string))
			return len(ids) >= 20
		})
		for _, id := range ids {
			pp, ok := passports.Get(id).(*AgentPassport)
			if !ok || pp == nil {
				continue
			}
			status := "ACTIVE"
			if pp.Revoked {
				status = "REVOKED"
			}
			tip := sdk.Hex(pp.LastRoot)[:16] + "..."
			b.WriteString("| [" + pp.AgentID + "](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2:agent/" + pp.AgentID + ") | " +
				pp.DisplayName + " | " + status + " | " +
				strconv.FormatUint(pp.AnchorCount, 10) + " | " +
				strconv.FormatUint(pp.TotalLeaves, 10) + " | `" + tip + "` |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## Recent Anchored Checkpoints\n\n")
	if anchorCount == 0 {
		b.WriteString("_No checkpoints anchored yet._\n")
	} else {
		var recent []sdk.AnchorRecord
		anchors.ReverseIterate("", "", func(_ string, v any) bool {
			recent = append(recent, v.(sdk.AnchorRecord))
			return len(recent) >= 20
		})
		for _, a := range recent {
			idStr := strconv.FormatUint(a.AnchorID, 10)
			b.WriteString("- [Checkpoint #" + idStr + "](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2:checkpoint/" + idStr + ") — agent `" +
				a.AgentID + "`, leaves `" + strconv.FormatUint(a.LeafCount, 10) +
				"`, root `" + sdk.Hex(a.CheckpointRoot)[:16] + "...`, height `" +
				strconv.FormatInt(a.Height, 10) + "`\n")
		}
	}
	return b.String()
}

func renderAgent(agentID string) string {
	pp, ok := passports.Get(agentID).(*AgentPassport)
	if !ok || pp == nil {
		return "# Agent Not Found\n\nNo passport for `" + agentID + "`.\n\n[Back](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2)"
	}
	status := "ACTIVE"
	if pp.Revoked {
		status = "REVOKED"
	}
	var b strings.Builder
	b.WriteString("# Agent Passport: `" + pp.AgentID + "`\n\n")
	b.WriteString("- **Display Name:** " + pp.DisplayName + "\n")
	b.WriteString("- **Owner:** `" + pp.Owner.String() + "`\n")
	b.WriteString("- **Status:** `" + status + "`\n")
	b.WriteString("- **Policy Digest:** `" + sdk.Hex(pp.PolicyDigest) + "`\n")
	if pp.MetadataURI != "" {
		b.WriteString("- **Metadata URI:** " + pp.MetadataURI + "\n")
	}
	b.WriteString("- **Registered Height:** `" + strconv.FormatInt(pp.RegisteredHeight, 10) + "`\n")
	b.WriteString("- **Anchors:** `" + strconv.FormatUint(pp.AnchorCount, 10) + "` | **Leaves:** `" +
		strconv.FormatUint(pp.TotalLeaves, 10) + "` | **Receipts:** `" +
		strconv.FormatUint(pp.TotalReceipts, 10) + "` | **Closures:** `" +
		strconv.FormatUint(pp.TotalClosures, 10) + "`\n")
	b.WriteString("- **Latest Root:** `" + sdk.Hex(pp.LastRoot) + "`\n\n")
	b.WriteString("[Back to Hub](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2)\n")
	return b.String()
}

func renderCheckpoint(idStr string) string {
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil || id == 0 || id > anchorCount {
		return "# Checkpoint Not Found\n\nInvalid checkpoint id `" + idStr + "`.\n\n[Back](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2)"
	}
	a := anchors.Get(anchorKey(id)).(sdk.AnchorRecord)
	size := globalAcc.Size()
	proofCSV := ProofFor(id, size)
	var b strings.Builder
	b.WriteString("# Anchored Checkpoint #" + idStr + "\n\n")
	b.WriteString("- **Agent:** [" + a.AgentID + "](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2:agent/" + a.AgentID + ")\n")
	b.WriteString("- **Caller:** `" + a.Caller + "`\n")
	b.WriteString("- **Block Height:** `" + strconv.FormatInt(a.Height, 10) + "`\n")
	b.WriteString("- **Prev Root:** `" + sdk.Hex(a.PrevRoot) + "`\n")
	b.WriteString("- **Checkpoint Root:** `" + sdk.Hex(a.CheckpointRoot) + "`\n")
	b.WriteString("- **Counters:** leaves `" + strconv.FormatUint(a.LeafCount, 10) +
		"`, receipts `" + strconv.FormatUint(a.ReceiptCount, 10) +
		"`, closures `" + strconv.FormatUint(a.ClosureCount, 10) + "`\n")
	b.WriteString("- **Anchor Leaf Hash:** `" + sdk.Hex(a.LeafHash()) + "`\n")
	b.WriteString("- **Global Tree Size:** `" + strconv.FormatUint(size, 10) + "`\n")
	b.WriteString("- **RFC 6962 Proof:** `" + proofCSV + "`\n\n")
	b.WriteString("[Back to Hub](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2)\n")
	return b.String()
}

func renderDemo() string {
	ag := ensureDemoAgent()
	cp := ag.Checkpoint()
	m := ag.Metrics(runtime.ChainHeight(), 0)
	var b strings.Builder
	b.WriteString("# Built-In Governed Demo Agent (`" + DemoAgentID + "`)\n\n")
	b.WriteString("Call `RunDemoAction(action, target, payload, budgetUgnot)` with `summarize` (LOW), `attest` (MEDIUM), ")
	b.WriteString("`escrow_transfer` (HIGH -> REQUIRE_APPROVAL), or `wipe_state` (CRITICAL -> ESCALATE).\n\n")
	b.WriteString("- **Policy Digest:** `" + sdk.Hex(ag.PolicyDigest()) + "`\n")
	b.WriteString("- **Accumulator Root:** `" + sdk.Hex(cp.CheckpointRoot) + "`\n")
	b.WriteString("- **Leaves:** `" + strconv.FormatUint(cp.LeafCount, 10) + "` (`" +
		strconv.FormatUint(cp.ReceiptCount, 10) + "` receipts, `" +
		strconv.FormatUint(cp.ClosureCount, 10) + "` closures)\n")
	if m.Measured {
		b.WriteString("- **Measured Assurance:** Governance `" + strconv.FormatUint(m.GovernanceBps, 10) +
			" bps`, Closure Integrity `" + strconv.FormatUint(m.ClosureIntegrityBps, 10) +
			" bps`, Refusal Integrity `" + strconv.FormatUint(m.RefusalIntegrityBps, 10) + " bps`\n")
	} else {
		b.WriteString("- **Measured Assurance:** `UNMEASURED` (requires at least `" +
			strconv.FormatUint(sdk.MinSamplesForMeasuredScore, 10) + "` decisions)\n")
	}
	if demoDriftGuard != nil {
		b.WriteString("- **Hampel-Guarded CUSUM Drift Breaker:** latched `" + strconv.FormatBool(demoDriftGuard.Latched()) +
			"`, stat `" + strconv.FormatInt(demoDriftGuard.Statistic(), 10) +
			"`, alarms `" + strconv.FormatUint(demoDriftGuard.AlarmCount(), 10) + "`\n")
	}
	if demoCoherence != nil {
		b.WriteString("- **Spherical Coherence Gate Threshold:** `" + strconv.FormatInt(demoCoherence.ThresholdFixed, 10) + "` (micro-units)\n")
	}
	if demoLastOut != "" {
		b.WriteString("- **Last Output:** `" + demoLastOut + "`\n")
	}
	if demoLastErr != "" {
		b.WriteString("- **Last Refusal/Error:** `" + demoLastErr + "`\n")
	}
	b.WriteString("\n[Back to Hub](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2)\n")
	return b.String()
}

func renderBenchmarks() string {
	var b strings.Builder
	b.WriteString("# Measured Scientific Benchmarks (Experiments E1–E5, Seed `20261123`)\n\n")
	b.WriteString("Pre-registered evaluation comparing deterministic fixed-point Gno primitives (`gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/signals/v2`) ")
	b.WriteString("and full Arobi Assurance governance (`ImmaculateFull`, `ImmaculateMemoryVault`, `GeometricMedianFixed`) against static and naive baselines.\n\n")
	b.WriteString("| Architecture | +10σ Spike FPR | Stealth +2σ Drift TPR | Median Delay | Memory Poison Block | Escalation Block | RFC 6962 Verified |\n")
	b.WriteString("| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n")
	b.WriteString("| StaticCapOnly | 0% | 0% | N/A | 0% | 33% | 0% |\n")
	b.WriteString("| NaiveEMA | 91% | 100% | 7 steps | 0% | 33% | 0% |\n")
	b.WriteString("| RawCUSUM | 100% | 100% | 2 steps | 0% | 33% | 0% |\n")
	b.WriteString("| **ImmaculateFull (HampelCusum + Coherence + Warrants)** | **4%** | **100%** | **3 steps** | **100%** | **100%** | **100%** |\n\n")
	b.WriteString("- **Fixed-Point Fidelity (E1):** MAE `1.9e-6 .. 7.2e-6` vs float64; `0` permutation diffs; `5/5` bit-exact Gno v1.8.0 ↔ JS RFC 6962 parity.\n")
	b.WriteString("- **Real Gno v1.8.0 VM Gas (E3):** `2,659,102` gas per governed action (`4,971,378` gas adaptive; `14,418,924` gas Familiar + 8-record MemoryVault + Hybrid RRF); `<= 8` proof hashes at `250` leaves.\n")
	b.WriteString("- **Governed Familiar MemoryVault (E4, 500 episodes):** Overlap-Weighted Hybrid RRF (`k=60`) + Spherical Quarantine hits **`100%` Top-1 exact-target recall** with **`0%` Top-3 poison contamination** (vs `7.6%` dense-only and `100%` lexical poison).\n")
	b.WriteString("- **External Cross-Reference (E5):** Fixed-Point L1 Geometric Median (`GeometricMedianFixed`, 50% breakdown point) hits **`0.9299` ROC-AUC** under 35% coordinated poison vs `0.8640` arithmetic centroid; raw 3rd-order jerk (`n=3`) rejected (`2.5%` runaway TPR vs `99%` `HampelCusum`).\n\n")
	b.WriteString("[Inspect Live Demo](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2:demo) · [Inspect Familiar](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2:familiar) · [Back to Hub](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2)\n")
	return b.String()
}

func renderFamiliar() string {
	fam := ensureDemoFamiliar()
	cp := fam.Agent.Checkpoint()
	var b strings.Builder
	b.WriteString("# Immaculate Familiar & Poison-Resistant MemoryVault (`" + fam.ID + "`)\n\n")
	b.WriteString("Call `RunFamiliarDemoMemory(note, xFixed, yFixed)` to test spherical poisoning quarantine (e.g., `-950000, 300000` is quarantined) ")
	b.WriteString("and `RunFamiliarDemoAction(action, target, queryText, budgetUgnot)` to execute a Hybrid RRF memory-grounded, capability-leased action.\n\n")
	b.WriteString("- **Active Trusted Memories:** `" + strconv.Itoa(fam.Memory.ActiveCount()) + "` | **Quarantined Injections:** `" + strconv.Itoa(fam.Memory.QuarantinedCount()) + "`\n")
	b.WriteString("- **Memory Vault Root:** `" + sdk.Hex(fam.Memory.RootHash()) + "`\n")
	b.WriteString("- **Capability Token Digest:** `" + sdk.Hex(fam.Capability.Digest()) + "` (Max Spend `" + strconv.FormatInt(fam.Capability.MaxSpendUgnot, 10) + "ugnot`)\n")
	b.WriteString("- **Wilson 95% Trust Lower Bound:** `" + strconv.FormatInt(fam.Trust.LowerBoundFixed(), 10) + "` / `1000000` (`" +
		strconv.FormatUint(fam.Trust.Successes, 10) + "` successes, `" + strconv.FormatUint(fam.Trust.Violations, 10) + "` violations)\n")
	b.WriteString("- **Evidence Accumulator Root:** `" + sdk.Hex(cp.CheckpointRoot) + "` (`" + strconv.FormatUint(cp.LeafCount, 10) + "` leaves)\n")
	if demoFamiliarLastOut != "" {
		b.WriteString("- **Last Action Output:** `" + demoFamiliarLastOut + "`\n")
	}
	if demoFamiliarLastErr != "" {
		b.WriteString("- **Last Refusal:** `" + demoFamiliarLastErr + "`\n")
	}
	b.WriteString("\n[Back to Hub](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2)\n")
	return b.String()
}
