package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"

	"gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/signals"
)

const (
	DomainCapability = "arobi-assurance-capability-v1"
	DomainFamiliar   = "arobi-assurance-familiar-v1"

	// Bitmask object-capabilities for Immaculate Familiars & cross-harness sub-agents.
	CapReadMemory   uint32 = 1 << 0
	CapWriteMemory  uint32 = 1 << 1
	CapInvokeTool   uint32 = 1 << 2
	CapDelegate     uint32 = 1 << 3
	CapSendWhisper  uint32 = 1 << 4
	CapManageEscrow uint32 = 1 << 5
	CapAll          uint32 = CapReadMemory | CapWriteMemory | CapInvokeTool | CapDelegate | CapSendWhisper | CapManageEscrow

	// z^2 = 1.96^2 = 3.8416 scaled by signals.Scale (95% Wilson score lower bound).
	wilsonZ2Fixed int64 = 3841600
)

// CapabilityToken is an unforgeable, strictly attenuable object-capability lease governing
// what a Familiar (or delegated gnosh.ai / Ullumii / Whisper worker) is authorized to do.
type CapabilityToken struct {
	ID                uint64
	FamiliarID        string
	Owner             string
	GrantMask         uint32
	MaxSpendUgnot     int64
	MaxCallsPerWindow uint64
	WindowBlocks      int64
	IssuedHeight      int64
	ExpiryHeight      int64
	ParentDigest      [32]byte
}

// Digest returns canonical SHA-256 over the CapabilityToken fields.
func (c CapabilityToken) Digest() [32]byte {
	out := make([]byte, 0, 160)
	out = appendString(out, DomainCapability)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, c.ID)
	out = appendString(out, c.FamiliarID)
	out = appendString(out, c.Owner)
	out = binary.BigEndian.AppendUint32(out, c.GrantMask)
	out = binary.BigEndian.AppendUint64(out, uint64(c.MaxSpendUgnot))
	out = binary.BigEndian.AppendUint64(out, c.MaxCallsPerWindow)
	out = binary.BigEndian.AppendUint64(out, uint64(c.WindowBlocks))
	out = binary.BigEndian.AppendUint64(out, uint64(c.IssuedHeight))
	out = binary.BigEndian.AppendUint64(out, uint64(c.ExpiryHeight))
	out = append(out, c.ParentDigest[:]...)
	return sha256.Sum256(out)
}

// Has checks whether all bits in required are granted by this CapabilityToken.
func (c CapabilityToken) Has(required uint32) bool {
	return (c.GrantMask & required) == required
}

// AttenuateCapability derives a strictly attenuated child CapabilityToken from parent.
// Any attempt to amplify capability bits, spend limit, call cadence, or expiry FAILS CLOSED.
func AttenuateCapability(
	parent CapabilityToken,
	childID uint64,
	childFamiliarID string,
	childMask uint32,
	childMaxSpendUgnot int64,
	childMaxCalls uint64,
	nowHeight int64,
	childExpiry int64,
) (CapabilityToken, error) {
	if !parent.Has(CapDelegate) {
		return CapabilityToken{}, errors.New("parent capability lacks CapDelegate")
	}
	if childFamiliarID == "" || childFamiliarID == parent.FamiliarID {
		return CapabilityToken{}, errors.New("child familiar must be distinct and non-empty")
	}
	if childMask == 0 {
		return CapabilityToken{}, errors.New("child capability mask must be non-empty")
	}
	if (childMask &^ parent.GrantMask) != 0 {
		return CapabilityToken{}, errors.New("capability amplification denied: child requests bits outside parent grant")
	}
	if childMaxSpendUgnot < 0 || childMaxSpendUgnot > parent.MaxSpendUgnot {
		return CapabilityToken{}, errors.New("spend amplification denied: childMaxSpend exceeds parent")
	}
	if parent.MaxCallsPerWindow > 0 && (childMaxCalls == 0 || childMaxCalls > parent.MaxCallsPerWindow) {
		return CapabilityToken{}, errors.New("rate amplification denied: childMaxCalls exceeds parent")
	}
	if nowHeight < parent.IssuedHeight || nowHeight > parent.ExpiryHeight {
		return CapabilityToken{}, errors.New("parent capability is inactive or expired")
	}
	if childExpiry < nowHeight || childExpiry > parent.ExpiryHeight {
		return CapabilityToken{}, errors.New("expiry amplification denied: child expiry exceeds parent")
	}
	return CapabilityToken{
		ID:                childID,
		FamiliarID:        childFamiliarID,
		Owner:             parent.Owner,
		GrantMask:         childMask,
		MaxSpendUgnot:     childMaxSpendUgnot,
		MaxCallsPerWindow: childMaxCalls,
		WindowBlocks:      parent.WindowBlocks,
		IssuedHeight:      nowHeight,
		ExpiryHeight:      childExpiry,
		ParentDigest:      parent.Digest(),
	}, nil
}

