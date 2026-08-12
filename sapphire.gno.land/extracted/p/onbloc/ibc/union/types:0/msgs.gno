package types

// Packet-lifecycle datagrams, mirroring the ibc-union-spec `Datagram` variants
// that carry packets (recv / acknowledgement / timeout / intent / batch).
// Proof heights are plain block numbers (u64), matching the spec.

// MsgPacketRecv delivers one or more packets to their destination, proven
// against the source chain's batch commitment.
type MsgPacketRecv struct {
	Packets     []Packet
	RelayerMsgs [][]byte
	Relayer     address
	Proof       []byte
	ProofHeight uint64
}

func NewMsgPacketRecv(packets []Packet, relayerMsgs [][]byte, proof []byte, proofHeight uint64) MsgPacketRecv {
	return MsgPacketRecv{
		Packets:     packets,
		RelayerMsgs: relayerMsgs,
		Proof:       proof,
		ProofHeight: proofHeight,
	}
}

// MsgPacketAcknowledgement settles sent packets against the acknowledgements
// committed on the destination chain.
type MsgPacketAcknowledgement struct {
	Packets          []Packet
	Acknowledgements [][]byte
	Proof            []byte
	ProofHeight      uint64
	Relayer          address
}

func NewMsgPacketAcknowledgement(packets []Packet, acknowledgements [][]byte, proof []byte, proofHeight uint64) MsgPacketAcknowledgement {
	return MsgPacketAcknowledgement{
		Packets:          packets,
		Acknowledgements: acknowledgements,
		Proof:            proof,
		ProofHeight:      proofHeight,
	}
}

// MsgPacketTimeout proves, via non-membership, that a packet was never received
// on the destination chain before its timeout.
type MsgPacketTimeout struct {
	Packet      Packet
	Proof       []byte
	ProofHeight uint64
	Relayer     address
}

func NewMsgPacketTimeout(packet Packet, proof []byte, proofHeight uint64) MsgPacketTimeout {
	return MsgPacketTimeout{
		Packet:      packet,
		Proof:       proof,
		ProofHeight: proofHeight,
	}
}

// MsgCommitMembershipProof verifies and commits a membership proof for later
// counterparty proof-lens reads.
type MsgCommitMembershipProof struct {
	ClientId    ClientId
	ProofHeight uint64
	Proof       []byte
	Path        []byte
	Value       []byte
}

func NewMsgCommitMembershipProof(clientId ClientId, proofHeight uint64, proof, path, value []byte) MsgCommitMembershipProof {
	return MsgCommitMembershipProof{
		ClientId:    clientId,
		ProofHeight: proofHeight,
		Proof:       proof,
		Path:        path,
		Value:       value,
	}
}

// MsgCommitNonMembershipProof verifies and commits a non-membership proof for
// later counterparty proof-lens reads.
type MsgCommitNonMembershipProof struct {
	ClientId    ClientId
	ProofHeight uint64
	Proof       []byte
	Path        []byte
}

func NewMsgCommitNonMembershipProof(clientId ClientId, proofHeight uint64, proof, path []byte) MsgCommitNonMembershipProof {
	return MsgCommitNonMembershipProof{
		ClientId:    clientId,
		ProofHeight: proofHeight,
		Proof:       proof,
		Path:        path,
	}
}

// MsgIntentPacketRecv lets a market maker fill packets ahead of proof, carrying
// per-packet market-maker messages instead of a membership proof.
type MsgIntentPacketRecv struct {
	Packets             []Packet
	MarketMakerMessages [][]byte
	MarketMaker         address
}

func NewMsgIntentPacketRecv(packets []Packet, marketMakerMessages [][]byte) MsgIntentPacketRecv {
	return MsgIntentPacketRecv{
		Packets:             packets,
		MarketMakerMessages: marketMakerMessages,
	}
}

// MsgBatchSend commits a batch of already-sent packets so they can be proven
// together.
type MsgBatchSend struct {
	Packets []Packet
}

func NewMsgBatchSend(packets []Packet) MsgBatchSend {
	return MsgBatchSend{
		Packets: packets,
	}
}

// MsgBatchAcks commits a batch of acknowledgements for received packets.
type MsgBatchAcks struct {
	Packets []Packet
	Acks    [][]byte
}

func NewMsgBatchAcks(packets []Packet, acks [][]byte) MsgBatchAcks {
	return MsgBatchAcks{
		Packets: packets,
		Acks:    acks,
	}
}

// MsgWriteAcknowledgement writes the acknowledgement for a previously received
// packet (the async-ack settlement path).
type MsgWriteAcknowledgement struct {
	Packet          Packet
	Acknowledgement []byte
}

func NewMsgWriteAcknowledgement(packet Packet, acknowledgement []byte) MsgWriteAcknowledgement {
	return MsgWriteAcknowledgement{
		Packet:          packet,
		Acknowledgement: acknowledgement,
	}
}
