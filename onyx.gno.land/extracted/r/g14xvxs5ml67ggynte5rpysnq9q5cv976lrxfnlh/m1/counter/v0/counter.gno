// Package counter is the M1 learning realm: a throwaway contract whose real
// job is to exercise, end to end, every primitive the oracle will need later:
//
//   - persistent state (variables that survive between transactions)
//   - caller identity  (who called? -> the oracle's per-source feeder allowlist)
//   - block height     (when was it called? -> the oracle's staleness rule)
//   - an admin guard   (only one address may do X -> the oracle's admin functions)
//   - Render           (the realm's public web page -> the oracle's health view)
//
// API verified 2026-11-25 against gnolang/gno tag v1.8.0:
//
//	examples/gno.land/r/demo/counter (crossing-fn + Render signatures),
//	examples/gno.land/r/demo/disperse (cur.Previous() auth pattern),
//	gnovm/stdlibs/chain/runtime/native.gno (ChainHeight),
//	gnovm/pkg/gnolang/uverse.go (address is string-based -> comparable).
package counter

import (
	"strconv"

	"chain/runtime"
)

// ---- Persistent state ----------------------------------------------------
// Package-level vars in a realm (/r/ path) are stored on-chain: they keep
// their values between transactions, paid for by the realm's storage deposit.

var (
	count      int     // the counter itself
	lastCaller address // who called Increment most recently
	lastHeight int64   // block height at which that call happened
)

// admin is alice — the deployer key. Hard-coding an address like this is the
// simplest form of on-chain authorization. (The oracle will use a 3-entry
// allowlist of feeder addresses instead of a single admin.)
var admin = address("g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh")

// ---- Public functions ----------------------------------------------------

// Increment can be called by ANYONE (gnokey maketx call).
//
// `cur realm` is the caller-context parameter every "crossing function"
// receives: it tells us who is calling and through which path. cur.Previous()
// is the caller one frame back — for a direct user transaction, that's the
// user's address. This is the v1.8.0 replacement for the old std.PrevRealm().
func Increment(cur realm) int {
	count++
	lastCaller = cur.Previous().Address() // record WHO called
	lastHeight = runtime.ChainHeight()    // record WHEN (block height)
	return count
}

// SetCount is ADMIN-ONLY. If anyone else calls it, the transaction panics —
// on-chain, a panic rolls back every state change the call made and the
// caller still pays gas. This guard pattern (check caller, else panic) is
// exactly what the oracle will use for feeder submissions and admin actions.
func SetCount(cur realm, n int) {
	caller := cur.Previous()
	// IsUserCall() is true only for a direct transaction from a wallet
	// (an "externally owned account"). It is false when another realm or a
	// `maketx run` script calls us — closing the "confused deputy" hole
	// where a malicious contract pretends to be its user.
	if !caller.IsUserCall() {
		panic("counter: SetCount requires a direct user call")
	}
	if caller.Address() != admin {
		panic("counter: only the admin may set the count")
	}
	count = n
}

// Render is NOT a transaction — it's a free, read-only query. gnoweb and the
// chain's /vm/qrender endpoint call it to build the realm's public page.
// The oracle will render feed health here (prices, ages, quorum status).
func Render(_ string) string {
	return "count:       " + strconv.Itoa(count) + "\n" +
		"last caller: " + lastCaller.String() + "\n" +
		"last height: " + strconv.FormatInt(lastHeight, 10) + "\n"
}
