// Package vaultfixed — unit tests for the FIXED vault (design §9.1).
//
// The fix: Withdraw requires caller == victim and pays the victim.
// An attacker calling Withdraw(victim, amount) must panic and move no
// coins; the victim withdrawing their own deposit still works.
package vaultfixed

import (
	"testing"

	"chain"
	"chain/banker"
)

const (
	fixedVictimAddr   = "g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m"
	fixedAttackerAddr = "g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8"
)

const fixedVaultPkgPath = "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/vaultfixed"

// mustPanic runs fn and fails the test unless fn panics.
func mustPanic(t *testing.T, name string, fn func()) {
	t.Helper()
	panicked := false
	func() {
		defer func() {
			if recover() != nil {
				panicked = true
			}
		}()
		fn()
	}()
	if !panicked {
		t.Fatalf("%s: expected panic, got none", name)
	}
}

// TestWithdrawByNonVictimPanics is the day-7 PoC, fixed side (design
// §9.2): the same attacker call that drains the vulnerable vault must
// panic here, leave the victim's balance untouched at 5 GNOT, and
// move no coins to the attacker or out of the vault.
//
// NOTE: Withdraw is called WITHOUT cross(cur) on purpose. A panic
// from a crossing call becomes an abort at the realm boundary and is
// not catchable by recover(); a direct call in the same realm keeps
// the panic local and recoverable. The fix panics before any coin
// moves, so the direct call proves the guard.
func TestWithdrawByNonVictimPanics(cur realm, t *testing.T) {
	deposits = make(map[address]int64)
	victim := address(fixedVictimAddr)
	attacker := address(fixedAttackerAddr)
	realmAddr := chain.PackageAddress(fixedVaultPkgPath)
	deposits[victim] = 5000000
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 5000000}})
	testing.SetRealm(testing.NewUserRealm(attacker))
	mustPanic(t, "Withdraw by non-victim", func() {
		Withdraw(cur, victim, 5000000)
	})
	if got := BalanceOf(victim); got != 5000000 {
		t.Fatalf("BalanceOf(victim) after refused Withdraw = %d, want 5000000", got)
	}
	bank := banker.NewReadonlyBanker()
	if got := bank.GetCoin(attacker, "ugnot"); got != 0 {
		t.Fatalf("attacker bank balance = %d, want 0", got)
	}
	if got := bank.GetCoin(realmAddr, "ugnot"); got != 5000000 {
		t.Fatalf("vault bank balance = %d, want 5000000", got)
	}
}

// TestWithdrawByVictimSucceeds is the positive control for the fix:
// the victim withdrawing their own deposit still works, and the
// coins go to the victim.
func TestWithdrawByVictimSucceeds(cur realm, t *testing.T) {
	deposits = make(map[address]int64)
	victim := address(fixedVictimAddr)
	realmAddr := chain.PackageAddress(fixedVaultPkgPath)
	deposits[victim] = 5000000
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 5000000}})
	testing.SetRealm(testing.NewUserRealm(victim))
	Withdraw(cross(cur), victim, 5000000)
	if got := BalanceOf(victim); got != 0 {
		t.Fatalf("BalanceOf(victim) after own Withdraw = %d, want 0", got)
	}
	bank := banker.NewReadonlyBanker()
	if got := bank.GetCoin(victim, "ugnot"); got != 5000000 {
		t.Fatalf("victim bank balance = %d, want 5000000", got)
	}
	if got := bank.GetCoin(realmAddr, "ugnot"); got != 0 {
		t.Fatalf("vault bank balance = %d, want 0", got)
	}
}
