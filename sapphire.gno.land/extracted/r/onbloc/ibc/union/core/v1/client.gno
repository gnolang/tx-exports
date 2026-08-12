package core

import (
	"gno.land/p/onbloc/ibc/union/lightclient"
	"gno.land/p/onbloc/ibc/union/types"
	core "gno.land/r/onbloc/ibc/union/core"
)

// RegisterClient stores a light client implementation for a client type.
// CreateClient calls it to produce a fresh instance from the submitted state
// bytes. Callers that pass nil are rejected as unauthorized.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/core/src/contract.rs#L849-L865
func (c *coreV1) RegisterClient(_ int, rlm realm, clientType types.ClientType, clientImpl lightclient.ClientImpl) {
	assertIsRlmCurrent(0, rlm)

	if clientImpl == nil {
		panic("caller not authorized to register client: unauthorized")
	}
	c.store.RegisterClient(0, rlm, clientType, clientImpl)
	core.EmitRegisterClient(0, rlm, clientType)
}

// HasClient reports whether a light client is registered for a client type.
func (c *coreV1) HasClient(clientType types.ClientType) bool {
	return c.store.HasRegisteredClient(clientType)
}

// CreateClient assigns a client id for a registered light client type, stores
// the submitted state bytes, then lets the light client verify creation against
// that freshly stored state.
func (c *coreV1) CreateClient(_ int, rlm realm, msg types.MsgCreateClient) {
	assertIsRlmCurrent(0, rlm)

	creator := rlm.Previous().Address()
	relayer := resolveRelayer(creator, msg.Relayer)

	clientImpl, ok := c.store.ClientRegistry(msg.ClientType)
	if !ok {
		panic("client type not found")
	}

	lc, err := clientImpl(msg.ClientStateBytes, msg.ConsensusStateBytes)
	if err != nil {
		panic("create client: " + err.Error())
	}

	clientId := c.store.AddClient(0, rlm, msg.ClientType, creator, lc)
	c.initClient(0, rlm, clientId, msg.ClientStateBytes, msg.ConsensusStateBytes, relayer)

	core.EmitCreateClient(0, rlm, clientId, msg.ClientType, lc.GetCounterpartyChainID())
}

// initClient mirrors the submitted client/consensus state for a stored client,
// runs the light client's creation verification, then persists any state
// overwrite and storage writes the verification returns. It returns the height
// the consensus state was stored at.
func (c *coreV1) initClient(_ int, rlm realm, clientId types.ClientId, clientStateBytes, consensusStateBytes []byte, relayer address) types.Height {
	lc, ok := c.store.GetLightClient(clientId)
	if !ok {
		panic("client " + clientId.String() + " not found")
	}

	c.store.SaveClientState(0, rlm, clientId, clientStateBytes)

	height := types.NewHeight(lc.GetLatestHeight())
	c.store.SaveConsensusState(0, rlm, clientId, height, consensusStateBytes)

	// union threads info.sender as the caller; gno derives the authenticated
	// caller from the realm (internal calls preserve the entry frame).
	result, err := lc.VerifyCreation(rlm.Previous().Address(), relayer)
	if err != nil {
		panic("create client: " + err.Error())
	}

	if len(result.ClientStateBytes) != 0 {
		c.store.SaveClientState(0, rlm, clientId, result.ClientStateBytes)
	}

	for k, v := range result.StorageWrites {
		c.store.SaveClientStore(0, rlm, clientId, k, v)
	}

	return height
}

