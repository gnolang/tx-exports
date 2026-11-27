package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"strconv"
)

// Effect lifecycle. An authorized action that can stop part way gets a life of its own, sealed event by event:
//
//	STARTED -> step receipts -> CLOSE: COMMITTED | PARTIAL | IN_DOUBT | ABORTED
//	   |                                    |
//	   +-- deadline height passes: IN_DOUBT +--> COMPENSATED | ACCEPTED
//
// Detection does not depend on the executor: a start that is not closed by its deadline height is IN_DOUBT, and anyone
// may seal that. A close is computed from a read-back, never asserted:
//   - the read-back equals the postcondition the start declared: COMMITTED;
//   - it equals the declared pre-state: nothing is seen, which is not yet proof of no effect. It is ABORTED only once
//     the effect is fenced (it was fenced, or its deadline passed, before the read-back was observed), so that nothing
//     sent under it can still land; until then it is IN_DOUBT;
//   - anything else: PARTIAL.
//
// The start names who owns the cleanup and how the effect is undone. An IRREVERSIBLE effect needs a recorded human
// approval before it starts, and a refused start leaves no record. Each attempt is its own effect: a retry carries
// the same idempotency key and the next attempt number, and every event names the attempt it belongs to.

const (
	DomainEffectSpec  = "arobi-assurance-effect-spec-v1"
	DomainEffectEvent = "arobi-assurance-effect-event-v1"

	// MaxEffectSteps bounds the step receipts one effect may carry.
	MaxEffectSteps uint32 = 32
	// MaxEffectDeadlineBlocks bounds how long an effect may stay open: about 7 days at 2 s per block.
	MaxEffectDeadlineBlocks int64 = 302400
	// MaxReadBackAgeBlocks bounds how old an agent's read-back may be when it closes an effect.
	MaxReadBackAgeBlocks int64 = 600
	// MaxCompensations bounds how many compensations one effect may start: recovery is bounded, never a loop.
	MaxCompensations uint32 = 3

	maxEffectKeyLength = 96
	maxInverseLength   = 96
)

// ReversalClass says how an effect is undone.
type ReversalClass string

const (
	// ReversalReversible: the inverse operation is named.
	ReversalReversible ReversalClass = "REVERSIBLE"
	// ReversalCompensable: a different action undoes the effect (a refund, a revert commit, the previous deploy).
	ReversalCompensable ReversalClass = "COMPENSABLE"
	// ReversalIrreversible: nothing undoes it (mail sent, a transfer on another chain, physical motion).
	ReversalIrreversible ReversalClass = "IRREVERSIBLE"
)

// ReadBack says who observes an effect's downstream state when it closes.
const (
	// ReadBackRealm: the downstream is state the realm itself holds, so the realm reads it at the close.
	ReadBackRealm = "REALM"
	// ReadBackAgent: the downstream is outside the chain; the agent reports a digest and the height it observed it at,
	// and the realm can only compare that digest with the ones the start declared.
	ReadBackAgent = "AGENT"
)

// EffectState is where an effect is in its life.
type EffectState string

const (
	EffectStarted     EffectState = "STARTED"
	EffectCommitted   EffectState = "COMMITTED"
	EffectAborted     EffectState = "ABORTED"
	EffectPartial     EffectState = "PARTIAL"
	EffectInDoubt     EffectState = "IN_DOUBT"
	EffectCompensated EffectState = "COMPENSATED"
	EffectAccepted    EffectState = "ACCEPTED"
)

// Terminal reports whether nothing more can happen to an effect in this state. COMMITTED is not terminal: a
// completed effect that is not IRREVERSIBLE may still be undone by a linked compensation.
func (s EffectState) Terminal() bool {
	switch s {
	case EffectAborted, EffectCompensated, EffectAccepted:
		return true
	}
	return false
}

// Closed reports whether an effect in this state no longer holds its key: it is terminal or COMMITTED.
func (s EffectState) Closed() bool {
	return s == EffectCommitted || s.Terminal()
}

// Obligation reports whether an effect in this state is owed a cleanup by its cleanup owner.
func (s EffectState) Obligation() bool {
	return s == EffectInDoubt || s == EffectPartial
}

