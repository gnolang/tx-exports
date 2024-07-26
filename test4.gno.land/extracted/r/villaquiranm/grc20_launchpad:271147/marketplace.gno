
package grc20_marketplace

import (
	"std"
	"strings"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ownable"
	"gno.land/p/demo/ufmt"
)

var (
	fee float64 = 0.025 // initialized at 2.5%
	vault std.Address  	// address receiving fee from total supply
	admin std.Address	// admin
	instances avl.Tree // symbol -> instance
)


func init() {
	admin = std.PrevRealm().Addr()
}

func NewGRC20(name, symbol string, decimals uint, initialMint uint64, imageURL string, creator std.Address, totalSupply uint64) {
	//Should we check for token name ? to avoid conflicts different symbol but same name ?
	exists := instances.Has(symbol)
	if exists {
		panic("token already exists")
	}

	banker := grc20.NewBanker(name, symbol, decimals)
	if initialMint > 0 {
		banker.Mint(creator, initialMint)
	}

	inst := instance{
		banker: banker,
		admin:  ownable.NewWithAddress(creator),
		imageURL: imageURL,
	}

	if totalSupply > 0 {
		inst.totalSupply = totalSupply
	}

	instances.Set(symbol, &inst)
}

type instance struct {
	banker *grc20.Banker
	admin  *ownable.Ownable
	imageURL string // per-request amount. disabled if 0.
	totalSupply uint64
}

func (inst instance) Token() grc20.Token { return inst.banker.Token() }

func TotalSupply(symbol string) uint64 {
	inst := mustGetInstance(symbol)
	return inst.Token().TotalSupply()
}

func BalanceOf(symbol string, owner std.Address) uint64 {
	inst := mustGetInstance(symbol)
	return inst.Token().BalanceOf(owner)
}

func Allowance(symbol string, owner, spender std.Address) uint64 {
	inst := mustGetInstance(symbol)
	return inst.Token().Allowance(owner, spender)
}

func Transfer(symbol string, to std.Address, amount uint64) {
	inst := mustGetInstance(symbol)
	checkErr(inst.Token().Transfer(to, amount))
}

func Approve(symbol string, spender std.Address, amount uint64) {
	inst := mustGetInstance(symbol)
	checkErr(inst.Token().Approve(spender, amount))
}

func TransferFrom(symbol string, from, to std.Address, amount uint64) {
	inst := mustGetInstance(symbol)
	checkErr(inst.Token().TransferFrom(from, to, amount))
}


func Mint(symbol string, to std.Address, amount uint64) {
	inst := mustGetInstance(symbol)
	inst.admin.AssertCallerIsOwner()
	checkErr(inst.banker.Mint(to, amount))
}

func Burn(symbol string, from std.Address, amount uint64) {
	inst := mustGetInstance(symbol)
	inst.admin.AssertCallerIsOwner()
	checkErr(inst.banker.Burn(from, amount))
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return "TODO: list existing tokens and admins"
	case c == 1:
		symbol := parts[0]
		inst := mustGetInstance(symbol)
		return inst.banker.RenderHome()
	case c == 3 && parts[1] == "balance":
		symbol := parts[0]
		inst := mustGetInstance(symbol)
		owner := std.Address(parts[2])
		balance := inst.Token().BalanceOf(owner)
		return ufmt.Sprintf("%d", balance)
	default:
		return "404\n"
	}
}

func mustGetInstance(symbol string) *instance {
	t, exists := instances.Get(symbol)
	if !exists {
		panic("token instance does not exist")
	}
	return t.(*instance)
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
