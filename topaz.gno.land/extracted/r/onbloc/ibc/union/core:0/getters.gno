package core

import (
	"gno.land/p/onbloc/ibc/union/lightclient"
	"gno.land/p/onbloc/ibc/union/types"
)

// GetStatus returns the client's status, or an error when the client is missing.
func GetStatus(clientId types.ClientId) (types.Status, error) {
	return mustGetImpl().GetStatus(clientId)
}

// GetLightClient returns the live light client instance for a client, or
// (nil, false) when the client is missing.
func GetLightClient(clientId types.ClientId) (lightclient.Interface, bool) {
	return mustGetImpl().GetLightClient(clientId)
}

// GetClientType returns the registered client type for a client, or an error
// when the client is missing.
func GetClientType(clientId types.ClientId) (types.ClientType, error) {
	return mustGetImpl().GetClientType(clientId)
}

// GetClientImpl returns the impl identifier for a client (best-effort: type), or
// an error when the client is missing.
func GetClientImpl(clientId types.ClientId) (string, error) {
	return mustGetImpl().GetClientImpl(clientId)
}

// GetRegisteredClientType reports whether a client type is registered (best-effort).
func GetRegisteredClientType(clientType types.ClientType) bool {
	return mustGetImpl().GetRegisteredClientType(clientType)
}

// GetClientState returns the mirrored client state bytes, or an error when the
// client state is missing.
func GetClientState(clientId types.ClientId) ([]byte, error) {
	return mustGetImpl().GetClientStateBytes(clientId)
}

// GetConsensusState returns the consensus state bytes at a height, or an error
// when no consensus state is stored at that height.
func GetConsensusState(clientId types.ClientId, height types.Height) ([]byte, error) {
	return mustGetImpl().GetConsensusStateBytes(clientId, height)
}

// GetLatestHeight returns the light client's latest height, or an error when the
// client is missing.
func GetLatestHeight(clientId types.ClientId) (uint64, error) {
	return mustGetImpl().GetLatestHeight(clientId)
}

// GetTimestampAtHeight returns the consensus timestamp recorded at a height, or
// an error when the client is missing or has no consensus state at that height.
func GetTimestampAtHeight(clientId types.ClientId, height uint64) (types.Timestamp, error) {
	return mustGetImpl().GetTimestampAtHeight(clientId, height)
}

// GetConnection returns the typed connection record, or an error when the
// connection is missing.
func GetConnection(connectionId types.ConnectionId) (types.Connection, error) {
	return mustGetImpl().GetConnection(connectionId)
}

// GetBatchPackets returns the batch packet commitment for a batch hash, or an
// error when no batch packet commitment is stored for that hash.
func GetBatchPackets(batchHash types.H256) (types.H256, error) {
	return mustGetImpl().GetBatchPacketsCommitment(batchHash)
}

// GetBatchReceipts returns the batch receipt commitment for a batch hash, or an
// error when no batch receipt commitment is stored for that hash.
func GetBatchReceipts(batchHash types.H256) (types.H256, error) {
	return mustGetImpl().GetBatchReceiptsCommitment(batchHash)
}

// GetCommittedMembershipProof returns the committed membership proof value for
// the client/height/path key.
func GetCommittedMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte) (types.H256, error) {
	return mustGetImpl().GetCommittedMembershipProofCommitment(clientId, proofHeight, path)
}

// GetCommittedNonMembershipProof reports whether a non-membership proof
// commitment is stored for the key.
func GetCommittedNonMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte) bool {
	return mustGetImpl().GetCommittedNonMembershipProof(clientId, proofHeight, path)
}

// GetChannels returns all stored channel records.
func GetChannels() ([]types.Channel, error) {
	return mustGetImpl().GetChannels()
}

// GetChannel returns the stored channel record for channelId.
// Apps need this to look up the counterparty channel id when constructing packets to send via
// BatchSend (the core no longer auto-derives it from a sender-side helper).
func GetChannel(channelId types.ChannelId) (types.Channel, error) {
	return mustGetImpl().GetChannel(channelId)
}
