package core

import (
	"encoding/hex"

	"gno.land/p/onbloc/ibc/union/types"
)

func keccak(bz []byte) types.H256 {
	return types.Keccak(bz)
}

// ABI-encoding helpers wrap the pure union/types encoders, which return an
// error (encoding can fail). core treats an encoding failure as a fatal
// invariant violation and panics, matching the Union spec's revert-on-failure
// semantics.

func commitPacketHash(packet types.Packet) types.H256 {
	h, err := types.CommitPacket(packet)
	if err != nil {
		panic(err)
	}

	return h
}

func commitPacketsHash(packets []types.Packet) types.H256 {
	h, err := types.CommitPackets(packets)
	if err != nil {
		panic(err)
	}

	return h
}

func packetCommitmentPath(packet types.Packet) types.H256 {
	h, err := types.PacketCommitmentPath(packet)
	if err != nil {
		panic(err)
	}

	return h
}

func packetAcknowledgementPath(packet types.Packet) types.H256 {
	h, err := types.PacketAcknowledgementPath(packet)
	if err != nil {
		panic(err)
	}

	return h
}

func channelValue(channel types.Channel) types.H256 {
	bz, err := channel.EncodeABI()
	if err != nil {
		panic(err)
	}

	return keccak(bz)
}

func connectionValue(connection types.Connection) types.H256 {
	bz, err := connection.EncodeABI()
	if err != nil {
		panic(err)
	}

	return keccak(bz)
}

// h256Bytes returns a fresh byte slice containing h.
//
// Use it when passing package-level types.H256 values such as types.COMMITMENT_MAGIC to
// foreign-realm light clients. ics23 may copy and append against the input, so
// callers should pass a freshly allocated slice.
func h256Bytes(h types.H256) []byte {
	out := make([]byte, len(h))
	copy(out, h[:])

	return out
}

// cloneChannel returns a core-realm-owned copy of c with its byte field laundered,
// so persisting the copy does not taint the caller's channel (and vice versa).
// Without this, storing the channel makes its shared CounterpartyPortId slice
// externally stored, and the caller's later use (e.g. event emission) panics with
// "illegal conversion of readonly or externally stored value". Bytes.Clone copies
// the bytes element-wise (the only laundering gno's borrow rules permit on a
// foreign slice).
func cloneChannel(c types.Channel) types.Channel {
	return types.Channel{
		State:                 c.State,
		ConnectionId:          c.ConnectionId,
		CounterpartyChannelId: c.CounterpartyChannelId,
		CounterpartyPortId:    c.CounterpartyPortId.Clone(),
		Version:               c.Version,
	}
}

func hexString(b []byte) string {
	return "0x" + hex.EncodeToString(b)
}

// hexAttr encodes b as a lowercase 0x-prefixed hexadecimal string for use in
// chain.Emit attributes.
//
// Use hexAttr for binary attribute values. Converting arbitrary []byte values
// directly to string is lossy for non-UTF-8 input.
func hexAttr(b []byte) string {
	return hexString(b)
}

// hexAttrLen returns the length of b after hexAttr encoding.
//
// It avoids building the encoded string on validation paths that only need to
// compare against an event attribute size budget.
func hexAttrLen(b []byte) int {
	return len(b)*2 + 2
}

func h256String(h types.H256) string {
	return hexString(h[:])
}
