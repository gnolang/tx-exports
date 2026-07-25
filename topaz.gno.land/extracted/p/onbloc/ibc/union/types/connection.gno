package types

import "gno.land/p/onbloc/encoding/abi"

type ConnectionState uint8

const (
	ConnectionStateUnknown ConnectionState = 0
	ConnectionStateInit    ConnectionState = 1
	ConnectionStateTryOpen ConnectionState = 2
	ConnectionStateOpen    ConnectionState = 3
)

type Connection struct {
	State                    ConnectionState
	ClientId                 ClientId
	CounterpartyClientId     ClientId
	CounterpartyConnectionId ConnectionId
}

func (c Connection) EncodeABI() ([]byte, error) {
	schema := abi.Schema{Fields: []abi.Field{
		{Type: abi.TypeUint8},
		{Type: abi.TypeUint32},
		{Type: abi.TypeUint32},
		{Type: abi.TypeUint32},
	}}

	bz, err := abi.Encode(schema, []any{
		uint8(c.State),
		uint32(c.ClientId),
		uint32(c.CounterpartyClientId),
		uint32(c.CounterpartyConnectionId),
	})
	if err != nil {
		return nil, err
	}

	return bz, nil
}

func NewConnection(state ConnectionState, clientId, counterpartyClientId ClientId, counterpartyConnectionId ConnectionId) Connection {
	return Connection{
		State:                    state,
		ClientId:                 clientId,
		CounterpartyClientId:     counterpartyClientId,
		CounterpartyConnectionId: counterpartyConnectionId,
	}
}
