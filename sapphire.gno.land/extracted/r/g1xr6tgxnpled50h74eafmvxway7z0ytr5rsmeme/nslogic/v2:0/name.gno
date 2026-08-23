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
	validateLabel(label)
	if !DomainOpen(domainLabel) {
		panic("nslogic: this domain is not accepting new names")
	}
	takePayment(cur, NamePrice(domainLabel, label))

	caller := cur.Previous().Address()
	if err := nsdata.RegisterNameRecord(cross(cur), label, domainLabel, caller, time.Now().Unix(), true); err != nil {
		panic(err)
	}
}

// RenewName — same anchoring rule as RenewDomain: extends from the
// previous due date, not from the payment date. Deliberately does not
// call validateLabel — an already-registered name must keep renewing
// under whatever pattern was in force when it was minted.
func RenewName(cur realm, label, domainLabel string) {
	takePayment(cur, NamePrice(domainLabel, label))

	caller := cur.Previous().Address()
	if err := nsdata.RenewNameRecord(cross(cur), label, domainLabel, caller, time.Now().Unix()); err != nil {
		panic(err)
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
