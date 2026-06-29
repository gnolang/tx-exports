package admin

import (
	"chain"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/ds/btreeset"
)

const (
	SetOperatorEvent   = "SetOperator"
	UnsetOperatorEvent = "UnsetOperator"
)

var (
	operatorAddrs *btreeset.StringBTreeSet = btreeset.NewStringBTreeSet(32)
)

func SetOperator(cur realm, addr address) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)

	assertValidAddress(addr)
	operatorAddrs.Set(addr.String())

	chain.Emit(
		SetOperatorEvent,
		"address", addr.String(),
	)
}

func GetOperators() []address {
	assertMigrationStateAvailable()
	result := []address{}
	operatorAddrs.Iterate(nil, nil, func(addr string) bool {
		result = append(result, address(addr))
		return false
	})
	return result
}

func UnsetOperator(cur realm, addr address) {
	assertNotFrozen()
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
	assertMigrationStateAvailable()
	return operatorAddrs.Has(addr.String())
}
