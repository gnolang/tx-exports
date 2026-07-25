package cometbls

import (
	"errors"

	"gno.land/p/aib/encoding/proto"
	abienc "gno.land/p/onbloc/encoding/abi"
	"gno.land/p/onbloc/ibc/union/types"
)

// Wire formats for CometBLS client messages.
//
// Each light client owns the parsing of its own client messages, since the
// header layout differs per client. CometBLS uses:
//   - Header: Ethereum ABI tuple (mirrors Union's Solidity Header struct)
//   - Misbehaviour: protobuf with two embedded ABI-encoded headers
//
// Header ABI layout (Solidity params tuple form):
//
//	[0] uint64  Height
//	[1] uint64  TimeSeconds
//	[2] uint64  TimeNanos
//	[3] bytes32 ValidatorsHash
//	[4] bytes32 NextValidatorsHash
//	[5] bytes32 AppHash
//	[6] uint64  TrustedHeight
//	[7] bytes   ZeroKnowledgeProof (dynamic)
var headerSchema = abienc.Schema{Fields: []abienc.Field{
	{Type: abienc.TypeUint64},
	{Type: abienc.TypeUint64},
	{Type: abienc.TypeUint64},
	{Type: abienc.TypeBytes32},
	{Type: abienc.TypeBytes32},
	{Type: abienc.TypeBytes32},
	{Type: abienc.TypeUint64},
	{Type: abienc.TypeBytes},
}}

// maxTimeNanos bounds the sub-second component of a header timestamp.
const maxTimeNanos = 1_000_000_000

// EncodeHeader ABI-encodes a Header. ValidatorsHash, NextValidatorsHash and
// AppHash must each be exactly 32 bytes.
func EncodeHeader(h *Header) ([]byte, error) {
	if h == nil || h.SignedHeader == nil {
		return nil, errors.New("nil header")
	}

	lh := h.SignedHeader

	vh, err := toBytes32(lh.ValidatorsHash)
	if err != nil {
		return nil, err
	}

	nvh, err := toBytes32(lh.NextValidatorsHash)
	if err != nil {
		return nil, err
	}

	ah, err := toBytes32(lh.AppHash)
	if err != nil {
		return nil, err
	}

	var trustedHeight uint64
	if h.TrustedHeight != nil {
		trustedHeight = h.TrustedHeight.RevisionHeight
	}

	return abienc.Encode(headerSchema, []any{
		uint64(lh.Height),
		uint64(lh.TimeSeconds),
		uint64(lh.TimeNanos),
		vh, nvh, ah,
		trustedHeight,
		h.ZeroKnowledgeProof,
	})
}

// DecodeHeader ABI-decodes a Header.
func DecodeHeader(buf []byte) (*Header, error) {
	vals, err := abienc.Decode(headerSchema, buf)
	if err != nil {
		return nil, errors.New("" + err.Error())
	}

	timeSeconds := vals[1].(uint64)

	timeNanos := vals[2].(uint64)
	if timeNanos >= maxTimeNanos {
		return nil, errors.New("TimeNanos out of range")
	}

	vh := vals[3].([32]byte)
	nvh := vals[4].([32]byte)
	ah := vals[5].([32]byte)

	trustedHeight := types.NewHeight(vals[6].(uint64))

	return &Header{
		SignedHeader: &LightHeader{
			Height:             int64(vals[0].(uint64)),
			TimeSeconds:        int64(timeSeconds),
			TimeNanos:          int32(timeNanos),
			ValidatorsHash:     vh[:],
			NextValidatorsHash: nvh[:],
			AppHash:            ah[:],
		},
		TrustedHeight:      &trustedHeight,
		ZeroKnowledgeProof: vals[7].([]byte),
	}, nil
}

// EncodeMisbehaviour protobuf-encodes a Misbehaviour: field 1 is Header1 and
// field 2 is Header2, each an ABI-encoded header.
func EncodeMisbehaviour(m *Misbehaviour) ([]byte, error) {
	if m == nil {
		return nil, errors.New("nil misbehaviour")
	}

	h1, err := EncodeHeader(m.Header1)
	if err != nil {
		return nil, err
	}

	h2, err := EncodeHeader(m.Header2)
	if err != nil {
		return nil, err
	}

	buf := make([]byte, 0, len(h1)+len(h2)+8)
	buf = proto.AppendLengthDelimited(buf, 1, h1)
	buf = proto.AppendLengthDelimited(buf, 2, h2)

	return buf, nil
}

// DecodeMisbehaviour protobuf-decodes a Misbehaviour.
func DecodeMisbehaviour(buf []byte) (*Misbehaviour, error) {
	m := &Misbehaviour{}

	pos := 0
	for pos < len(buf) {
		fieldNum, wireType, newPos, err := decodeTag(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos

		if wireType != proto.LEN {
			pos, err = skipField(buf, pos, wireType)
			if err != nil {
				return nil, err
			}

			continue
		}

		s, newPos, err := proto.DecodeString(buf, pos)
		if err != nil {
			return nil, err
		}

		pos = newPos

		header, err := DecodeHeader([]byte(s))
		if err != nil {
			return nil, err
		}

		switch fieldNum {
		case 1:
			m.Header1 = header
		case 2:
			m.Header2 = header
		}
	}

	if m.Header1 == nil || m.Header2 == nil {
		return nil, errors.New("misbehaviour missing a header")
	}

	return m, nil
}

// toBytes32 converts a 32-byte slice into a [32]byte array, returning an error
// for any other length.
func toBytes32(b []byte) ([32]byte, error) {
	var out [32]byte
	if len(b) != 32 {
		return out, errors.New("must be 32 bytes")
	}

	copy(out[:], b)

	return out, nil
}
