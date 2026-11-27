// Package effects gives an agent's actions a life on gno.land, so an action that stops part way is detected, owned
// and undone. An effect starts with a deadline, a cleanup owner and a reversal class; each step leaves a receipt;
// its close is computed from a read-back; and a start that is not closed by its deadline height is IN_DOUBT, which
// anyone may seal. Open obligations are listed with their cleanup owner. Every event is a leaf of one RFC 6962
// accumulator, and each effect's events form a hash chain that VerifyEffect re-checks on chain and the offline
// verifier re-checks from EffectJSON.
//
// Two kinds of effect:
//   - a demo effect acts on a small state held in this realm, so the realm reads the pre-state and the read-back
//     itself and every close is computed from state it can see;
//   - an external effect acts outside the chain. The agent reports digests, and the realm can only compare them with
//     the digests the start declared; it cannot see that downstream, and a fence binds only what honours it (the
//     downstream checks EffectLive before it applies anything).
//
// Only the agent's owner (its passport in gno.land/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2) starts its effects. An IRREVERSIBLE effect needs
// a recorded approval, as a separate call, from the agent's approver: an account the owner names that is not the owner
// itself, so the key that runs an effect never approves it. MarkInDoubt is open to anyone and changes nothing but the
// effect's state: it moves no value.
package effects

import (
	"chain"
	"chain/runtime"
	"encoding/binary"
	"strconv"
	"strings"

	sdk "gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2"
)

const (
	demoStateDomain = "arobi-effects-demo-state-v1"
	demoStepDomain  = "arobi-effects-demo-step-v1"
	maxDemoKeys     = 8
	maxDemoKeyLen   = 48
	maxDemoValueLen = 64
	openListLimit   = 100
)

type effect struct {
	ID            uint64
	Spec          sdk.EffectSpec
	Executor      address
	StartHeight   int64
	State         sdk.EffectState
	Receipts      uint32
	Events        uint32
	LastHash      [32]byte
	Fenced        bool
	FenceSeq      uint32
	FenceHeight   int64
	Compensation  uint64 // the latest compensation started for this effect
	Compensations uint32
	Released      bool // the approver freed the key this effect kept holding (ReleaseKey)
	DemoKeys      []string // demo effects: the keys the steps write, in step order
	DemoValues    []string // what the start declared the steps write
	DemoPrior     []string // the values before the start: what a compensation restores
}

type approval struct {
	ID            uint64
	AgentID       string
	EffectKey     string
	Postcondition [32]byte
	Approver      address
	Epoch         uint64 // the agent's approver epoch when it was given: SetApprover moves to the next one
	Height        int64
	Used          bool
}

type sealedEvent struct {
	Event sdk.EffectEvent
	Index uint64 // the event's leaf index in the evidence accumulator
}

var (
	effects       = avl.NewTree() // key(id) -> *effect
	effectCount   uint64
	events        = avl.NewTree() // key(id) + "/" + key(seq) -> sealedEvent
	holders       = avl.NewTree() // pair(agentID, effectKey) -> id of the effect that holds the key
	attempts      = avl.NewTree() // pair(agentID, idempotencyKey) -> id of the latest attempt
	active        = avl.NewTree() // key(id) -> id, for effects that are not closed
	approvals     = avl.NewTree() // key(id) -> *approval
	approvalCount uint64
	approvers     = avl.NewTree() // agentID -> address that approves (never the owner who runs the effects)
	epochs        = avl.NewTree() // agentID -> approver epoch; every SetApprover starts a new one
	paused        = avl.NewTree() // agentID -> true while the owner has paused the agent's effects
	evidence      sdk.LedgerAccumulator
	demoState     = avl.NewTree() // demo key -> value
)

// ── Approvals and pauses ─────────────────────────────────────────────────────

// SetApprover names the account that approves the agent's IRREVERSIBLE effects, the undo of its effects that may still
// land, and the release of the keys those keep. The agent's owner sets it, and it must be another account: the key that
// runs an effect never approves it. Every call starts a new approver epoch, which voids every unused approval given
// before it, even when the same account is named again.
func SetApprover(cur realm, agentID string, approver address) {
	owner := mustOwner(cur, agentID)
	if !approver.IsValid() || approver == owner {
		panic("the approver must be a valid account other than the agent's owner")
	}
	approvers.Set(agentID, approver)
	epochs.Set(agentID, approverEpoch(agentID)+1)
	chain.Emit("ImmaculateEffectApproverSet", "agent_id", agentID, "approver", approver.String(),
		"epoch", strconv.FormatUint(approverEpoch(agentID), 10))
}

func approverEpoch(agentID string) uint64 {
	if e, ok := epochs.Get(agentID).(uint64); ok {
		return e
	}
	return 0
}

