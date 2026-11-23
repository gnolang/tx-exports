package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

// EncodingVersion is fixed for all v1 canonical structures.
// Any wire-format change increments this version rather than mutating v1.
const EncodingVersion uint8 = 1

const (
	DomainProjection = "arobi-assurance-projection-v1"
	DomainWarrant    = "arobi-assurance-warrant-v1"
	DomainReceipt    = "arobi-assurance-decision-receipt-v1"
	DomainClosure    = "arobi-assurance-effect-closure-v1"
	DomainAnchor     = "arobi-assurance-anchor-v1"
)

// Verdict is the fail-closed decision emitted by a Policy.
type Verdict string

const (
	VerdictAllow           Verdict = "ALLOW"
	VerdictDeny            Verdict = "DENY"
	VerdictRequireApproval Verdict = "REQUIRE_APPROVAL"
	VerdictEscalate        Verdict = "ESCALATE"
)

// VerdictSeverity ranks verdicts from least to most restrictive for fail-closed composition.
func VerdictSeverity(v Verdict) int {
	switch v {
	case VerdictAllow:
		return 0
	case VerdictRequireApproval:
		return 1
	case VerdictEscalate:
		return 2
	case VerdictDeny:
		return 3
	default:
		// Unknown verdicts fail closed as DENY.
		return 3
	}
}

// RiskTier classifies the blast radius of a governed agent tool.
type RiskTier string

const (
	RiskLow      RiskTier = "LOW"
	RiskMedium   RiskTier = "MEDIUM"
	RiskHigh     RiskTier = "HIGH"
	RiskCritical RiskTier = "CRITICAL"
)

// Outcome classifies how a warranted or refused effect closed.
type Outcome string

const (
	OutcomeExecuted   Outcome = "EXECUTED"
	OutcomeFailed     Outcome = "FAILED"
	OutcomeRolledBack Outcome = "ROLLED_BACK"
	OutcomeRefused    Outcome = "REFUSED"
)

// PolicyInputProjection is the canonical, deterministic snapshot of everything a policy
// inspects before an agent acts. Its Digest() binds receipts and warrants to exact inputs.
type PolicyInputProjection struct {
	ChainID       string
	Realm         string
	AgentID       string
	Principal     string
	Caller        string
	Action        string
	Target        string
	InputDigest   [32]byte
	ContextDigest [32]byte
	BudgetUgnot   int64
	RiskTier      RiskTier
	Height        int64
}

// Encode serializes PolicyInputProjection into canonical length-prefixed big-endian bytes.
func (p PolicyInputProjection) Encode() []byte {
	out := make([]byte, 0, 256)
	out = appendString(out, DomainProjection)
	out = append(out, EncodingVersion)
	out = appendString(out, p.ChainID)
	out = appendString(out, p.Realm)
	out = appendString(out, p.AgentID)
	out = appendString(out, p.Principal)
	out = appendString(out, p.Caller)
	out = appendString(out, p.Action)
	out = appendString(out, p.Target)
	out = append(out, p.InputDigest[:]...)
	out = append(out, p.ContextDigest[:]...)
	out = binary.BigEndian.AppendUint64(out, uint64(p.BudgetUgnot))
	out = appendString(out, string(p.RiskTier))
	out = binary.BigEndian.AppendUint64(out, uint64(p.Height))
	return out
}

// Digest returns SHA-256(Encode()).
func (p PolicyInputProjection) Digest() [32]byte {
	return sha256.Sum256(p.Encode())
}

// PolicyDecision is the deterministic result of evaluating a Policy against a projection.
type PolicyDecision struct {
	Verdict       Verdict
	PolicyID      string
	PolicyDigest  [32]byte
	ReasonCode    string
	Reason        string
	MaxSpendUgnot int64
}

// EffectWarrant is a single-use cryptographic authorization bound to one exact projection
// and policy evaluation. A tool cannot execute without an unconsumed, unexpired warrant.
type EffectWarrant struct {
	ID               uint64
	AgentID          string
	ProjectionDigest [32]byte
	PolicyDigest     [32]byte
	Action           string
	Target           string
	MaxSpendUgnot    int64
	IssuedHeight     int64
	ExpiryHeight     int64
	Consumed         bool
}

