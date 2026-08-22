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

// -- pricing controls (admin) --
//
// Every amount here is MICRO-USD (1 USD = 1_000_000). Nothing is priced
// in the chain token; ugnot is derived at payment time from the stored
// rate, so a second settlement token later is a second rate rather than
// a second price list.

// SetDomainOpen enables or disables registration of new names under a
// domain. Existing names are untouched: closing a domain stops new
// mints, it does not seize anything already held.
func SetDomainOpen(cur realm, label string, open bool) {
	assertNoSend()
	assertIsAdmin(cur)
	v := "1"
	if !open {
		v = "0"
	}
	setDomainExtra(cur, label, keyOpen, v)
}

// SetDomainBasePrice sets the domain's base price in micro-USD. Every
// "%N" rule under the domain is relative to this, so one call reprices
// the whole domain.
func SetDomainBasePrice(cur realm, label string, microUsd int64) {
	assertNoSend()
	assertIsAdmin(cur)
	if microUsd < 0 {
		panic("nslogic: price cannot be negative")
	}
	setDomainExtra(cur, label, keyPrice, strconv.FormatInt(microUsd, 10))
}

// SetDomainLengthRules prices by label length: "3:2000000,4:%150,5:0"
// means 3-char names cost $2.00, 4-char names cost 150% of the domain
// base, and 5-char names are free.
func SetDomainLengthRules(cur realm, label, rules string) {
	assertNoSend()
	assertIsAdmin(cur)
	setDomainExtra(cur, label, keyLens, normalizeRules(rules, true))
}

// SetDomainNameOverrides prices specific labels: "420:5000000,gm:%500".
// Highest precedence — this beats length rules and the base.
func SetDomainNameOverrides(cur realm, label, rules string) {
	assertNoSend()
	assertIsAdmin(cur)
	setDomainExtra(cur, label, keyNames, normalizeRules(rules, false))
}

// SetDomainField writes an arbitrary key on a domain, for whatever a
// future feature needs without a vault change.
func SetDomainField(cur realm, label, key, value string) {
	assertNoSend()
	assertIsAdmin(cur)
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
