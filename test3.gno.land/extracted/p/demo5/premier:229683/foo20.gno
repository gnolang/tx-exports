package foo

import (
	"errors"
	"std"
	"strings"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	foo   *grc20.AdminToken
	admin std.Address = "g1at4q8pkwwll82azmxek7enpvyhh2c94mmk2c67"
)
func assertIsAdmin() error {
	caller := std.GetOrigCaller()
	if caller != admin {
		return errors.New("you're not admin")
	}
	return nil
}
func init() {
	foo = grc20.NewAdminToken("Foo Token", "FOO", 4)
	foo.Mint(admin, 100)
}
func Mint(address users.AddressOrName, amount uint64) error {
	if err := assertIsAdmin(); err != nil {
		return err
	}
	foo.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) error {
	if err := assertIsAdmin(); err != nil {
		return err
	}

	foo.Burn(address.Resolve(), amount)
	return nil
}
func TotalSupply() uint64 {
	return foo.TotalSupply()
}

func BalanceOf(account users.AddressOrName) uint64 {
	balance, err := foo.BalanceOf(account.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	foo.Transfer(caller, to.Resolve(), amount)
}

func FaucetWithAdmin() error {
	if err := assertIsAdmin(); err != nil {
		return err
	}
	caller := std.GetOrigCaller()
	foo.Mint(caller, 200)
	return nil
}

func FaucetWithoutAdmin() {
	caller := std.GetOrigCaller()
	foo.Mint(caller, 200) 
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := foo.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

func Approve(spender users.AddressOrName, amount uint64) error {
	owner := std.GetOrigCaller()

	if err := foo.Approve(owner, spender.Resolve(), amount); err != nil {
		return err
	}
	return nil
}

func TransferFrom(from, to users.AddressOrName, amount uint64) error {
	spender := std.GetOrigCaller()
	if err := foo.TransferFrom(spender, from.Resolve(), to.Resolve(), amount); err != nil {
		return err
	}
	return nil
}
