package lightclient

import "gno.land/p/onbloc/ibc/union/types"

// ClientImpl is the registered light client implementation for a client type.
// It mirrors Union's ClientRegistry value: Union stores a client contract
// address, while this Gno core stores a constructor function that instantiates
// the live light client for a submitted client state.
// Union references:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/core/src/contract.rs#L849-L865
type ClientImpl func(clientStateBytes, consensusStateBytes []byte) (Interface, error)

type Status string

const (
	Active Status = "Active"

	Frozen Status = "Frozen"

	Expired Status = "Expired"

	Unknown Status = "Unknown"

	Unauthorized Status = "Unauthorized"
)

func (s Status) ToType() types.Status {
	switch s {
	case Active:
		return types.StatusActive
	case Expired:
		return types.StatusExpired
	case Frozen:
		return types.StatusFrozen
	default:
		return types.StatusUnknown
	}
}

type Interface interface {
	VerifyMembership(height uint64, key []byte, proof []byte, value []byte) error

	VerifyNonMembership(height uint64, key []byte, proof []byte) error

	GetTimestamp() types.Timestamp

	// GetTimestampAtHeight returns the consensus timestamp recorded at a specific
	// height. Packet timeout verification needs the counterparty timestamp at the
	// proof height, not just the latest. Returns an error when no consensus state
	// exists at the height.
	GetTimestampAtHeight(height uint64) (types.Timestamp, error)

	GetLatestHeight() uint64

	GetCounterpartyChainID() string

	Status() Status

	VerifyHeader(caller address, header []byte, relayer address) (types.StateUpdate, error)

	VerifyCreation(caller address, relayer address) (types.ClientCreationResult, error)

	Misbehaviour(caller address, misbehaviour []byte, relayer address) ([]byte, error)
}
