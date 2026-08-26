package ics23_mpt

import (
	"bytes"
	"crypto/keccak256"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/ibc/union/lightclient"
	"gno.land/p/onbloc/ibc/union/types"
	"gno.land/p/onbloc/verifier/evm/storage"
)

// Sentinel errors for the object-form client. Proof-shape errors reuse the
// errors declared in consensus.gno (ErrConsensusStateTooShort,
// ErrInvalidCommitmentKey).
var (
	ErrNoL1Client              = errors.New("ics23mpt: l1 client not configured")
	ErrInvalidHeight           = errors.New("ics23mpt: proof height above latest height")
	ErrConsensusStateNotFound  = errors.New("ics23mpt: consensus state not found at height")
	ErrInvalidCommitmentValue  = errors.New("ics23mpt: commitment value must be 32 bytes")
	ErrStoredValueMismatch     = errors.New("ics23mpt: stored value mismatch")
	ErrMisbehaviourUnsupported = errors.New("ics23mpt: misbehaviour is not supported for state-lens clients")
)

// StateLensIcs23MptLightClient is the stateful object implementing
// lightclient.Interface for the state-lens/ics23/mpt client.
//
// It holds the client state and the L2 consensus states keyed by height.
// The L1 client dependency is resolved lazily on every use via getL1Client,
// mirroring Union's ctx-based approach where the light client struct is
// stateless and the host provides L1 access through the execution context.
//
// A state-lens client does not track its own chain directly. It trusts the
// counterparty's opaque L2 consensus blob, proven to exist in the L1 chain's
// state via the L1 light client. Membership of application state is then
// verified against the L2 storage root with EVM MPT storage proofs.
//
// This mirrors Union's StateLensIcs23MptLightClient
// (cosmwasm/lightclient/state-lens-ics23-mpt).
type StateLensIcs23MptLightClient struct {
	clientState            *ClientState
	consensusStateByHeight *bptree.BPTree // height:*ConsensusState
	// getL1ClientFn resolves the settlement-chain light client from the host store
	// on every call, so the state-lens always sees the current L1 state without
	// needing an explicit refresh step.
	getL1ClientFn func(types.ClientId) (lightclient.Interface, bool)
}

var _ lightclient.Interface = (*StateLensIcs23MptLightClient)(nil)

// NewStateLensIcs23MptLightClient builds the Gno object-form light client from
// decoded client and consensus state. getL1ClientFn is a live store getter
// called on every L1 lookup, matching Union's ctx-based approach where the
// light client resolves the L1 dependency lazily from the host store.
func NewStateLensIcs23MptLightClient(clientState *ClientState, consensusState *ConsensusState, getL1ClientFn func(types.ClientId) (lightclient.Interface, bool)) (*StateLensIcs23MptLightClient, error) {
	c := &StateLensIcs23MptLightClient{
		clientState:            clientState,
		consensusStateByHeight: bptree.NewBPTree32(),
		getL1ClientFn:          getL1ClientFn,
	}
	c.setConsensusState(clientState.L2LatestHeight, consensusState)
	return c, nil
}

// VerifyMembership verifies that key stores value under the L2 storage root at
// the given height using an EVM MPT storage proof. Status gating is the caller's
// responsibility, mirroring the cometbls object form.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/state-lens-ics23-mpt/src/client.rs#L39-L50
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/state-lens-ics23-mpt/src/client.rs#L189-L218
func (c *StateLensIcs23MptLightClient) VerifyMembership(height uint64, key []byte, proof []byte, value []byte) error {
	consensusState, storageProof, err := c.prepareProof(height, key, proof)
	if err != nil {
		return err
	}

	if len(value) != 32 {
		return ErrInvalidCommitmentValue
	}

	if !bytes.Equal(storageProof.Value, value) {
		return ErrStoredValueMismatch
	}

	// storage.VerifyProof only reads the storage root (it hashes the proof key
	// and walks the trie), so the root slice can be passed without copying.
	if err := storage.VerifyProof(consensusState.StorageRoot, storage.Proof{
		Key:   storageProof.Key,
		Value: storageProof.Value,
		Proof: storageProof.Proof,
	}); err != nil {
		return ufmt.Errorf("ics23mpt: storage membership verification failed: %v", err)
	}

	return nil
}

