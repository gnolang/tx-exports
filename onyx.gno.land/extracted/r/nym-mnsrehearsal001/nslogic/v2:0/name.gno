package nslogic

import (
	"chain"
	"strings"
	"time"

	"gno.land/r/nym-mnsrehearsal001/nsdata/v2"
)

// Profile field names inside a name's extension slot. The vault stores
// them as opaque strings and bounds their size; what they MEAN is this
// realm's convention, so new profile fields need no vault change.
const (
	keyDisplayName = "displayName"
	keyBio         = "bio"
	keyWebsite     = "website"
	keyAvatar      = "avatar"
)

// RegisterName mints `label*domain` under an existing domain. Anyone may
// call this. Minting still works while the parent domain is past its own
// due date, as long as its grace period hasn't fully lapsed and it isn't
// frozen — nsdata's RegisterNameRecord enforces that.
func RegisterName(cur realm, label, domainLabel string) {
	registerName(cur, label, domainLabel, "")
}

// RegisterNameRef is RegisterName with a referral code — the NAME of
// whoever sent the buyer here, as it appears in the link.
//
// It is a second entry point rather than a third argument on the first
// one because the first one is already deployed and already being called
// by wallets and by the site. Changing its arity would break every one
// of those callers at the same instant, which is exactly the failure the
// voting realm produced last time; adding a function breaks nothing and
// lets the front end pick whichever the deployed realm actually has.
//
// A code that does not earn — misspelt, lapsed, the buyer's own name, a
// free-tier name, or one not yet held for thirty days (referral.gno) — is
// IGNORED, not rejected. The registration goes through at list price.
// Refusing to sell somebody a name because they mistyped somebody else's
// would be an absurd way to lose a sale.
func RegisterNameRef(cur realm, label, domainLabel, refName string) {
	registerName(cur, label, domainLabel, refName)
}

func registerName(cur realm, label, domainLabel, refName string) {
	assertNotRestoring()
	validateLabel(label)
	assertNotBlocked(label)
	if !DomainOpen(domainLabel) {
		panic("nslogic: this domain is not accepting new names")
	}
	caller := cur.Previous().Address()

	// Resolved BEFORE anything is written, so the code is judged in the
	// world the buyer was quoted in.
	ref := resolveReferrer(refName, caller)
	price := NamePrice(domainLabel, label)
	if ref != "" {
		if _, pct := RefRates(); pct > 0 {
			price -= price * pct / 100
		}
	}
	payTo, cut := referralCut(ref, price)
	takePaymentSplit(cur, price, payTo, cut)

	if err := nsdata.RegisterNameRecord(cross(cur), label, domainLabel, caller, time.Now().Unix(), true); err != nil {
		panic(err)
	}

	// Written after the record exists, because the extension slot is
	// created by registration. Only recorded when the cut was actually
	// paid: the record says who brought this buyer, and a referrer who
	// earned nothing did not.
	if ref != "" && cut > 0 {
		setExtra(cur, label, domainLabel, keyRef, ref.String())
		creditReferral(cur, ref)
		// Money left the treasury's share: say so, so a monitor can add up
		// what referral rules are costing without reading every tx.
		chain.Emit("ReferralPaid", "tid", label+"*"+domainLabel, "referrer", ref.String(),
			"amount", fmtInt(cut), "price", fmtInt(price))
	}
}

// RenewName — same anchoring rule as RenewDomain: extends from the
// previous due date, not from the payment date. Deliberately does not
// call validateLabel — an already-registered name must keep renewing
// under whatever pattern was in force when it was minted.
func RenewName(cur realm, label, domainLabel string) {
	// Not while a restore window is open: the prices may not be back yet
	// (restore.gno, assertNotRestoring; review follow-up).
	assertNotRestoring()
	// FIRST YEAR ONLY (referral.gno): a renewal pays the full price, all
	// of it to the treasury, and nobody's cut. Renewals used to pay the
	// referrer for as long as the name survived, which made a second
	// wallet's code a permanent discount on its owner's own renewals.
	assertRoomToRenew(label, domainLabel)
	takePayment(cur, NamePrice(domainLabel, label))

	caller := cur.Previous().Address()
	if err := nsdata.RenewNameRecord(cross(cur), label, domainLabel, caller, time.Now().Unix()); err != nil {
		panic(err)
	}
}