// EffectSpec is what a start declares. Its digest is sealed in the START event before any step runs.
type EffectSpec struct {
	AgentID        string
	EffectKey      string // what the effect acts on: one effect at a time per key
	IdempotencyKey string // the same key on every retry: an effect is never applied twice
	Attempt        uint32 // 1 for the first try, one more for each retry after an ABORTED or COMPENSATED try
	Steps          uint32 // how many step receipts a complete run leaves
	Reversal       ReversalClass
	Inverse        string   // REVERSIBLE: the inverse operation; COMPENSABLE: the compensating action
	ReadBack       string   // ReadBackRealm or ReadBackAgent
	// DownstreamHonoursLive declares that the downstream checks EffectLive(id, attempt) in the same step that applies
	// anything, or keeps its own record of the attempts it consumed. Only then does a fence or a passed deadline
	// prove that nothing sent under the effect can still land. A realm read-back is always true: the realm is the
	// downstream, and it refuses every step after a fence or the deadline.
	DownstreamHonoursLive bool
	PreState              [32]byte // the downstream state before the effect
	Postcondition  [32]byte // the read-back that closes the effect as COMMITTED
	DeadlineBlocks int64    // the effect must close within this many blocks of its start
	CleanupOwner   string   // who owns the cleanup when the effect is IN_DOUBT or PARTIAL
	ApprovalID     uint64   // IRREVERSIBLE: the recorded approval this start consumes
	Compensates    uint64   // non-zero: this effect undoes that one
}

// Validate refuses a spec that leaves any part of the lifecycle undecided.
func (s EffectSpec) Validate() error {
	switch {
	case s.AgentID == "":
		return errors.New("effect: agent id is empty")
	case s.EffectKey == "" || len(s.EffectKey) > maxEffectKeyLength:
		return errors.New("effect: effect key must be 1.." + strconv.Itoa(maxEffectKeyLength) + " bytes")
	case s.IdempotencyKey == "" || len(s.IdempotencyKey) > maxEffectKeyLength:
		return errors.New("effect: idempotency key must be 1.." + strconv.Itoa(maxEffectKeyLength) + " bytes")
	case s.Attempt < 1:
		return errors.New("effect: attempt starts at 1")
	case s.Steps < 1 || s.Steps > MaxEffectSteps:
		return errors.New("effect: steps must be 1.." + strconv.FormatUint(uint64(MaxEffectSteps), 10))
	case s.DeadlineBlocks < 1 || s.DeadlineBlocks > MaxEffectDeadlineBlocks:
		return errors.New("effect: a deadline of 1.." + strconv.FormatInt(MaxEffectDeadlineBlocks, 10) + " blocks is required")
	case s.CleanupOwner == "":
		return errors.New("effect: a cleanup owner is required")
	case s.ReadBack != ReadBackRealm && s.ReadBack != ReadBackAgent:
		return errors.New("effect: read-back must be REALM or AGENT")
	case s.ReadBack == ReadBackRealm && !s.DownstreamHonoursLive:
		return errors.New("effect: a realm read-back's downstream is the realm, which honours EffectLive")
	case s.PreState == s.Postcondition:
		return errors.New("effect: the postcondition equals the pre-state, so a run could not be told from a no-op")
	case len(s.Inverse) > maxInverseLength:
		return errors.New("effect: inverse must be at most " + strconv.Itoa(maxInverseLength) + " bytes")
	}
	switch s.Reversal {
	case ReversalReversible, ReversalCompensable:
		if s.Inverse == "" {
			return errors.New("effect: a " + string(s.Reversal) + " effect names how it is undone")
		}
		if s.ApprovalID != 0 && s.Compensates == 0 {
			return errors.New("effect: only an IRREVERSIBLE effect, or the compensation of an effect that may still land, consumes an approval")
		}
	case ReversalIrreversible:
		if s.Inverse != "" {
			return errors.New("effect: an IRREVERSIBLE effect has no inverse")
		}
		if s.ApprovalID == 0 {
			return errors.New("effect: an IRREVERSIBLE effect needs a recorded human approval before it starts")
		}
		if s.Compensates != 0 {
			return errors.New("effect: a compensation cannot be IRREVERSIBLE")
		}
	default:
		return errors.New("effect: reversal class must be REVERSIBLE, COMPENSABLE or IRREVERSIBLE")
	}
	return nil
}

// Encode serializes the spec canonically.
func (s EffectSpec) Encode() []byte {
	out := make([]byte, 0, 320)
	out = appendString(out, DomainEffectSpec)
	out = append(out, EncodingVersion)
	out = appendString(out, s.AgentID)
	out = appendString(out, s.EffectKey)
	out = appendString(out, s.IdempotencyKey)
	out = binary.BigEndian.AppendUint32(out, s.Attempt)
	out = binary.BigEndian.AppendUint32(out, s.Steps)
	out = appendString(out, string(s.Reversal))
	out = appendString(out, s.Inverse)
	out = appendString(out, s.ReadBack)
	out = append(out, boolByte(s.DownstreamHonoursLive))
	out = append(out, s.PreState[:]...)
	out = append(out, s.Postcondition[:]...)
	out = binary.BigEndian.AppendUint64(out, uint64(s.DeadlineBlocks))
	out = appendString(out, s.CleanupOwner)
	out = binary.BigEndian.AppendUint64(out, s.ApprovalID)
	out = binary.BigEndian.AppendUint64(out, s.Compensates)
	return out
}

