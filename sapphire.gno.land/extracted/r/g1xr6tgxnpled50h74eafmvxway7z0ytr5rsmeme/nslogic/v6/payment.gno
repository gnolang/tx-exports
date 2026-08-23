package nslogic

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// takePayment verifies the attached send-envelope covers `price` ugnot,
// forwards the price to the treasury, and refunds any overpayment to the
// caller in the same transaction. Nothing is ever retained: every ugnot
// that arrives leaves again, as either payment or refund.
//
// It used to take a `beneficiary` and split the price fee/remainder,
// routing the remainder to treasury only while `beneficiary == admin`.
// That comparison was a proxy for "is this a project-owned domain", and
// it silently broke the moment `admin` rotated — the planned EOA-to-
// multisig step — because a domain's owner is frozen into its record at
// registration time. After a rotation, every registration's remainder
// would have been paid to the retired key instead of the treasury, with
// no error and no log line.
//
// The heuristic is gone rather than patched. Domains are admin-only to
// create and permanently non-transferable, so every domain is
// project-owned by construction and 100% of every payment belongs to the
// treasury. `platformFeeBps` stays in nsdata's config for a future logic
// realm that reintroduces third-party domain ownership; reinstating the
// split is then a logic-realm swap, not a migration.
func takePayment(cur realm, price int64) {
	takePaymentSplit(cur, price, "", 0)
}

// takePaymentSplit is takePayment with a referrer's cut carved out of the
// same price. The buyer pays exactly what they were quoted; the cut is
// not added on top, it is a share of what the treasury would otherwise
// have received.
//
// All three legs settle inside the buyer's own transaction — treasury,
// referrer, refund — so this realm's balance is the same after the call
// as before it. That is not a stylistic preference: holding a referrer's
// cut until they claim it would make this an account you can have a
// balance in, and that is a different kind of thing to operate, subject
// to a different set of rules, run by people with licences. The cut is
// paid now or it is not paid.
func takePaymentSplit(cur realm, price int64, cutTo address, cut int64) {
	if !cur.Previous().IsUserCall() {
		panic("nslogic: only direct wallet calls may attach payment")
	}
	caller := cur.Previous().Address()
	sent := unsafe.OriginSend()
	assertOnlyUgnot(sent)

	paid := sent.AmountOf(ugnot)
	if paid < price {
		panic(ufmt.Sprintf("nslogic: insufficient payment: need %d ugnot, got %d", price, paid))
	}
	excess := paid - price

	// Belt and braces. referralCut already caps the percentage, but this
	// is the line where the arithmetic becomes money leaving an address,
	// and a bug upstream must not be able to pay out more than came in.
	if cut < 0 || cut > price || cutTo == "" {
		cut = 0
	}

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	pkgAddr := cur.Address()
	if cut > 0 {
		b.SendCoins(pkgAddr, cutTo, chain.Coins{chain.NewCoin(ugnot, cut)})
	}
	if price-cut > 0 {
		b.SendCoins(pkgAddr, nsdata.GetTreasury(), chain.Coins{chain.NewCoin(ugnot, price-cut)})
	}
	if excess > 0 {
		b.SendCoins(pkgAddr, caller, chain.Coins{chain.NewCoin(ugnot, excess)})
	}
}

// assertOnlyUgnot rejects any other denomination outright. Only the
// ugnot amount was ever accounted for, and neither realm has a
// withdrawal path, so a foreign coin sent alongside a payment would have
// been stranded in this realm's address permanently. Refusing the whole
// transaction is simpler than sweeping it back and keeps the
// "this realm never retains funds" invariant absolute.
func assertOnlyUgnot(sent chain.Coins) {
	for _, c := range sent {
		if c.Denom != ugnot {
			panic("nslogic: only ugnot is accepted, got: " + c.Denom)
		}
	}
}

// assertNoSend guards every entry point that has no price. Without it,
// coins attached to a free call (a renewal of a project domain, a
// profile edit, an admin setter) would land in this realm's address with
// no way back out.
func assertNoSend() {
	if !unsafe.OriginSend().IsZero() {
		panic("nslogic: this function takes no payment; do not attach coins")
	}
}
