package nslogic

import (
	"strings"
	"time"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
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
// A code that does not resolve — misspelt, lapsed, or the buyer's own
// name — is IGNORED, not rejected. The registration goes through at
// list price. Refusing to sell somebody a name because they mistyped
// somebody else's would be an absurd way to lose a sale.
func RegisterNameRef(cur realm, label, domainLabel, refName string) {
	registerName(cur, label, domainLabel, refName)
}

func registerName(cur realm, label, domainLabel, refName string) {
	validateLabel(label)
	if !DomainOpen(domainLabel) {
		panic("nslogic: this domain is not accepting new names")
	}
	caller := cur.Previous().Address()

	// Resolved BEFORE anything is written, so the tier and the discount
	// are read from the world the buyer was quoted in. Registering first
	// would change the buyer's own primary name and, on a self-referral
	// that slipped through, their tenure with it.
	ref := resolveReferrer(refName, caller)
	price := NamePrice(domainLabel, label)
	if ref != "" {
		if pct := tierPercent(RefDiscountRules(), TenureYears(ref)); pct > 0 {
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
	// paid: a referrer who earned nothing on the sale has no claim on
	// the renewals either, and storing them would say otherwise.
	if ref != "" && cut > 0 {
		setExtra(cur, label, domainLabel, keyRef, ref.String())
		creditReferral(cur, ref)
	}
}

// RenewName — same anchoring rule as RenewDomain: extends from the
// previous due date, not from the payment date. Deliberately does not
// call validateLabel — an already-registered name must keep renewing
// under whatever pattern was in force when it was minted.
func RenewName(cur realm, label, domainLabel string) {
	// No new code is accepted here and none is needed: the referrer was
	// fixed into this name when it was registered, and renewals keep
	// paying them for as long as the name survives unbroken. If it
	// lapses or is sold the vault destroys the record's extras, so the
	// link ends without this realm having to notice.
	//
	// Renewals pay the FULL price. The discount was a reason to arrive;
	// it is not a permanent lower rate, and compounding it every year
	// would make the referred name cheaper forever than the same name
	// bought directly.
	assertRoomToRenew(label, domainLabel)
	price := NamePrice(domainLabel, label)
	ref := ReferrerOf(label, domainLabel)
	payTo, cut := referralCut(ref, price)
	takePaymentSplit(cur, price, payTo, cut)

	caller := cur.Previous().Address()
	if err := nsdata.RenewNameRecord(cross(cur), label, domainLabel, caller, time.Now().Unix()); err != nil {
		panic(err)
	}
	if cut > 0 {
		creditReferral(cur, ref)
	}
}

// SetProfile writes the four conventional profile fields. Each lands in
// the name's extension slot, where the vault enforces size bounds.
func SetProfile(cur realm, label, domainLabel, displayName, bio, website, avatar string) {
	assertNoSend()
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
	assertNoSend()
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
	assertNoSend()
	caller := cur.Previous().Address()
	if nsdata.GetNameOwner(label, domainLabel) != caller {
		panic("nslogic: restricted to name owner")
	}
	if err := nsdata.SetPrimaryRecord(cross(cur), caller, label, domainLabel); err != nil {
		panic(err)
	}
}

// SetNameTTL is the owner's cache policy for their own name, in
// seconds, where 0 MEANS NEVER CACHE — copied from the ENS registry so
// integrators need not read anything of ours to handle it.
//
// The owner sets it rather than the registry because only they know the
// risk: a name being used to receive payments wants 0, since a cached
// answer after a sale pays the previous owner; a name used as a display
// handle can safely be cached for a long time.
func SetNameTTL(cur realm, label, domainLabel string, seconds int64) {
	assertNoSend()
	assertNameOwner(cur, label, domainLabel)
	if seconds < 0 {
		panic("nslogic: ttl may not be negative")
	}
	if err := nsdata.SetNameTTLRecord(cross(cur), label, domainLabel, seconds); err != nil {
		panic(err)
	}
}

func FreezeName(cur realm, label, domainLabel string) {
	assertNoSend()
	assertIsAdmin(cur)
	nsdata.SetNameFrozen(cross(cur), label, domainLabel, true)
}

func UnfreezeName(cur realm, label, domainLabel string) {
	assertNoSend()
	assertIsAdmin(cur)
	nsdata.SetNameFrozen(cross(cur), label, domainLabel, false)
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
