package ics23_mpt

import (
	"errors"

	abienc "gno.land/p/onbloc/encoding/abi"
)

var (
	clientStateSchema = abienc.Schema{Fields: []abienc.Field{
		{Type: abienc.TypeString},
		{Type: abienc.TypeUint32},
		{Type: abienc.TypeUint32},
		{Type: abienc.TypeUint64},
		{Type: abienc.TypeUint32},
		{Type: abienc.TypeUint32},
		{Type: abienc.TypeUint32},
	}}

	consensusStateSchema = abienc.Schema{Fields: []abienc.Field{
		{Type: abienc.TypeUint64},
		{Type: abienc.TypeBytes32},
		{Type: abienc.TypeBytes32},
	}}

	headerSchema = abienc.Schema{Fields: []abienc.Field{
		{Type: abienc.TypeUint64},
		{Type: abienc.TypeUint64},
		{Type: abienc.TypeBytes},
		{Type: abienc.TypeBytes},
	}}
)

func EncodeClientState(cs ClientState) ([]byte, error) {
	return abienc.Encode(clientStateSchema, []any{
		cs.L2ChainID,
		cs.L1ClientID,
		cs.L2ClientID,
		uint64(cs.L2LatestHeight),
		uint32(cs.TimestampOffset),
		uint32(cs.StateRootOffset),
		uint32(cs.StorageRootOffset),
	})
}

func DecodeClientState(buf []byte) (ClientState, error) {
	vals, err := abienc.Decode(clientStateSchema, buf)
	if err != nil {
		return ClientState{}, wrapErr(err)
	}

	timestampOffset, err := toUint16(vals[4].(uint32), "timestamp offset")
	if err != nil {
		return ClientState{}, err
	}

	stateRootOffset, err := toUint16(vals[5].(uint32), "state root offset")
	if err != nil {
		return ClientState{}, err
	}

	storageRootOffset, err := toUint16(vals[6].(uint32), "storage root offset")
	if err != nil {
		return ClientState{}, err
	}

	return ClientState{
		L2ChainID:         vals[0].(string),
		L1ClientID:        vals[1].(uint32),
		L2ClientID:        vals[2].(uint32),
		L2LatestHeight:    vals[3].(uint64),
		TimestampOffset:   timestampOffset,
		StateRootOffset:   stateRootOffset,
		StorageRootOffset: storageRootOffset,
	}, nil
}

func EncodeConsensusState(cs ConsensusState) ([]byte, error) {
	stateRoot, err := toBytes32(cs.StateRoot, "state root")
	if err != nil {
		return nil, err
	}

	storageRoot, err := toBytes32(cs.StorageRoot, "storage root")
	if err != nil {
		return nil, err
	}

	return abienc.Encode(consensusStateSchema, []any{
		cs.Timestamp,
		stateRoot,
		storageRoot,
	})
}

func DecodeConsensusState(buf []byte) (ConsensusState, error) {
	vals, err := abienc.Decode(consensusStateSchema, buf)
	if err != nil {
		return ConsensusState{}, wrapErr(err)
	}

	stateRoot := vals[1].([32]byte)
	storageRoot := vals[2].([32]byte)

	return ConsensusState{
		Timestamp:   vals[0].(uint64),
		StateRoot:   cloneBytes(stateRoot[:]),
		StorageRoot: cloneBytes(storageRoot[:]),
	}, nil
}

func EncodeHeader(h Header) ([]byte, error) {
	return abienc.Encode(headerSchema, []any{
		uint64(h.L1Height),
		uint64(h.L2Height),
		h.L2ConsensusStateProof,
		h.L2ConsensusState,
	})
}

func DecodeHeader(buf []byte) (Header, error) {
	vals, err := abienc.Decode(headerSchema, buf)
	if err != nil {
		return Header{}, wrapErr(err)
	}

	return Header{
		L1Height:              vals[0].(uint64),
		L2Height:              vals[1].(uint64),
		L2ConsensusStateProof: vals[2].([]byte),
		L2ConsensusState:      vals[3].([]byte),
	}, nil
}

// wrapErr prefixes a wrapped decode error with the package domain.
func wrapErr(err error) error {
	return errors.New("ics23mpt: " + err.Error())
}

func toUint16(v uint32, name string) (uint16, error) {
	if v > 0xFFFF {
		return 0, errors.New("ics23mpt: " + name + " exceeds uint16")
	}

	return uint16(v), nil
}

func toBytes32(b []byte, name string) ([32]byte, error) {
	if len(b) != 32 {
		return [32]byte{}, errors.New("ics23mpt: " + name + " must be 32 bytes")
	}

	var out [32]byte
	copy(out[:], b)

	return out, nil
}

func cloneBytes(b []byte) []byte {
	out := make([]byte, len(b))
	copy(out, b)

	return out
}
