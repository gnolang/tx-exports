package nslogic

import (
	"strconv"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// How far ahead a name may be paid.
//
// Renewal was unbounded. RenewNameRecord adds one term to the previous
// due date and asks no further questions, so a holder pressing renew
// seven times bought seven years of runway, and nothing anywhere said
// that was not intended. It is a bug in two directions at once:
//
//   - Free domains have a base price of zero. Renewal is free too, so a
//     script could take every good name under *gnoland and hold it for a
//     century for the cost of gas. There is no economic brake on a free
//     name at all; the term limit IS the brake.
//   - A paid name held fifty years ahead is fifty years of a promise we
//     have made against a rate written by hand and a testnet that will
//     be replaced. Selling that is easy and honouring it is not.
//
// The limit is RUNWAY, not total lifetime: at most N years may be
// outstanding at any moment. Nobody is stopped from holding a name
// forever — they renew as the runway burns down, which is the same
// arrangement every domain registrar has always used and the one people
// already understand.
//
// Per domain first, then a project-wide default, so a free domain can be
// capped at one year without capping anything else.
const (
	keyMaxTerm       = "maxterm" // domain extra AND global: years of runway
	defaultMaxTerm   = int64(5)
	maxMaxTermYears  = int64(100)
)

// MaxTermYears is the cap that applies to names under this domain.
func MaxTermYears(domainLabel string) int64 {
	if v := nsdata.GetDomainExtra(domainLabel, keyMaxTerm); v != "" {
		if y, err := strconv.ParseInt(v, 10, 64); err == nil && y > 0 {
			return y
		}
	}
	if v := nsdata.GetGlobal(keyMaxTerm); v != "" {
		if y, err := strconv.ParseInt(v, 10, 64); err == nil && y > 0 {
			return y
		}
	}
	return defaultMaxTerm
}

// SetMaxTerm caps a single domain, or the whole project when the domain
// label is empty. A domain's own cap always wins, so tightening one free
// domain does not disturb the rest.
func SetMaxTerm(cur realm, domainLabel string, years int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if years < 1 || years > maxMaxTermYears {
		panic("nslogic: term cap must be 1-100 years")
	}
	v := strconv.FormatInt(years, 10)
	if domainLabel == "" {
		setGlobal(cur, keyMaxTerm, v)
		return
	}
	if !nsdata.DomainExists(domainLabel) {
		panic("nslogic: unknown domain")
	}
	if err := nsdata.SetDomainExtraRecord(cross(cur), domainLabel, keyMaxTerm, v); err != nil {
		panic(err)
	}
}

// RenewalsLeft is how many more years may be added to a name right now.
// Zero means the renew button should be off, and the site reads this
// rather than doing the arithmetic itself — the cap can be per domain,
// and a page that guesses it will guess wrong on exactly the domains
// where it matters.
//
// An unregistered name reports the full allowance: nothing is holding
// runway yet.
func RenewalsLeft(label, domainLabel string) int64 {
	maxYears := MaxTermYears(domainLabel)
	if !nsdata.NameExists(label, domainLabel) {
		return maxYears
	}
	term := nsdata.GetTermLength()
	if term <= 0 {
		return 0
	}
	_, _, expires, _, _, _ := nsdata.GetNameInfo(label, domainLabel)
	return renewalsLeft(expires, time.Now().Unix(), term, maxYears)
}

// renewalsLeft is the arithmetic on its own, so it can be tested without
// a chain under it.
//
// Runway is measured from NOW, not from the registration date, so a name
// deep in its grace period counts as zero rather than as a negative that
// would then read as extra room. Years already bought round UP: a name
// with thirteen months left is holding two of its five, because the
// alternative lets somebody sit permanently at four-years-and-eleven-
// months and renew every month forever.
func renewalsLeft(expires, now, term, maxYears int64) int64 {
	if term <= 0 {
		return 0
	}
	runway := expires - now
	if runway < 0 {
		runway = 0
	}
	left := maxYears - (runway+term-1)/term
	if left < 0 {
		return 0
	}
	return left
}

// assertRoomToRenew is the enforcement. It runs before payment is taken,
// so a rejected renewal costs gas and nothing else — taking the money
// first and reverting would work too, but only because a panic reverts,
// and depending on that for a refund is a habit that eventually meets a
// path where it is not true.
func assertRoomToRenew(label, domainLabel string) {
	if RenewalsLeft(label, domainLabel) > 0 {
		return
	}
	panic(ufmt.Sprintf(
		"nslogic: %s*%s is already paid %d years ahead, which is the limit. Renew again when it has run down.",
		label, domainLabel, MaxTermYears(domainLabel)))
}
