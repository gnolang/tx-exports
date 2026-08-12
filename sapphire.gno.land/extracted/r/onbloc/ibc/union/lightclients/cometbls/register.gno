package cometbls

import (
	"gno.land/p/onbloc/ibc/union/lightclient"
	cometblsp "gno.land/p/onbloc/ibc/union/lightclient/cometbls"
	"gno.land/p/onbloc/ibc/union/types"
	"gno.land/r/onbloc/ibc/union/core"
)

const ClientType = types.ClientType(cometblsp.ClientType)

// RegisterClient registers the cometbls light client implementation with core.
func RegisterClient(cur realm) {
	core.RegisterClient(cross(cur), ClientType, newClientImpl)
}

func newClientImpl(clientStateBytes, consensusStateBytes []byte) (lightclient.Interface, error) {
	clientState, err := cometblsp.DecodeClientState(clientStateBytes)
	if err != nil {
		return nil, err
	}

	consensusState, err := cometblsp.DecodeConsensusState(consensusStateBytes)
	if err != nil {
		return nil, err
	}

	return cometblsp.NewCometblsLightClient(clientState, consensusState)
}