// SetProfile writes the four conventional profile fields. Each lands in
// the name's extension slot, where the vault enforces size bounds.
func SetProfile(cur realm, label, domainLabel, displayName, bio, website, avatar string) {
	assertNoSend(cur)
	assertNameOwner(cur, label, domainLabel)
	setExtra(cur, label, domainLabel, keyDisplayName, displayName)
	setExtra(cur, label, domainLabel, keyBio, bio)
	setExtra(cur, label, domainLabel, keyWebsite, website)
	setExtra(cur, label, domainLabel, keyAvatar, avatar)
}

// SetNameField writes a single arbitrary key — cross-chain addresses and
// anything else a future feature needs, with no vault change required.
// Keys used by this realm's own machinery are reserved.
func SetNameField(cur realm, label, domainLabel, key, value string) {
	assertNoSend(cur)
	assertNameOwner(cur, label, domainLabel)
	if strings.HasPrefix(key, "_") {
		panic("nslogic: keys beginning with '_' are reserved")
	}
	// `ref` decides who gets paid out of every renewal of this name. A
	// holder who could write it would set it to an address they control
	// and take a permanent cut of their own renewals out of the
	// treasury — so the one key that moves money is the one key its
	// owner may not touch.
	if key == keyRef {
		panic("nslogic: '" + keyRef + "' is set at registration and cannot be edited")
	}
	setExtra(cur, label, domainLabel, key, value)
}

func setExtra(cur realm, label, domainLabel, key, value string) {
	if err := nsdata.SetNameExtraRecord(cross(cur), label, domainLabel, key, value); err != nil {
		panic(err)
	}
}

func assertNameOwner(cur realm, label, domainLabel string) {
	if nsdata.GetNameOwner(label, domainLabel) != cur.Previous().Address() {
		panic("nslogic: restricted to name owner")
	}
}

// SetPrimaryName lets a wallet explicitly choose (and later change) which
// of its names is used for reverse resolution.
func SetPrimaryName(cur realm, label, domainLabel string) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	if nsdata.GetNameOwner(label, domainLabel) != caller {
		panic("nslogic: restricted to name owner")
	}
	if err := nsdata.SetPrimaryRecord(cross(cur), caller, label, domainLabel); err != nil {
		panic(err)
	}
}

/*
ClearPrimaryName switches reverse resolution OFF for the caller.

WHY THIS HAS TO EXIST, and it is a hole rather than a feature request.

nsdata sets the reverse pointer AUTOMATICALLY on a wallet's first
registration — RegisterNameRecord does it, and nothing asked the person
first. From that moment their address answers with their name, so anybody
who sees that address anywhere can find the persona attached to it, and
every transaction it has ever made becomes attributable. Retroactively:
the chain is permanent and indexers keep copies.

And until now there was NO WAY OUT. ClearPrimaryRecord is gated to
trusted logic, and no logic realm exposed it, so the one person the
pointer is about could not remove it. A name service is a bridge between
a persona and a wallet; publishing that bridge without consent and
without an exit is the worst version of it.

This is the exit. It takes no arguments on purpose: a wallet has exactly
one reverse pointer, and the only address it can clear is its own, so
there is nothing to pass and nothing to get wrong.

WHAT IT DOES NOT DO, said plainly because a promise we cannot keep would
be worse than the hole: clearing stops FUTURE lookups. It does not
unpublish what was already visible, and it cannot — the history is on
chain and other people have copies. The honest sequence is to choose
before publishing, which is why the site now shows what the link exposes
before it offers to make it.
*/
func ClearPrimaryName(cur realm) {
	assertNoSend(cur)
	nsdata.ClearPrimaryRecord(cross(cur), cur.Previous().Address())
}

// maxTTL caps a cache policy, a name's or a domain's: 2^31-1 seconds,
// about 68 years, the ceiling DNS itself uses (RFC 2181). Anything longer
// reads as forever to every resolver, and an unbounded value did not
// survive a snapshot (restore.gno, ttlSecs).
const maxTTL = int64(1<<31 - 1)