// VerifyNonMembership verifies the absence of key under the L2 storage root at
// the given height using an EVM MPT absence proof.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/state-lens-ics23-mpt/src/client.rs#L53-L63
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/state-lens-ics23-mpt/src/client.rs#L233-L254
func (c *StateLensIcs23MptLightClient) VerifyNonMembership(height uint64, key []byte, proof []byte) error {
	consensusState, storageProof, err := c.prepareProof(height, key, proof)
	if err != nil {
		return err
	}

	if err := storage.VerifyAbsence(consensusState.StorageRoot, storage.Proof{
		Key:   storageProof.Key,
		Proof: storageProof.Proof,
	}); err != nil {
		return ufmt.Errorf("ics23mpt: storage non-membership verification failed: %v", err)
	}

	return nil
}

// prepareProof performs the validation shared by VerifyMembership and
// VerifyNonMembership: the proof height must not exceed the latest height, a
// consensus state must exist at the height, the storage proof must decode, and
// its key must match the IBC commitment key derived from path.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/state-lens-ics23-mpt/src/client.rs#L189-L231
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/state-lens-ics23-mpt/src/client.rs#L233-L254
func (c *StateLensIcs23MptLightClient) prepareProof(height uint64, key []byte, proof []byte) (*ConsensusState, storage.Proof, error) {
	if height > c.clientState.L2LatestHeight {
		return nil, storage.Proof{}, ErrInvalidHeight
	}

	consensusState, found := c.getConsensusState(height)
	if !found {
		return nil, storage.Proof{}, ErrConsensusStateNotFound
	}

	storageProof, err := storage.DecodeProof(proof)
	if err != nil {
		return nil, storage.Proof{}, ufmt.Errorf("ics23mpt: invalid storage proof: %v", err)
	}

	if err := VerifyCommitmentKey(key, storageProof.Key); err != nil {
		return nil, storage.Proof{}, err
	}

	return consensusState, storageProof, nil
}

// VerifyHeader verifies a state-lens header and updates the client. It proves
// that the submitted L2 consensus state is committed in the L1 state at
// L1Height (via the L1 client), then extracts and stores the L2 consensus state
// at L2Height. Mirrors Union's verify_header.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/state-lens-ics23-mpt/src/client.rs#L98-L134
func (c *StateLensIcs23MptLightClient) VerifyHeader(caller address, headerBytes []byte, relayer address) (types.StateUpdate, error) {
	l1, ok := c.getL1ClientFn(types.ClientId(c.clientState.L1ClientID))
	if !ok {
		return types.StateUpdate{}, ErrNoL1Client
	}

	header, err := DecodeHeader(headerBytes)
	if err != nil {
		return types.StateUpdate{}, ufmt.Errorf("ics23mpt: failed to decode header: %v", err)
	}

	// The L2 consensus state must be committed under the consensus-state path of
	// the L2 client, in the L1 chain's state, as a keccak256 hash.
	consensusPath := types.ConsensusStatePath(types.ClientId(c.clientState.L2ClientID), types.NewHeight(header.L2Height))

	consensusHash := keccak256.Sum256(header.L2ConsensusState)
	if err := l1.VerifyMembership(header.L1Height, consensusPath[:], header.L2ConsensusStateProof, consensusHash[:]); err != nil {
		return types.StateUpdate{}, ufmt.Errorf("ics23mpt: l1 consensus state membership verification failed: %v", err)
	}

	consensusState, err := c.clientState.ExtractConsensusState(header.L2ConsensusState)
	if err != nil {
		return types.StateUpdate{}, err
	}

	return c.updateState(header, &consensusState), nil
}