// ReleaseKey frees the key that an ACCEPTED or COMPENSATED effect whose downstream does not honour EffectLive kept
// holding. Only the agent's approver may release it, and only against receiptHex: the digest of the downstream's own
// record that the attempt was refused or expired unused. The RELEASE is sealed in the effect's life.
func ReleaseKey(cur realm, effectID uint64, receiptHex string) {
	e := mustEffect(effectID)
	caller := mustUser(cur)
	receipt := mustDigest("receiptHex", receiptHex)
	approver, ok := approvers.Get(e.Spec.AgentID).(address)
	holderID, held := holders.Get(pair(e.Spec.AgentID, e.Spec.EffectKey)).(uint64)
	switch {
	case !ok || caller != approver:
		panic("only agent " + e.Spec.AgentID + "'s approver releases a key")
	case caller == e.Executor:
		panic("the executor does not release its own effect's key")
	case !holdsKey(e) || !held || holderID != e.ID:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " holds no key to release")
	case receipt == sdk.ZeroDigest():
		panic("a release needs the downstream's record that the attempt will not land")
	}
	e.Released = true
	seal(e, sdk.EventRelease, e.State, caller, 0, receipt, 0, 0)
}

// ApproveEffect records the approver's approval of one effect of the agent: on this key, with this postcondition,
// used once, by a start (IRREVERSIBLE) or a compensation (of an effect that may still land) that is a separate call.
func ApproveEffect(cur realm, agentID, effectKey, postconditionHex string) uint64 {
	caller := mustUser(cur)
	if approver, ok := approvers.Get(agentID).(address); !ok || approver != caller {
		panic("only agent " + agentID + "'s approver (SetApprover) approves its effects")
	}
	mustKey("effectKey", effectKey)
	post := mustDigest("postconditionHex", postconditionHex)
	approvalCount++
	approvals.Set(key(approvalCount), &approval{
		ID: approvalCount, AgentID: agentID, EffectKey: effectKey, Postcondition: post, Approver: caller,
		Epoch: approverEpoch(agentID), Height: runtime.ChainHeight(),
	})
	chain.Emit("ImmaculateEffectApproved", "approval_id", strconv.FormatUint(approvalCount, 10), "agent_id", agentID, "effect_key", effectKey)
	return approvalCount
}

// useApproval consumes an approval for exactly this agent, key and postcondition, given by the agent's current
// approver, who is not the executor. It returns the approval's digest, which the sealed event carries.
func useApproval(id uint64, agentID, effectKey string, postcondition [32]byte, executor address) [32]byte {
	a := mustApproval(id)
	approver, ok := approvers.Get(agentID).(address)
	switch {
	case a.Used:
		panic("approval " + strconv.FormatUint(a.ID, 10) + " is used")
	case a.AgentID != agentID || a.EffectKey != effectKey || a.Postcondition != postcondition:
		panic("approval " + strconv.FormatUint(a.ID, 10) + " was given for another agent, key or postcondition")
	case !ok || a.Approver != approver || a.Epoch != approverEpoch(agentID):
		panic("approval " + strconv.FormatUint(a.ID, 10) + " is not from agent " + agentID + "'s current approver")
	case a.Approver == executor:
		panic("approval " + strconv.FormatUint(a.ID, 10) + " is from the executor itself")
	}
	a.Used = true
	out := lenPrefixed(nil, "arobi-effects-approval-v1")
	out = binary.BigEndian.AppendUint64(out, a.ID)
	out = lenPrefixed(out, a.AgentID)
	out = lenPrefixed(out, a.EffectKey)
	out = append(out, a.Postcondition[:]...)
	out = lenPrefixed(out, a.Approver.String())
	out = binary.BigEndian.AppendUint64(out, a.Epoch)
	out = binary.BigEndian.AppendUint64(out, uint64(a.Height))
	return sdk.HashBytes(out)
}

// PauseEffects stops the agent's new starts, steps and compensations until ResumeEffects. Detection does not pause:
// MarkInDoubt still works, and so does a cleanup owner's acceptance.
func PauseEffects(cur realm, agentID string) {
	mustOwner(cur, agentID)
	paused.Set(agentID, true)
	chain.Emit("ImmaculateEffectsPaused", "agent_id", agentID)
}

// ResumeEffects lifts PauseEffects.
func ResumeEffects(cur realm, agentID string) {
	mustOwner(cur, agentID)
	paused.Remove(agentID)
	chain.Emit("ImmaculateEffectsResumed", "agent_id", agentID)
}

// ── Starting an effect ───────────────────────────────────────────────────────

