package cometbls

import (
	"crypto/cometblszk"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/ibc/union/types"
)

type Header struct {
	SignedHeader       *LightHeader
	TrustedHeight      *types.Height
	ZeroKnowledgeProof []byte
}

func NewHeader(
	signedHeader *LightHeader,
	trustedHeight *types.Height,
	zeroKnowledgeProof []byte,
) *Header {
	return &Header{
		SignedHeader:       signedHeader,
		TrustedHeight:      trustedHeight,
		ZeroKnowledgeProof: zeroKnowledgeProof,
	}
}

func (Header) ClientType() string {
	return ClientType
}

func (h *Header) ConsensusState() *ConsensusState {
	return &ConsensusState{
		Timestamp:          uint64(h.GetTime().UnixNano()),
		Root:               MerkleRoot{Hash: h.SignedHeader.AppHash},
		NextValidatorsHash: h.SignedHeader.NextValidatorsHash,
	}
}

// GetHeight returns the height of the signed (untrusted) header. CometBLS
// carries a single revision, so it shares the trusted height's revision number.
func (h *Header) GetHeight() types.Height {
	return types.NewHeightWithRevision(h.TrustedHeight.RevisionNumber, uint64(h.SignedHeader.Height))
}

func (h *Header) GetTime() time.Time {
	return time.Unix(h.SignedHeader.TimeSeconds, int64(h.SignedHeader.TimeNanos)).UTC()
}

// ValidateBasic calls the SignedHeader ValidateBasic function and checks
// that validatorsets are not nil.
// NOTE: TrustedHeight and TrustedValidators may be empty when creating client
// with MsgCreateClient
func (h *Header) ValidateBasic() error {
	if h.SignedHeader == nil {
		return errorWithDetails(ErrInvalidHeader, "signed header cannot be nil")
	}

	if len(h.ZeroKnowledgeProof) == 0 {
		return errorWithDetails(ErrInvalidHeader, "zero-knowledge proof cannot be empty")
	}

	// TrustedHeight is less than Header for updates and misbehaviour
	if h.TrustedHeight.GTE(h.GetHeight()) {
		return errorWithDetails(
			ErrInvalidHeaderHeight,
			ufmt.Sprintf("TrustedHeight %d must be less than header height %d", h.TrustedHeight, h.GetHeight()),
		)
	}

	return nil
}

// LightHeader is the bespoke CometBLS light header. It is an alias of
// crypto/cometblszk.LightHeader so a SignedHeader feeds VerifyZKP directly
// without re-mapping, and its TimeSeconds/TimeNanos split mirrors the ABI wire
// format (see headerSchema in encoding.gno).
type LightHeader = cometblszk.LightHeader

func NewLightHeader(height, timeSeconds int64, timeNanos int32, validatorsHash, nextValidatorsHash, appHash []byte) *LightHeader {
	return &LightHeader{
		Height:             height,
		TimeSeconds:        timeSeconds,
		TimeNanos:          timeNanos,
		ValidatorsHash:     validatorsHash,
		NextValidatorsHash: nextValidatorsHash,
		AppHash:            appHash,
	}
}