// VerifyCapabilityAttenuation verifies that child is a strictly valid attenuation of parent.
func VerifyCapabilityAttenuation(parent, child CapabilityToken) error {
	if child.ParentDigest != parent.Digest() {
		return errors.New("capability parent digest mismatch")
	}
	if !parent.Has(CapDelegate) {
		return errors.New("parent lacks CapDelegate")
	}
	if (child.GrantMask &^ parent.GrantMask) != 0 {
		return errors.New("child capability mask exceeds parent")
	}
	if child.MaxSpendUgnot > parent.MaxSpendUgnot {
		return errors.New("child spend limit exceeds parent")
	}
	if child.ExpiryHeight > parent.ExpiryHeight {
		return errors.New("child expiry exceeds parent")
	}
	return nil
}

// WilsonLowerBoundFixed computes the 95% Wilson score lower confidence bound for
// successes / total in fixed-point [0, signals.Scale], using pure integer math (zero floats).
// Returns 0 when total == 0 (conservative unmeasured floor).
func WilsonLowerBoundFixed(successes, total uint64) int64 {
	if total == 0 || successes == 0 {
		return 0
	}
	if successes > total {
		successes = total
	}
	n := int64(total)
	p := (int64(successes) * signals.Scale) / n // in [0, Scale]
	z2OverN := wilsonZ2Fixed / n                // z^2 / n in Scale units

	// Numerator center: p + z^2 / (2n)
	center := p + z2OverN/2

	// Variance term inside sqrt: (p*(1-p)/n) + (z^2 / (4*n^2))
	// Multiply by z^2 and compute sqrt in Scale units:
	// margin = sqrt(z^2 * (p*(1-p)/n + z^2/(4*n^2)))
	pOneMinusP := signals.MulFixed(p, signals.Scale-p) // in [0, 0.25*Scale]
	term1 := signals.MulFixed(wilsonZ2Fixed, pOneMinusP/n)
	term2 := signals.MulFixed(z2OverN, z2OverN) / 4
	radicand := term1 + term2
	if radicand < 0 {
		radicand = 0
	}
	// sqrt(radicand / Scale) * Scale = isqrt(radicand * Scale)
	margin := int64(signals.ISqrt64(uint64(radicand) * uint64(signals.Scale)))

	denom := signals.Scale + z2OverN
	num := center - margin
	if num <= 0 {
		return 0
	}
	res := signals.DivFixed(num, denom)
	if res > signals.Scale {
		res = signals.Scale
	}
	return res
}

// TrustLedger tracks a Familiar's empirical execution reliability using Wilson lower bounds.
type TrustLedger struct {
	Successes          uint64
	Violations         uint64
	MinTrustFloorFixed int64 // if > 0 and Total >= MinSamples, lower bound below floor triggers auto-halt
	MinSamples         uint64
}

// Total returns total observed actions.
func (t *TrustLedger) Total() uint64 { return t.Successes + t.Violations }

// LowerBoundFixed returns the 95% Wilson lower confidence bound in [0, Scale].
func (t *TrustLedger) LowerBoundFixed() int64 {
	return WilsonLowerBoundFixed(t.Successes, t.Total())
}

// Healthy returns true if the Familiar has not breached its calibrated trust floor.
func (t *TrustLedger) Healthy() bool {
	if t.MinTrustFloorFixed <= 0 || t.Total() < t.MinSamples {
		return true
	}
	return t.LowerBoundFixed() >= t.MinTrustFloorFixed
}

// Familiar is a persistent, owner-bonded autonomous companion agent combining:
//   - Governed Agent runtime + RFC 6962 evidence accumulator
//   - Poison-resistant Hybrid RRF MemoryVault
//   - Strictly attenuable Object-Capability lease (CapabilityToken)
//   - Paced sliding-window rate governor + Wilson-calibrated TrustLedger
type Familiar struct {
	ID             string
	Owner          string
	Agent          *Agent
	Memory         *MemoryVault
	CoherenceGuard *CoherenceGuardPolicy
	Capability     CapabilityToken
	Trust          TrustLedger
	Revoked        bool

	windowStartHeight int64
	windowCalls       uint64
	childCapSeq       uint64
}

// NewFamiliar constructs a governed Familiar with fail-closed defaults.
func NewFamiliar(
	id string,
	owner string,
	agent *Agent,
	memory *MemoryVault,
	coherenceGuard *CoherenceGuardPolicy,
	capToken CapabilityToken,
	minTrustFloorFixed int64,
) (*Familiar, error) {
	if id == "" || owner == "" || agent == nil {
		return nil, errors.New("familiar requires non-empty id, owner, and agent")
	}
	if memory == nil {
		memory = NewMemoryVault(MemoryVaultConfig{VaultID: id + "-memory"})
	}
	if capToken.FamiliarID == "" {
		capToken.FamiliarID = id
	}
	if capToken.Owner == "" {
		capToken.Owner = owner
	}
	return &Familiar{
		ID:             id,
		Owner:          owner,
		Agent:          agent,
		Memory:         memory,
		CoherenceGuard: coherenceGuard,
		Capability:     capToken,
		Trust: TrustLedger{
			MinTrustFloorFixed: minTrustFloorFixed,
			MinSamples:         5,
		},
	}, nil
}