// BeginEffect starts an external effect: one acting outside the chain, read back by the agent.
// downstreamHonoursLive declares that the downstream checks EffectLive in the same step that applies anything (or
// keeps its own record of the attempts it consumed). When it is false, nothing the realm records can prove "no
// effect": a pre-state read-back stays IN_DOUBT, ACCEPTED keeps the key held, and a compensation while the effect is
// IN_DOUBT or PARTIAL needs the owner's approval.
func BeginEffect(cur realm, agentID, effectKey, idempotencyKey string, attempt, steps int, reversal, inverse,
	preStateHex, postconditionHex string, downstreamHonoursLive bool, deadlineBlocks int64, cleanupOwner address, approvalID uint64,
) uint64 {
	executor := mustOwner(cur, agentID)
	spec := sdk.EffectSpec{
		AgentID: agentID, EffectKey: effectKey, IdempotencyKey: idempotencyKey, Attempt: mustCount("attempt", attempt),
		Steps: mustCount("steps", steps), Reversal: sdk.ReversalClass(reversal), Inverse: inverse, ReadBack: sdk.ReadBackAgent,
		DownstreamHonoursLive: downstreamHonoursLive,
		PreState:              mustDigest("preStateHex", preStateHex), Postcondition: mustDigest("postconditionHex", postconditionHex),
		DeadlineBlocks: deadlineBlocks, CleanupOwner: mustAddress("cleanupOwner", cleanupOwner), ApprovalID: approvalID,
	}
	return begin(spec, executor, nil, nil, nil)
}

// BeginDemoEffect starts a demo effect on this realm's demo state: step i writes the i-th of valuesCSV to the i-th of
// keysCSV. The realm reads the pre-state itself; the postcondition is those keys holding those values.
func BeginDemoEffect(cur realm, agentID, effectKey, idempotencyKey string, attempt int, reversal, inverse,
	keysCSV, valuesCSV string, deadlineBlocks int64, cleanupOwner address, approvalID uint64,
) uint64 {
	executor := mustOwner(cur, agentID)
	keys := mustDemoKeys(keysCSV)
	values := mustDemoValues(valuesCSV, len(keys))
	prior := demoRead(keys)
	spec := sdk.EffectSpec{
		AgentID: agentID, EffectKey: effectKey, IdempotencyKey: idempotencyKey, Attempt: mustCount("attempt", attempt),
		Steps: uint32(len(keys)), Reversal: sdk.ReversalClass(reversal), Inverse: inverse, ReadBack: sdk.ReadBackRealm,
		DownstreamHonoursLive: true, // the realm is the downstream, and it refuses every step after a fence or the deadline
		PreState:              demoDigest(keys, prior), Postcondition: demoDigest(keys, values),
		DeadlineBlocks: deadlineBlocks, CleanupOwner: mustAddress("cleanupOwner", cleanupOwner), ApprovalID: approvalID,
	}
	return begin(spec, executor, keys, values, prior)
}

func begin(spec sdk.EffectSpec, executor address, keys, values, prior []string) uint64 {
	mustKey("effectKey", spec.EffectKey)
	mustKey("idempotencyKey", spec.IdempotencyKey)
	for i := 0; i < len(spec.Inverse); i++ {
		if c := spec.Inverse[i]; c < 0x20 || c > 0x7e {
			panic("inverse must be printable ASCII")
		}
	}
	height := runtime.ChainHeight()
	ik := pair(spec.AgentID, spec.IdempotencyKey)
	if spec.Compensates == 0 {
		// A retry with the same idempotency key is never applied twice. It is answered before the new start is checked:
		// once a demo effect has committed, a retry reads the committed state as its pre-state, a start no one could
		// begin, and the answer is still the effect that ran.
		if prevID, ok := attempts.Get(ik).(uint64); ok {
			prev := mustEffect(prevID)
			st := effectiveState(prev, height)
			switch {
			case prev.Spec.EffectKey != spec.EffectKey:
				panic("idempotency key " + spec.IdempotencyKey + " belongs to effect key " + prev.Spec.EffectKey)
			case st == sdk.EffectCommitted || st == sdk.EffectAccepted:
				chain.Emit("ImmaculateEffectReplay", "effect_id", strconv.FormatUint(prev.ID, 10), "state", string(st))
				return prev.ID
			case !st.Closed():
				panic("idempotency key " + spec.IdempotencyKey + " has open effect " + strconv.FormatUint(prev.ID, 10) + " (" + string(st) + ")")
			case spec.Attempt != prev.Spec.Attempt+1:
				panic("this retry is attempt " + strconv.FormatUint(uint64(prev.Spec.Attempt+1), 10))
			}
		} else if spec.Attempt != 1 {
			panic("the first try is attempt 1")
		}
	}
	if err := spec.Validate(); err != nil {
		panic(err.Error())
	}
	if spec.Compensates == 0 && paused.Has(spec.AgentID) {
		panic("agent " + spec.AgentID + " has its effects paused")
	}
	// One effect at a time per key: a compensation may run while the effect it undoes holds the key. An ACCEPTED
	// effect that may still land keeps holding it.
	kk := pair(spec.AgentID, spec.EffectKey)
	if holderID, ok := holders.Get(kk).(uint64); ok {
		h := mustEffect(holderID)
		st := effectiveState(h, height)
		if h.ID != spec.Compensates && (!st.Closed() || holdsKey(h)) {
			why := string(st)
			if st.Closed() {
				why += ", and it may still land"
			}
			panic("effect key " + spec.EffectKey + " has open effect " + strconv.FormatUint(h.ID, 10) + " (" + why + ")")
		}
	}
	if spec.Reversal == sdk.ReversalIrreversible {
		useApproval(spec.ApprovalID, spec.AgentID, spec.EffectKey, spec.Postcondition, executor)
	}
	effectCount++
	e := &effect{
		ID: effectCount, Spec: spec, Executor: executor, StartHeight: height, State: sdk.EffectStarted,
		DemoKeys: keys, DemoValues: values, DemoPrior: prior,
	}
	effects.Set(key(e.ID), e)
	active.Set(key(e.ID), e.ID)
	if spec.Compensates == 0 {
		holders.Set(kk, e.ID)
		attempts.Set(ik, e.ID)
	} else if mustEffect(spec.Compensates).State.Closed() {
		holders.Set(kk, e.ID) // undoing a COMMITTED effect: the compensation holds the key while it runs
	}
	seal(e, sdk.EventStart, sdk.EffectStarted, executor, 0, spec.Digest(), 0, 0)
	return e.ID
}