// Digest returns SHA-256(Encode()).
func (s EffectSpec) Digest() [32]byte {
	return sha256.Sum256(s.Encode())
}

// Landable reports whether something sent under this effect may still land after a fence or the deadline: its
// downstream is outside the chain and does not honour EffectLive. For such an effect nothing the realm records proves
// "no effect", so a pre-state read-back stays IN_DOUBT, ACCEPTED keeps the key held, and compensating it while it is
// IN_DOUBT or PARTIAL consumes the owner's recorded approval.
func (s EffectSpec) Landable() bool {
	return s.ReadBack == ReadBackAgent && !s.DownstreamHonoursLive
}

// CloseOutcome computes how an effect closes from the read-back of its downstream state. fencedBeforeRead says
// whether the effect was fenced before the read-back was observed; without that, a read-back of the pre-state shows
// only that nothing has landed yet.
func CloseOutcome(s EffectSpec, readBack [32]byte, fencedBeforeRead bool) EffectState {
	switch readBack {
	case s.Postcondition:
		return EffectCommitted
	case s.PreState:
		if fencedBeforeRead {
			return EffectAborted
		}
		return EffectInDoubt
	}
	return EffectPartial
}

// EffectiveState is the state a reader sees at height now: a STARTED effect past its deadline is IN_DOUBT whether or
// not anyone has sealed that yet.
func EffectiveState(stored EffectState, startHeight, deadlineBlocks, now int64) EffectState {
	if stored == EffectStarted && now > startHeight+deadlineBlocks {
		return EffectInDoubt
	}
	return stored
}

// EffectEventKind names one sealed event of an effect's life.
type EffectEventKind string

const (
	EventStart       EffectEventKind = "START"
	EventStep        EffectEventKind = "STEP"
	EventFence       EffectEventKind = "FENCE" // nothing more may be sent under this effect; steps are refused after it
	EventClose       EffectEventKind = "CLOSE"
	EventInDoubt     EffectEventKind = "IN_DOUBT"
	EventCompensate  EffectEventKind = "COMPENSATE"  // on the effect being undone: its compensation (Link) started
	EventCompensated EffectEventKind = "COMPENSATED" // on the effect being undone: the compensation (Link) committed
	EventAccept      EffectEventKind = "ACCEPT"
	// EventRelease frees the key an ACCEPTED or COMPENSATED effect that may still land kept holding. Only the agent's
	// approver seals it, with the digest of the downstream's own record that the attempt was refused or expired unused.
	EventRelease EffectEventKind = "RELEASE"
)

// EffectEvent is one sealed event, hash-chained to the effect's previous event.
type EffectEvent struct {
	EffectID       uint64
	Attempt        uint32 // the attempt this event belongs to: the spec's
	Seq            uint32 // 0 for START, then 1, 2, ... with no gap
	PrevHash       [32]byte
	Kind           EffectEventKind
	State          EffectState // the state after this event
	Actor          string
	Height         int64
	StepIndex      uint32   // STEP: 1-based
	Digest         [32]byte // START: the spec; STEP: the receipt; CLOSE, COMPENSATED: the read-back; ACCEPT: the reason
	ObservedHeight int64    // CLOSE: the height the read-back was observed at
	Link           uint64   // COMPENSATE, COMPENSATED: the compensation effect
}

// Encode serializes the event canonically.
func (e EffectEvent) Encode() []byte {
	out := make([]byte, 0, 240)
	out = appendString(out, DomainEffectEvent)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, e.EffectID)
	out = binary.BigEndian.AppendUint32(out, e.Attempt)
	out = binary.BigEndian.AppendUint32(out, e.Seq)
	out = append(out, e.PrevHash[:]...)
	out = appendString(out, string(e.Kind))
	out = appendString(out, string(e.State))
	out = appendString(out, e.Actor)
	out = binary.BigEndian.AppendUint64(out, uint64(e.Height))
	out = binary.BigEndian.AppendUint32(out, e.StepIndex)
	out = append(out, e.Digest[:]...)
	out = binary.BigEndian.AppendUint64(out, uint64(e.ObservedHeight))
	out = binary.BigEndian.AppendUint64(out, e.Link)
	return out
}

