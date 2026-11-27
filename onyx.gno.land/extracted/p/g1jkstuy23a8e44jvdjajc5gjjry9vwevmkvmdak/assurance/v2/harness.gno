package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

const (
	HarnessGnosh      = "gnosh.ai"
	HarnessUllumii    = "ullumii"
	HarnessWhisperBus = "whisper-bus"
	HarnessGnoRealm   = "gno-realm"
	DomainHarness     = "arobi-assurance-harness-frame-v1"
)

// HarnessFrame binds an external agent harness execution frame (such as a gnosh.ai `mem`
// stack frame or an Ullumii governed work handoff / MCP tool call) into the Arobi Assurance
// evidence spine so every frame transition is cryptographically anchored on Gno.land.
type HarnessFrame struct {
	Harness       string // HarnessGnosh, HarnessUllumii, HarnessWhisperBus, HarnessGnoRealm
	SessionID     string
	FrameID       string
	ParentFrameID string
	Action        string
	Target        string
	Height        int64
}

// Encode serializes HarnessFrame into canonical big-endian bytes.
func (f HarnessFrame) Encode() []byte {
	out := make([]byte, 0, 160)
	out = appendString(out, DomainHarness)
	out = append(out, EncodingVersion)
	out = appendString(out, f.Harness)
	out = appendString(out, f.SessionID)
	out = appendString(out, f.FrameID)
	out = appendString(out, f.ParentFrameID)
	out = appendString(out, f.Action)
	out = appendString(out, f.Target)
	out = binary.BigEndian.AppendUint64(out, uint64(f.Height))
	return out
}

// Digest returns SHA-256(Encode()).
func (f HarnessFrame) Digest() [32]byte {
	return sha256.Sum256(f.Encode())
}

// ExecuteHarnessFrame executes an action originating from gnosh.ai, Ullumii, or a cross-shell
// Whisper Agent Bus dispatch. The canonical HarnessFrame digest is folded into ContextDigest
// before policy evaluation so the resulting DecisionReceipt, EffectWarrant, and EffectClosure
// are cryptographically bound to the exact harness session and stack frame.
func (a *Agent) ExecuteHarnessFrame(
	frame HarnessFrame,
	caller string,
	input []byte,
	extraContext []byte,
	budgetUgnot int64,
) ([]byte, EvidenceBundle, error) {
	if frame.Harness == "" || frame.SessionID == "" || frame.FrameID == "" {
		return nil, EvidenceBundle{}, errors.New("harness frame requires non-empty Harness, SessionID, and FrameID")
	}
	fDig := frame.Digest()
	boundCtx := make([]byte, 0, 32+len(extraContext))
	boundCtx = append(boundCtx, fDig[:]...)
	boundCtx = append(boundCtx, extraContext...)
	return a.Execute(caller, frame.Action, frame.Target, input, boundCtx, budgetUgnot, frame.Height)
}