// ── Running it ───────────────────────────────────────────────────────────────

// RecordStep seals an external effect's next step receipt (the executor, before the deadline and the fence).
func RecordStep(cur realm, effectID uint64, attempt, stepIndex int, receiptHex string) {
	e := mustEffect(effectID)
	if e.Spec.ReadBack != sdk.ReadBackAgent {
		panic("a demo effect records its steps with DemoStep")
	}
	actor := mustStepper(cur, e, attempt, stepIndex)
	step(e, actor, stepIndex, mustDigest("receiptHex", receiptHex))
}

// DemoStep runs a demo effect's next step: it writes value to the step's key and seals the receipt. The value need
// not be the one the start declared, as a faulty tool's need not be; the close reads back what was written.
func DemoStep(cur realm, effectID uint64, attempt, stepIndex int, value string) {
	e := mustEffect(effectID)
	if e.Spec.ReadBack != sdk.ReadBackRealm {
		panic("an external effect records its steps with RecordStep")
	}
	actor := mustStepper(cur, e, attempt, stepIndex)
	mustDemoValue(value)
	k := e.DemoKeys[stepIndex-1]
	old := demoGet(k)
	demoState.Set(k, value)
	step(e, actor, stepIndex, demoStepDigest(k, old, value))
}

func step(e *effect, actor address, stepIndex int, receipt [32]byte) {
	e.Receipts++
	seal(e, sdk.EventStep, sdk.EffectStarted, actor, uint32(stepIndex), receipt, 0, 0)
}

// FenceEffect seals that nothing more may be sent under the effect: from here on its steps are refused and
// EffectLive is false. The executor or the cleanup owner may fence; a read-back observed after the fence that shows
// the pre-state closes the effect as ABORTED.
func FenceEffect(cur realm, effectID uint64, attempt int) {
	e := mustEffect(effectID)
	actor := mustUser(cur)
	mustAttempt(e, attempt)
	st := effectiveState(e, runtime.ChainHeight())
	switch {
	case e.Fenced:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is already fenced")
	case st != sdk.EffectStarted && st != sdk.EffectInDoubt:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is " + string(st) + ": only an open effect is fenced")
	case actor != e.Executor && actor.String() != e.Spec.CleanupOwner:
		panic("only the effect's executor or cleanup owner fences it")
	}
	if e.State == sdk.EffectStarted && st == sdk.EffectInDoubt {
		seal(e, sdk.EventInDoubt, sdk.EffectInDoubt, actor, 0, sdk.ZeroDigest(), 0, 0)
	}
	e.Fenced, e.FenceSeq, e.FenceHeight = true, e.Events, runtime.ChainHeight()
	seal(e, sdk.EventFence, e.State, actor, 0, sdk.ZeroDigest(), 0, 0)
}

// CloseEffect closes an external effect from the agent's read-back: its digest and the height it was observed at.
func CloseEffect(cur realm, effectID uint64, attempt int, readBackHex string, observedHeight int64) string {
	e := mustEffect(effectID)
	if e.Spec.ReadBack != sdk.ReadBackAgent {
		panic("a demo effect closes with CloseDemoEffect: the realm reads it back itself")
	}
	return closeWith(cur, e, attempt, mustDigest("readBackHex", readBackHex), observedHeight)
}

