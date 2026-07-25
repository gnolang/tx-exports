package cometbls

import (
	"time"

	aibtypes "gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/ibc/union/lightclient"
	"gno.land/p/onbloc/ibc/union/types"
)

// CometblsLightClient is the stateful object implementing lightclient.Interface.
//
// It holds the client state and the consensus states keyed by height, mirroring
// the host store's per-client entry as a self-contained pure object. The core
// host routes by clientId to the stored light-client object; this object owns its
// own state and is verified directly against lightclient.Interface.
type CometblsLightClient struct {
	clientState            *ClientState
	consensusStateByHeight *bptree.BPTree // height:*ConsensusState
}

var _ lightclient.Interface = (*CometblsLightClient)(nil)

// NewCometblsLightClient builds the Gno object-form light client from decoded
// client and consensus state. Core ClientImpl adapters decode MsgCreateClient
// bytes before calling this constructor.
func NewCometblsLightClient(clientState *ClientState, consensusState *ConsensusState) (*CometblsLightClient, error) {
	client := &CometblsLightClient{
		clientState:            clientState,
		consensusStateByHeight: bptree.NewBPTree32(),
	}
	client.setConsensusState(clientState.LatestHeight, consensusState)
	return client, nil
}

// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/cometbls/src/client.rs#L48-L72
func (c *CometblsLightClient) VerifyMembership(height uint64, key []byte, proof []byte, value []byte) error {
	clientState := c.clientState

	consensusState, storageProof, merklePath, err := c.prepareProof(clientState, height, key, proof)
	if err != nil {
		return err
	}

	return c.verifyChainedMembershipProof(consensusState.GetRoot().Hash, storageProof, merklePath, value, 0)
}

// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/cometbls/src/client.rs#L75-L99
func (c *CometblsLightClient) VerifyNonMembership(height uint64, key []byte, proof []byte) error {
	clientState := c.clientState

	consensusState, storageProof, merklePath, err := c.prepareProof(clientState, height, key, proof)
	if err != nil {
		return err
	}

	// VerifyNonMembership verifies the absence of the key in the lowest subtree
	// and then chains inclusion proofs of all subroots up to the final root.
	nonexist := storageProof[0].GetNonexist()
	if nonexist == nil {
		return errorWithDetails(ErrInvalidProof, "commitment proof must be non-existence proof for verifying non-membership")
	}

	subroot, err := nonexist.Calculate()
	if err != nil {
		return errorWithDetails(ErrInvalidProof, "could not calculate root for proof index 0, merkle tree is likely empty: "+err.Error())
	}

	key0 := merklePath.KeyPath[len(merklePath.KeyPath)-1]
	if err := nonexist.Verify(ics23.GetSDKProofSpecs()[0], subroot, key0); err != nil {
		return errorWithDetails(ErrInvalidProof, "failed to verify non-membership proof: "+err.Error())
	}

	// Verify the chained membership proof starting from index 1 with value =
	// subroot.
	return c.verifyChainedMembershipProof(consensusState.GetRoot().Hash, storageProof, merklePath, subroot, 1)
}

// prepareProof performs the validation shared by VerifyMembership and
// VerifyNonMembership: the proof height must not exceed the latest height, the
// proof must decode, its length must match the SDK proof specs, and a consensus
// state must exist at the height. It returns the consensus state, decoded
// storage proof and the membership path for the key.
func (c *CometblsLightClient) prepareProof(clientState *ClientState, height uint64, key []byte, proof []byte) (*ConsensusState, []ics23.CommitmentProof, aibtypes.MerklePath, error) {
	if clientState.GetLatestRevisionHeight() < height {
		return nil, nil, aibtypes.MerklePath{}, errorWithDetails(
			ErrInvalidHeight,
			ufmt.Sprintf("client state height < proof height (%d < %d), please ensure the client has been updated", clientState.GetLatestRevisionHeight(), height),
		)
	}

	storageProof, err := DecodeProofs(proof)
	if err != nil {
		return nil, nil, aibtypes.MerklePath{}, errorWithDetails(ErrInvalidProof, "failed to decode proof: "+err.Error())
	}

	specs := ics23.GetSDKProofSpecs()
	if len(storageProof) != len(specs) {
		return nil, nil, aibtypes.MerklePath{}, errorWithDetails(
			ErrInvalidProof,
			ufmt.Sprintf("length of specs: %d not equal to length of proof: %d", len(specs), len(storageProof)),
		)
	}

	consensusState, found := c.getConsensusState(types.NewHeight(height))
	if !found {
		return nil, nil, aibtypes.MerklePath{}, errorWithDetails(ErrInvalidConsensus, "please ensure the proof was constructed against a height that exists on the client")
	}

	merklePath := aibtypes.MerklePath{KeyPath: [][]byte{moduleKey, makeStoreKey(clientState.ContractAddress, key)}}

	return consensusState, storageProof, merklePath, nil
}

// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/cometbls/src/client.rs#L143-L160
func (c *CometblsLightClient) VerifyHeader(caller address, headerBytes []byte, relayer address) (types.StateUpdate, error) {
	header, err := DecodeHeader(headerBytes)
	if err != nil {
		return types.StateUpdate{}, errorWithDetails(ErrInvalidHeader, "failed to decode header: "+err.Error())
	}

	consensusState, found := c.getConsensusState(*header.TrustedHeight)
	if !found {
		return types.StateUpdate{}, errorWithDetails(
			ErrInvalidConsensus,
			ufmt.Sprintf("could not get trusted consensus state for Header at TrustedHeight: %s", header.TrustedHeight),
		)
	}

	headerHeight := header.GetHeight()
	if consensusState, found := c.getConsensusState(headerHeight); found {
		return makeStateUpdate(headerHeight, consensusState), nil
	}

	if err := c.verifyHeader(c.clientState, consensusState, header, time.Now()); err != nil {
		return types.StateUpdate{}, err
	}

	return c.updateState(c.clientState, consensusState, header), nil
}