// SetNameTTL is the owner's cache policy for their own name, in
// seconds, where 0 MEANS NEVER CACHE — copied from the ENS registry so
// integrators need not read anything of ours to handle it.
//
// The owner sets it rather than the registry because only they know the
// risk: a name being used to receive payments wants 0, since a cached
// answer after a sale pays the previous owner; a name used as a display
// handle can safely be cached for a long time. At most maxTTL.
func SetNameTTL(cur realm, label, domainLabel string, seconds int64) {
	assertNoSend(cur)
	assertNameOwner(cur, label, domainLabel)
	if seconds < 0 || seconds > maxTTL {
		panic("nslogic: a ttl is 0.." + fmtInt(maxTTL) + " seconds")
	}
	if err := nsdata.SetNameTTLRecord(cross(cur), label, domainLabel, seconds); err != nil {
		panic(err)
	}
}

func FreezeName(cur realm, label, domainLabel string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "FreezeName", "label", label, "domain", domainLabel)
	nsdata.SetNameFrozen(cross(cur), label, domainLabel, true)
}

// UnfreezeName is TIMELOCKED (timelock.gno); freezing stays instant. A
// freeze is the takedown and dispute lever — a disputed or stolen name is
// held while it is sorted out — so releasing one instantly would let a
// stolen admin key free a name and move it in the same transaction.
func UnfreezeName(cur realm, label, domainLabel string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "UnfreezeName", "label", label, "domain", domainLabel)
	requireAction(cur, actionID("UnfreezeName", label, domainLabel))
	nsdata.SetNameFrozen(cross(cur), label, domainLabel, false)
}

// UnfreezeNames releases several names behind ONE timelocked action:
// propose exactly "UnfreezeNames a*meme,b*doge,…" (token ids, comma-
// separated, at most maxUnfreezeBatch). A stolen key freezes names one call
// each and instantly, about a thousand a block; releasing them one action
// each, with at most 32 actions pending, took ⌈N/32⌉ timelocks (re-audit
// 2026-10-16, L-3). One unknown or malformed name refuses the whole call.
const maxUnfreezeBatch = 64

func UnfreezeNames(cur realm, tids string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "UnfreezeNames", "tids", tids)
	list := strings.Split(tids, ",")
	if tids == "" || len(list) > maxUnfreezeBatch {
		panic("nslogic: 1.." + fmtI(maxUnfreezeBatch) + " token ids, comma-separated")
	}
	type ref struct{ label, domain string }
	refs := make([]ref, 0, len(list))
	for _, tid := range list {
		label, domainLabel := splitTokenID(tid)
		if label == "" || domainLabel == "" || !nsdata.NameExists(label, domainLabel) {
			panic("nslogic: not a registered name: " + tid)
		}
		refs = append(refs, ref{label, domainLabel})
	}
	requireAction(cur, actionID("UnfreezeNames", tids))
	for _, r := range refs {
		nsdata.SetNameFrozen(cross(cur), r.label, r.domain, false)
	}
}

// -- resolution --

func ResolveName(label, domainLabel string) address {
	if !nsdata.IsNameValid(label, domainLabel) {
		panic("nslogic: name is expired")
	}
	return nsdata.GetNameOwner(label, domainLabel)
}

// ResolveAddress performs reverse resolution: address -> name.
//
// It must verify the ownership it is asserting, not merely that the
// pointed-at name exists and is unexpired. nsdata's `primary` tree is a
// record of what an address last SELECTED, not proof of what it still
// owns — and although nsdata now clears the pointer on transfer and
// reclaim, this check is the half that lives in the swappable realm and
// therefore stays correct even against pointers written by an older
// version of the logic. Without it, an address that sold or lost a name
// kept reverse-resolving to it, impersonating the new owner.
func ResolveAddress(addr address) string {
	tid := nsdata.GetPrimary(addr)
	if tid == "" {
		return ""
	}
	label, domainLabel := splitTokenID(tid)
	if !nsdata.IsNameValid(label, domainLabel) {
		return ""
	}
	if nsdata.GetNameOwner(label, domainLabel) != addr {
		return ""
	}
	return tid
}

// splitTokenID splits a `label*domain` token ID.
func splitTokenID(tid string) (label, domainLabel string) {
	for i := 0; i < len(tid); i++ {
		if tid[i] == '*' {
			return tid[:i], tid[i+1:]
		}
	}
	return tid, ""
}
