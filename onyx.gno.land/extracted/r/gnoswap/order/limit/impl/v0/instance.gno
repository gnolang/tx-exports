package impl

import plimit "gno.land/p/gnoswap/order/limit/v0"

type limitOrderImpl struct {
	store plimit.ILimitOrderStore
}

// NewLimitOrderImpl binds the implementation to the proxy-owned store.
func NewLimitOrderImpl(orderStore plimit.ILimitOrderStore) plimit.ILimitOrder {
	return &limitOrderImpl{store: orderStore}
}
