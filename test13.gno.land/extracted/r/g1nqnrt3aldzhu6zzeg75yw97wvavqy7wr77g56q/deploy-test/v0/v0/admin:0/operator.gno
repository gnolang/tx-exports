package admin

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
)

const (
	SetOperatorEvent   = "SetOperator"
	UnsetOperatorEvent = "UnsetOperator"
)

var (
	operatorAddrs map[address]bool = make(map[address]bool)
)

func SetOperator(cur realm, addr address) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)

	assertValidAddress(addr)
	operatorAddrs[addr] = true

	chain.Emit(
		SetOperatorEvent,
		"address", addr.String(),
	)
}

func GetOperators() []address {
	assertMigrationStateAvailable()
	result := []address{}
	for addr, active := range operatorAddrs {
		if active {
			result = append(result, addr)
		}
	}
	return result
}

func UnsetOperator(cur realm, addr address) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	assertValidAddress(addr)
	if !operatorAddrs[addr] {
		panic("address is not an operator")
	}
	delete(operatorAddrs, addr)
	chain.Emit(
		UnsetOperatorEvent,
		"address", addr.String(),
	)
}

func IsOperator(addr address) bool {
	assertMigrationStateAvailable()
	return operatorAddrs[addr]
}
