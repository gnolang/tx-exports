package types

import (
	"strconv"

	"gno.land/p/onbloc/encoding/abi"
)

type ChannelId uint32

func (id ChannelId) String() string {
	return strconv.FormatUint(uint64(id), 10)
}

type ChannelState uint8

const (
	ChannelStateUnknown ChannelState = 0
	ChannelStateInit    ChannelState = 1
	ChannelStateTryOpen ChannelState = 2
	ChannelStateOpen    ChannelState = 3
	ChannelStateClosed  ChannelState = 4
)

type Channel struct {
	State                 ChannelState
	ConnectionId          ConnectionId
	CounterpartyChannelId ChannelId
	CounterpartyPortId    Bytes
	Version               string
}

func (c Channel) EncodeABI() ([]byte, error) {
	schema := abi.Schema{Fields: []abi.Field{
		{Type: abi.TypeUint8},
		{Type: abi.TypeUint32},
		{Type: abi.TypeUint32},
		{Type: abi.TypeBytes},
		{Type: abi.TypeString},
	}}

	bz, err := abi.Encode(schema, []any{
		uint8(c.State),
		uint32(c.ConnectionId),
		uint32(c.CounterpartyChannelId),
		c.CounterpartyPortId.Bytes(),
		c.Version,
	})
	if err != nil {
		return nil, err
	}

	return wrapABIEncode(bz), nil
}

func NewChannel(
	state ChannelState,
	connectionId ConnectionId,
	counterpartyChannelId ChannelId,
	counterpartyPortId Bytes,
	version string,
) Channel {
	return Channel{
		State:                 state,
		ConnectionId:          connectionId,
		CounterpartyChannelId: counterpartyChannelId,
		CounterpartyPortId:    counterpartyPortId,
		Version:               version,
	}
}
