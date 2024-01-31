package main

import (
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
)

// Metadata defines the metadata info that accompanies
// gno source code
type Metadata struct {
	Creator string `json:"creator"` // the creator of the source code (deployer)
	Deposit string `json:"deposit"` // the deposit associated with the deployment
}

// metadataFromMsg extracts the metadata from a message
func metadataFromMsg(msg vm.MsgAddPackage) Metadata {
	return Metadata{
		Creator: msg.Creator.String(),
		Deposit: msg.Deposit.String(),
	}
}
