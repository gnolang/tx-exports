package cometbls

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/ibc/union/types"
)

// https://github.com/cometbft/cometbft/blob/6b567cd510acb6d729869db8621ae93ac79247cf/types/genesis.go#L18-L21
const MaxChainIDLen int = 50

type ClientState struct {
	ChainID         string
	TrustingPeriod  uint64
	UnbondingPeriod uint64
	MaxClockDrift   uint64
	FrozenHeight    types.Height
	LatestHeight    types.Height
	ContractAddress types.H256
}

func NewClientState(
	chainID string,
	trustingPeriod,
	unbondingPeriod uint64,
	maxClockDrift uint64,
	frozenHeight types.Height,
	latestHeight types.Height,
	contractAddress types.H256,
) *ClientState {
	return &ClientState{
		ChainID:         chainID,
		TrustingPeriod:  trustingPeriod,
		UnbondingPeriod: unbondingPeriod,
		MaxClockDrift:   maxClockDrift,
		FrozenHeight:    frozenHeight,
		LatestHeight:    latestHeight,
		ContractAddress: contractAddress,
	}
}

// ClientType is tendermint.
func (ClientState) ClientType() string {
	return ClientType
}

// GetChainID returns the chain-id
func (cs *ClientState) GetChainID() string {
	return cs.ChainID
}

func (cs *ClientState) GetTrustingPeriod() uint64 {
	return cs.TrustingPeriod
}

func (cs *ClientState) GetUnbondingPeriod() uint64 {
	return cs.UnbondingPeriod
}

func (cs *ClientState) GetMaxClockDrift() uint64 {
	return cs.MaxClockDrift
}

// GetLatestHeight returns latest block height.
func (cs *ClientState) GetLatestHeight() types.Height {
	return cs.LatestHeight
}

func (cs *ClientState) GetFrozenRevisionHeight() uint64 {
	return cs.FrozenHeight.RevisionHeight
}

// GetLatestRevisionHeight returns latest block height.
func (cs *ClientState) GetLatestRevisionHeight() uint64 {
	return cs.LatestHeight.RevisionHeight
}

func (cs *ClientState) GetContractAddress() types.H256 {
	return cs.ContractAddress
}

// IsExpired returns whether or not the client has passed the trusting period since the last
// update (in which case no headers are considered valid).
func (cs *ClientState) IsExpired(latestTimestamp, now uint64) bool {
	return isClientExpiredAt(latestTimestamp, cs.TrustingPeriod, now)
}

// Validate performs a basic validation of the client state fields.
func (cs *ClientState) Validate() error {
	if strings.TrimSpace(cs.ChainID) == "" {
		return errorWithDetails(ErrInvalidChainID, "chain id cannot be empty string")
	}

	// NOTE: the value of tmtypes.MaxChainIDLen may change in the future.
	// If this occurs, the code here must account for potential difference
	// between the tendermint version being run by the counterparty chain
	// and the tendermint version used by this light client.
	// https://github.com/cosmos/ibc-go/issues/177
	if len(cs.ChainID) > MaxChainIDLen {
		return errorWithDetails(
			ErrInvalidChainID,
			ufmt.Sprintf("chainID is too long; got: %d, max: %d", len(cs.ChainID), MaxChainIDLen),
		)
	}

	if cs.TrustingPeriod <= 0 {
		return errorWithDetails(ErrInvalidTrustingPeriod, "trusting period must be greater than zero")
	}

	if cs.UnbondingPeriod <= 0 {
		return errorWithDetails(ErrInvalidUnbondingPeriod, "unbonding period must be greater than zero")
	}

	if cs.MaxClockDrift <= 0 {
		return errorWithDetails(ErrInvalidMaxClockDrift, "max clock drift must be greater than zero")
	}

	if cs.GetLatestRevisionHeight() == 0 {
		return errorWithDetails(ErrInvalidHeaderHeight, "cometbls client's latest height cannot be zero")
	}

	if cs.TrustingPeriod >= cs.UnbondingPeriod {
		return errorWithDetails(
			ErrInvalidTrustingPeriod,
			ufmt.Sprintf("trusting period (%d) should be < unbonding period (%d)", cs.TrustingPeriod, cs.UnbondingPeriod),
		)
	}

	return nil
}

// ZeroCustomFields returns a ClientState that is a copy of the current ClientState
// with all client customizable fields zeroed out
func (cs *ClientState) ZeroCustomFields() *ClientState {
	// copy over all chain-specified fields
	// and leave custom fields empty
	return &ClientState{
		ChainID:         cs.ChainID,
		UnbondingPeriod: cs.UnbondingPeriod,
		LatestHeight:    cs.LatestHeight,
	}
}
