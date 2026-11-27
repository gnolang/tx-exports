package effects

import (
	"chain/runtime"
	"strconv"
	"strings"

	sdk "gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2"
)

// ── Reads ────────────────────────────────────────────────────────────────────

// EffectState is the effect's state as a reader sees it now: a start past its deadline reads IN_DOUBT whether or not
// anyone has sealed that yet.
func EffectState(effectID uint64) string {
	return string(effectiveState(mustEffect(effectID), runtime.ChainHeight()))
}

// EffectLive reports whether something may still be sent under this effect and attempt: it is STARTED, not fenced,
// and not past its deadline. A downstream that checks it before applying anything is fenced by FenceEffect.
func EffectLive(effectID uint64, attempt int) bool {
	e, ok := effects.Get(key(effectID)).(*effect)
	if !ok || e == nil {
		return false
	}
	return int(e.Spec.Attempt) == attempt && !e.Fenced && effectiveState(e, runtime.ChainHeight()) == sdk.EffectStarted
}

// VerifyEffect re-checks the effect's whole sealed life on chain with the SDK's verifier and returns its last sealed
// state, or why the life does not verify.
func VerifyEffect(effectID uint64) string {
	e := mustEffect(effectID)
	st, err := sdk.VerifyEffectLife(e.ID, e.Spec, lifeOf(e))
	if err != nil {
		return "INVALID: " + err.Error()
	}
	return string(st)
}

// EffectCount is how many effects were ever started, compensations included.
func EffectCount() uint64 { return effectCount }

// DemoValue reads one key of the demo state.
func DemoValue(k string) string { return demoGet(k) }

// DemoDigest is the digest a demo effect declares for these keys holding these values: what ApproveEffect needs as
// the postcondition of an IRREVERSIBLE demo effect.
func DemoDigest(keysCSV, valuesCSV string) string {
	keys := mustDemoKeys(keysCSV)
	return sdk.Hex(demoDigest(keys, mustDemoValues(valuesCSV, len(keys))))
}

// Size and Root are the evidence accumulator's: one leaf per sealed event, across all effects.
func Size() uint64 { return evidence.Size() }
func Root() string { return sdk.Hex(evidence.Root()) }

// ProofFor returns the RFC 6962 inclusion proof of the leaf at index in the tree of the given size, as comma-separated
// hex digests.
func ProofFor(index, treeSize uint64) string {
	proof, err := evidence.Proof(index, treeSize)
	if err != nil {
		panic(err.Error())
	}
	parts := make([]string, len(proof))
	for i, p := range proof {
		parts[i] = sdk.Hex(p)
	}
	return strings.Join(parts, ",")
}