func (c *CometblsLightClient) VerifyCreation(caller address, relayer address) (types.ClientCreationResult, error) {
	// CometBLS performs no creation-time validation and writes nothing, so the
	// result is empty (mirrors Union's verify_creation).
	return types.ClientCreationResult{}, nil
}

func (c *CometblsLightClient) Misbehaviour(caller address, misbehaviour []byte, relayer address) ([]byte, error) {
	m, err := DecodeMisbehaviour(misbehaviour)
	if err != nil {
		return nil, errorWithDetails(ErrInvalidMisbehaviour, "failed to decode misbehaviour: "+err.Error())
	}

	if err := m.ValidateBasic(); err != nil {
		return nil, err
	}

	if err := c.verifyMisbehaviour(m, time.Now()); err != nil {
		return nil, err
	}

	// Freeze the client. The frozen height is a sentinel boolean (non-zero).
	c.clientState.FrozenHeight = FrozenHeight

	// Return the frozen client-state bytes so the host commits them back to its
	// client-state mirror, matching union's misbehaviour handling.
	csBytes, err := EncodeClientState(c.clientState)
	if err != nil {
		return nil, err
	}

	return csBytes, nil
}

// updateState creates or updates the consensus state for a verified header and
// advances the latest height when the header is newer. It mirrors Union's
// update_state in Union's cometbls client.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/cometbls/src/client.rs#L283-L309
func (c *CometblsLightClient) updateState(clientState *ClientState, trustedConsensusState *ConsensusState, header *Header) types.StateUpdate {
	untrustedHeight := header.GetHeight()

	consensusState := &ConsensusState{
		Timestamp:          trustedConsensusState.Timestamp,
		Root:               trustedConsensusState.Root,
		NextValidatorsHash: trustedConsensusState.NextValidatorsHash,
	}

	consensusState.Root = MerkleRoot{Hash: header.SignedHeader.AppHash}
	consensusState.NextValidatorsHash = header.SignedHeader.NextValidatorsHash
	// Normalized to nanoseconds to follow tendermint convention
	consensusState.Timestamp = uint64(header.GetTime().UnixNano())

	c.setConsensusState(untrustedHeight, consensusState)

	stateUpdate := makeStateUpdate(untrustedHeight, consensusState)
	if untrustedHeight.GT(clientState.LatestHeight) {
		clientState.LatestHeight = untrustedHeight
		if csBytes, err := EncodeClientState(clientState); err == nil {
			stateUpdate.ClientStateBytes = csBytes
		}
	}

	return stateUpdate
}

func makeStateUpdate(height types.Height, consensusState *ConsensusState) types.StateUpdate {
	update := types.StateUpdate{Height: height.RevisionHeight}
	if consBytes, err := EncodeConsensusState(consensusState); err == nil {
		update.ConsensusStateBytes = consBytes
	}

	return update
}

func (c *CometblsLightClient) GetTimestamp() types.Timestamp {
	lastConsState, found := c.getConsensusState(c.clientState.LatestHeight)
	if !found {
		return 0
	}

	return types.Timestamp(lastConsState.Timestamp)
}

func (c *CometblsLightClient) GetTimestampAtHeight(height uint64) (types.Timestamp, error) {
	consensusState, found := c.getConsensusState(types.NewHeight(height))
	if !found {
		return 0, errorWithDetails(ErrInvalidConsensus, "no consensus state at height")
	}

	return types.Timestamp(consensusState.Timestamp), nil
}

func (c *CometblsLightClient) GetLatestHeight() uint64 {
	return c.clientState.GetLatestRevisionHeight()
}

func (c *CometblsLightClient) GetCounterpartyChainID() string {
	return c.clientState.ChainID
}

func (c *CometblsLightClient) Status() lightclient.Status {
	if !c.clientState.FrozenHeight.IsZero() {
		return lightclient.Frozen
	}

	// get latest consensus state to check for expiry
	lastConsState, found := c.getConsensusState(c.clientState.LatestHeight)
	if !found {
		// if the client state does not have an associated consensus state for its
		// latest height then it must be expired
		return lightclient.Expired
	}

	if c.clientState.IsExpired(lastConsState.Timestamp, uint64(time.Now().UnixNano())) {
		return lightclient.Expired
	}

	return lightclient.Active
}

func (c *CometblsLightClient) hasConsensusState(height types.Height) bool {
	return c.consensusStateByHeight.Has(heightKey(height))
}

func (c *CometblsLightClient) getConsensusState(height types.Height) (*ConsensusState, bool) {
	v := c.consensusStateByHeight.Get(heightKey(height))
	if v == nil {
		return nil, false
	}

	consensusState, ok := v.(*ConsensusState)
	if !ok {
		return nil, false
	}

	return consensusState, true
}

func (c *CometblsLightClient) setConsensusState(height types.Height, consensusState *ConsensusState) {
	c.consensusStateByHeight.Set(heightKey(height), consensusState)
}
