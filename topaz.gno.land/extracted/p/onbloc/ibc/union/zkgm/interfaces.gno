package zkgm

import u256 "gno.land/p/onbloc/math/uint256"

// Zkgmable is implemented by realms that receive ZKGM Call instructions
// dispatched from the ZKGM proxy.
type Zkgmable interface {
	// OnZkgm handles a standard ZKGM Call.
	OnZkgm(cur realm, env CallEnv) error

	// OnIntentZkgm handles the intent-settlement Call variant.
	OnIntentZkgm(cur realm, env IntentCallEnv) error
}

type CallEnv struct {
	Caller             string
	ProxyAccount       string
	Path               *u256.Uint
	SourceChannel      string
	DestinationChannel string
	Sender             []byte
	Calldata           []byte
	Relayer            []byte
	RelayerMsg         []byte
}

type IntentCallEnv struct {
	Caller             string
	ProxyAccount       string
	Path               *u256.Uint
	SourceChannel      string
	DestinationChannel string
	Sender             []byte
	Calldata           []byte
	MarketMaker        []byte
	MarketMakerMsg     []byte
}
