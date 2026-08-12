package cometbls

type ConsensusState struct {
	Timestamp          uint64
	Root               MerkleRoot
	NextValidatorsHash []byte
}

func NewConsensusState(
	timestamp uint64,
	root MerkleRoot,
	nextValidatorsHash []byte,
) *ConsensusState {
	return &ConsensusState{
		Timestamp:          timestamp,
		Root:               root,
		NextValidatorsHash: nextValidatorsHash,
	}
}

func (ConsensusState) ClientType() string {
	return ClientType
}

func (cs *ConsensusState) GetRoot() MerkleRoot {
	return cs.Root
}

func (cs *ConsensusState) GetRootHash() []byte {
	return cs.Root.Hash
}

func (cs *ConsensusState) GetTimestamp() uint64 {
	return cs.Timestamp
}

func (cs *ConsensusState) GetNextValidatorsHash() []byte {
	return cs.NextValidatorsHash
}

func (cs *ConsensusState) ValidateBasic() error {
	if cs.Root.Hash == nil || cs.Root.Empty() {
		return errorWithDetails(ErrInvalidConsensus, "root hash cannot be nil")
	}

	if err := validateHash(cs.NextValidatorsHash); err != nil {
		return errorWithDetails(ErrInvalidNextValidatorsHash, err.Error())
	}

	return nil
}
