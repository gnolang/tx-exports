package types

// COMMITMENT_MAGIC, COMMITMENT_MAGIC_ACK and mergeAck are defined in path.gno.

// CommitPacket returns the Union commitment hash of a single packet.
func CommitPacket(packet Packet) (H256, error) {
	return CommitPackets([]Packet{packet})
}

// CommitPackets returns the Union commitment hash of a packet batch: the
// keccak of the top-level-dynamic-wrapped ABI packet array.
func CommitPackets(packets []Packet) (H256, error) {
	encoded, err := encodeABIPacketArray(packets)
	if err != nil {
		return H256{}, err
	}

	return Keccak(wrapABIEncode(encoded)), nil
}

// MustCommit unwraps a commitment hash or panics on encoding errors.
func MustCommit(h H256, err error) H256 {
	if err != nil {
		panic(err)
	}

	return h
}

// CommitAck returns the Union commitment hash of a single acknowledgement.
func CommitAck(ack []byte) H256 {
	return CommitAcks([][]byte{ack})
}

// CommitAcks returns the Union commitment hash of an acknowledgement batch,
// with the leading byte replaced by the commitment magic.
func CommitAcks(acks [][]byte) H256 {
	return mergeAck(Keccak(wrapABIEncode(encodeABIBytesArray(acks))))
}
