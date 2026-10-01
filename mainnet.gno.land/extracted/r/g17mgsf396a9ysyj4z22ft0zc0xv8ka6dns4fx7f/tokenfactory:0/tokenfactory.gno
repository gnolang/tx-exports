package tokenfactory

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const creationFee = int64(40000000) // 40 GNOT

var (
	instances   avl.Tree
	nextTokenID seqid.ID

	feeRecipient = address(
		"g17mgsf396a9ysyj4z22ft0zc0xv8ka6dns4fx7f",
	)
)

type instance struct {
	token  *grc20.Token
	ledger *grc20.PrivateLedger
	admin  *ownable.Ownable
}

// CreationFee returns the token creation fee in ugnot.
func CreationFee() int64 {
	return creationFee
}

// FeeRecipient returns the address receiving creation fees.
func FeeRecipient() address {
	return feeRecipient
}

// CreateToken creates a new GRC20 token.
//
// initialSupply is expressed in the token's smallest unit.
//
// Example:
// decimals = 6
// initialSupply = 1000000000000
// => 1,000,000 tokens.
//
// A direct user call must attach exactly 40 GNOT.
func CreateToken(
	cur realm,
	name string,
	symbol string,
	decimals int,
	initialSupply int64,
) string {
	// Creation must come directly from a user wallet.
	if !cur.Previous().IsUserCall() {
		panic("token creation must be called directly by a user")
	}

	// Exactly 40 GNOT must be attached.
	if unsafe.OriginSend().AmountOf("ugnot") != creationFee {
		panic("invalid token creation fee")
	}

	if name == "" {
		panic("token name cannot be empty")
	}

	if symbol == "" {
		panic("token symbol cannot be empty")
	}

	if decimals < 0 {
		panic("decimals cannot be negative")
	}

	if initialSupply < 0 {
		panic("initial supply cannot be negative")
	}

	if instances.Has(symbol) {
		panic("token symbol already exists")
	}

	creator := cur.Previous().Address()

	token, ledger := grc20.NewToken(
		name,
		symbol,
		decimals,
		nextTokenID.Next(),
		cur,
	)

	// Mint the user-selected initial supply directly
	// to the wallet that created the token.
	if initialSupply > 0 {
		checkErr(
			ledger.Mint(
				creator,
				initialSupply,
			),
		)
	}

	inst := instance{
		token:  token,
		ledger: ledger,
		admin:  ownable.NewWithAddress(creator),
	}

	instances.Set(
		symbol,
		&inst,
	)

	// Register the token in the canonical GRC20 registry.
	grc20reg.Register(
		cross(cur),
		token,
		symbol,
	)

	// Transfer the 40 GNOT creation fee
	// from the Token Factory realm directly
	// to the GNO Explorer fee recipient.
	banker_ := banker.NewBanker(
		banker.BankerTypeRealmSend,
		cur,
	)

	feeCoins := chain.NewCoins(
		chain.NewCoin(
			"ugnot",
			creationFee,
		),
	)

	banker_.SendCoins(
		cur.Address(),
		feeRecipient,
		feeCoins,
	)

	return token.ID()
}

// Bank returns the GRC20 token instance.
func Bank(symbol string) *grc20.Token {
	return mustGetInstance(symbol).token
}

// TokenID returns the unique GRC20 token ID.
func TokenID(symbol string) string {
	return mustGetInstance(symbol).token.ID()
}

// TotalSupply returns the total token supply.
func TotalSupply(symbol string) int64 {
	return mustGetInstance(symbol).
		token.
		ReadonlyTeller().
		TotalSupply()
}

// BalanceOf returns the token balance of an address.
func BalanceOf(
	symbol string,
	owner address,
) int64 {
	return mustGetInstance(symbol).
		token.
		ReadonlyTeller().
		BalanceOf(owner)
}

// Mint allows the token owner to mint additional tokens.
func Mint(
	cur realm,
	symbol string,
	to address,
	amount int64,
) {
	if amount <= 0 {
		panic("mint amount must be greater than zero")
	}

	inst := mustGetInstance(symbol)

	inst.admin.AssertOwnedBy(
		cur.Previous().Address(),
	)

	checkErr(
		inst.ledger.Mint(
			to,
			amount,
		),
	)
}

// Burn allows the token owner to burn tokens.
func Burn(
	cur realm,
	symbol string,
	from address,
	amount int64,
) {
	if amount <= 0 {
		panic("burn amount must be greater than zero")
	}

	inst := mustGetInstance(symbol)

	inst.admin.AssertOwnedBy(
		cur.Previous().Address(),
	)

	checkErr(
		inst.ledger.Burn(
			from,
			amount,
		),
	)
}

// TransferTokenOwnership transfers administration
// of a token to another address.
func TransferTokenOwnership(
	cur realm,
	symbol string,
	newOwner address,
) {
	inst := mustGetInstance(symbol)

	checkErr(
		inst.admin.TransferOwnership(
			0,
			cur,
			newOwner,
		),
	)
}

// DropTokenOwnership permanently removes
// the administrator of the token.
func DropTokenOwnership(
	cur realm,
	symbol string,
) {
	inst := mustGetInstance(symbol)

	checkErr(
		inst.admin.DropOwnership(
			0,
			cur,
		),
	)
}

func mustGetInstance(
	symbol string,
) *instance {
	value := instances.Get(symbol)

	if value == nil {
		panic("token does not exist")
	}

	return value.(*instance)
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}