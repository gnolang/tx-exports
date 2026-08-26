package types

type Status uint8

const (
	StatusUnknown Status = 0
	StatusActive  Status = 1
	StatusExpired Status = 2
	StatusFrozen  Status = 3
)

// ConsensusStateUpdate carries the height-stamped consensus and client state
// bytes a light client returns after verifying a header update.
type ConsensusStateUpdate struct {
	Height              Height
	ConsensusStateBytes []byte
	ClientStateBytes    []byte
}

func NewConsensusStateUpdate(height Height, consensusStateBytes, clientStateBytes []byte) ConsensusStateUpdate {
	return ConsensusStateUpdate{
		Height:              height,
		ConsensusStateBytes: consensusStateBytes,
		ClientStateBytes:    clientStateBytes,
	}
}
