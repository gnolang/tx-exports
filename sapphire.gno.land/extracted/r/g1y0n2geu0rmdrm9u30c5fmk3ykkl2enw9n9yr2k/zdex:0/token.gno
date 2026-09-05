package zdex

import (
	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/demo/defi/grc20reg"
)

type tokenRec struct {
	token  *grc20.Token
	ledger *grc20.PrivateLedger
}

var nextTok seqid.ID

func getTok(symbol string) *tokenRec {
	v := tokens.Get(symbol)
	if v == nil {
		panic("zdex: unknown token " + symbol)
	}
	return v.(*tokenRec)
}

func tryTok(symbol string) *tokenRec {
	v := tokens.Get(symbol)
	if v == nil {
		return nil
	}
	return v.(*tokenRec)
}

func mintInternal(cur realm, name, symbol string, decimals, amount int64, to address) string {
	require(tryTok(symbol) == nil, "zdex: symbol taken")
	require(decimals >= 0 && decimals <= 18, "zdex: decimals")
	tok, led := grc20.NewToken(name, symbol, int(decimals), nextTok.Next(), cur)
	if amount > 0 {
		checkErr(led.Mint(to, amount))
	}
	tokens.Set(symbol, &tokenRec{token: tok, ledger: led})
	return grc20reg.Register(cross(cur), tok, "")
}

func pullUserToken(_ int, rlm realm, symbol string, from address, amount int64) {
	require(amount > 0, "zdex: amount")
	require(from == rlm.Previous().Address(), "zdex: from must be caller")
	rec := tryTok(symbol)
	if rec != nil {
		checkErr(rec.token.CallerTeller().Transfer(0, rlm, thisAddr(), amount))
		return
	}
	grc20reg.TransferFrom(cross(rlm), symbol, from, thisAddr(), amount)
}

func pushToken(_ int, rlm realm, symbol string, to address, amount int64) {
	require(amount > 0, "zdex: amount")
	rec := tryTok(symbol)
	if rec != nil {
		checkErr(rec.ledger.Transfer(thisAddr(), to, amount))
		return
	}
	grc20reg.Transfer(cross(rlm), symbol, to, amount)
}

func tokenBalance(symbol string, owner address) int64 {
	rec := tryTok(symbol)
	if rec != nil {
		return rec.token.BalanceOf(owner)
	}
	t := grc20reg.Get(symbol)
	if t == nil {
		return 0
	}
	return t.BalanceOf(owner)
}

// Transfer moves an internally minted token. External GRC20s are transferred
// on their own realm.
func Transfer(cur realm, symbol string, to address, amount int64) {
	rec := getTok(symbol)
	checkErr(rec.token.CallerTeller().Transfer(0, cur, to, amount))
}

func Approve(cur realm, symbol string, spender address, amount int64) {
	rec := getTok(symbol)
	checkErr(rec.token.CallerTeller().Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, symbol string, from, to address, amount int64) {
	rec := getTok(symbol)
	checkErr(rec.token.CallerTeller().TransferFrom(0, cur, from, to, amount))
}

func BalanceOf(symbol string, owner address) int64 {
	return tokenBalance(symbol, owner)
}

func TotalSupply(symbol string) int64 {
	rec := tryTok(symbol)
	if rec == nil {
		t := grc20reg.Get(symbol)
		if t == nil {
			return 0
		}
		return t.TotalSupply()
	}
	return rec.token.TotalSupply()
}

func TokenKey(symbol string) string {
	rec := tryTok(symbol)
	if rec == nil {
		return ""
	}
	return rec.token.ID()
}