// Revoke permanently halts this Familiar (fail-closed kill switch).
func (f *Familiar) Revoke() {
	f.Revoked = true
	f.Agent.Pause()
}

// Remember ingests a memory episode through the Familiar's capability check and spherical
// quarantine firewall. Quarantined injections increment Trust.Violations.
func (f *Familiar) Remember(
	kind string,
	content []byte,
	embedding []int64,
	salienceFixed int64,
	height int64,
) (MemoryIngestReceipt, error) {
	if f.Revoked {
		return MemoryIngestReceipt{}, errors.New("familiar is revoked")
	}
	if !f.Capability.Has(CapWriteMemory) {
		return MemoryIngestReceipt{}, errors.New("familiar lacks CapWriteMemory")
	}
	if height > f.Capability.ExpiryHeight {
		return MemoryIngestReceipt{}, errors.New("familiar capability expired")
	}
	cp := f.Agent.Checkpoint()
	receipt, err := f.Memory.Ingest(kind, f.ID, content, embedding, salienceFixed, height, cp.LastHash)
	if err != nil {
		return MemoryIngestReceipt{}, err
	}
	if receipt.Quarantined {
		f.Trust.Violations++
	}
	return receipt, nil
}

// ExecuteWithCapability checks capability bits, expiry, paced rate limit, and calibrated
// trust floor, optionally retrieves Top-K hybrid memories, and runs the governed action.
func (f *Familiar) ExecuteWithCapability(
	requiredCap uint32,
	caller string,
	action string,
	target string,
	input []byte,
	queryEmbedding []int64,
	queryText string,
	topK int,
	budgetUgnot int64,
	height int64,
) ([]byte, EvidenceBundle, MemoryRecallProof, error) {
	if f.Revoked {
		return nil, EvidenceBundle{}, MemoryRecallProof{}, errors.New("familiar is revoked")
	}
	if !f.Capability.Has(requiredCap | CapInvokeTool) {
		f.Trust.Violations++
		return nil, EvidenceBundle{}, MemoryRecallProof{}, errors.New("capability denied: familiar lacks required grant bits")
	}
	if height < f.Capability.IssuedHeight || height > f.Capability.ExpiryHeight {
		f.Trust.Violations++
		return nil, EvidenceBundle{}, MemoryRecallProof{}, errors.New("capability expired or not yet active")
	}
	if budgetUgnot > f.Capability.MaxSpendUgnot {
		f.Trust.Violations++
		return nil, EvidenceBundle{}, MemoryRecallProof{}, errors.New("budget exceeds familiar capability MaxSpendUgnot")
	}
	if !f.Trust.Healthy() {
		return nil, EvidenceBundle{}, MemoryRecallProof{}, errors.New("familiar suspended: Wilson trust lower bound below floor")
	}

	// Paced sliding-window rate governor.
	if f.Capability.MaxCallsPerWindow > 0 && f.Capability.WindowBlocks > 0 {
		if f.windowStartHeight == 0 || height-f.windowStartHeight >= f.Capability.WindowBlocks {
			f.windowStartHeight = height
			f.windowCalls = 0
		}
		if f.windowCalls >= f.Capability.MaxCallsPerWindow {
			f.Trust.Violations++
			return nil, EvidenceBundle{}, MemoryRecallProof{}, errors.New("familiar rate limit exceeded for current block window")
		}
		f.windowCalls++
	}

	// If memory read is requested and queryEmbedding provided, bind deterministic recall proof.
	if len(queryEmbedding) > 0 && topK > 0 {
		if !f.Capability.Has(CapReadMemory) {
			f.Trust.Violations++
			return nil, EvidenceBundle{}, MemoryRecallProof{}, errors.New("familiar lacks CapReadMemory")
		}
		out, bundle, recallProof, err := f.Agent.ExecuteWithMemory(
			f.Memory, f.CoherenceGuard, caller, action, target, input, queryEmbedding, queryText, topK, budgetUgnot, height,
		)
		if err != nil {
			f.Trust.Violations++
		} else {
			f.Trust.Successes++
		}
		return out, bundle, recallProof, err
	}

	capDig := f.Capability.Digest()
	out, bundle, err := f.Agent.Execute(caller, action, target, input, capDig[:], budgetUgnot, height)
	if err != nil {
		f.Trust.Violations++
	} else {
		f.Trust.Successes++
	}
	return out, bundle, MemoryRecallProof{}, err
}

// MintSubCapability derives a strictly attenuated CapabilityToken for a sub-familiar or
// remote harness worker (gnosh.ai, Ullumii, Whisper Agent Bus).
func (f *Familiar) MintSubCapability(
	childFamiliarID string,
	childMask uint32,
	childMaxSpend int64,
	childMaxCalls uint64,
	nowHeight int64,
	childExpiry int64,
) (CapabilityToken, error) {
	if f.Revoked {
		return CapabilityToken{}, errors.New("revoked familiar cannot delegate")
	}
	f.childCapSeq++
	return AttenuateCapability(
		f.Capability,
		f.childCapSeq,
		childFamiliarID,
		childMask,
		childMaxSpend,
		childMaxCalls,
		nowHeight,
		childExpiry,
	)
}
