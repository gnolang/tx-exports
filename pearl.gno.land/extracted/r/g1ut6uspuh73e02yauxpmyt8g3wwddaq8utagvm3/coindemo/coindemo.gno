// Realm coindemo is a deliberately minimal third consumer proving the
// extracted primitives compose: coinio handles every coin movement,
// feeledger handles every balance. It is an echo-vault: deposit GNOT,
// claim it back in full (no fees), owner sweeps out-of-band surplus.
//
// Conservation: H == U + S (no fee pot, no app escrow), where U is the
// ledger's users total and S >= 0 is out-of-band surplus, recoverable
// only via the owner's Sweep which reserves U.
package coindemo

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
)

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

var (
	owner  address // may sweep surplus
	self   address // this realm's address, captured at deploy
	ledger = feeledger.MustNew(0) // zero fee cap: pure echo accounting
)

func init() {
	owner = unsafe.OriginCaller()
	self = unsafe.CurrentRealm().Address()
}

// Deposit credits the caller with the attached GNOT, in full.
func Deposit(cur realm) {
	from, amount := coinio.Receive(0, cur, Denom)
	if _, _, err := ledger.Deposit(from.String(), amount, 0); err != nil {
		panic(err)
	}
	chain.Emit("Deposit", "from", from.String(), "amount", fmtInt(amount))
}

// ClaimAll sends the caller's entire balance back. Fails if empty.
func ClaimAll(cur realm) {
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", fmtInt(amount))
}

// Sweep sends ugnot held above user liabilities to the owner. Owner
// only; user balances are reserved by construction.
func Sweep(cur realm) {
	if cur.Previous().Address() != owner {
		panic("owner only")
	}
	swept := coinio.Sweep(0, cur, owner, Denom, ledger.Liabilities())
	chain.Emit("SurplusSwept", "to", owner.String(), "amount", fmtInt(swept))
}

// TransferOwner hands the sweep role to next. Owner only; zero
// address rejected (audit Y3: without rotation, key loss permanently
// orphans surplus sweeping).
func TransferOwner(cur realm, next address) {
	if cur.Previous().Address() != owner {
		panic("owner only")
	}
	var zero address
	if next == zero {
		panic("empty owner address")
	}
	owner = next
	chain.Emit("OwnerTransferred", "newOwner", next.String())
}

// --- read-only views ---

// Owner returns who may sweep surplus.
func Owner() address { return owner }

// BalanceOf returns addr's claimable balance.
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// UsersTotal returns the sum of all claimable balances.
func UsersTotal() int64 { return ledger.UsersTotal() }

// Held returns the ugnot actually held at the realm address.
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns Held() - UsersTotal().
func Surplus() int64 { return Held() - ledger.Liabilities() }

// Address returns this realm's address (the deposit target).
func Address() address { return self }

// Render shows totals and the conservation check.
func Render(_ string) string {
	held := Held()
	status := "OK"
	if held < ledger.Liabilities() {
		status = "VIOLATED"
	}
	return "# Coindemo\n\n" +
		"Echo-vault composing coinio + feeledger.\n\n" +
		"- claimable (U): " + fmtInt(ledger.UsersTotal()) + Denom + "\n" +
		"- held (H): " + fmtInt(held) + Denom + "\n" +
		"- conservation (H >= U): " + status + "\n"
}

func fmtInt(n int64) string {
	return strconv.FormatInt(n, 10)
}
