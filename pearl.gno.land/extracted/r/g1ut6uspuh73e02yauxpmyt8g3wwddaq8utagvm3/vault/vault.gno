// Realm vault holds GNOT deposits with per-user balances and an
// explicit, inspectable protocol fee, built on
// gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger.
//
// Flow: an EOA deposits GNOT by calling Deposit with coins attached
// (`-send`); the configured fee (FeeBps, capped at MaxFeeBps) accrues to
// a separate fee pot and the remainder credits the depositor's balance.
// Users claim their balance back at any time, partially or fully. The
// fee recipient — a role distinct from the admin — withdraws the fee
// pot.
//
// FEE MODEL (all values inspectable via FeeBps/FeeRecipient/MaxFeeBps):
//   - fee = floor(amount * FeeBps / 10000); rounding favors the
//     depositor; no minimum fee (small deposits may pay 0).
//   - FeeBps starts at 0 (no fee) and is changed only by the admin via
//     SetFeeBps, hard-capped at MaxFeeBps (10% — the cap itself is a
//     compile-time constant and cannot be raised by anyone).
//   - A fee change applies to FUTURE deposits only; already-accrued fees
//     and user balances are untouched.
//   - Fees accrue to a pot, not an address. Changing the fee recipient
//     re-points who may withdraw the pot, INCLUDING what was accrued
//     under the previous recipient (positional, documented trade-off).
//   - With FeeBps == 0 deposits credit in full and the pot grows by 0.
//   - The fee can never exceed the deposit: FeeBps <= 10000 structurally
//     and <= 1000 by this realm's cap.
//
// ACCOUNTING INVARIANT (conservation): let H be the ugnot held at this
// realm's address, U the sum of user balances, F the accrued fee pot.
// At every transaction boundary:
//
//	H == U + F + S,  S >= 0
//
// where S (surplus) is ugnot pushed to the realm address outside
// Deposit (e.g. a direct bank send). S stays 0 if all coins arrive via
// Deposit. Derivation from chain semantics: (1) a MsgCall `-send`
// envelope is transferred to the realm address BEFORE the call body
// runs, and Deposit's IsUserCall guard is exactly the case where that
// receipt is guaranteed, so Deposit raises U+F by the amount already
// added to H; (2) Claim/WithdrawFees debit the ledger first, then move
// the identical amount out via a RealmSend banker, lowering H and U+F
// equally; (3) any panic aborts the whole transaction, reverting ledger
// and coin movements together (atomicity); (4) this realm never uses
// IssueCoin/RemoveCoin. Surplus is intentionally unreachable: it can
// only be swept by the fee recipient via SweepSurplus, never counted as
// a user balance.
//
// ONLY GNOT: Deposit rejects any transaction whose send envelope is not
// exactly one ugnot coin. Other assets force-sent to the realm address
// are not accepted, not tracked, and sit in surplus.
package vault

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
)

// Denom is the only asset this vault accepts.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%. Nobody can
// configure a higher fee; changing this requires deploying a new realm.
const MaxFeeBps = int64(1000)

