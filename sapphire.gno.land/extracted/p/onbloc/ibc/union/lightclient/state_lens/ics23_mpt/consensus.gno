package ics23_mpt

import (
	"bytes"
	"encoding/binary"
	"errors"

	"gno.land/p/onbloc/verifier/evm/storage"
)

var (
	ErrConsensusStateTooShort = errors.New("ics23mpt: l2 consensus state too short")
	ErrInvalidCommitmentKey   = errors.New("ics23mpt: invalid commitment key")
)

// ExtractConsensusState parses the L2 consensus state bytes into a
// ConsensusState using the byte offsets recorded in this client state. The
// state-lens client trusts the counterparty's opaque L2 consensus blob and
// reads timestamp / state root / storage root from fixed offsets.
func (cs ClientState) ExtractConsensusState(data []byte) (ConsensusState, error) {
	timestamp, err := extractUint64(data, int(cs.TimestampOffset))
	if err != nil {
		return ConsensusState{}, err
	}

	stateRoot, err := extractBytes32(data, int(cs.StateRootOffset))
	if err != nil {
		return ConsensusState{}, err
	}

	storageRoot, err := extractBytes32(data, int(cs.StorageRootOffset))
	if err != nil {
		return ConsensusState{}, err
	}

	return ConsensusState{
		Timestamp:   timestamp,
		StateRoot:   stateRoot,
		StorageRoot: storageRoot,
	}, nil
}

func extractUint64(data []byte, offset int) (uint64, error) {
	if offset < 0 || offset+8 > len(data) {
		return 0, ErrConsensusStateTooShort
	}

	return binary.BigEndian.Uint64(data[offset : offset+8]), nil
}

func extractBytes32(data []byte, offset int) ([]byte, error) {
	if offset < 0 || offset+32 > len(data) {
		return nil, ErrConsensusStateTooShort
	}

	out := make([]byte, 32)
	copy(out, data[offset:offset+32])

	return out, nil
}

// VerifyCommitmentKey checks that proofKey matches the IBC commitment key
// derived from path. It rejects proofs whose key does not bind to the
// expected commitment path.
func VerifyCommitmentKey(path []byte, proofKey []byte) error {
	expected, err := storage.IBCCommitmentKey(path)
	if err != nil {
		return ErrInvalidCommitmentKey
	}

	if !bytes.Equal(expected[:], proofKey) {
		return ErrInvalidCommitmentKey
	}

	return nil
}
