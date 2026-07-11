package mytoken

import (
	"strconv"

	"gno.land/p/nt/avl/v0"

	"chain/runtime/unsafe"
)

var (
	balances    avl.Tree
	totalSupply int64
	admin       address
)

func init() {
	admin = unsafe.OriginCaller()
	totalSupply = 1000000
	balances.Set(admin.String(), totalSupply)
}

func Transfer(cur realm, to address, amount int64) {
	caller := cur.Previous().Address()

	fromRaw, exists := balances.Get(caller.String())
	if !exists {
		panic("caller has no balance")
	}
	fromBalance := fromRaw.(int64)
	if fromBalance < amount {
		panic("insufficient balance")
	}
	balances.Set(caller.String(), fromBalance-amount)

	toRaw, exists := balances.Get(to.String())
	var toBalance int64
	if exists {
		toBalance = toRaw.(int64)
	}
	balances.Set(to.String(), toBalance+amount)
}

func BalanceOf(addr address) int64 {
	raw, exists := balances.Get(addr.String())
	if !exists {
		return 0
	}
	return raw.(int64)
}

func Render(path string) string {
	return "Total supply: " + strconv.FormatInt(totalSupply, 10) +
		"\nAdmin: " + admin.String()
}