var (
	admin        address // may set fee, fee recipient, and successor admin
	feeRecipient address // may withdraw the fee pot and sweep surplus
	feeBps       int64   // current protocol fee in basis points

	self   address // this realm's own address, captured at deploy
	ledger = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller() // the deployer
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// Deposit credits the caller with the attached GNOT minus the current
// protocol fee. Only direct EOA calls (maketx call with -send) are
// accepted: that is the only shape where the chain guarantees the send
// envelope landed at this realm's address before the body runs. The
// envelope must be exactly one coin of denom ugnot with positive
// amount.
func Deposit(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("deposit must be a direct EOA call with -send (realms and maketx-run are rejected)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("send exactly one coin type: " + Denom)
	}
	amount := sent[0].Amount
	if amount <= 0 {
		panic("deposit amount must be positive")
	}

	depositor := cur.Previous().Address()
	credited, fee, err := ledger.Deposit(depositor.String(), amount, feeBps)
	if err != nil {
		panic(err)
	}
	chain.Emit("Deposit",
		"from", depositor.String(),
		"amount", itoa(amount),
		"credited", itoa(credited),
		"fee", itoa(fee),
	)
}

// Claim sends amount ugnot of the caller's balance back to the caller.
// Fails if amount is not positive or exceeds the caller's balance.
func Claim(cur realm, amount int64) {
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	send(cur, caller, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire balance back to the caller. Fails
// if the caller has no balance.
func ClaimAll(cur realm) {
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	send(cur, caller, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// WithdrawFees sends the entire accrued fee pot to the fee recipient.
// Only the fee recipient may call it. Fails if the pot is empty.
func WithdrawFees(cur realm) {
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may withdraw fees")
	}
	amount := ledger.WithdrawFees()
	if amount == 0 {
		panic("no fees accrued")
	}
	send(cur, feeRecipient, amount)
	chain.Emit("FeesWithdrawn", "to", feeRecipient.String(), "amount", itoa(amount))
}

// SweepSurplus sends coins that sit at the realm address ABOVE the
// ledger's liabilities (ugnot force-sent outside Deposit, or any other
// denomination) to the fee recipient. Only the fee recipient may call
// it. User balances and the fee pot are untouchable by construction:
// only the excess over Liabilities() moves. Fails if there is no
// surplus.
func SweepSurplus(cur realm) {
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may sweep surplus")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	held := bk.GetCoins(self)
	var out chain.Coins
	for _, c := range held {
		if c.Denom == Denom {
			surplus := c.Amount - ledger.Liabilities()
			if surplus > 0 {
				out = append(out, chain.NewCoin(Denom, surplus))
			}
			continue
		}
		if c.Amount > 0 {
			out = append(out, c)
		}
	}
	if len(out) == 0 {
		panic("no surplus to sweep")
	}
	bk.SendCoins(self, feeRecipient, out)
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", out.String())
}

// SweepDenom sends the surplus of a single denomination to the fee
// recipient. This is the bounded escape hatch for when SweepSurplus
// would exceed gas because a third party force-sent many junk
// denominations to the realm address: each call touches exactly one
// denomination, so ugnot surplus can always be recovered regardless of
// how many foreign denoms accumulate. For ugnot only the excess over
// Liabilities() moves; any other denom moves wholly. Only the fee
// recipient may call it.
func SweepDenom(cur realm, denom string) {
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may sweep surplus")
	}
	if denom == "" {
		panic("empty denom")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	amount := bk.GetCoin(self, denom)
	if denom == Denom {
		amount -= ledger.Liabilities()
	}
	if amount <= 0 {
		panic("no surplus to sweep for " + denom)
	}
	bk.SendCoins(self, feeRecipient, chain.Coins{chain.NewCoin(denom, amount)})
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(amount)+denom)
}

// SetFeeBps sets the protocol fee for FUTURE deposits. Admin only;
// bounded by [0, MaxFeeBps].
func SetFeeBps(cur realm, bps int64) {
	assertAdmin(cur.Previous().Address())
	if bps < 0 || bps > MaxFeeBps {
		panic("fee bps out of range [0, " + itoa(MaxFeeBps) + "]")
	}
	old := feeBps
	feeBps = bps
	chain.Emit("FeeBpsChanged", "old", itoa(old), "new", itoa(bps))
}

// SetFeeRecipient re-points who may withdraw the fee pot (including
// fees accrued before the change) and sweep surplus. Admin only; the
// zero address is rejected.
func SetFeeRecipient(cur realm, next address) {
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty fee recipient")
	}
	old := feeRecipient
	feeRecipient = next
	chain.Emit("FeeRecipientChanged", "old", old.String(), "new", next.String())
}

// TransferAdmin hands the admin role to next. Admin only; the zero
// address is rejected. One-step: a transfer to a wrong-but-valid
// address permanently loses fee administration (deposits and claims
// keep working).
func TransferAdmin(cur realm, next address) {
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty admin address")
	}
	admin = next
	chain.Emit("AdminTransferred", "newAdmin", next.String())
}

// --- read-only views ---

// Admin returns the current admin.
func Admin() address { return admin }

// FeeRecipient returns who may withdraw the fee pot.
func FeeRecipient() address { return feeRecipient }

// FeeBps returns the protocol fee applied to future deposits, in basis
// points of the deposit amount.
func FeeBps() int64 { return feeBps }

// FeeOn previews the fee and credited amount for a deposit of amount at
// the CURRENT FeeBps.
func FeeOn(amount int64) (fee, credited int64) {
	f, err := feeledger.FeeFor(amount, feeBps)
	if err != nil {
		panic(err)
	}
	return f, amount - f
}

// BalanceOf returns addr's claimable balance.
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// UsersTotal returns the sum of all user balances.
func UsersTotal() int64 { return ledger.UsersTotal() }

// FeesAccrued returns the fee pot awaiting withdrawal.
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns UsersTotal() + FeesAccrued().
func Liabilities() int64 { return ledger.Liabilities() }

// Held returns the ugnot actually held at the realm address.
func Held() int64 {
	return banker.NewReadonlyBanker().GetCoin(self, Denom)
}

// Surplus returns Held() - Liabilities(): ugnot at the realm address
// that the ledger does not owe to anyone. Negative would indicate a
// conservation bug (see the invariant in the package doc).
func Surplus() int64 { return Held() - ledger.Liabilities() }

// Address returns this realm's own address (the deposit target).
func Address() address { return self }

// Render shows configuration, totals, and the live conservation check.
func Render(_ string) string {
	held := Held()
	liab := ledger.Liabilities()
	status := "OK"
	if held < liab {
		status = "VIOLATED"
	}
	out := "# Vault\n\n"
	out += "GNOT deposits with per-user balances and an explicit protocol fee.\n\n"
	out += "## Fee configuration\n\n"
	out += "- fee: " + itoa(feeBps) + " bps (cap " + itoa(MaxFeeBps) + " bps)\n"
	out += "- fee recipient: " + feeRecipient.String() + "\n"
	out += "- admin: " + admin.String() + "\n\n"
	out += "## Accounting\n\n"
	out += "- users total: " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fees accrued: " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held: " + itoa(held) + Denom + "\n"
	out += "- accounts: " + strconv.Itoa(ledger.Accounts()) + "\n"
	out += "- conservation (held >= users+fees): " + status + "\n"
	return out
}

// --- internals ---

// assertAdmin gates admin-only entrypoints; callers resolve identity at
// the crossing boundary and pass the address down.
func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

// send moves amount ugnot from the realm to `to`. Callers must have
// debited the ledger first (checks-effects-interactions); a panic here
// aborts the transaction, reverting the debit with it.
func send(cur realm, to address, amount int64) {
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(self, to, chain.Coins{chain.NewCoin(Denom, amount)})
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}
