package core

import (
	"strconv"

	"gno.land/p/onbloc/ibc/union/types"
)

// QueryClientState returns the client state bytes as a hex string, or an empty
// string when the client is missing.
func QueryClientState(clientId types.ClientId) string {
	bz, ok := store.ClientStateBytes(clientId)
	if !ok {
		return ""
	}

	return hexString(bz)
}

// QueryConsensusState returns the consensus state bytes at a given height as a
// hex string, or an empty string when missing.
func QueryConsensusState(clientId types.ClientId, height uint64) string {
	bz, ok := store.ConsensusStateBytes(clientId, types.NewHeight(height))
	if !ok {
		return ""
	}

	return hexString(bz)
}

// QueryConnection returns the ABI-encoded connection as a hex string, or an
// empty string when the connection is missing.
func QueryConnection(connectionId types.ConnectionId) string {
	conn, ok := store.GetConnection(connectionId)
	if !ok {
		return ""
	}
	bz, err := conn.EncodeABI()
	if err != nil {
		return ""
	}

	return hexString(bz)
}

// QueryChannel returns the ABI-encoded channel as a hex string, or an empty
// string when the channel is missing.
func QueryChannel(channelId types.ChannelId) string {
	channel, ok := store.GetChannel(channelId)
	if !ok {
		return ""
	}
	bz, err := channel.EncodeABI()
	if err != nil {
		return ""
	}

	return hexString(bz)
}

// GetClientStatus returns the client status as a uint8 string ("1"=Active,
// "2"=Expired, "3"=Frozen), or "0" when the client is missing.
func GetClientStatus(clientId types.ClientId) string {
	lc, ok := store.GetLightClient(clientId)
	if !ok {
		return strconv.FormatUint(uint64(types.StatusUnknown), 10)
	}

	return strconv.FormatUint(uint64(lc.Status().ToType()), 10)
}