// CloseDemoEffect closes a demo effect: the realm reads its keys back now.
func CloseDemoEffect(cur realm, effectID uint64, attempt int) string {
	e := mustEffect(effectID)
	if e.Spec.ReadBack != sdk.ReadBackRealm {
		panic("an external effect closes with CloseEffect")
	}
	return closeWith(cur, e, attempt, demoDigest(e.DemoKeys, demoRead(e.DemoKeys)), runtime.ChainHeight())
}

func closeWith(cur realm, e *effect, attempt int, readBack [32]byte, observed int64) string {
	actor := mustUser(cur)
	mustAttempt(e, attempt)
	height := runtime.ChainHeight()
	deadline := e.StartHeight + e.Spec.DeadlineBlocks
	st := effectiveState(e, height)
	switch {
	case st == sdk.EffectStarted && actor == e.Executor:
	case st == sdk.EffectInDoubt && actor.String() == e.Spec.CleanupOwner:
	default:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is " + string(st) +
			": its executor closes it before the deadline, its cleanup owner once it is IN_DOUBT")
	}
	fencedBefore := false
	if e.Spec.ReadBack == sdk.ReadBackRealm {
		fencedBefore = e.Fenced || height > deadline
	} else {
		if observed < e.lastStepHeight() || observed > height || height-observed > sdk.MaxReadBackAgeBlocks {
			panic("the read-back must be observed after the last step, not in the future, and at most " +
				strconv.FormatInt(sdk.MaxReadBackAgeBlocks, 10) + " blocks ago")
		}
		// A fence or the clock proves "nothing can still land" only to a downstream that honours EffectLive.
		fencedBefore = !e.Spec.Landable() && ((e.Fenced && observed > e.FenceHeight) || observed > deadline)
	}
	if readBack == sdk.ZeroDigest() {
		panic("a close needs a read-back digest")
	}
	if e.State == sdk.EffectStarted && st == sdk.EffectInDoubt {
		seal(e, sdk.EventInDoubt, sdk.EffectInDoubt, actor, 0, sdk.ZeroDigest(), 0, 0)
	}
	out := sdk.CloseOutcome(e.Spec, readBack, fencedBefore)
	seal(e, sdk.EventClose, out, actor, 0, readBack, observed, 0)
	if out == sdk.EffectCommitted && e.Spec.Compensates != 0 {
		orig := mustEffect(e.Spec.Compensates)
		if !orig.State.Terminal() {
			seal(orig, sdk.EventCompensated, sdk.EffectCompensated, actor, 0, readBack, 0, e.ID)
		}
	}
	return string(out)
}

// MarkInDoubt seals IN_DOUBT on an effect past its deadline height that was never closed. Anyone may call it; it
// changes the effect's state and nothing else.
func MarkInDoubt(cur realm, effectID uint64) string {
	e := mustEffect(effectID)
	if e.State != sdk.EffectStarted || runtime.ChainHeight() <= e.StartHeight+e.Spec.DeadlineBlocks {
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is " + string(effectiveState(e, runtime.ChainHeight())) + ", not a start past its deadline")
	}
	seal(e, sdk.EventInDoubt, sdk.EffectInDoubt, cur.Previous().Address(), 0, sdk.ZeroDigest(), 0, 0)
	return string(sdk.EffectInDoubt)
}

// ── Owning and undoing it (the cleanup owner) ────────────────────────────────

// Compensate starts the compensation of an external effect: an effect of its own, on the same key, whose
// postcondition is the original's pre-state. preStateHex is the downstream state now. When the original may still
// land (its downstream does not honour EffectLive) and is IN_DOUBT or PARTIAL, approvalID names the owner's
// ApproveEffect for this undo (the original's key, with the original's pre-state as the postcondition); otherwise 0.
func Compensate(cur realm, effectID uint64, steps int, preStateHex string, deadlineBlocks int64, approvalID uint64) uint64 {
	orig := mustEffect(effectID)
	if orig.Spec.ReadBack != sdk.ReadBackAgent {
		panic("a demo effect is compensated with CompensateDemo")
	}
	actor := mustCleanupOwner(cur, orig)
	return startCompensation(orig, actor, mustCount("steps", steps), mustDigest("preStateHex", preStateHex), deadlineBlocks, approvalID, nil, nil, nil)
}

// CompensateDemo starts the compensation of a demo effect: its steps write back the values the keys held before the
// original started.
func CompensateDemo(cur realm, effectID uint64, deadlineBlocks int64) uint64 {
	orig := mustEffect(effectID)
	if orig.Spec.ReadBack != sdk.ReadBackRealm {
		panic("an external effect is compensated with Compensate")
	}
	actor := mustCleanupOwner(cur, orig)
	now := demoRead(orig.DemoKeys)
	return startCompensation(orig, actor, uint32(len(orig.DemoKeys)), demoDigest(orig.DemoKeys, now), deadlineBlocks, 0,
		orig.DemoKeys, orig.DemoPrior, now)
}

