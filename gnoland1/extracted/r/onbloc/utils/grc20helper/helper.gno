package grc20helper

import (
	"gno.land/r/demo/defi/grc20reg"
)

func GetName(tokenKey string) string {
	return grc20reg.MustGet(tokenKey).GetName()
}

func GetSymbol(tokenKey string) string {
	return grc20reg.MustGet(tokenKey).GetSymbol()
}

func GetDecimals(tokenKey string) int {
	return grc20reg.MustGet(tokenKey).GetDecimals()
}

func TotalSupply(tokenKey string) int64 {
	return grc20reg.MustGet(tokenKey).TotalSupply()
}

func BalanceOf(tokenKey string, account address) int64 {
	return grc20reg.MustGet(tokenKey).BalanceOf(account)
}

func Allowance(tokenKey string, owner, spender address) int64 {
	return grc20reg.MustGet(tokenKey).Allowance(owner, spender)
}

// Transfer moves tokens owned by the immediate caller. A direct user call
// spends the user's balance; a realm cross-call spends the calling realm's.
func Transfer(cur realm, tokenKey string, to address, amount int64) {
	checkErr(grc20reg.MustGet(tokenKey).CallerTeller().Transfer(to, amount))
}

// Approve sets an allowance owned by the immediate caller. A direct user call
// uses the user's allowance; a realm cross-call uses the calling realm's.
func Approve(cur realm, tokenKey string, spender address, amount int64) {
	checkErr(grc20reg.MustGet(tokenKey).CallerTeller().Approve(spender, amount))
}

// TransferFrom spends an allowance as the immediate caller. A direct user is
// the spender; for a realm cross-call, the calling realm is the spender.
func TransferFrom(cur realm, tokenKey string, from, to address, amount int64) {
	checkErr(grc20reg.MustGet(tokenKey).CallerTeller().TransferFrom(from, to, amount))
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
