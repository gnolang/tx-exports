// Package vault is the DEMO VULNERABLE realm for BugTavern (design §9.1).
//
// DO NOT USE IN PRODUCTION. It is intentionally flawed so the demo can
// show a real Critical finding end to end: deposit, drain, bounty,
// commit, reveal, verdict, payout, disclosure.
//
// The flaw (one sentence): Withdraw checks the VICTIM's balance but
// sends the coins to the CALLER without checking caller == victim —
// anyone can drain anyone else's deposit.
//
// The fix lives in the sibling package vaultfixed (a separate realm
// path): it checks caller == victim and pays the victim. It is a
// separate directory because two files defining Deposit in one package
// cannot compile; the design doc's single-directory sketch (§3.3) is
// corrected on that point — see README.
package vault

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

// Withdraw sends amount ugnot of the VICTIM's deposit to the CALLER.
//
// VULNERABLE — INTENTIONAL: there is no check that the caller is the
// victim, and the payout goes to the caller instead of the victim.
// Anyone can call Withdraw(victim, victimBalance) and take everything.
func Withdraw(cur realm, victim address, amount int64) {
	caller := cur.Previous().Address()
	bal := deposits[victim]
	if amount <= 0 {
		panic("amount must be positive")
	}
	if amount > bal {
		panic("insufficient balance")
	}
	deposits[victim] = bal - amount
	banker.NewBanker(banker.BankerTypeRealmSend, cur).
		SendCoins(cur.Address(), caller,
			chain.NewCoins(chain.NewCoin("ugnot", amount)))
}