// UpdateClient verifies a client message against the light client object, which
// updates its own state, and mirrors the resulting state bytes for queries and
// counterparty proofs.
func (c *coreV1) UpdateClient(_ int, rlm realm, msg types.MsgUpdateClient) {
	assertIsRlmCurrent(0, rlm)

	lc, err := c.getActiveClient(msg.ClientId)
	if err != nil {
		panic(err)
	}

	caller := rlm.Previous().Address()
	relayer := resolveRelayer(caller, msg.Relayer)

	update, err := lc.VerifyHeader(caller, msg.ClientMessage, relayer)
	if err != nil {
		panic("update client: " + err.Error())
	}

	height := types.NewHeight(update.Height)

	if len(update.ClientStateBytes) != 0 {
		c.store.SaveClientState(0, rlm, msg.ClientId, update.ClientStateBytes)
	}

	// Union stores consensus_state_bytes unconditionally because the field is not
	// optional in the update response.
	c.store.SaveConsensusState(0, rlm, msg.ClientId, height, update.ConsensusStateBytes)

	for k, v := range update.StorageWrites {
		c.store.SaveClientStore(0, rlm, msg.ClientId, k, v)
	}

	core.EmitUpdateClient(0, rlm, msg.ClientId, height)
}

func (c *coreV1) ForceUpdateClient(_ int, rlm realm, msg types.MsgForceUpdateClient) {
	assertIsRlmCurrent(0, rlm)

	clientImpl, ok := c.store.GetClientImpl(msg.ClientId)
	if !ok {
		panic(makeError(core.ErrClientNotFound, msg.ClientId.String()))
	}

	next, err := clientImpl(msg.ClientStateBytes, msg.ConsensusStateBytes)
	if err != nil {
		panic("force update client: " + err.Error())
	}

	c.store.SetLightClient(0, rlm, msg.ClientId, next)

	caller := rlm.Previous().Address()
	height := c.initClient(0, rlm, msg.ClientId, msg.ClientStateBytes, msg.ConsensusStateBytes, caller)

	core.EmitForceUpdateClient(0, rlm, msg.ClientId, height)
}

// Misbehaviour verifies a misbehaviour message against an active light client and
// freezes it. Mirroring union (contract.rs L1048-L1093), the host commits the
// frozen client-state bytes the light client returns back to the client-state
// mirror / ClientStatePath commitment before emitting the event.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/core/src/contract.rs#L1048-L1093
func (c *coreV1) Misbehaviour(_ int, rlm realm, msg types.MsgMisbehaviour) {
	assertIsRlmCurrent(0, rlm)

	lc, err := c.getActiveClient(msg.ClientId)
	if err != nil {
		panic(err)
	}

	caller := rlm.Previous().Address()
	relayer := resolveRelayer(caller, msg.Relayer)

	clientStateBytes, err := lc.Misbehaviour(caller, msg.ClientMessage, relayer)
	if err != nil {
		panic("misbehaviour: " + err.Error())
	}

	if len(clientStateBytes) != 0 {
		c.store.SaveClientState(0, rlm, msg.ClientId, clientStateBytes)
	}

	core.EmitMisbehaviour(0, rlm, msg.ClientId)
}

// verifyMembership checks a membership proof against a registered, active light
// client. Shared by the connection/channel handshakes.
func (c *coreV1) verifyMembership(clientId types.ClientId, height types.Height, proof, key, value []byte) {
	lc, err := c.getActiveClient(clientId)
	if err != nil {
		panic(err)
	}

	err = lc.VerifyMembership(height.RevisionHeight, key, proof, value)
	if err != nil {
		panic(err)
	}
}

// getClient returns the light client registered under clientId, or an error
// when no client is registered for it. The caller (entrypoint) decides whether
// a miss reverts.
func (c *coreV1) getClient(clientId types.ClientId) (lightclient.Interface, error) {
	lc, ok := c.store.GetLightClient(clientId)
	if !ok {
		return nil, makeError(core.ErrClientNotFound, clientId.String())
	}

	return lc, nil
}

// getActiveClient returns the light client registered under clientId, or an
// error when it is missing or not in the Active status. It centralizes the
// "registered and active" precondition shared by the update, misbehaviour, and
// proof-verification paths.
func (c *coreV1) getActiveClient(clientId types.ClientId) (lightclient.Interface, error) {
	lc, err := c.getClient(clientId)
	if err != nil {
		return nil, err
	}

	if lc.Status() != lightclient.Active {
		return nil, makeError(core.ErrClientNotActive)
	}

	return lc, nil
}