// Encode serializes the immutable fields of EffectWarrant (excluding mutable Consumed flag).
func (w EffectWarrant) Encode() []byte {
	out := make([]byte, 0, 192)
	out = appendString(out, DomainWarrant)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, w.ID)
	out = appendString(out, w.AgentID)
	out = append(out, w.ProjectionDigest[:]...)
	out = append(out, w.PolicyDigest[:]...)
	out = appendString(out, w.Action)
	out = appendString(out, w.Target)
	out = binary.BigEndian.AppendUint64(out, uint64(w.MaxSpendUgnot))
	out = binary.BigEndian.AppendUint64(out, uint64(w.IssuedHeight))
	out = binary.BigEndian.AppendUint64(out, uint64(w.ExpiryHeight))
	return out
}

// Digest returns SHA-256(Encode()).
func (w EffectWarrant) Digest() [32]byte {
	return sha256.Sum256(w.Encode())
}

// DecisionReceipt is an immutable, hash-chained record of a policy gate evaluation.
type DecisionReceipt struct {
	Seq              uint64
	PrevHash         [32]byte
	ChainID          string
	Realm            string
	AgentID          string
	Caller           string
	ProjectionDigest [32]byte
	PolicyDigest     [32]byte
	Verdict          Verdict
	ReasonCode       string
	WarrantDigest    [32]byte // zero digest when not ALLOW
	Height           int64
}

// Encode serializes DecisionReceipt into canonical bytes.
func (r DecisionReceipt) Encode() []byte {
	out := make([]byte, 0, 256)
	out = appendString(out, DomainReceipt)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, r.Seq)
	out = append(out, r.PrevHash[:]...)
	out = appendString(out, r.ChainID)
	out = appendString(out, r.Realm)
	out = appendString(out, r.AgentID)
	out = appendString(out, r.Caller)
	out = append(out, r.ProjectionDigest[:]...)
	out = append(out, r.PolicyDigest[:]...)
	out = appendString(out, string(r.Verdict))
	out = appendString(out, r.ReasonCode)
	out = append(out, r.WarrantDigest[:]...)
	out = binary.BigEndian.AppendUint64(out, uint64(r.Height))
	return out
}

// LeafHash returns RFC 6962 LeafHash(Encode()).
func (r DecisionReceipt) LeafHash() [32]byte {
	return LeafHash(r.Encode())
}

// EffectClosure binds the execution result (or refusal) back to its DecisionReceipt and Warrant.
type EffectClosure struct {
	Seq              uint64
	PrevHash         [32]byte
	AgentID          string
	WarrantDigest    [32]byte // zero digest when OutcomeRefused
	DecisionLeafHash [32]byte
	OutputDigest     [32]byte
	WitnessDigest    [32]byte
	Outcome          Outcome
	SpentUgnot       int64
	Height           int64
}

// Encode serializes EffectClosure into canonical bytes.
func (c EffectClosure) Encode() []byte {
	out := make([]byte, 0, 256)
	out = appendString(out, DomainClosure)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, c.Seq)
	out = append(out, c.PrevHash[:]...)
	out = appendString(out, c.AgentID)
	out = append(out, c.WarrantDigest[:]...)
	out = append(out, c.DecisionLeafHash[:]...)
	out = append(out, c.OutputDigest[:]...)
	out = append(out, c.WitnessDigest[:]...)
	out = appendString(out, string(c.Outcome))
	out = binary.BigEndian.AppendUint64(out, uint64(c.SpentUgnot))
	out = binary.BigEndian.AppendUint64(out, uint64(c.Height))
	return out
}

// LeafHash returns RFC 6962 LeafHash(Encode()).
func (c EffectClosure) LeafHash() [32]byte {
	return LeafHash(c.Encode())
}

// AnchorRecord is the canonical on-chain record stored by gno.land/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/assurance.
type AnchorRecord struct {
	ChainID        string
	Realm          string
	AnchorID       uint64
	AgentID        string
	Caller         string
	Height         int64
	PrevRoot       [32]byte
	CheckpointRoot [32]byte
	LeafCount      uint64
	ReceiptCount   uint64
	ClosureCount   uint64
}

