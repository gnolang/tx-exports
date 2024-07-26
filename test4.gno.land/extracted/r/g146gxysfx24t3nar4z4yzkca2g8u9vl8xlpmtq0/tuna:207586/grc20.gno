package tuna

import (
	"std"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ownable"
	pusers "gno.land/p/demo/users"
	"gno.land/r/demo/users"
)

var (
	banker *grc20.Banker
	admin  *ownable.Ownable
	token  grc20.Token
)

func init() {
	admin = ownable.NewWithAddress("g146gxysfx24t3nar4z4yzkca2g8u9vl8xlpmtq0")
	banker = grc20.NewBanker("Office", "OFC", 6)
	banker.Mint(admin.Owner(), 1000000000*1000000)
	token = banker.Token()
}

func TotalSupply() uint64 { return token.TotalSupply() }

func BalanceOf(owner pusers.AddressOrName) uint64 {
	ownerAddr := users.Resolve(owner)
	return token.BalanceOf(ownerAddr)
}

func Allowance(owner, spender pusers.AddressOrName) uint64 {
	ownerAddr := users.Resolve(owner)
	spenderAddr := users.Resolve(spender)
	return token.Allowance(ownerAddr, spenderAddr)
}

func Transfer(to pusers.AddressOrName, amount uint64) {
	toAddr := users.Resolve(to)
	checkErr(token.Transfer(toAddr, amount))
}

func Approve(spender pusers.AddressOrName, amount uint64) {
	spenderAddr := users.Resolve(spender)
	checkErr(token.Approve(spenderAddr, amount))
}

func TransferFrom(from, to pusers.AddressOrName, amount uint64) {
	fromAddr := users.Resolve(from)
	toAddr := users.Resolve(to)
	checkErr(token.TransferFrom(fromAddr, toAddr, amount))
}

func Faucet() {
	caller := std.PrevRealm().Addr()
	amount := uint64(1_000 * 10_000) // 1k
	checkErr(banker.Mint(caller, amount))
}

func Mint(to pusers.AddressOrName, amount uint64) {
	admin.AssertCallerIsOwner()
	toAddr := users.Resolve(to)
	checkErr(banker.Mint(toAddr, amount))
}

func Burn(from pusers.AddressOrName, amount uint64) {
	admin.AssertCallerIsOwner()
	fromAddr := users.Resolve(from)
	checkErr(banker.Burn(fromAddr, amount))
}

func Render(path string) string {
	return path
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}