// OpenEffects lists the obligations, newest first (at most 100): every effect that reads IN_DOUBT or PARTIAL, with
// its cleanup owner, its age in blocks and the receipts that landed.
func OpenEffects() string {
	now := runtime.ChainHeight()
	var b strings.Builder
	b.WriteString("[")
	n := 0
	active.ReverseIterate("", "", func(_ string, v any) bool {
		e := mustEffect(v.(uint64))
		st := effectiveState(e, now)
		if !st.Obligation() {
			return false
		}
		if n > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"id":` + strconv.FormatUint(e.ID, 10) +
			`,"agent":` + jsonString(e.Spec.AgentID) +
			`,"effect_key":` + jsonString(e.Spec.EffectKey) +
			`,"attempt":` + strconv.FormatUint(uint64(e.Spec.Attempt), 10) +
			`,"state":` + jsonString(string(st)) +
			`,"cleanup_owner":` + jsonString(e.Spec.CleanupOwner) +
			`,"age_blocks":` + strconv.FormatInt(now-e.StartHeight, 10) +
			`,"deadline_height":` + strconv.FormatInt(e.StartHeight+e.Spec.DeadlineBlocks, 10) +
			`,"receipts":` + strconv.FormatUint(uint64(e.Receipts), 10) +
			`,"steps":` + strconv.FormatUint(uint64(e.Spec.Steps), 10) +
			`,"fenced":` + strconv.FormatBool(e.Fenced) +
			`,"compensations":` + strconv.FormatUint(uint64(e.Compensations), 10) + `}`)
		n++
		return n >= openListLimit
	})
	b.WriteString("]")
	return b.String()
}

// EffectJSON is the effect's spec and every sealed event, with each event's leaf index: what the offline verifier
// (verifier/verify-effect.mjs) checks, with ProofFor and Root for inclusion.
func EffectJSON(effectID uint64) string {
	e := mustEffect(effectID)
	s := e.Spec
	var b strings.Builder
	b.WriteString(`{"id":` + strconv.FormatUint(e.ID, 10) +
		`,"realm":"gno.land/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/effects/v2"` +
		`,"spec":{"agent_id":` + jsonString(s.AgentID) +
		`,"effect_key":` + jsonString(s.EffectKey) +
		`,"idempotency_key":` + jsonString(s.IdempotencyKey) +
		`,"attempt":` + strconv.FormatUint(uint64(s.Attempt), 10) +
		`,"steps":` + strconv.FormatUint(uint64(s.Steps), 10) +
		`,"reversal":` + jsonString(string(s.Reversal)) +
		`,"inverse":` + jsonString(s.Inverse) +
		`,"read_back":` + jsonString(s.ReadBack) +
		`,"downstream_honours_live":` + strconv.FormatBool(s.DownstreamHonoursLive) +
		`,"pre_state":"` + sdk.Hex(s.PreState) + `"` +
		`,"postcondition":"` + sdk.Hex(s.Postcondition) + `"` +
		`,"deadline_blocks":` + strconv.FormatInt(s.DeadlineBlocks, 10) +
		`,"cleanup_owner":` + jsonString(s.CleanupOwner) +
		`,"approval_id":` + strconv.FormatUint(s.ApprovalID, 10) +
		`,"compensates":` + strconv.FormatUint(s.Compensates, 10) +
		`},"spec_digest":"` + sdk.Hex(s.Digest()) + `"` +
		`,"state":` + jsonString(string(e.State)) +
		`,"effective_state":` + jsonString(string(effectiveState(e, runtime.ChainHeight()))) +
		`,"compensation":` + strconv.FormatUint(e.Compensation, 10) +
		`,"holds_key":` + strconv.FormatBool(holdsKey(e)) +
		`,"events":[`)
	for seq := uint32(0); seq < e.Events; seq++ {
		se := events.Get(key(e.ID) + "/" + key(uint64(seq))).(sealedEvent)
		ev := se.Event
		if seq > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"seq":` + strconv.FormatUint(uint64(ev.Seq), 10) +
			`,"attempt":` + strconv.FormatUint(uint64(ev.Attempt), 10) +
			`,"kind":` + jsonString(string(ev.Kind)) +
			`,"state":` + jsonString(string(ev.State)) +
			`,"actor":` + jsonString(ev.Actor) +
			`,"height":` + strconv.FormatInt(ev.Height, 10) +
			`,"step_index":` + strconv.FormatUint(uint64(ev.StepIndex), 10) +
			`,"digest":"` + sdk.Hex(ev.Digest) + `"` +
			`,"observed_height":` + strconv.FormatInt(ev.ObservedHeight, 10) +
			`,"link":` + strconv.FormatUint(ev.Link, 10) +
			`,"prev_hash":"` + sdk.Hex(ev.PrevHash) + `"` +
			`,"leaf":"` + sdk.Hex(ev.LeafHash()) + `"` +
			`,"index":` + strconv.FormatUint(se.Index, 10) + `}`)
	}
	b.WriteString(`],"tree_size":` + strconv.FormatUint(evidence.Size(), 10) + `,"root":"` + sdk.Hex(evidence.Root()) + `"}`)
	return b.String()
}

func lifeOf(e *effect) []sdk.EffectEvent {
	out := make([]sdk.EffectEvent, 0, e.Events)
	for seq := uint32(0); seq < e.Events; seq++ {
		out = append(out, events.Get(key(e.ID)+"/"+key(uint64(seq))).(sealedEvent).Event)
	}
	return out
}

// jsonString quotes printable ASCII for JSON; every string the realm stores is checked to be printable ASCII, and
// anything else is escaped as a code point.
func jsonString(s string) string {
	var b strings.Builder
	b.WriteString(`"`)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteString(`\` + string(c))
		case c < 0x20 || c > 0x7e:
			h := strconv.FormatUint(uint64(c), 16)
			b.WriteString(`\u` + strings.Repeat("0", 4-len(h)) + h)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteString(`"`)
	return b.String()
}

// ── Render ───────────────────────────────────────────────────────────────────

func Render(path string) string {
	clean := strings.Trim(path, "/")
	if strings.HasPrefix(clean, "effect/") {
		id, err := strconv.ParseUint(strings.TrimPrefix(clean, "effect/"), 10, 64)
		if err != nil || !effects.Has(key(id)) {
			return "# Not found\n\nNo such effect.\n\n[Open obligations](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/effects/v2)"
		}
		return renderEffect(mustEffect(id))
	}
	return renderHome()
}

func renderHome() string {
	now := runtime.ChainHeight()
	var b strings.Builder
	b.WriteString("# Effects: detect, own and undo a partly-run action\n\n")
	b.WriteString("Every effect starts with a deadline, a cleanup owner and a reversal class. A start not closed by its " +
		"deadline height reads IN_DOUBT, and anyone may seal that with `MarkInDoubt`. A close is computed from a " +
		"read-back: COMMITTED when it shows the declared postcondition; ABORTED when it shows the pre-state after the " +
		"effect was fenced; IN_DOUBT when it shows the pre-state before any fence; PARTIAL otherwise.\n\n")
	b.WriteString("| Effects started | Sealed events | Evidence root |\n| ---: | ---: | --- |\n")
	b.WriteString("| " + strconv.FormatUint(effectCount, 10) + " | " + strconv.FormatUint(evidence.Size(), 10) + " | `" + sdk.Hex(evidence.Root()) + "` |\n\n")
	b.WriteString("## Open obligations\n\n")
	rows := 0
	active.ReverseIterate("", "", func(_ string, v any) bool {
		e := mustEffect(v.(uint64))
		st := effectiveState(e, now)
		if !st.Obligation() {
			return false
		}
		if rows == 0 {
			b.WriteString("| Effect | Agent | Key | State | Cleanup owner | Age (blocks) | Receipts |\n| --- | --- | --- | --- | --- | ---: | ---: |\n")
		}
		b.WriteString("| [" + strconv.FormatUint(e.ID, 10) + "](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/effects/v2:effect/" + strconv.FormatUint(e.ID, 10) + ") | " +
			e.Spec.AgentID + " | `" + e.Spec.EffectKey + "` | " + string(st) + " | `" + e.Spec.CleanupOwner + "` | " +
			strconv.FormatInt(now-e.StartHeight, 10) + " | " + strconv.FormatUint(uint64(e.Receipts), 10) + " of " +
			strconv.FormatUint(uint64(e.Spec.Steps), 10) + " |\n")
		rows++
		return rows >= 20
	})
	if rows == 0 {
		b.WriteString("_None: every effect is running within its deadline or closed._\n")
	}
	return b.String()
}

func renderEffect(e *effect) string {
	now := runtime.ChainHeight()
	s := e.Spec
	var b strings.Builder
	b.WriteString("# Effect " + strconv.FormatUint(e.ID, 10) + ": " + string(effectiveState(e, now)) + "\n\n")
	b.WriteString("- **Agent:** " + s.AgentID + ", attempt " + strconv.FormatUint(uint64(s.Attempt), 10) + "\n")
	b.WriteString("- **Key:** `" + s.EffectKey + "`, idempotency key `" + s.IdempotencyKey + "`\n")
	b.WriteString("- **Reversal:** " + string(s.Reversal))
	if s.Inverse != "" {
		b.WriteString(" (" + s.Inverse + ")")
	}
	b.WriteString("\n- **Read back by:** " + s.ReadBack + "\n")
	b.WriteString("- **Deadline height:** " + strconv.FormatInt(e.StartHeight+s.DeadlineBlocks, 10) + "\n")
	b.WriteString("- **Cleanup owner:** `" + s.CleanupOwner + "`\n")
	if s.Compensates != 0 {
		b.WriteString("- **Undoes:** [effect " + strconv.FormatUint(s.Compensates, 10) + "](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/effects/v2:effect/" + strconv.FormatUint(s.Compensates, 10) + ")\n")
	}
	if e.Compensation != 0 {
		b.WriteString("- **Latest compensation:** [effect " + strconv.FormatUint(e.Compensation, 10) + "](/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/effects/v2:effect/" + strconv.FormatUint(e.Compensation, 10) + ")\n")
	}
	b.WriteString("- **Verifies:** " + VerifyEffect(e.ID) + "\n\n")
	b.WriteString("| Seq | Event | State | Height | Actor |\n| ---: | --- | --- | ---: | --- |\n")
	for _, ev := range lifeOf(e) {
		label := string(ev.Kind)
		if ev.Kind == sdk.EventStep {
			label += " " + strconv.FormatUint(uint64(ev.StepIndex), 10)
		}
		if ev.Link != 0 {
			label += " (effect " + strconv.FormatUint(ev.Link, 10) + ")"
		}
		b.WriteString("| " + strconv.FormatUint(uint64(ev.Seq), 10) + " | " + label + " | " + string(ev.State) + " | " +
			strconv.FormatInt(ev.Height, 10) + " | `" + ev.Actor + "` |\n")
	}
	return b.String()
}
