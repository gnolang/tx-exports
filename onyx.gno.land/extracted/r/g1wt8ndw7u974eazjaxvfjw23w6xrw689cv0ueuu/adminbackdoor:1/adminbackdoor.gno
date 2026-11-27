// Package adminbackdoor is a deliberately vulnerable demo treasury realm
// for RealmCheck, the Gno.land audit demo entry for the Gnome Tavern
// Hackathon.
//
// A single hard-coded admin address controls the treasury. It is
// intentionally insecure: the admin can drain the entire treasury to any
// address in one call, with no timelock, no spending cap, no second
// approver, and no multisig. It also pays bonuses in vulnmint tokens
// through an external realm call whose result it never checks, so a failed
// payout is still recorded as paid.
//
// Demo only. Funds are modeled as an internal ledger (ugnot amounts tracked
// in memory) so the realm is self-contained and testable offline with
// `gno test`. Deploy vulnmint before this realm, because PayBonus calls it.
// The admin address below is a placeholder; replace it with the real admin
// address before any real use, and even then, do not use this code for a
// real treasury.
package adminbackdoor

import (
	"errors"
	"strconv"

	"chain"

	vulnmint "gno.land/r/g1wt8ndw7u974eazjaxvfjw23w6xrw689cv0ueuu/vulnmint"
)

// Admin is the single hard-coded admin address. Whoever controls this
// address controls the whole treasury.
var Admin = address("g1wt8ndw7u974eazjaxvfjw23w6xrw689cv0ueuu")

// treasury is the ugnot balance held by this realm, as an internal ledger.
var treasury int64

// drainedTo records how much Drain has paid to each address.
var drainedTo = map[address]int64{}

// paid records bonus amounts this realm claims to have paid to each
// address, whether or not the external transfer actually succeeded.
var paid = map[address]int64{}

// Fund credits amount to the treasury.
//
// Note: like the vault demo, this credits value without verifying that any
// payment was actually sent. That is a secondary demonstration of funds
// accepted without a check; the main vulnerability of this realm is the
// admin backdoor below.
func Fund(cur realm, amount int64) {
	if amount <= 0 {
		panic("fund amount must be positive")
	}
	treasury += amount
}

// Drain sends the entire treasury to to.
//
// INTENTIONAL VULNERABILITY (demo): owner/admin backdoor. Only the single
// hard-coded admin can call this, and once the admin calls it, the whole
// treasury moves at once: there is no timelock, no daily or per-call cap,
// no second approver, and no multisig. One compromised key, or one
// malicious admin, empties the treasury in a single transaction, and the
// payout address is freely chosen by the admin. A safe treasury would
// require multiple approvers, a timelock between proposal and execution,
// and a cap on each withdrawal.
func Drain(cur realm, to address) (int64, error) {
	caller := cur.Previous().Address()
	if caller != Admin {
		return 0, errors.New("only the admin can drain the treasury")
	}
	if to == "" {
		return 0, errors.New("drain to empty address")
	}
	amount := treasury
	treasury = 0
	drainedTo[to] += amount
	return amount, nil
}

// FundBonusPool mints amount vulnmint tokens into this realm's own balance
// so PayBonus has something to pay with. It works because vulnmint.Mint
// has no access control; anyone can mint.
func FundBonusPool(cur realm, amount int64) {
	vulnmint.Mint(cross(cur), cur.Address(), amount)
}

// BonusPool returns this realm's vulnmint balance, the pool PayBonus pays
// from.
func BonusPool() int64 {
	return vulnmint.BalanceOf(chain.PackageAddress("gno.land/r/g1wt8ndw7u974eazjaxvfjw23w6xrw689cv0ueuu/adminbackdoor"))
}

// PayBonus pays amount vulnmint tokens to to and records the payment.
//
// INTENTIONAL VULNERABILITY (demo): unchecked external realm call, and
// public state mutation with no guard. PayBonus calls
// vulnmint.Transfer, which returns an error when the bonus pool is empty,
// and discards that error with `_ =`. It then records the bonus as paid
// no matter what happened. If the transfer failed, the books claim to have
// paid money that never moved, and nobody is told. There is also no
// caller check, so anyone can trigger a bonus payment to anyone. A safe
// version would check the returned error and abort the payment, and would
// restrict who can pay bonuses.
func PayBonus(cur realm, to address, amount int64) {
	_ = vulnmint.Transfer(cross(cur), to, amount)
	paid[to] += amount
}

// Treasury returns the current treasury balance.
func Treasury() int64 {
	return treasury
}

// DrainedTo returns the total amount Drain has paid to addr.
func DrainedTo(addr address) int64 {
	return drainedTo[addr]
}

// PaidBonus returns the total bonus amount recorded as paid to addr.
func PaidBonus(addr address) int64 {
	return paid[addr]
}

// Render returns a short human readable summary of the treasury.
func Render(path string) string {
	return "# Admin Backdoor Treasury\n\n" +
		"Demo treasury for RealmCheck. One admin can drain it all.\n\n" +
		"Admin: " + string(Admin) + "\n" +
		"Treasury: " + strconv.FormatInt(treasury, 10) + " ugnot\n"
}