// Encode serializes AnchorRecord into canonical bytes.
func (a AnchorRecord) Encode() []byte {
	out := make([]byte, 0, 224)
	out = appendString(out, DomainAnchor)
	out = append(out, EncodingVersion)
	out = appendString(out, a.ChainID)
	out = appendString(out, a.Realm)
	out = binary.BigEndian.AppendUint64(out, a.AnchorID)
	out = appendString(out, a.AgentID)
	out = appendString(out, a.Caller)
	out = binary.BigEndian.AppendUint64(out, uint64(a.Height))
	out = append(out, a.PrevRoot[:]...)
	out = append(out, a.CheckpointRoot[:]...)
	out = binary.BigEndian.AppendUint64(out, a.LeafCount)
	out = binary.BigEndian.AppendUint64(out, a.ReceiptCount)
	out = binary.BigEndian.AppendUint64(out, a.ClosureCount)
	return out
}

// LeafHash returns RFC 6962 LeafHash(Encode()).
func (a AnchorRecord) LeafHash() [32]byte {
	return LeafHash(a.Encode())
}

// EvidenceBundle is the self-verifying artifact returned out of the box by every
// governed agent action. Any third party can call Verify() without trusting the agent.
type EvidenceBundle struct {
	Projection       PolicyInputProjection
	Decision         PolicyDecision
	HasWarrant       bool
	Warrant          EffectWarrant
	Receipt          DecisionReceipt
	Closure          EffectClosure
	ReceiptLeafIndex uint64
	ClosureLeafIndex uint64
	AccumulatorSize  uint64
	AccumulatorRoot  [32]byte
	ReceiptProof     [][32]byte
	ClosureProof     [][32]byte
}

// Verify independently recomputes every digest, hash-chain link, warrant binding,
// and RFC 6962 Merkle inclusion proof contained in the bundle.
func (b EvidenceBundle) Verify() error {
	projDigest := b.Projection.Digest()
	if b.Receipt.ProjectionDigest != projDigest {
		return errors.New("receipt projection digest mismatch")
	}
	if b.Receipt.PolicyDigest != b.Decision.PolicyDigest {
		return errors.New("receipt policy digest mismatch")
	}
	if b.Receipt.Verdict != b.Decision.Verdict {
		return errors.New("receipt verdict mismatch")
	}

	if b.Decision.Verdict == VerdictAllow {
		if !b.HasWarrant {
			return errors.New("allowed decision missing warrant")
		}
		if b.Warrant.ProjectionDigest != projDigest {
			return errors.New("warrant projection digest mismatch")
		}
		if b.Warrant.PolicyDigest != b.Decision.PolicyDigest {
			return errors.New("warrant policy digest mismatch")
		}
		wDigest := b.Warrant.Digest()
		if b.Receipt.WarrantDigest != wDigest {
			return errors.New("receipt warrant digest mismatch")
		}
		if b.Closure.WarrantDigest != wDigest {
			return errors.New("closure warrant digest mismatch")
		}
	} else {
		if b.HasWarrant {
			return errors.New("non-allow decision must not issue a warrant")
		}
		if b.Receipt.WarrantDigest != ZeroDigest() || b.Closure.WarrantDigest != ZeroDigest() {
			return errors.New("non-allow decision must have zero warrant digest")
		}
		if b.Closure.Outcome != OutcomeRefused {
			return errors.New("non-allow decision must close as REFUSED")
		}
	}

	rLeaf := b.Receipt.LeafHash()
	if b.Closure.DecisionLeafHash != rLeaf {
		return errors.New("closure decision leaf hash mismatch")
	}
	if b.Closure.PrevHash != rLeaf {
		return errors.New("closure hash-chain PrevHash does not point to its decision receipt")
	}

	cLeaf := b.Closure.LeafHash()
	if !VerifyInclusion(b.ReceiptLeafIndex, b.AccumulatorSize, rLeaf, b.ReceiptProof, b.AccumulatorRoot) {
		return errors.New("decision receipt RFC 6962 inclusion proof failed")
	}
	if !VerifyInclusion(b.ClosureLeafIndex, b.AccumulatorSize, cLeaf, b.ClosureProof, b.AccumulatorRoot) {
		return errors.New("effect closure RFC 6962 inclusion proof failed")
	}
	return nil
}

func appendString(out []byte, s string) []byte {
	out = binary.BigEndian.AppendUint32(out, uint32(len(s)))
	return append(out, []byte(s)...)
}
