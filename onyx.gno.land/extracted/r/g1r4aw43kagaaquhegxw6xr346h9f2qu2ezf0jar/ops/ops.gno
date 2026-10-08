// Package ops is the house's till.
//
// WHAT IT IS FOR. The three arcade realms each take a cut -- 5% of a draw ticket,
// 3% of a duel stake -- and each pushes it to ONE compile-time address,
// opsVaultAddr, which is the address derived from THIS package's path. Until this
// realm existed, that address had no code at it: the money left the games and
// landed somewhere nothing could ever spend from. That is
// AUDIT-2026-10-07.md RED-2 and the arcade's own source names it, in terms, as
// "still blocking for deployment ... the owner's address is the missing input".
//
// This realm is that input, and nothing else. It holds wrapped GNOT and lets one
// address take it out.
//
// WHAT IT DELIBERATELY DOES NOT DO, because every one of these is a way for a
// till to become a liability:
//
//   - NO ACCESS TO ANY PRIZE POT. It cannot reach one. The draws pay winners from
//     their own balances and this realm has no call into them. The owner key
//     cannot touch a player's money because there is no code here that could.
//   - NO OWNERSHIP TRANSFER. owner is a compile-time constant with no setter, so
//     there is no function an attacker can reach to become the owner, and no
//     function the owner can be tricked into calling. The cost is stated below.
//   - NO PAUSE, NO UPGRADE, NO ADMIN. Nothing here can be turned off or changed
//     after deployment, by anyone.
//   - NO NATIVE COIN. chain/banker is not imported. This realm can move wrapped
//     GNOT and nothing else, which is what the games actually send.
//
// THE COST OF A FIXED OWNER, SAID PLAINLY RATHER THAN DISCOVERED LATER: if that
// key is lost, every coin in this realm is lost with it. There is no recovery
// path and cannot be one without adding exactly the kind of privileged function
// the list above refuses. That trade is the owner's and it was made knowingly.
package ops

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/r/gnoland/wugnot"
)

// owner is the only address that may withdraw. Compile-time, no setter.
//
// IT IS THE OWNER'S PERSONAL WALLET AND NOT A REALM, which is the opposite of
// how the games address this one. That is deliberate: a till wants a person at
// the end of it, and putting another contract there would just move the same
// question one step along.
const owner address = "g1srj6dxvyd378vm7787r45drryzvalcu32rdkfu"

// Owner reports who may withdraw. Exported so the claim is checkable from
// outside rather than taken from this comment.
func Owner() address { return owner }

// Balance is the wrapped GNOT this realm holds, read from wugnot rather than
// tracked in a counter of our own. A realm that keeps its own idea of its
// balance is a realm that can disagree with the truth.
func Balance(cur realm) int64 { return wugnot.BalanceOf(cur.Address()) }

// rejectAttachedCoin panics if the caller attached native coin to a call that
// has no use for it. Identical in shape and reasoning to the guard the three
// arcade realms gained on 2026-10-07: every money path here is wrapped GNOT, so
// attached ugnot would sit in this realm for ever with nothing able to reach it.
//
// Inert on a non-user call, for the reason r/splash/exchange's Buy comment
// gives: unsafe.OriginSend() reads the envelope attached at the chain root,
// shared by every realm in the call chain, so reading it is only sound when the
// immediate caller is an EOA.
func rejectAttachedCoin(cur realm, what string) {
	if !cur.Previous().IsUserCall() {
		return
	}
	if sent := unsafe.OriginSend(); len(sent) != 0 {
		panic("ops: " + what + " does not take native coin")
	}
}

// requireOwner is the only authorisation in this realm.
//
// cur.Previous().Address() AND NOT runtime.OriginCaller(). The origin caller is
// whoever signed the transaction, which is the same thing right up until the
// owner is persuaded to call some other realm that calls this one -- at which
// point an origin check would authorise a withdrawal the owner never asked for.
// The immediate caller is the one that cannot be borrowed.
func requireOwner(cur realm) {
	if cur.Previous().Address() != owner {
		panic("ops: only the owner may withdraw")
	}
}

// Withdraw sends `amount` of wrapped GNOT to the owner.
//
// THE DESTINATION IS NOT AN ARGUMENT. It is always the owner's own address, so
// there is no call shape in which this realm pays somebody else -- not by
// mistake, not by a malformed argument, not by a caller who has somehow got past
// requireOwner. A withdrawal function that takes a recipient is one typo away
// from being a drain.
func Withdraw(cur realm, amount int64) int64 {
	rejectAttachedCoin(cur, "Withdraw")
	requireOwner(cur)
	if amount <= 0 {
		panic("ops: amount must be positive")
	}
	have := wugnot.BalanceOf(cur.Address())
	if amount > have {
		panic("ops: asked for " + strconv.FormatInt(amount, 10) +
			" and hold " + strconv.FormatInt(have, 10))
	}
	wugnot.Transfer(cross(cur), owner, amount)
	chain.Emit("OpsWithdraw",
		"to", string(owner),
		"amount", strconv.FormatInt(amount, 10),
	)
	return amount
}

// WithdrawAll empties the till to the owner. Refuses on an empty one rather than
// succeeding with a zero transfer: "it worked" and "there was nothing there"
// are different answers and a caller deserves to be told which.
func WithdrawAll(cur realm) int64 {
	rejectAttachedCoin(cur, "WithdrawAll")
	requireOwner(cur)
	have := wugnot.BalanceOf(cur.Address())
	if have == 0 {
		panic("ops: nothing to withdraw")
	}
	wugnot.Transfer(cross(cur), owner, have)
	chain.Emit("OpsWithdraw",
		"to", string(owner),
		"amount", strconv.FormatInt(have, 10),
	)
	return have
}

func Render(path string) string {
	return "# SPLASH ops\n\n" +
		"The house's till. It holds the cut the three arcade games take " +
		"(5% of a draw ticket, 3% of a duel stake) and lets exactly one address " +
		"withdraw it.\n\n" +
		"- **Owner:** `" + string(owner) + "`\n" +
		"- **No ownership transfer, no pause, no upgrade, no admin.** None of " +
		"those functions exist here.\n" +
		"- **It cannot reach a prize pot.** There is no call from this realm " +
		"into any game.\n\n" +
		"If the owner's key is lost, the balance is lost with it. There is no " +
		"recovery path and adding one would mean adding the privileged function " +
		"this realm refuses to have.\n"
}
