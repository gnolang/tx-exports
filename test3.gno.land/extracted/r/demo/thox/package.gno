package thox

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"

	pusers "gno.land/p/demo/users"
)

var (
	tokenbest *grc20.AdminToken
	admin     std.Address = "g1v664qx78zhv2edtx6ypdylfpafrqjz8g2rlaea"
)

func init() {
	tokenbest = grc20.NewAdminToken("Thox", "TOHX", 4)

	tokenbest.Mint(admin, 1000000*10000)
}

func TotalSupply() uint64 {
	return tokenbest.TotalSupply()
}

func BalanceOf(owner pusers.AddressOrName) uint64 {
	balance, err := tokenbest.BalanceOf(users.Resolve(owner))
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender pusers.AddressOrName) uint64 {
	allowance, err := tokenbest.Allowance(users.Resolve(owner), users.Resolve(spender))
	if err != nil {
		panic(err)
	}
	return allowance
}

func Transfer(to pusers.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	err := tokenbest.Transfer(caller, users.Resolve(to), amount)
	if err != nil {
		panic(err)
	}
}

func Approve(spender pusers.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	err := tokenbest.Approve(caller, users.Resolve(spender), amount)
	if err != nil {
		panic(err)
	}
}

func TransferFrom(from, to pusers.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	err := tokenbest.TransferFrom(caller, users.Resolve(from), users.Resolve(to), amount)
	if err != nil {
		panic(err)
	}
}

func Mint(address pusers.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := tokenbest.Mint(users.Resolve(address), amount)
	if err != nil {
		panic(err)
	}
}

func Burn(address pusers.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := tokenbest.Burn(users.Resolve(address), amount)
	if err != nil {
		panic(err)
	}
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return tokenbest.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := pusers.AddressOrName(parts[1])
		balance, _ := tokenbest.BalanceOf(users.Resolve(owner))
		return ufmt.Sprintf("%d\n", balance)
	default:
		return "404\n"
	}
}

func assertIsAdmin(address std.Address) {
	if address != admin {
		panic("restricted access")
	}
}