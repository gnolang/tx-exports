package nsdata

import (
	"strings"
	"time"

	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsnft/v1"
)

// Plain reads — no `cur realm` parameter, no authentication, since there
// is no caller identity to check on a read. Everything here returns raw
// stored values; formatting them for display is the view realm's job,
// not the vault's. (Status strings like "VALID (363 days left)" used to
// live here. They were display logic in a realm that can never be
// redeployed, so they moved to nsview.)

func ListDomains() string {
	var b strings.Builder
	first := true
	domains.Iterate("", "", func(key string, v any) bool {
		if !first {
			b.WriteString(",")
		}
		b.WriteString(key)
		first = false
		return false
	})
	return b.String()
}

// ListNames and CountNames scan only the key span belonging to
// `domainLabel` (see domainRange in auth.gno), costing O(names in that
// domain) rather than O(every name in the registry).
func ListNames(domainLabel string) string {
	var b strings.Builder
	first := true
	start, end := domainRange(domainLabel)
	// The label is the part of the key after "domain*". Records no
	// longer carry their own label — the key already held it, and
	// storing it twice cost storage forever to say the same thing.
	cut := len(domainLabel) + 1
	names.Iterate(start, end, func(key string, v any) bool {
		if !first {
			b.WriteString(",")
		}
		b.WriteString(key[cut:])
		first = false
		return false
	})
	return b.String()
}

func CountNames(domainLabel string) int64 {
	var count int64
	start, end := domainRange(domainLabel)
	names.Iterate(start, end, func(key string, v any) bool {
		count++
		return false
	})
	return count
}

func CountDomains() int64 { return int64(domains.Size()) }

func DomainExists(label string) bool            { _, ok := getDomain(label); return ok }
func NameExists(label, domainLabel string) bool { _, ok := getName(label, domainLabel); return ok }

func GetDomainOwner(label string) address { return mustGetDomain(label).owner }

// GetNameOwner asks the ledger. It still panics for an unknown NAME, as it
// always did, so callers that relied on that are unchanged.
func GetNameOwner(label, domainLabel string) address {
	mustGetName(label, domainLabel)
	return nsnft.OwnerOf(nameTokenID(label, domainLabel))
}

// GetDomainInfo / GetNameInfo return a whole record in one call, so a
// view realm can render a page without six round trips.
// Timestamps come back as unix SECONDS. They used to be time.Time,
// which vm/qeval rendered using gno's internal epoch, so every consumer
// had to know to subtract 62135596800 — our own frontend did exactly
// that. Returning unix seconds stops leaking that offset into every
// integration, and it is what the records now hold anyway.
//
// `streak` is computed from the registration date rather than read from
// a stored field. See streakOf.
func GetDomainInfo(label string) (owner address, registered, expires, streak int64, frozen bool) {
	d := mustGetDomain(label)
	return d.owner, d.registered, d.expires, streakOf(d.registered, time.Now().Unix()), d.frozen
}

/*
GetNameInfo keeps its six-value shape so every existing reader — nslogic,
nsview, nsskin, nsvote, the site, both snapshot tools — goes on parsing it
unchanged. Two of the six are now answered differently:

	owner  is read from nsnft, never stored here. The snapshot tools record
	       whatever this returns, so they now record the real owner — the
	       restore-hands-sold-names-back bug the first attempt had cannot
	       happen, because there is no stale copy for them to read.

	paid   replaces isNFT and means exactly one thing: the name is NOT
	       held as an un-upgraded free-tier record. It is deliberately not
	       "transferable" — a frozen paid name is locked too, and reading
	       the lock would have made a frozen paid name look free, which is
	       precisely the proxy bug that let free renewals renew paid names.
*/
func GetNameInfo(label, domainLabel string) (owner address, registered, expires, streak int64, frozen, paid bool) {
	n := mustGetName(label, domainLabel)
	tid := nameTokenID(label, domainLabel)
	return nsnft.OwnerOf(tid), n.registered, n.expires,
		streakOf(n.registered, time.Now().Unix()), n.frozen,
		nsnft.LockBits(tid)&(1<<lockBitFree) == 0
}

