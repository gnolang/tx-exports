package nsdata

import (
	"strings"
	"time"
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
	names.Iterate(start, end, func(key string, v any) bool {
		if !first {
			b.WriteString(",")
		}
		b.WriteString(v.(*Name).label)
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

func GetDomainOwner(label string) address            { return mustGetDomain(label).owner }
func GetNameOwner(label, domainLabel string) address { return mustGetName(label, domainLabel).owner }

// GetDomainInfo / GetNameInfo return a whole record in one call, so a
// view realm can render a page without six round trips.
func GetDomainInfo(label string) (owner address, registered, expires time.Time, streak int64, frozen bool) {
	d := mustGetDomain(label)
	return d.owner, d.registered, d.expires, d.streak, d.frozen
}

func GetNameInfo(label, domainLabel string) (owner address, registered, expires time.Time, streak int64, frozen, isNFT bool) {
	n := mustGetName(label, domainLabel)
	return n.owner, n.registered, n.expires, n.streak, n.frozen, n.isNFT
}

// IsNameNFT reports whether a GRC-721 token backs this record. The logic
// realm needs it to pick a transfer path and to gate the paid upgrade.
func IsNameNFT(label, domainLabel string) bool { return mustGetName(label, domainLabel).isNFT }

func IsDomainValid(label string) bool {
	d, ok := getDomain(label)
	return ok && isValidNow(d.expires, time.Now())
}

func IsNameValid(label, domainLabel string) bool {
	n, ok := getName(label, domainLabel)
	return ok && isValidNow(n.expires, time.Now())
}

// -- extension slots --

func GetDomainExtra(label, key string) string {
	v := mustGetDomain(label).extra.Get(key)
	if v == nil {
		return ""
	}
	return v.(string)
}

func GetNameExtra(label, domainLabel, key string) string {
	v := mustGetName(label, domainLabel).extra.Get(key)
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

func GetTreasury() address                 { return treasury }
func GetTermLength() time.Duration         { return termLength }
func GetGracePeriod() time.Duration        { return gracePeriod }
func GetLabelPattern() string              { return labelPattern }
func GetLabelLength() (min, max int)       { return minLabelLen, maxLabelLen }
func GetTokenURIBase() string              { return tokenURIBase }
func GetExtraLimits() (k, v, entries int)  { return maxExtraKeyLen, maxExtraValueLen, maxExtraEntries }