func startCompensation(orig *effect, actor address, steps uint32, pre [32]byte, deadlineBlocks int64, approvalID uint64, keys, targets, prior []string) uint64 {
	height := runtime.ChainHeight()
	st := effectiveState(orig, height)
	owner, live := assurance.AgentOwner(orig.Spec.AgentID)
	switch {
	case !live || owner == "":
		panic("agent " + orig.Spec.AgentID + " is revoked: nothing is compensated under it")
	case paused.Has(orig.Spec.AgentID):
		panic("agent " + orig.Spec.AgentID + " has its effects paused: no compensation starts until it resumes")
	case orig.Spec.Reversal == sdk.ReversalIrreversible:
		panic("effect " + strconv.FormatUint(orig.ID, 10) + " is IRREVERSIBLE")
	case st != sdk.EffectPartial && st != sdk.EffectInDoubt && st != sdk.EffectCommitted:
		panic("effect " + strconv.FormatUint(orig.ID, 10) + " is " + string(st) + ": only a PARTIAL, IN_DOUBT or COMMITTED effect is compensated")
	case orig.Compensations >= sdk.MaxCompensations:
		panic("effect " + strconv.FormatUint(orig.ID, 10) + " has had " + strconv.FormatUint(uint64(sdk.MaxCompensations), 10) + " compensations")
	case pre == orig.Spec.PreState:
		panic("the downstream already holds effect " + strconv.FormatUint(orig.ID, 10) + "'s pre-state: fence it and close it instead")
	}
	if orig.Compensation != 0 {
		if c := mustEffect(orig.Compensation); !effectiveState(c, height).Closed() {
			panic("effect " + strconv.FormatUint(orig.ID, 10) + " already has compensation " + strconv.FormatUint(c.ID, 10) + " running")
		}
	}
	// Undoing an effect that may still land is a person's decision, never the clock's: it consumes the approver's
	// recorded approval for this key with the original's pre-state as the postcondition.
	approvalSeal := sdk.ZeroDigest()
	if orig.Spec.Landable() && st != sdk.EffectCommitted {
		if approvalID == 0 {
			panic("effect " + strconv.FormatUint(orig.ID, 10) + " may still land: compensating it now needs ApproveEffect from the agent's approver")
		}
		approvalSeal = useApproval(approvalID, orig.Spec.AgentID, orig.Spec.EffectKey, orig.Spec.PreState, orig.Executor)
	} else if approvalID != 0 {
		panic("this compensation needs no approval; pass 0")
	}
	if orig.State == sdk.EffectStarted && st == sdk.EffectInDoubt {
		seal(orig, sdk.EventInDoubt, sdk.EffectInDoubt, actor, 0, sdk.ZeroDigest(), 0, 0)
	}
	orig.Compensations++
	spec := sdk.EffectSpec{
		AgentID: orig.Spec.AgentID, EffectKey: orig.Spec.EffectKey,
		IdempotencyKey: "compensate-" + strconv.FormatUint(orig.ID, 10) + "-" + strconv.FormatUint(uint64(orig.Compensations), 10),
		Attempt:        1, Steps: steps, Reversal: sdk.ReversalCompensable, Inverse: "re-apply effect " + strconv.FormatUint(orig.ID, 10),
		ReadBack: orig.Spec.ReadBack, DownstreamHonoursLive: orig.Spec.DownstreamHonoursLive,
		PreState: pre, Postcondition: orig.Spec.PreState, DeadlineBlocks: deadlineBlocks,
		CleanupOwner: orig.Spec.CleanupOwner, ApprovalID: approvalID, Compensates: orig.ID,
	}
	comp := begin(spec, actor, keys, targets, prior)
	orig.Compensation = comp
	seal(orig, sdk.EventCompensate, orig.State, actor, 0, approvalSeal, 0, comp)
	return comp
}

