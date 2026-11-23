package whisper

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"

	"gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/assurance"
)

const (
	DomainAgentBus = "arobi-whisper-agent-bus-v1"

	// Standard cross-shell / cross-environment / cross-harness message kinds.
	AgentKindTaskDispatch    = "task_dispatch"
	AgentKindWarrantDelegate = "warrant_delegate"
	AgentKindEvidenceReceipt = "evidence_receipt"
	AgentKindStatusReply     = "status_reply"
	AgentKindHandoff         = "handoff"
	AgentKindHaltSignal      = "halt_signal"
	AgentKindCapabilityLease = "capability_lease"
	AgentKindMemorySync      = "memory_sync"
)

// AgentBusRoute describes the authenticated routing metadata for an encrypted cross-shell,
// cross-environment, or cross-harness agent/Familiar packet carried inside a Whisper SealedEnvelope.
// Plaintext prompts, code, and secrets stay encrypted inside SealedEnvelope.CiphertextB64.
type AgentBusRoute struct {
	FromHarness           string // e.g. "ullumii", "gnosh.ai", "shell", "mcp", "gno-realm", "local-llm"
	FromEnv               string // e.g. "linux-docker", "windows-pwsh", "wsl", "cloud-worker"
	FromAgentID           string
	ToHarness             string
	ToEnv                 string
	ToAgentID             string
	Kind                  string // AgentKind*
	CorrelationID         string
	ParentWarrantDigest   string // optional 64-hex digest linking to gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/assurance
	EvidenceRootHex       string // optional 64-hex RFC 6962 accumulator root
	CapabilityDigestHex   string // optional 64-hex Familiar CapabilityToken digest
	MemoryRecallDigestHex string // optional 64-hex MemoryRecallProof digest
}

// Validate checks routing metadata fields before hashing or sealing.
func (r AgentBusRoute) Validate() error {
	if r.FromHarness == "" || r.FromAgentID == "" {
		return errors.New("fromHarness and fromAgentID are required")
	}
	if r.ToHarness == "" || r.ToAgentID == "" {
		return errors.New("toHarness and toAgentID are required")
	}
	switch r.Kind {
	case AgentKindTaskDispatch, AgentKindWarrantDelegate, AgentKindEvidenceReceipt,
		AgentKindStatusReply, AgentKindHandoff, AgentKindHaltSignal,
		AgentKindCapabilityLease, AgentKindMemorySync:
	default:
		return errors.New("unsupported agent bus message kind: " + r.Kind)
	}
	if r.CorrelationID == "" || len(r.CorrelationID) > 64 {
		return errors.New("correlationID must be 1..64 characters")
	}
	if r.ParentWarrantDigest != "" {
		if _, err := assurance.ParseDigest(r.ParentWarrantDigest); err != nil {
			return errors.New("parentWarrantDigest: " + err.Error())
		}
	}
	if r.EvidenceRootHex != "" {
		if _, err := assurance.ParseDigest(r.EvidenceRootHex); err != nil {
			return errors.New("evidenceRootHex: " + err.Error())
		}
	}
	if r.CapabilityDigestHex != "" {
		if _, err := assurance.ParseDigest(r.CapabilityDigestHex); err != nil {
			return errors.New("capabilityDigestHex: " + err.Error())
		}
	}
	if r.MemoryRecallDigestHex != "" {
		if _, err := assurance.ParseDigest(r.MemoryRecallDigestHex); err != nil {
			return errors.New("memoryRecallDigestHex: " + err.Error())
		}
	}
	return nil
}

// Encode serializes AgentBusRoute into canonical length-prefixed big-endian bytes.
func (r AgentBusRoute) Encode() []byte {
	out := make([]byte, 0, 256)
	out = appendStr(out, DomainAgentBus)
	out = append(out, EncodingVersion)
	out = appendStr(out, r.FromHarness)
	out = appendStr(out, r.FromEnv)
	out = appendStr(out, r.FromAgentID)
	out = appendStr(out, r.ToHarness)
	out = appendStr(out, r.ToEnv)
	out = appendStr(out, r.ToAgentID)
	out = appendStr(out, r.Kind)
	out = appendStr(out, r.CorrelationID)
	out = appendStr(out, r.ParentWarrantDigest)
	out = appendStr(out, r.EvidenceRootHex)
	out = appendStr(out, r.CapabilityDigestHex)
	out = appendStr(out, r.MemoryRecallDigestHex)
	return out
}

// Digest returns SHA-256(Encode()) for binding route metadata to encrypted envelopes.
func (r AgentBusRoute) Digest() [32]byte {
	return sha256.Sum256(r.Encode())
}

// LeafHash returns the RFC 6962 leaf hash of this cross-harness route commitment.
func (r AgentBusRoute) LeafHash() [32]byte {
	return assurance.LeafHash(r.Encode())
}

// BindAgentEnvelopeCommitment computes SHA-256(routeDigest || payloadCommitment) so both
// the encrypted ciphertext and the cross-harness route metadata are tamper-evident together.
func BindAgentEnvelopeCommitment(route AgentBusRoute, payloadCommitmentHex string) (string, error) {
	if err := route.Validate(); err != nil {
		return "", err
	}
	pDig, err := assurance.ParseDigest(payloadCommitmentHex)
	if err != nil {
		return "", err
	}
	rDig := route.Digest()
	buf := make([]byte, 0, 8+64)
	buf = binary.BigEndian.AppendUint32(buf, 64)
	buf = append(buf, rDig[:]...)
	buf = append(buf, pDig[:]...)
	return assurance.Hex(sha256.Sum256(buf)), nil
}
