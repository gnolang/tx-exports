// Package token is a fixed-supply GRC20-shaped fungible token realm.
//
// The full supply (TotalSupplyConst) is minted once, to the deploying
// address, inside init() — there is no ongoing or public Mint function
// afterward, and no way to create more supply later.
//
// Deliberately not a dependency on gno.land/p/demo/tokens/grc20: that
// package's NewToken constructor, Teller interface, and Token.ID()
// collision-safety were all found to diverge between gno.land networks
// (confirmed directly against each chain's deployed source, not
// assumed — see ~/gno-land-dev-notes.md's discovery log). Everything
// here is self-implemented on a vendored, network-agnostic avl.Tree
// instead — see gno.land/p/<addr>/avl/tree.gno's own header comment for
// why that package is vendored rather than imported from
// gno.land/p/nt/avl/v0.
package token

import (
	unsaferealm "chain/runtime/unsafe"
	"chain"
	"errors"
	"strconv"

	"gno.land/p/g1avv0u2d45d8lf8ywqxt8t867npwp4zvdxw2fl2/avl"
)

const (
	MintEvent     = "Mint"
	TransferEvent = "Transfer"
	ApprovalEvent = "Approval"
)

const (
	TokenName     = "Sample Token"
	TokenSymbol   = "SAMPLE"
	TokenDecimals = 6

	TotalSupplyConst int64 = 1_000_000
)

var (
	creator address = "g1avv0u2d45d8lf8ywqxt8t867npwp4zvdxw2fl2"

	balances   avl.Tree // address string -> int64
	allowances avl.Tree // "owner:spender" string -> int64
)

var (
	ErrInsufficientBalance   = errors.New("insufficient balance")
	ErrInsufficientAllowance = errors.New("insufficient allowance")
	ErrInvalidAddress        = errors.New("invalid address")
	ErrCannotTransferToSelf  = errors.New("cannot transfer to self")
	ErrInvalidAmount         = errors.New("invalid amount")
)

func init(cur realm) {
	balances.Set(creator.String(), TotalSupplyConst)
	chain.Emit(
		MintEvent,
		"to", creator.String(),
		"amount", strconv.FormatInt(TotalSupplyConst, 10),
	)
}

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func Name() string       { return TokenName }
func Symbol() string     { return TokenSymbol }
func Decimals() int      { return TokenDecimals }
func TotalSupply() int64 { return TotalSupplyConst }

func BalanceOf(addr address) int64 {
	v := balances.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

func Allowance(owner, spender address) int64 {
	v := allowances.Get(allowanceKey(owner, spender))
	if v == nil {
		return 0
	}
	return v.(int64)
}

func allowanceKey(owner, spender address) string {
	return owner.String() + ":" + spender.String()
}

func Transfer(cur realm, to address, amount int64) error {
	return transfer(callerAddress(), to, amount)
}

func Approve(cur realm, spender address, amount int64) error {
	owner := callerAddress()
	if !spender.IsValid() {
		return ErrInvalidAddress
	}
	if amount < 0 {
		return ErrInvalidAmount
	}
	allowances.Set(allowanceKey(owner, spender), amount)
	chain.Emit(
		ApprovalEvent,
		"owner", owner.String(),
		"spender", spender.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
	return nil
}

func TransferFrom(cur realm, from, to address, amount int64) error {
	spender := callerAddress()
	current := Allowance(from, spender)
	if current < amount {
		return ErrInsufficientAllowance
	}
	if err := transfer(from, to, amount); err != nil {
		return err
	}
	allowances.Set(allowanceKey(from, spender), current-amount)
	return nil
}

func transfer(from, to address, amount int64) error {
	if !to.IsValid() {
		return ErrInvalidAddress
	}
	if from == to {
		return ErrCannotTransferToSelf
	}
	if amount <= 0 {
		return ErrInvalidAmount
	}
	fromBal := BalanceOf(from)
	if fromBal < amount {
		return ErrInsufficientBalance
	}
	balances.Set(from.String(), fromBal-amount)
	balances.Set(to.String(), BalanceOf(to)+amount)
	chain.Emit(
		TransferEvent,
		"from", from.String(),
		"to", to.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
	return nil
}

func Render(path string) string {
	b := "# " + TokenName + " (" + TokenSymbol + ")\n\n"
	b += "* **Decimals**: " + strconv.Itoa(TokenDecimals) + "\n"
	b += "* **Total supply**: " + strconv.FormatInt(TotalSupply(), 10) + "\n"
	b += "* **Creator**: " + creator.String() + "\n"
	return b
}
