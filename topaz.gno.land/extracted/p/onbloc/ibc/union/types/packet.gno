package types

import "gno.land/p/onbloc/encoding/abi"

type PacketStatus uint8

const (
	PacketStatusUnknown PacketStatus = 0
	PacketStatusSuccess PacketStatus = 1
	PacketStatusFailure PacketStatus = 2
	PacketStatusAsync   PacketStatus = 3
)

// MustBeZero is a u64 that is always zero. Union packets carry no timeout
// height (timeouts are expressed via the timestamp), so the ABI-encoded height
// field is fixed to zero, mirroring the ibc-union-spec MustBeZero type.
type MustBeZero uint64

func (MustBeZero) String() string { return "0" }

// Packet is a Union IBC packet. Mirroring the ibc-union-spec, the timeout
// height is fixed to zero (see MustBeZero) and only the timeout timestamp is
// meaningful.
type Packet struct {
	SourceChannelId      ChannelId
	DestinationChannelId ChannelId
	Data                 []byte
	TimeoutHeight        MustBeZero
	TimeoutTimestamp     Timestamp
}

func (p Packet) EncodeABI() ([]byte, error) {
	schema := abi.Schema{Fields: []abi.Field{
		{Type: abi.TypeUint32},
		{Type: abi.TypeUint32},
		{Type: abi.TypeBytes},
		{Type: abi.TypeUint64},
		{Type: abi.TypeUint64},
	}}

	bz, err := abi.Encode(schema, []any{
		uint32(p.SourceChannelId),
		uint32(p.DestinationChannelId),
		p.Data,
		uint64(0), // timeout height is always zero (MustBeZero)
		uint64(p.TimeoutTimestamp),
	})
	if err != nil {
		return nil, err
	}

	return bz, nil
}

func NewPacket(sourceChannelId, destinationChannelId ChannelId, data []byte, timeoutTimestamp Timestamp) Packet {
	return Packet{
		SourceChannelId:      sourceChannelId,
		DestinationChannelId: destinationChannelId,
		Data:                 data,
		TimeoutHeight:        0,
		TimeoutTimestamp:     timeoutTimestamp,
	}
}

// RecvPacketResult is the outcome an app returns from OnRecvPacket: the sync
// status and, for non-async results, the acknowledgement bytes to commit.
type RecvPacketResult struct {
	Status          PacketStatus
	Acknowledgement []byte
}

func NewRecvPacketResult(status PacketStatus, acknowledgement []byte) RecvPacketResult {
	return RecvPacketResult{Status: status, Acknowledgement: acknowledgement}
}
