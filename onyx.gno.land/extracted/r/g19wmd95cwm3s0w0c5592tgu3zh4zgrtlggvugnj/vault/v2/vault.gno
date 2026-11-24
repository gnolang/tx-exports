// Package vault is the demo vault, version 2. Users deposit ugnot and
// withdraw it later. Version 2 fixes the bug Bouncer proved in version 1:
// Balances returns a copy of the ledger, not a pointer to it (security guide
// §5.1).
package vault

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

var (
	self   address         // this realm's address
	owner  address         // the deployer
	ledger = avl.NewTree() // address -> int64 ugnot owed to the depositor
)

func init(cur realm) {
	self = cur.Address()
	owner = cur.Previous().Address()
	// The deployer's opening deposit (addpkg -send) is the first entry.
	ledger.Set(string(owner), unsafe.OriginSend().AmountOf("ugnot"))
}

// Deposit credits the caller with the ugnot sent with the call.
func Deposit(cur realm) {
	if !cur.IsCurrent() {
		panic("not current")
	}
	if !cur.Previous().IsUserCall() {
		panic("deposit with maketx call")
	}
	amount := unsafe.OriginSend().AmountOf("ugnot")
	if amount <= 0 {
		panic("send ugnot to deposit")
	}
	caller := string(cur.Previous().Address())
	ledger.Set(caller, balanceOf(caller)+amount)
	chain.Emit("Deposit", "from", caller, "amount", strconv.FormatInt(amount, 10))
}

// Withdraw pays the caller back up to their balance.
func Withdraw(cur realm, amount int64) {
	if !cur.IsCurrent() {
		panic("not current")
	}
	caller := cur.Previous().Address()
	bal := balanceOf(string(caller))
	if amount <= 0 || amount > bal {
		panic("insufficient balance")
	}
	ledger.Set(string(caller), bal-amount)
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(self, caller, chain.Coins{chain.NewCoin("ugnot", amount)})
	chain.Emit("Withdraw", "to", caller.String(), "amount", strconv.FormatInt(amount, 10))
}

// BalanceOf returns addr's balance in ugnot.
func BalanceOf(addr address) int64 {
	return balanceOf(string(addr))
}

// Entry is one depositor's balance.
type Entry struct {
	Depositor address
	Balance   int64
}

// Balances returns a copy of the ledger, for frontends that list depositors.
func Balances() []Entry {
	out := make([]Entry, 0, ledger.Size())
	ledger.Iterate("", "", func(key string, value any) bool {
		out = append(out, Entry{Depositor: address(key), Balance: value.(int64)})
		return false
	})
	return out
}

func balanceOf(key string) int64 {
	if v := ledger.Get(key); v != nil {
		return v.(int64)
	}
	return 0
}

func Render(_ string) string {
	var sb strings.Builder
	sb.WriteString("# Vault v2\n\n")
	held := banker.NewReadonlyBanker().GetCoins(self).AmountOf("ugnot")
	sb.WriteString("Holds " + strconv.FormatInt(held, 10) + " ugnot.\n\n| Depositor | Balance (ugnot) |\n| --- | --- |\n")
	ledger.Iterate("", "", func(key string, value any) bool {
		sb.WriteString("| " + key + " | " + strconv.FormatInt(value.(int64), 10) + " |\n")
		return false
	})
	return sb.String()
}
