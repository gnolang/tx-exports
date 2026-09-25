// Package coinio is the chain-facing coin plumbing that every
// value-holding realm on gno.land repeats: verified payment receipt,
// disciplined payout, and reserve-protected surplus sweeping. It was
// extracted from two audited, pearl-1-validated realms (vault and
// bounties) whose implementations of these mechanics were
// line-identical.
//
// The package is PURE and STATELESS: it holds no balances, no roles,
// and no configuration; all state stays in the consuming realm (and
// its accounting package, e.g. feeledger). It emits no events —
// consumers emit their own. Every function either succeeds or panics,
// aborting the transaction: these are payment guards, and no failure
// here has a meaningful recovery path.
//
// CAPABILITY CONTRACT: pure packages cannot declare crossing
// functions (a first `realm` parameter), so every coin-moving function
// here uses the canonical secondary-parameter shape `(_ int, rlm
// realm, ...)` — the same pattern as chain treasury packages. Pass 0
// and your crossing entrypoint's own live `cur` (forwarded through
// non-crossing calls keeps it current). Each function asserts
// rlm.IsCurrent() before acting, so a stale, stored, or Previous()
// realm value fails closed (the designation-forgery guard secondary
// realm parameters require). Coins can only move FROM rlm.Address() —
// the calling realm itself — so no consumer can spend another realm's
// funds through this package.
//
// AUTHORIZATION is the consumer's responsibility: coinio decides HOW
// coins move, never WHO may move them. Gate your entrypoints before
// calling in.
//
// ORDERING CONTRACT (the one invariant coinio cannot enforce): debit
// your own accounting BEFORE calling Payout or Sweep
// (checks-effects-interactions). A panic inside coinio aborts the
// whole transaction, reverting your debit with it — that is what makes
// the debit-first order safe.
package coinio

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// Receive verifies the canonical receipt-guaranteed payment shape and
// returns the payer and amount:
//
//   - the caller of the consuming realm's entrypoint is an EOA via
//     MsgCall (IsUserCall) — the only shape where the chain guarantees
//     the -send envelope landed at the realm address before the body
//     ran (realms and maketx-run are rejected);
//   - the envelope is exactly one coin of the given denom;
//   - the amount is positive.
//
// Receive is a READ of the transaction's send envelope, NOT a
// consumption: a stateless pure package cannot mark an envelope spent,
// so calling Receive N times in one transaction reports the same
// envelope N times. CALL IT AT MOST ONCE PER TRANSACTION and credit
// its result at most once — a consumer that credits per call mints
// unbacked liabilities from a single -send.
//
// Call it first (and once) in any payable crossing entrypoint:
//
//	func Deposit(cur realm) {
//		from, amount := coinio.Receive(0, cur, "ugnot")
//		// credit `from` with `amount` in your accounting
//	}
func Receive(_ int, rlm realm, denom string) (from address, amount int64) {
	if !rlm.IsCurrent() {
		panic("coinio: realm capability is not current")
	}
	if denom == "" {
		panic("coinio: empty denom")
	}
	if !rlm.Previous().IsUserCall() {
		panic("coinio: payment must be a direct EOA call with -send (realms and maketx-run are rejected)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom {
		panic("coinio: send exactly one coin type: " + denom)
	}
	if sent[0].Amount <= 0 {
		panic("coinio: amount must be positive")
	}
	return rlm.Previous().Address(), sent[0].Amount
}

// Payout sends amount of denom from the calling realm's own address to
// `to`. DEBIT YOUR ACCOUNTING FIRST — a panic here (or anywhere later
// in the transaction) reverts the debit together with the send.
func Payout(_ int, rlm realm, to address, denom string, amount int64) {
	if !rlm.IsCurrent() {
		panic("coinio: realm capability is not current")
	}
	var zero address
	if to == zero {
		panic("coinio: empty payout address")
	}
	if denom == "" {
		panic("coinio: empty denom")
	}
	if amount <= 0 {
		panic("coinio: amount must be positive")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{chain.NewCoin(denom, amount)})
}

// Sweep sends the surplus of a single denomination — everything the
// calling realm holds above `reserve` — to `to`, and returns the swept
// amount. Pass your total liabilities as the reserve for the denom
// your accounting tracks, and 0 for foreign denominations. Panics if
// there is no positive surplus, so reserved funds are untouchable by
// construction. One denomination per call keeps the operation gas-
// bounded regardless of how many junk denoms third parties force-send.
func Sweep(_ int, rlm realm, to address, denom string, reserve int64) int64 {
	if !rlm.IsCurrent() {
		panic("coinio: realm capability is not current")
	}
	var zero address
	if to == zero {
		panic("coinio: empty sweep address")
	}
	if denom == "" {
		panic("coinio: empty denom")
	}
	if reserve < 0 {
		panic("coinio: negative reserve")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	surplus := bk.GetCoin(rlm.Address(), denom) - reserve
	if surplus <= 0 {
		panic("coinio: no surplus to sweep for " + denom)
	}
	bk.SendCoins(rlm.Address(), to, chain.Coins{chain.NewCoin(denom, surplus)})
	return surplus
}

// HeldAt returns the amount of denom held at addr. Read-only; usable
// from views and Render without a realm capability.
func HeldAt(addr address, denom string) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, denom)
}
