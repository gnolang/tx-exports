package token

import (
	"gno.land/p/demo/tokens/grc20"
	"gno.land/r/demo/defi/grc20reg"
)

const (
	tokenName   = "ZDEX"
	tokenSymbol = "ZDEX"
	tokenDec    = 6
	totalSupply = int64(1_000_000_000_000)
)

var (
	tok *grc20.Token
	led *grc20.PrivateLedger
	key string
)

func init(cur realm) {
	t, l := grc20.NewToken(tokenName, tokenSymbol, tokenDec, 0, cur)
	tok = t
	led = l
	owner := cur.Previous().Address()
	if err := led.Mint(owner, totalSupply); err != nil {
		panic(err.Error())
	}
	key = grc20reg.Register(cross(cur), tok, "")
}

func Key() string {
	return key
}

func Token() *grc20.Token {
	return tok
}

func TotalSupply() int64 {
	return tok.TotalSupply()
}

func BalanceOf(owner address) int64 {
	return tok.BalanceOf(owner)
}

func Approve(cur realm, spender address, amount int64) {
	if !cur.Previous().IsUserCall() {
		panic("zdex: EOA only")
	}
	if amount < 0 {
		panic("zdex: amount")
	}
	if err := led.Approve(cur.Previous().Address(), spender, amount); err != nil {
		panic(err.Error())
	}
}

func Transfer(cur realm, to address, amount int64) {
	if !cur.Previous().IsUserCall() {
		panic("zdex: EOA only")
	}
	if err := led.Transfer(cur.Previous().Address(), to, amount); err != nil {
		panic(err.Error())
	}
}

func Render(_ string) string {
	return "# ZDEX\n\nGRC20 for the zdex GNOT pool. Decimals 6. Registry key: `" + key + "`.\n"
}
