package core

import (
	"gno.land/p/onbloc/ibc/union/lightclient"
	"gno.land/p/onbloc/ibc/union/types"
	core "gno.land/r/onbloc/ibc/union/core"
)

// getters.gno implements the read-only ICoreGetter surface. Results read the
// injected store / light client. Queries that fail on a missing lookup
// (client/consensus/connection/channel state, status, latest height, timestamp,
// batch commitments) return an error rather than a found-bool or a panic.

// GetLightClient returns the live light client instance for a client, or
// (nil, false) when the client is missing.
func (c *coreV1) GetLightClient(clientId types.ClientId) (lightclient.Interface, bool) {
	return c.store.GetLightClient(clientId)
}

// GetStatus returns the client's status, or an error when the client is missing.
func (c *coreV1) GetStatus(clientId types.ClientId) (types.Status, error) {
	lc, ok := c.store.GetLightClient(clientId)
	if !ok {
		return types.StatusUnknown, makeError(core.ErrClientNotFound)
	}

	return lc.Status().ToType(), nil
}

// GetClientType returns the registered client type for a client, or an error
// when the client is missing.
func (c *coreV1) GetClientType(clientId types.ClientId) (types.ClientType, error) {
	typ, ok := c.store.ClientType(clientId)
	if !ok {
		return "", makeError(core.ErrClientNotFound)
	}

	return typ, nil
}

// GetClientImpl is best-effort: gno has no client_type->impl address mapping, so
// it returns the registered client type as the impl identifier, or an error when
// the client is missing.
func (c *coreV1) GetClientImpl(clientId types.ClientId) (string, error) {
	typ, ok := c.store.ClientType(clientId)
	if !ok {
		return "", makeError(core.ErrClientNotFound)
	}

	return string(typ), nil
}

// GetRegisteredClientType reports whether a light client implementation is
// registered for the given client type.
func (c *coreV1) GetRegisteredClientType(clientType types.ClientType) bool {
	return c.store.HasRegisteredClient(clientType)
}

// GetClientStateBytes returns the mirrored client state bytes, or an error when
// the client state is missing.
func (c *coreV1) GetClientStateBytes(clientId types.ClientId) ([]byte, error) {
	bz, ok := c.store.ClientStateBytes(clientId)
	if !ok {
		return nil, makeError(core.ErrClientStateNotFound)
	}

	return bz, nil
}

// GetConsensusStateBytes returns the consensus state bytes at a height, or an
// error when no consensus state is stored at that height.
func (c *coreV1) GetConsensusStateBytes(clientId types.ClientId, height types.Height) ([]byte, error) {
	bz, ok := c.store.ConsensusStateBytes(clientId, height)
	if !ok {
		return nil, makeError(core.ErrConsensusStateNotFound)
	}

	return bz, nil
}

// GetLatestHeight returns the light client's latest height, or an error when the
// client is missing.
func (c *coreV1) GetLatestHeight(clientId types.ClientId) (uint64, error) {
	lc, ok := c.store.GetLightClient(clientId)
	if !ok {
		return 0, makeError(core.ErrClientNotFound)
	}

	return lc.GetLatestHeight(), nil
}

// GetTimestampAtHeight returns the consensus timestamp recorded at a height, or
// an error when the client is missing or has no consensus state at that height.
func (c *coreV1) GetTimestampAtHeight(clientId types.ClientId, height uint64) (types.Timestamp, error) {
	lc, ok := c.store.GetLightClient(clientId)
	if !ok {
		return 0, makeError(core.ErrClientNotFound)
	}

	ts, err := lc.GetTimestampAtHeight(height)
	if err != nil {
		return 0, err
	}

	return ts, nil
}

// GetConnection returns the typed connection record, or an error when the
// connection is missing.
func (c *coreV1) GetConnection(connectionId types.ConnectionId) (types.Connection, error) {
	conn, ok := c.store.GetConnection(connectionId)
	if !ok {
		return types.Connection{}, makeError(core.ErrConnectionNotFound)
	}

	return conn, nil
}

// GetChannels returns all stored channel records.
func (c *coreV1) GetChannels() ([]types.Channel, error) {
	return c.store.GetChannels()
}

// GetChannel returns the typed channel record, or an error when the channel
// is missing.
func (c *coreV1) GetChannel(channelId types.ChannelId) (types.Channel, error) {
	ch, ok := c.store.GetChannel(channelId)
	if !ok {
		return types.Channel{}, makeError(core.ErrChannelNotFound)
	}

	return ch, nil
}

// GetBatchPacketsCommitment returns the batch packet commitment for a batch hash,
// or an error when no batch packet commitment is stored for that hash.
func (c *coreV1) GetBatchPacketsCommitment(batchHash types.H256) (types.H256, error) {
	commitment, ok := c.store.BatchPacketsAt(batchHash)
	if !ok {
		return types.H256{}, makeError(core.ErrBatchPacketsNotFound)
	}

	return commitment, nil
}

// GetBatchReceiptsCommitment returns the batch receipt commitment for a batch hash,
// or an error when no batch receipt commitment is stored for that hash.
func (c *coreV1) GetBatchReceiptsCommitment(batchHash types.H256) (types.H256, error) {
	commitment, ok := c.store.BatchReceiptsAt(batchHash)
	if !ok {
		return types.H256{}, makeError(core.ErrBatchReceiptsNotFound)
	}

	return commitment, nil
}

// GetCommittedMembershipProofCommitment returns the committed membership proof
// value for a client/height/path key.
func (c *coreV1) GetCommittedMembershipProofCommitment(clientId types.ClientId, proofHeight uint64, path []byte) (types.H256, error) {
	commitment, ok := c.store.MembershipProofAt(clientId, proofHeight, path)
	if !ok {
		return types.H256{}, makeError(core.ErrMembershipProofNotFound)
	}

	return commitment, nil
}

// GetCommittedNonMembershipProof reports whether a non-membership proof
// commitment exists for a client/height/path key.
func (c *coreV1) GetCommittedNonMembershipProof(clientId types.ClientId, proofHeight uint64, path []byte) bool {
	return c.store.HasNonMembershipProof(clientId, proofHeight, path)
}
