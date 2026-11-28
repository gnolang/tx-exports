// Package vaultfixed is the FIXED version of the demo TavernVault
// (design §9.1). It is deployed as its own realm path after the
// vulnerable vault is exploited in the demo, so the sponsor can call
// MarkFixed and the finding becomes Disclosed.
//
// The fix (two lines): Withdraw requires caller == victim, and pays
// the victim (who is now proven to be the caller).
package vaultfixed

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// deposits maps each depositor to their ugnot balance.
var deposits = make(map[address]int64)

// Deposit records the ugnot attached to this call under the caller.
// Only direct user calls may deposit, and the amount must be positive.
func Deposit(cur realm) {
	caller := cur.Previous().Address()
	if !cur.Previous().IsUserCall() {
		panic("deposit must be a direct user call")
	}
	amount := unsafe.OriginSend().AmountOf("ugnot")
	if amount <= 0 {
		panic("deposit amount must be positive")
	}
	deposits[caller] += amount
}

// BalanceOf returns the recorded deposit of addr (0 when none).
func BalanceOf(addr address) int64 {
	return deposits[addr]
}

// Withdraw sends amount ugnot of the caller's own deposit back to the
// caller. Fixed: the caller must be the victim, and the payout goes to
// the victim.
func Withdraw(cur realm, victim address, amount int64) {
	caller := cur.Previous().Address()
	if caller != victim {
		panic("not your deposit")
	}
	bal := deposits[victim]
	if amount <= 0 {
		panic("amount must be positive")
	}
	if amount > bal {
		panic("insufficient balance")
	}
	deposits[victim] = bal - amount
	banker.NewBanker(banker.BankerTypeRealmSend, cur).
		SendCoins(cur.Address(), victim,
			chain.NewCoins(chain.NewCoin("ugnot", amount)))
}
