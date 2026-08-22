package nslogic

import (
	"strconv"
	"strings"
	"time"

	"gno.land/r/g17l06jwgez8aun250609y6ej4048e6d78zfle3s/nsdata"
)

// RegisterDomain mints a new `*domain` — ADMIN-ONLY (2026-08-15 policy:
// domains are never sold or owned by third parties). No payment: the
// project isn't paying itself. Domains are also permanently
// non-transferable by users (see nft.gno's TransferFrom).
func RegisterDomain(cur realm, label string) {
	assertNoSend()
	assertIsAdmin(cur)
	validateLabel(label)
	caller := cur.Previous().Address()
	if err := nsdata.RegisterDomainRecord(cross(cur), label, caller, time.Now()); err != nil {
		panic(err)
	}
}

// RenewDomain extends a domain's expiry by exactly one year from its
// PREVIOUS due date, not from the payment date. No payment — domains are
// always project-owned, so this is self-service upkeep, not a sale.
// Deliberately does not call validateLabel — a tightened pattern only
// gates new registrations, never renewals of what's already registered.
func RenewDomain(cur realm, label string) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := nsdata.RenewDomainRecord(cross(cur), label, caller, time.Now()); err != nil {
		panic(err)
	}
}

// ReassignDomain moves a domain record to a new owner. ADMIN-ONLY, and
// the deliberate exception to "domains are non-transferable".
//
// It exists because domain ownership is snapshotted into the record at
// registration time, while `admin` is a rotatable role. After the
// planned EOA-to-multisig rotation, the incoming admin could not renew
// or reprice any domain the outgoing key had registered — and if the
// rotation happened *because* the old key was compromised, the attacker
// could still reprice those domains afterwards. This is the recovery
// lever for exactly that situation.
//
// Not a loophole in the non-transferability policy: that policy exists
// to stop domains reaching third parties as tradeable assets, and this
// path is reachable only by the current admin, moving a project domain
// between project-controlled addresses.
func ReassignDomain(cur realm, label string, newOwner address) {
	assertNoSend()
	assertIsAdmin(cur)
	owner := nsdata.GetDomainOwner(label)
	if err := nsdata.RawTransferNFT(cross(cur), owner, owner, newOwner, "*"+label); err != nil {
		panic(err)
	}
}

// SetDomainPricingFlat sets a single price for every name under the
// domain. Stored as an opaque string in the domain's extension slot —
// the vault has no pricing model of its own, so the model can be
// replaced by swapping this realm.
func SetDomainPricingFlat(cur realm, label string, price int64) {
	assertNoSend()
	assertDomainOwner(cur, label)
	if price <= 0 {
		panic("nslogic: price must be positive")
	}
	setDomainExtra(cur, label, keyPrice, strconv.FormatInt(price, 10))
	setDomainExtra(cur, label, keyTiers, "") // empty deletes: flat overrides tiers
}

// SetDomainPricingTiered sets price-by-name-length from a single CSV
// string, NOT []int/[]int64 slice params — vm/MsgCall (what gnokey
// maketx call and Adena's DoContract both send) only carries flat
// []string args, verified live against a slice-typed call. Format:
// "length:priceUgnot,length:priceUgnot,..." e.g. "3:50,4:20,5:10" — a
// length with no entry falls back to the domain's flat price.
func SetDomainPricingTiered(cur realm, label string, tiersCSV string) {
	assertNoSend()
	assertDomainOwner(cur, label)
	setDomainExtra(cur, label, keyTiers, normalizeTiers(tiersCSV))
}

// SetDomainField writes an arbitrary key on a domain, for whatever a
// future feature needs without a vault change.
func SetDomainField(cur realm, label, key, value string) {
	assertNoSend()
	assertDomainOwner(cur, label)
	if strings.HasPrefix(key, "_") {
		panic("nslogic: keys beginning with '_' are reserved")
	}
	setDomainExtra(cur, label, key, value)
}

func setDomainExtra(cur realm, label, key, value string) {
	if err := nsdata.SetDomainExtraRecord(cross(cur), label, key, value); err != nil {
		panic(err)
	}
}

func assertDomainOwner(cur realm, label string) {
	if nsdata.GetDomainOwner(label) != cur.Previous().Address() {
		panic("nslogic: restricted to domain owner")
	}
}

// FreezeDomain / UnfreezeDomain: project-only power to permanently block
// re-registration of a domain even after its grace period lapses.
func FreezeDomain(cur realm, label string) {
	assertNoSend()
	assertIsAdmin(cur)
	nsdata.SetDomainFrozen(cross(cur), label, true)
}

func UnfreezeDomain(cur realm, label string) {
	assertNoSend()
	assertIsAdmin(cur)
	nsdata.SetDomainFrozen(cross(cur), label, false)
}
