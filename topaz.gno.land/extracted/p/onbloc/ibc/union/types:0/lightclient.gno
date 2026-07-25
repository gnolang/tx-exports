package types

// ClientState is the marker interface a light client's client-state satisfies.
// Concrete client states (e.g. cometbls.ClientState) implement it so the
// lightclient.Interface can return them opaquely; callers downcast as needed.
type ClientState interface {
	ClientType() string
}

// Header is the marker interface for a light client update message — either a
// header or a misbehaviour. Concrete update messages implement it so the
// lightclient.Interface can accept them opaquely; the client downcasts to its
// own concrete type.
type Header interface {
	ClientType() string
}

// StateUpdate is the result of a successful lightclient.Interface.VerifyHeader.
//
// It mirrors the Union (Rust) StateUpdate{height, client_state: Option,
// consensus_state}. The field shape matches ConsensusStateUpdate so the caller
// can persist it the same way. An empty ClientStateBytes means the client state
// did not change as part of this update (Rust's None client_state).
type StateUpdate struct {
	Height              uint64
	ConsensusStateBytes []byte
	ClientStateBytes    []byte
	StorageWrites       map[string][]byte
}

// ClientCreationResult is the result of lightclient.Interface.VerifyCreation.
//
// It mirrors the Union (Rust) ClientCreationResult{client_state: Option, ...}.
// An empty ClientStateBytes means the client state was not overwritten during
// creation. CometBLS performs no creation-time validation and writes nothing,
// so its result is empty; the type is kept for symmetry with other clients.
type ClientCreationResult struct {
	ClientStateBytes []byte
	StorageWrites    map[string][]byte
}
