// Package probe1789429680 is a minimal, throwaway realm deployed ONLY to
// confirm two mainnet-specific behaviors before the real gems5 launch:
// (1) whether a freshly-deployed package is immediately callable or
// held in some "inert until enabled" state, and (2) whether the exact
// AssertOriginCall + OriginSend + BankerTypeRealmSend payment-check
// pattern gems5/v1's MintAssembled relies on still behaves as expected
// on mainnet's current node build. Not part of the Gems collection --
// disposable.
package probe1789429680

import (
	"chain"
	"chain/banker"
	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"
)

var (
	owner    address = "g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku"
	received int64
	calls    int64
)

// TestPayment mirrors gems5/v1's MintAssembled payment check exactly.
// Forwards whatever ugnot is attached straight back to owner, so this
// costs only gas + storage deposit, not the attached amount itself.
func TestPayment(cur realm) {
	runtime.AssertOriginCall()
	if !unsaferealm.PreviousRealm().IsUserCall() {
		panic("payment verification requires a direct user call")
	}
	got := unsaferealm.OriginSend().AmountOf("ugnot")
	if got <= 0 {
		panic("attach a small amount of ugnot to test the payment path")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), owner, chain.Coins{{Denom: "ugnot", Amount: got}})
	received += got
	calls++
}

func Received() int64 { return received }
func Calls() int64    { return calls }

func Render(path string) string {
	return "# gems5 mainnet probe\n\nThrowaway realm, not part of the Gems collection. Confirms deploy + payment-check semantics before the real launch."
}