// updateState stores the extracted L2 consensus state at L2Height and advances
// the latest height when the header is newer. Mirrors Union's StateUpdate flow.
func (c *StateLensIcs23MptLightClient) updateState(header Header, consensusState *ConsensusState) types.StateUpdate {
	height := header.L2Height

	c.setConsensusState(height, consensusState)

	stateUpdate := types.StateUpdate{Height: height}
	// Mirror the new consensus state bytes so the host (core) can persist them
	// for queries and counterparty proofs. Encoding cannot fail here (roots are
	// fixed 32-byte words), but stay defensive and leave the mirror empty on error.
	if consensusStateBytes, err := EncodeConsensusState(*consensusState); err == nil {
		stateUpdate.ConsensusStateBytes = consensusStateBytes
	}

	if height > c.clientState.L2LatestHeight {
		c.clientState.L2LatestHeight = height
		if clientStateBytes, err := EncodeClientState(*c.clientState); err == nil {
			stateUpdate.ClientStateBytes = clientStateBytes
		}
	}

	return stateUpdate
}

// VerifyCreation performs no creation-time state mutation; the state-lens client
// trusts its initial consensus state. Mirrors Union's verify_creation, which
// only emits an event.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/state-lens-ics23-mpt/src/client.rs#L83-L96
func (c *StateLensIcs23MptLightClient) VerifyCreation(caller address, relayer address) (types.ClientCreationResult, error) {
	return types.ClientCreationResult{}, nil
}

// Misbehaviour is unsupported for state-lens clients, mirroring Union's
// `unimplemented!()` for this client type.
func (c *StateLensIcs23MptLightClient) Misbehaviour(caller address, misbehaviour []byte, relayer address) ([]byte, error) {
	return nil, ErrMisbehaviourUnsupported
}

// GetTimestamp returns the timestamp of the consensus state at the latest
// height, or zero when none exists.
func (c *StateLensIcs23MptLightClient) GetTimestamp() types.Timestamp {
	consState, found := c.getConsensusState(c.clientState.L2LatestHeight)
	if !found {
		return 0
	}

	return types.Timestamp(consState.Timestamp)
}

func (c *StateLensIcs23MptLightClient) GetTimestampAtHeight(height uint64) (types.Timestamp, error) {
	consState, found := c.getConsensusState(height)
	if !found {
		return 0, ErrConsensusStateNotFound
	}

	return types.Timestamp(consState.Timestamp), nil
}

func (c *StateLensIcs23MptLightClient) GetLatestHeight() uint64 {
	return c.clientState.L2LatestHeight
}

func (c *StateLensIcs23MptLightClient) GetCounterpartyChainID() string {
	return c.clientState.L2ChainID
}

// Status mirrors the L1 client's status. A state-lens client has no liveness of
// its own: it is only as live as the L1 client it depends on. A missing or
// unknown L1 status is treated as Frozen, matching Union's unwrap_or(Frozen).
func (c *StateLensIcs23MptLightClient) Status() lightclient.Status {
	l1, ok := c.getL1ClientFn(types.ClientId(c.clientState.L1ClientID))
	if !ok {
		return lightclient.Frozen
	}

	switch status := l1.Status(); status {
	case lightclient.Active, lightclient.Expired, lightclient.Frozen:
		return status
	default:
		return lightclient.Frozen
	}
}

func (c *StateLensIcs23MptLightClient) getConsensusState(height uint64) (*ConsensusState, bool) {
	v := c.consensusStateByHeight.Get(heightKey(height))
	if v == nil {
		return nil, false
	}

	consState, ok := v.(*ConsensusState)
	if !ok {
		return nil, false
	}

	return consState, true
}

func (c *StateLensIcs23MptLightClient) setConsensusState(height uint64, consState *ConsensusState) {
	c.consensusStateByHeight.Set(heightKey(height), consState)
}

// heightKey renders a height as a fixed-width, lexicographically sortable bptree
// key. ibc-union heights carry a single revision, so the numeric ordering of the
// formatted height matches height ordering.
func heightKey(height uint64) string {
	return zeroPadDecimalUint64(height)
}

// zeroPadDecimalUint64 converts a uint64 number into a zero-padded 20-character string.
func zeroPadDecimalUint64(num uint64) string {
	s := strconv.FormatUint(num, 10)
	zerosNeeded := 20 - len(s)

	return strings.Repeat("0", zerosNeeded) + s
}