// LeafHash returns RFC 6962 LeafHash(Encode()).
func (e EffectEvent) LeafHash() [32]byte {
	return LeafHash(e.Encode())
}

// VerifyEffectLife checks one effect's whole life offline and returns the last sealed state. START must seal this
// spec; every event must link to the one before it with no gap, belong to this effect and attempt, and make a
// transition the lifecycle allows, by the actor allowed to make it, at a height it allows; every close's state must
// be the one its read-back computes.
func VerifyEffectLife(effectID uint64, spec EffectSpec, events []EffectEvent) (EffectState, error) {
	if err := spec.Validate(); err != nil {
		return "", err
	}
	if len(events) == 0 {
		return "", errors.New("effect life: no events")
	}
	first := events[0]
	switch {
	case first.EffectID != effectID || first.Attempt != spec.Attempt:
		return "", errors.New("effect life: START belongs to another effect or attempt")
	case first.Kind != EventStart || first.Seq != 0 || first.PrevHash != ZeroDigest() || first.State != EffectStarted:
		return "", errors.New("effect life: the first event must be START, seq 0, with a zero previous hash")
	case first.Digest != spec.Digest():
		return "", errors.New("effect life: START does not seal this spec")
	}
	executor := first.Actor
	start := first.Height
	deadline := start + spec.DeadlineBlocks
	state := EffectStarted
	steps := uint32(0)
	lastStepHeight := start
	fenced, fenceSeq, fenceHeight := false, uint32(0), int64(0)
	compensations := uint32(0)
	released := false
	openLinks := map[uint64]bool{}
	for i := 1; i < len(events); i++ {
		ev, prev := events[i], events[i-1]
		at := "effect life, event " + strconv.Itoa(i) + ": "
		switch {
		case ev.EffectID != effectID || ev.Attempt != spec.Attempt:
			return "", errors.New(at + "belongs to another effect or attempt")
		case ev.Seq != uint32(i) || ev.PrevHash != prev.LeafHash():
			return "", errors.New(at + "breaks the hash chain (a gap, a fork or a reordering)")
		case ev.Height < prev.Height:
			return "", errors.New(at + "goes back in height")
		case state.Terminal() && ev.Kind != EventRelease:
			return "", errors.New(at + "follows a terminal state")
		}
		next := state
		switch ev.Kind {
		case EventStep:
			if state != EffectStarted || fenced || ev.Actor != executor || ev.Height > deadline ||
				ev.StepIndex != steps+1 || ev.StepIndex > spec.Steps {
				return "", errors.New(at + "is not a step the executor may record here")
			}
			steps++
			lastStepHeight = ev.Height
		case EventFence:
			if fenced || (state != EffectStarted && state != EffectInDoubt) || (ev.Actor != executor && ev.Actor != spec.CleanupOwner) {
				return "", errors.New(at + "is not a fence this actor may seal here")
			}
			fenced, fenceSeq, fenceHeight = true, ev.Seq, ev.Height
		case EventClose:
			switch {
			case state == EffectStarted && ev.Actor == executor && ev.Height <= deadline:
			case state == EffectInDoubt && ev.Actor == spec.CleanupOwner:
			default:
				return "", errors.New(at + "is not a close this actor may make here")
			}
			fencedBefore := false
			if spec.ReadBack == ReadBackRealm {
				if ev.ObservedHeight != ev.Height {
					return "", errors.New(at + "a realm read-back is observed at its own close")
				}
				fencedBefore = (fenced && fenceSeq < ev.Seq) || ev.Height > deadline
			} else {
				if ev.ObservedHeight < lastStepHeight || ev.ObservedHeight > ev.Height || ev.Height-ev.ObservedHeight > MaxReadBackAgeBlocks {
					return "", errors.New(at + "the read-back is older than the last step, from the future, or too old")
				}
				// A fence or the clock proves nothing about a downstream that does not honour EffectLive.
				fencedBefore = !spec.Landable() && ((fenced && ev.ObservedHeight > fenceHeight) || ev.ObservedHeight > deadline)
			}
			if ev.Digest == ZeroDigest() {
				return "", errors.New(at + "a close needs a read-back digest")
			}
			next = CloseOutcome(spec, ev.Digest, fencedBefore)
		case EventInDoubt:
			if state != EffectStarted || ev.Height <= deadline {
				return "", errors.New(at + "IN_DOUBT before the deadline height")
			}
			next = EffectInDoubt
		case EventCompensate:
			if spec.Reversal == ReversalIrreversible || ev.Actor != spec.CleanupOwner || ev.Link == 0 ||
				(state != EffectPartial && state != EffectInDoubt && state != EffectCommitted) {
				return "", errors.New(at + "is not a compensation the cleanup owner may start here")
			}
			compensations++
			if compensations > MaxCompensations {
				return "", errors.New(at + "more compensations than MaxCompensations")
			}
			// Undoing an effect that may still land is the owner's decision: the event carries the approval it used.
			if spec.Landable() && state != EffectCommitted && ev.Digest == ZeroDigest() {
				return "", errors.New(at + "compensates an effect that may still land without the owner's recorded approval")
			}
			openLinks[ev.Link] = true
		case EventCompensated:
			if !openLinks[ev.Link] || ev.Digest != spec.PreState {
				return "", errors.New(at + "COMPENSATED without its compensation, or with a read-back other than the pre-state")
			}
			next = EffectCompensated
		case EventRelease:
			// The key an accepted or undone effect that may still land kept holding is freed once, by someone other than
			// the executor, against the downstream's own record (a non-zero digest) that the attempt will not land.
			if !spec.Landable() || released || ev.Actor == executor || ev.Digest == ZeroDigest() ||
				(state != EffectAccepted && state != EffectCompensated) {
				return "", errors.New(at + "is not a release the approver may seal here")
			}
			released = true
		case EventAccept:
			// A person may take what landed as final, once nothing more can be sent under the effect: an IN_DOUBT
			// effect is fenced first.
			if ev.Actor != spec.CleanupOwner || (state != EffectPartial && state != EffectInDoubt) || (state == EffectInDoubt && !fenced) {
				return "", errors.New(at + "is not an acceptance the cleanup owner may make here (an IN_DOUBT effect is fenced first)")
			}
			next = EffectAccepted
		default:
			return "", errors.New(at + "unknown kind " + string(ev.Kind))
		}
		if ev.State != next {
			return "", errors.New(at + "seals " + string(ev.State) + " where the lifecycle gives " + string(next))
		}
		state = next
	}
	return state, nil
}

