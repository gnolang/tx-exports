package nslogic

import (
	"strconv"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// assertIsAdmin reads nsdata.GetAdmin() fresh every call — correct even
// immediately after a TransferAdmin, and correct for a freshly-deployed
// logic realm with no local state of its own to go stale.
//
// Note: admin authority to swap WHICH realm is trustedLogic, or to
// transfer admin itself, is deliberately NOT exposed here — those live
// only in nsdata's own admin.gno, callable solely by a direct wallet
// call from the current admin address, never proxied through logic.
// That's the one part of the system a compromised or buggy logic realm
// cannot touch.
func assertIsAdmin(cur realm) {
	if cur.Previous().Address() != nsdata.GetAdmin() {
		panic("nslogic: restricted to project admin")
	}
}

// SetLabelPattern no longer changes anything, and refuses anything but
// the rule this realm actually implements.
//
// It used to compile an arbitrary regex and store it, with validateLabel
// reading it back. That flexibility cost 15 GNOT of permanent storage
// per deploy — see the measurements in validate.gno — for a rule that
// has never changed and should not change casually.
//
// It is kept rather than deleted so that an admin who reaches for it
// gets told what happened instead of a "function not found". And it
// refuses a different pattern rather than accepting one it will not
// enforce: a stored string describing rules the code does not apply is
// the exact silent divergence the caching version was written to avoid.
func SetLabelPattern(cur realm, pattern string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if pattern != labelRule {
		panic("nslogic: the label rule is fixed in this realm (" + labelRule +
			"). Changing it means deploying a new logic realm — which is deliberate, " +
			"because a stored pattern the code does not enforce is worse than no setting at all.")
	}
	nsdata.SetLabelPatternRecord(cross(cur), pattern)
}

func SetLabelLengthLimits(cur realm, minLen, maxLen int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if minLen < 1 || maxLen < minLen {
		panic("nslogic: invalid length bounds")
	}
	nsdata.SetLabelLengthRecord(cross(cur), minLen, maxLen)
}

// SetDefaultNamePrice sets the fallback price in micro-USD, used by any
// domain that has not set its own base.
func SetDefaultNamePrice(cur realm, microUsd int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if microUsd < 0 {
		panic("nslogic: price cannot be negative")
	}
	setGlobal(cur, keyDefaultPrice, strconv.FormatInt(microUsd, 10))
}

// SetUsdRate records how many ugnot one USD buys — the bridge between
// the USD price list and settlement on this chain.
//
// It is a MANUAL rate, not a market feed: it sits where it was last
// written. A stale rate during a sharp move sells names at the wrong
// price, and no amount of contract logic fixes that — keeping it current
// is an operational duty. Isolated as one global so a future logic realm
// can swap in a real oracle without touching the vault or restating a
// single price.
func SetUsdRate(cur realm, ugnotPerUsd int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if ugnotPerUsd <= 0 {
		panic("nslogic: rate must be positive")
	}
	setGlobal(cur, keyRate, strconv.FormatInt(ugnotPerUsd, 10))
}

// SetTermLength / SetGracePeriod retune the lifecycle itself. Both were
// hardcoded constants in the vault until 2026-08-21 — meaning the 1-year
// term and 90-day grace could never have been changed, on a realm that
// is never redeployed. There was no reason to accept that.
// maxLifecycleDays bounds both setters. time.Duration is int64
// NANOSECONDS, so `days * 24h` overflows above ~106,751 days and wraps to
// a NEGATIVE duration — which would install a negative term and brick
// every registration and renewal in the registry. Guarding the input is
// what keeps the multiplication in range.
const maxLifecycleDays = 36500 // 100 years

func SetTermLength(cur realm, days int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if days <= 0 || days > maxLifecycleDays {
		panic("nslogic: term out of range (1..36500 days)")
	}
	term := days * 24 * 60 * 60
	// Keep gracePeriod <= termLength. Anchoring a renewal to the previous
	// due date is only coherent while a renewal cannot happen more than
	// one full term after it; the vault clamps forward defensively, but
	// the combination should not be reachable in the first place.
	if nsdata.GetGracePeriod() > term {
		panic("nslogic: term must be at least the current grace period")
	}
	nsdata.SetTermLengthRecord(cross(cur), term)
}

func SetGracePeriod(cur realm, days int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if days < 0 || days > maxLifecycleDays {
		panic("nslogic: grace period out of range (0..36500 days)")
	}
	grace := days * 24 * 60 * 60
	if grace > nsdata.GetTermLength() {
		panic("nslogic: grace period may not exceed the term length")
	}
	nsdata.SetGracePeriodRecord(cross(cur), grace)
}

// SetTokenURIBase re-points TokenURI at a different renderer, so the NFT
// artwork can be replaced without touching the vault.
func SetTokenURIBase(cur realm, base string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	nsdata.SetTokenURIBaseRecord(cross(cur), base)
}

func SetExtraLimits(cur realm, keyLen, valueLen, entries int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if keyLen < 1 || valueLen < 1 || entries < 1 {
		panic("nslogic: limits must be positive")
	}
	nsdata.SetExtraLimitsRecord(cross(cur), keyLen, valueLen, entries)
}

// SetGlobal writes an arbitrary project-wide key into the vault's
// package-level extension slot — the escape hatch for global state that
// does not exist yet.
func SetGlobal(cur realm, key, value string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	setGlobal(cur, key, value)
}

func setGlobal(cur realm, key, value string) {
	if err := nsdata.SetGlobalRecord(cross(cur), key, value); err != nil {
		panic(err)
	}
}

// SetTreasury moves the revenue-receiving role — independent of
// nsdata's TransferAdmin, same reasoning as the original build's
// admin/treasury separation.
func SetTreasury(cur realm, newTreasury address) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if !newTreasury.IsValid() {
		panic("nslogic: invalid treasury address")
	}
	nsdata.SetTreasuryRecord(cross(cur), newTreasury)
}

// SelfAddress reports this deployed realm's own address — needed once,
// at wiring time, so admin knows what to pass to nsdata.SetTrustedLogic.
func SelfAddress(cur realm) address {
	return cur.Address()
}
