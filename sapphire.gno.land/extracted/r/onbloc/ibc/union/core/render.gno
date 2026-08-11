package core

import (
	"gno.land/p/onbloc/ibc/union/types"
)

func Render(_ string) string {
	return "next client id: " + types.ClientId(uint32(store.clientSeq)+1).String()
}
