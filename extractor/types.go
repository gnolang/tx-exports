package main

import (
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/tm2/pkg/std"
)

// Metadata defines the metadata info that accompanies
// gno source code
type Metadata struct {
	Creator string `json:"creator"` // the creator of the source code (deployer)
	Deposit string `json:"deposit"` // the deposit associated with the deployment
}

// TxData contains the single block transaction,
// along with the block information
type TxData struct {
	Tx       std.Tx `json:"tx"`
	BlockNum uint64 `json:"blockNum"`
}

// metadataFromMsg extracts the metadata from a message
func metadataFromMsg(msg vm.MsgAddPackage) Metadata {
	return Metadata{
		Creator: msg.Creator.String(),
		Deposit: msg.Deposit.String(),
	}
}
