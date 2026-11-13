package impl

import (
	pdca "gno.land/p/gnoswap/order/dca/v0"
)

type dcaOrderImpl struct {
	store pdca.IDCAOrderStore
}

// NewDCAOrderImpl creates the implementation over the shared store.
func NewDCAOrderImpl(dcaStore pdca.IDCAOrderStore) pdca.IDCAOrder {
	return &dcaOrderImpl{store: dcaStore}
}