// GetNameTTL / GetDomainTTL report how long a resolver may cache an
// answer about this record, in seconds, where 0 MEANS NEVER CACHE — the
// ENS registry's rule, deliberately, so integrators need not read
// anything of ours to handle it correctly.
// A TTL written for a previous holder is not this holder's cache policy.
// A stale one reads as 0 — never cache — which is the safe answer during
// exactly the window after a sale when a cached answer pays the seller.
func GetNameTTL(label, domainLabel string) int64 {
	n := mustGetName(label, domainLabel)
	if !isFresh(n, nameTokenID(label, domainLabel)) {
		return 0
	}
	return n.ttl
}
func GetDomainTTL(label string) int64 { return mustGetDomain(label).ttl }

// RestoredFor reports whom a restore wrote this record for, or empty.
// See Name.restoredFor.
func RestoredFor(label, domainLabel string) address {
	return mustGetName(label, domainLabel).restoredFor
}

// IsNamePaid reports that a name is not held as an un-upgraded free-tier
// record. See GetNameInfo on why this is not "transferable".
func IsNamePaid(label, domainLabel string) bool {
	mustGetName(label, domainLabel)
	return nsnft.LockBits(nameTokenID(label, domainLabel))&(1<<lockBitFree) == 0
}

func IsDomainValid(label string) bool {
	d, ok := getDomain(label)
	return ok && isValidNow(d.expires, time.Now().Unix())
}

func IsNameValid(label, domainLabel string) bool {
	n, ok := getName(label, domainLabel)
	return ok && isValidNow(n.expires, time.Now().Unix())
}

// -- extension slots --

func GetDomainExtra(label, key string) string {
	v := mustGetDomain(label).extra.Get(key)
	if v == nil {
		return ""
	}
	return v.(string)
}

/*
GetNameExtra answers EMPTY for data written in a previous ownership epoch.

This is the read half of the lazy wipe. A sale that settles on nsnft —
through our marketplace or anybody else's — never calls this realm, so
nothing here can clear the seller's payment addresses at the moment it
happens. What this CAN do is refuse to repeat them: the instant the
ledger's epoch moves, every extra on the name stops answering, for every
reader, before anybody has written anything.

The write half, which destroys the stale data rather than hiding it, is
freshen in write.gno. Both halves are needed: hiding alone is what the
first attempt shipped, and the buyer's first edit brought the seller's
Bitcoin address back as the buyer's.
*/
func GetNameExtra(label, domainLabel, key string) string {
	n := mustGetName(label, domainLabel)
	if !isFresh(n, nameTokenID(label, domainLabel)) {
		return ""
	}
	v := n.extra.Get(key)
	if v == nil {
		return ""
	}
	return v.(string)
}

func GetGlobal(key string) string {
	v := globals.Get(key)
	if v == nil {
		return ""
	}
	return v.(string)
}

// GetPrimary is a raw pointer lookup. It reports what an address last
// SELECTED, not what it still owns — callers presenting this as reverse
// resolution must re-check ownership (see nslogic.ResolveAddress).
func GetPrimary(owner address) string {
	v := primary.Get(owner.String())
	if v == nil {
		return ""
	}
	return v.(string)
}

// -- config reads --

func GetTreasury() address                { return treasury }
func GetTermLength() int64                { return termLength }
func GetGracePeriod() int64               { return gracePeriod }
func GetMaxDeletePerCall() int            { return maxDeletePerCall }
func GetLabelPattern() string             { return labelPattern }
func GetLabelLength() (min, max int)      { return minLabelLen, maxLabelLen }
func GetTokenURIBase() string             { return tokenURIBase }
func GetExtraLimits() (k, v, entries int) { return maxExtraKeyLen, maxExtraValueLen, maxExtraEntries }
