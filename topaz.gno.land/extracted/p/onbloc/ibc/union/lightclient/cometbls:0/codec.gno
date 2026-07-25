package cometbls

import (
	abienc "gno.land/p/onbloc/encoding/abi"
	"gno.land/p/onbloc/ibc/union/types"
)

// Wire formats for the cometbls client and consensus state.
//
// ibc-union heights carry a single revision (revision 0), so only the revision
// height is encoded; decoding rebuilds the Height with types.NewHeight.

var clientStateSchema = abienc.Schema{Fields: []abienc.Field{
	{Type: abienc.TypeBytes32},
	{Type: abienc.TypeUint64},
	{Type: abienc.TypeUint64},
	{Type: abienc.TypeUint64},
	{Type: abienc.TypeUint64},
	{Type: abienc.TypeBytes32},
}}

var consensusStateSchema = abienc.Schema{Fields: []abienc.Field{
	{Type: abienc.TypeUint64},  // Timestamp
	{Type: abienc.TypeBytes32}, // Root (app hash)
	{Type: abienc.TypeBytes32}, // NextValidatorsHash
}}

func EncodeClientState(m *ClientState) ([]byte, error) {
	var chainIdWord [32]byte

	chainBytes := []byte(m.ChainID)
	if len(chainBytes) > 31 {
		chainBytes = chainBytes[:31]
	}

	copy(chainIdWord[:], chainBytes)

	return abienc.Encode(clientStateSchema, []any{
		chainIdWord,
		m.TrustingPeriod,
		m.MaxClockDrift,
		uint64(m.FrozenHeight.RevisionHeight),
		uint64(m.LatestHeight.RevisionHeight),
		[32]byte(m.ContractAddress),
	})
}

func DecodeClientState(buf []byte) (*ClientState, error) {
	vals, err := abienc.Decode(clientStateSchema, buf)
	if err != nil {
		return nil, err
	}

	chainIdWord := vals[0].([32]byte)
	chainID := trimNullBytes(chainIdWord)
	trustingPeriod := vals[1].(uint64)
	maxClockDrift := vals[2].(uint64)
	frozenHeight := types.NewHeight(vals[3].(uint64))
	latestHeight := types.NewHeight(vals[4].(uint64))
	contractAddress := vals[5].([32]byte)

	return NewClientState(
		chainID,
		trustingPeriod,
		0,
		maxClockDrift,
		frozenHeight,
		latestHeight,
		contractAddress,
	), nil
}

// EncodeConsensusState ABI-encodes a ConsensusState (96 bytes).
// Root.Hash must be exactly 32 bytes.
func EncodeConsensusState(cs *ConsensusState) ([]byte, error) {
	appHash, err := toBytes32(cs.Root.Hash)
	if err != nil {
		return nil, err
	}

	validatorsHash, err := toBytes32(cs.NextValidatorsHash)
	if err != nil {
		return nil, err
	}

	return abienc.Encode(
		consensusStateSchema,
		[]any{cs.Timestamp, appHash, validatorsHash},
	)
}

func DecodeConsensusState(buf []byte) (*ConsensusState, error) {
	vals, err := abienc.Decode(consensusStateSchema, buf)
	if err != nil {
		return nil, err
	}

	var cs ConsensusState

	rootHash, ok := vals[1].([32]byte)
	if !ok {
		return nil, ErrDecodeState
	}

	nextValidatorsHash, ok := vals[2].([32]byte)
	if !ok {
		return nil, ErrDecodeState
	}

	cs.Timestamp = vals[0].(uint64)
	cs.Root.Hash = rootHash[:]
	cs.NextValidatorsHash = nextValidatorsHash[:]

	return &cs, nil
}

func trimNullBytes(b [32]byte) string {
	end := 32
	for end > 0 && b[end-1] == 0 {
		end--
	}

	return string(b[:end])
}
