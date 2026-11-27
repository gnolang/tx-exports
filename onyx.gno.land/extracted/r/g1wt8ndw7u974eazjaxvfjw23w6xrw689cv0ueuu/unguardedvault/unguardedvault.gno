// Package unguardedvault is a deliberately vulnerable demo vault realm for
// RealmCheck, the Gno.land audit demo entry for the Gnome Tavern Hackathon.
//
// The vault accepts deposits and lets anyone withdraw funds. It is
// intentionally insecure in two ways: deposits are credited without verifying
// that any coins were actually sent, and withdrawals have no caller check, so
// anyone can drain deposits that belong to someone else.
//
// Demo only. Funds are modeled as an internal ledger (ugnot amounts tracked
// in memory) so the realm is self-contained and testable offline with
// `gno test`. A production vault would move real ugnot with
// banker.SendCoins; the missing checks demonstrated here are identical in
// that version, because the checks belong around the ledger update and the
// payout, not inside the banker call.
package unguardedvault

import (
	"errors"
	"strconv"

	"chain/runtime/unsafe"
)

// deposits records how much each address has deposited.
var deposits = map[address]int64{}

// paidOut records how much has been paid out to each address by Withdraw.
var paidOut = map[address]int64{}

// vaultBalance is the total amount currently held by the vault.
var vaultBalance int64

// Deposit credits amount to the caller's deposit balance.
//
// INTENTIONAL VULNERABILITY (demo): funds accepted without a check. This
// function reads the coins actually sent with the transaction through
// unsafe.OriginSend(), then ignores them and credits the claimed amount
// instead. It never compares the sent amount with the claimed amount, and
// it does not require the caller to be a user call. Any caller can claim
// a deposit of any size while sending nothing, or sending far less, and
// the vault will treat the invented deposit as real funds. A safe version
// would credit exactly the sent amount, and only that amount.
func Deposit(cur realm, amount int64) {
	caller := cur.Previous().Address()
	if amount <= 0 {
		panic("deposit amount must be positive")
	}
	sent := unsafe.OriginSend()
	_ = sent // the sent coins are read and then never checked
	deposits[caller] += amount
	vaultBalance += amount
}

// Withdraw pays amount out of the vault to to.
//
// INTENTIONAL VULNERABILITY (demo): missing caller check on a funds
// function. This function never checks who the caller is, and it never
// checks that the caller owns the funds being withdrawn. Any address can
// call Withdraw and send the vault's funds, including other users'
// deposits, to any address it chooses. The only check is that the vault
// holds enough in total. A safe version would require the caller to be the
// depositor (or an approved spender) and would debit that caller's own
// deposit balance, never the pooled balance of strangers.
func Withdraw(cur realm, to address, amount int64) error {
	if to == "" {
		return errors.New("withdraw to empty address")
	}
	if amount <= 0 {
		return errors.New("withdraw amount must be positive")
	}
	if amount > vaultBalance {
		return errors.New("insufficient vault balance")
	}
	vaultBalance -= amount
	paidOut[to] += amount
	return nil
}

// BalanceOf returns the recorded deposit balance of addr. Note that this
// bookkeeping can disagree with reality after an unguarded withdrawal,
// because Withdraw pays from the pooled balance without debiting any
// individual depositor. That disagreement is part of the demonstration.
func BalanceOf(addr address) int64 {
	return deposits[addr]
}

// VaultBalance returns the total amount currently held by the vault.
func VaultBalance() int64 {
	return vaultBalance
}

// PaidOut returns the total amount Withdraw has paid to addr.
func PaidOut(addr address) int64 {
	return paidOut[addr]
}

// Render returns a short human readable summary of the vault.
func Render(path string) string {
	return "# Unguarded Vault\n\n" +
		"Demo vault for RealmCheck. Anyone can withdraw.\n\n" +
		"Vault balance: " + strconv.FormatInt(vaultBalance, 10) + " ugnot\n"
}