// AcceptEffect closes a PARTIAL or IN_DOUBT effect as ACCEPTED: the cleanup owner takes what landed as final.
// reasonHex is the digest of the reason, kept off chain. An IN_DOUBT effect is fenced first (FenceEffect), so nothing
// more is accepted under it, and no effect is accepted while its compensation is running. An accepted effect whose
// downstream does not honour EffectLive keeps holding its key.
func AcceptEffect(cur realm, effectID uint64, reasonHex string) {
	e := mustEffect(effectID)
	actor := mustCleanupOwner(cur, e)
	reason := mustDigest("reasonHex", reasonHex)
	height := runtime.ChainHeight()
	st := effectiveState(e, height)
	switch {
	case st != sdk.EffectPartial && st != sdk.EffectInDoubt:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is " + string(st) + ": only a PARTIAL or IN_DOUBT effect is accepted")
	case st == sdk.EffectInDoubt && !e.Fenced:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is IN_DOUBT and not fenced: FenceEffect first")
	case e.Compensation != 0 && !effectiveState(mustEffect(e.Compensation), height).Closed():
		panic("effect " + strconv.FormatUint(e.ID, 10) + " has compensation " + strconv.FormatUint(e.Compensation, 10) + " running")
	}
	if e.State == sdk.EffectStarted && st == sdk.EffectInDoubt {
		seal(e, sdk.EventInDoubt, sdk.EffectInDoubt, actor, 0, sdk.ZeroDigest(), 0, 0)
	}
	seal(e, sdk.EventAccept, sdk.EffectAccepted, actor, 0, reason, 0, 0)
}

// ── Sealing ──────────────────────────────────────────────────────────────────

func seal(e *effect, kind sdk.EffectEventKind, state sdk.EffectState, actor address, stepIndex uint32, digest [32]byte, observed int64, link uint64) {
	ev := sdk.EffectEvent{
		EffectID: e.ID, Attempt: e.Spec.Attempt, Seq: e.Events, PrevHash: e.LastHash, Kind: kind, State: state,
		Actor: actor.String(), Height: runtime.ChainHeight(), StepIndex: stepIndex, Digest: digest, ObservedHeight: observed, Link: link,
	}
	leaf := ev.LeafHash()
	index := evidence.Append(leaf)
	events.Set(key(e.ID)+"/"+key(uint64(ev.Seq)), sealedEvent{Event: ev, Index: index})
	e.Events++
	e.LastHash = leaf
	e.State = state
	if state.Closed() {
		active.Remove(key(e.ID))
		kk := pair(e.Spec.AgentID, e.Spec.EffectKey)
		if holderID, ok := holders.Get(kk).(uint64); ok && holderID == e.ID && !holdsKey(e) {
			holders.Remove(kk)
		}
	}
	chain.Emit("ImmaculateEffect",
		"effect_id", strconv.FormatUint(e.ID, 10),
		"attempt", strconv.FormatUint(uint64(e.Spec.Attempt), 10),
		"seq", strconv.FormatUint(uint64(ev.Seq), 10),
		"kind", string(kind),
		"state", string(state),
		"leaf", sdk.Hex(leaf),
		"height", strconv.FormatInt(ev.Height, 10),
	)
}

// holdsKey reports whether a closed effect still holds its key: an ACCEPTED or COMPENSATED effect whose downstream does
// not honour EffectLive, until the approver releases it. A request sent under it may still land, and a new effect on
// the key would then apply twice; a person deciding the undo does not prove the old request is dead. (An effect undone
// after it COMMITTED had already landed: its compensation held the key while it ran, and frees it when it closes.)
func holdsKey(e *effect) bool {
	return (e.State == sdk.EffectAccepted || e.State == sdk.EffectCompensated) && e.Spec.Landable() && !e.Released
}

func (e *effect) lastStepHeight() int64 {
	h := e.StartHeight
	for seq := uint32(1); seq < e.Events; seq++ {
		if se, ok := events.Get(key(e.ID) + "/" + key(uint64(seq))).(sealedEvent); ok && se.Event.Kind == sdk.EventStep {
			h = se.Event.Height
		}
	}
	return h
}

// ── Checks ───────────────────────────────────────────────────────────────────

func mustUser(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("call this directly from a user account")
	}
	return prev.Address()
}

func mustOwner(cur realm, agentID string) address {
	caller := mustUser(cur)
	owner, live := assurance.AgentOwner(agentID)
	if !live {
		panic("agent " + agentID + " is not an active passport in gno.land/r/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2")
	}
	if owner != caller {
		panic("only agent " + agentID + "'s owner may do this")
	}
	return caller
}

func mustCleanupOwner(cur realm, e *effect) address {
	caller := mustUser(cur)
	if caller.String() != e.Spec.CleanupOwner {
		panic("only effect " + strconv.FormatUint(e.ID, 10) + "'s cleanup owner may do this")
	}
	return caller
}

func mustStepper(cur realm, e *effect, attempt, stepIndex int) address {
	caller := mustUser(cur)
	mustAttempt(e, attempt)
	height := runtime.ChainHeight()
	switch {
	case caller != e.Executor:
		panic("only effect " + strconv.FormatUint(e.ID, 10) + "'s executor records its steps")
	case e.Fenced:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is fenced: nothing more is recorded under it")
	case height > e.StartHeight+e.Spec.DeadlineBlocks:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " passed its deadline height: it is IN_DOUBT, and its cleanup owner resolves it")
	case e.State != sdk.EffectStarted:
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is " + string(e.State))
	case paused.Has(e.Spec.AgentID):
		panic("agent " + e.Spec.AgentID + " has its effects paused")
	case stepIndex != int(e.Receipts)+1 || stepIndex > int(e.Spec.Steps):
		panic("the next step of effect " + strconv.FormatUint(e.ID, 10) + " is " + strconv.FormatUint(uint64(e.Receipts+1), 10))
	}
	return caller
}

