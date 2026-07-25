package ics23_mpt

const ClientType = "state-lens/ics23/mpt"

// ClientState mirrors Union's state-lens ClientState<ics23-mpt Extra>.
//
// The generic Rust form is flattened here:
//
//	(string,uint32,uint32,uint64,uint16,uint16,uint16)
//
// L1ClientID is the client on this chain tracking the settlement chain.
// L2ClientID is the client on the settlement chain tracking the chain whose
// state this state-lens client exposes.
type ClientState struct {
	L2ChainID         string
	L1ClientID        uint32
	L2ClientID        uint32
	L2LatestHeight    uint64
	TimestampOffset   uint16
	StateRootOffset   uint16
	StorageRootOffset uint16
}

// ConsensusState mirrors state-lens-ics23-mpt ConsensusState.
type ConsensusState struct {
	Timestamp   uint64 // nanoseconds since Unix epoch
	StateRoot   []byte // bytes32
	StorageRoot []byte // bytes32
}

// Header is the state-lens ClientMessage used to update the client.
type Header struct {
	L1Height              uint64
	L2Height              uint64
	L2ConsensusStateProof []byte
	L2ConsensusState      []byte
}
