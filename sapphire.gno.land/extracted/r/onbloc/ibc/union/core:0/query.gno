package core

import (
	"strconv"

	"gno.land/p/onbloc/ibc/union/types"
)

// QueryClientState returns the client state bytes as a hex string, or an error
// when the client is missing.
func QueryClientState(clientId types.ClientId) (string, error) {
	bz, ok := store.ClientStateBytes(clientId)
	if !ok {
		return "", makeError(ErrClientStateNotFound)
	}

	return hexString(bz), nil
}

// QueryConsensusState returns the consensus state bytes at a given height as a
// hex string, or an error when missing.
func QueryConsensusState(clientId types.ClientId, height uint64) (string, error) {
	bz, ok := store.ConsensusStateBytes(clientId, types.NewHeight(height))
	if !ok {
		return "", makeError(ErrConsensusStateNotFound)
	}

	return hexString(bz), nil
}

// QueryConnection returns the ABI-encoded connection as a hex string, or an
// error when the connection is missing.
func QueryConnection(connectionId types.ConnectionId) (string, error) {
	conn, ok := store.GetConnection(connectionId)
	if !ok {
		return "", makeError(ErrConnectionNotFound)
	}

	bz, err := conn.EncodeABI()
	if err != nil {
		return "", err
	}

	return hexString(bz), nil
}

// QueryChannel returns the ABI-encoded channel as a hex string, or an error
// when the channel is missing.
func QueryChannel(channelId types.ChannelId) (string, error) {
	channel, ok := store.GetChannel(channelId)
	if !ok {
		return "", makeError(ErrChannelNotFound)
	}

	bz, err := channel.EncodeABI()
	if err != nil {
		return "", err
	}

	return hexString(bz), nil
}

// GetClientStatus returns the client status as a uint8 string ("1"=Active,
// "2"=Expired, "3"=Frozen), or an error when the client is missing.
func GetClientStatus(clientId types.ClientId) (string, error) {
	lc, ok := store.GetLightClient(clientId)
	if !ok {
		return strconv.FormatUint(uint64(types.StatusUnknown), 10), makeError(ErrClientNotFound)
	}

	return strconv.FormatUint(uint64(lc.Status().ToType()), 10), nil
}
