package nslogic

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata"
)

// validateLabel — same policy as the original single-realm build (see
// NOTES.md for the ENS/Starname/r/sys/users research behind it). Length
// bounds and the character pattern are both read from nsdata, so they
// survive a swap of this realm.
//
// Call sites, and why: RegisterName/RegisterDomain only (both the
// first-ever mint AND reclaiming a past-grace slot — a reclaim is a
// genuine new mint with a new owner). RenewName/RenewDomain deliberately
// do NOT call this — an already-registered name must keep renewing under
// whatever pattern was in force when it was minted, even after the admin
// tightens the pattern later.
func validateLabel(label string) {
	minLen, maxLen := nsdata.GetLabelLength()
	if len(label) < minLen || len(label) > maxLen {
		panic(ufmt.Sprintf("nslogic: label must be %d-%d characters", minLen, maxLen))
	}
	// Structural invariant, enforced regardless of what the admin-tunable
	// pattern happens to allow: "*" is the separator in both the token ID
	// (label*domain) and nsdata's storage key (domain*label). A label or
	// domain containing one would make those encodings ambiguous and let
	// two different names collide onto a single record.
	if strings.Contains(label, "*") {
		panic("nslogic: label may not contain '*'")
	}
	if !currentLabelRe().MatchString(label) {
		panic("nslogic: label doesn't match the current allowed pattern (see nsdata.GetLabelPattern)")
	}
	if reAddressLookalike.MatchString(label) {
		panic("nslogic: label looks like a wallet address, not allowed")
	}
}
