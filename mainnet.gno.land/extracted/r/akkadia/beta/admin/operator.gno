package admin

import (
	"chain"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/bptree/v0"
)

const (
	SetOperatorEvent   = "SetOperator"
	UnsetOperatorEvent = "UnsetOperator"
)

var (
	operatorAddrs *bptree.BPTree = bptree.NewBPTree32()
)

func SetOperator(cur realm, addr address) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)

	assertValidAddress(addr)
	operatorAddrs.Set(addr.String(), true)

	chain.Emit(
		SetOperatorEvent,
		"address", addr.String(),
	)
}

func GetOperators() []address {
	result := []address{}
	operatorAddrs.Iterate("", "", func(addr string, _ any) bool {
		result = append(result, address(addr))
		return false
	})
	return result
}

func UnsetOperator(cur realm, addr address) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	assertValidAddress(addr)
	if !operatorAddrs.Has(addr.String()) {
		panic("address is not an operator")
	}
	operatorAddrs.Remove(addr.String())
	chain.Emit(
		UnsetOperatorEvent,
		"address", addr.String(),
	)
}

func IsOperator(addr address) bool {
	return operatorAddrs.Has(addr.String())
}