func mustAttempt(e *effect, attempt int) {
	if attempt != int(e.Spec.Attempt) {
		panic("effect " + strconv.FormatUint(e.ID, 10) + " is attempt " + strconv.FormatUint(uint64(e.Spec.Attempt), 10) +
			": a call for another attempt is refused")
	}
}

func mustEffect(id uint64) *effect {
	e, ok := effects.Get(key(id)).(*effect)
	if !ok || e == nil {
		panic("no effect " + strconv.FormatUint(id, 10))
	}
	return e
}

func mustApproval(id uint64) *approval {
	a, ok := approvals.Get(key(id)).(*approval)
	if !ok || a == nil {
		panic("no approval " + strconv.FormatUint(id, 10))
	}
	return a
}

func mustDigest(name, hex string) [32]byte {
	d, err := sdk.ParseDigest(hex)
	if err != nil {
		panic(name + ": " + err.Error())
	}
	return d
}

func mustCount(name string, n int) uint32 {
	if n < 1 || n > int(sdk.MaxEffectSteps) {
		panic(name + " must be 1.." + strconv.FormatUint(uint64(sdk.MaxEffectSteps), 10))
	}
	return uint32(n)
}

func mustAddress(name string, a address) string {
	if !a.IsValid() {
		panic(name + " is not a valid address")
	}
	return a.String()
}

// mustKey accepts printable ASCII without the separators the realm's indexes use.
func mustKey(name, s string) {
	if len(s) == 0 || len(s) > 96 {
		panic(name + " must be 1..96 bytes")
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; c < 0x21 || c > 0x7e || c == ',' {
			panic(name + " must be printable ASCII without spaces or commas")
		}
	}
}

func effectiveState(e *effect, now int64) sdk.EffectState {
	return sdk.EffectiveState(e.State, e.StartHeight, e.Spec.DeadlineBlocks, now)
}

// ── Demo state ───────────────────────────────────────────────────────────────

func mustDemoKeys(csv string) []string {
	keys := strings.Split(csv, ",")
	if len(keys) < 1 || len(keys) > maxDemoKeys {
		panic("a demo effect writes 1.." + strconv.Itoa(maxDemoKeys) + " keys")
	}
	seen := map[string]bool{}
	for _, k := range keys {
		if len(k) == 0 || len(k) > maxDemoKeyLen || seen[k] {
			panic("demo keys must be distinct and 1.." + strconv.Itoa(maxDemoKeyLen) + " bytes")
		}
		mustKey("demo key", k)
		seen[k] = true
	}
	return keys
}

func mustDemoValues(csv string, n int) []string {
	values := strings.Split(csv, ",")
	if len(values) != n {
		panic("give one value per demo key")
	}
	for _, v := range values {
		mustDemoValue(v)
	}
	return values
}

func mustDemoValue(v string) {
	if len(v) > maxDemoValueLen {
		panic("a demo value is at most " + strconv.Itoa(maxDemoValueLen) + " bytes")
	}
	for i := 0; i < len(v); i++ {
		if c := v[i]; c < 0x21 || c > 0x7e || c == ',' {
			panic("a demo value is printable ASCII without spaces or commas")
		}
	}
}

func demoGet(k string) string {
	if v, ok := demoState.Get(k).(string); ok {
		return v
	}
	return ""
}

func demoRead(keys []string) []string {
	out := make([]string, len(keys))
	for i, k := range keys {
		out[i] = demoGet(k)
	}
	return out
}

func demoDigest(keys, values []string) [32]byte {
	out := lenPrefixed(nil, demoStateDomain)
	for i, k := range keys {
		out = lenPrefixed(out, k)
		out = lenPrefixed(out, values[i])
	}
	return sdk.HashBytes(out)
}

func demoStepDigest(k, old, next string) [32]byte {
	out := lenPrefixed(nil, demoStepDomain)
	out = lenPrefixed(out, k)
	out = lenPrefixed(out, old)
	out = lenPrefixed(out, next)
	return sdk.HashBytes(out)
}

func lenPrefixed(out []byte, s string) []byte {
	out = binary.BigEndian.AppendUint32(out, uint32(len(s)))
	return append(out, s...)
}

func key(id uint64) string {
	s := strconv.FormatUint(id, 10)
	return strings.Repeat("0", 20-len(s)) + s
}

func pair(agentID, k string) string {
	return agentID + "," + k
}
