package statelensics23mpt

import (
	"gno.land/p/onbloc/ibc/union/lightclient"
	statelensp "gno.land/p/onbloc/ibc/union/lightclient/state_lens/ics23_mpt"
	"gno.land/p/onbloc/ibc/union/types"
	core "gno.land/r/onbloc/ibc/union/core"
)

const ClientType = types.ClientType(statelensp.ClientType)

// RegisterClient registers the state_lens/ics23_mpt light client implementation with core.
func RegisterClient(cur realm) {
	core.RegisterClient(cross(cur), ClientType, newClientImpl)
}

func newClientImpl(clientStateBytes, consensusStateBytes []byte) (lightclient.Interface, error) {
	clientState, err := statelensp.DecodeClientState(clientStateBytes)
	if err != nil {
		return nil, err
	}

	consensusState, err := statelensp.DecodeConsensusState(consensusStateBytes)
	if err != nil {
		return nil, err
	}

	return statelensp.NewStateLensIcs23MptLightClient(&clientState, &consensusState, core.GetLightClient)
}