// EffectBuilder assembles an EffectSpec and refuses one with no deadline, cleanup owner or reversal class.
type EffectBuilder struct {
	spec EffectSpec
}

// NewEffect starts a spec for one effect of an agent on one key, read back by the agent. Its downstream is taken not
// to honour EffectLive until DownstreamHonoursLive(true) says it does: the conservative default.
func NewEffect(agentID, effectKey, idempotencyKey string) *EffectBuilder {
	return &EffectBuilder{spec: EffectSpec{
		AgentID: agentID, EffectKey: effectKey, IdempotencyKey: idempotencyKey, Attempt: 1, ReadBack: ReadBackAgent,
	}}
}

func (b *EffectBuilder) Attempt(n uint32) *EffectBuilder { b.spec.Attempt = n; return b }
func (b *EffectBuilder) Steps(n uint32) *EffectBuilder   { b.spec.Steps = n; return b }
func (b *EffectBuilder) States(pre, post [32]byte) *EffectBuilder {
	b.spec.PreState, b.spec.Postcondition = pre, post
	return b
}
func (b *EffectBuilder) ReadBy(who string) *EffectBuilder       { b.spec.ReadBack = who; return b }
func (b *EffectBuilder) DownstreamHonoursLive(v bool) *EffectBuilder {
	b.spec.DownstreamHonoursLive = v
	return b
}
func (b *EffectBuilder) Deadline(blocks int64) *EffectBuilder  { b.spec.DeadlineBlocks = blocks; return b }
func (b *EffectBuilder) CleanupOwner(who string) *EffectBuilder { b.spec.CleanupOwner = who; return b }
func (b *EffectBuilder) Reversible(inverse string) *EffectBuilder {
	b.spec.Reversal, b.spec.Inverse = ReversalReversible, inverse
	return b
}
func (b *EffectBuilder) Compensable(action string) *EffectBuilder {
	b.spec.Reversal, b.spec.Inverse = ReversalCompensable, action
	return b
}
func (b *EffectBuilder) Irreversible(approvalID uint64) *EffectBuilder {
	b.spec.Reversal, b.spec.Inverse, b.spec.ApprovalID = ReversalIrreversible, "", approvalID
	return b
}

// Build returns the spec, or why it is refused.
func (b *EffectBuilder) Build() (EffectSpec, error) {
	if err := b.spec.Validate(); err != nil {
		return EffectSpec{}, err
	}
	return b.spec, nil
}
