package nslogic

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// THE LABEL RULE IS WRITTEN OUT, NOT COMPILED.
//
// It used to be a regexp, and that regexp was the single most expensive
// thing in this realm — by a wide margin, and not by a little. Measured
// on sapphire-1 with vm/qstorage against purpose-built probe realms:
//
//	a realm with code and no package-level state      2,711 bytes
//	the same realm plus ONE compiled regexp         154,877 bytes
//
// A compiled regexp is an object graph, and gno charges 100 ugnot for
// every byte of it, forever. That one variable was 15.2 GNOT of the
// 22.5 GNOT it costs to deploy this realm — about 68% of the bill, to
// enforce a rule that fits in thirty lines.
//
// The second regexp was worse, because it was compiled LAZILY and cached
// in a package-level var. That does not avoid the cost, it MOVES it: the
// first person to register a name after a fresh deploy would have had
// their transaction grow this realm's storage by 150KB and been charged
// ~15 GNOT of deposit for it. Confirmed by probe, not inferred — a realm
// deployed at 2,711 bytes went to 154,149 the moment one call compiled
// and cached a regexp, billed to the caller. Somebody buying a ten-cent
// name would have been asked for fifteen GNOT.
//
// The hand-written version is also 6x cheaper in gas on every call
// (1.06M against 6.67M), so there is no axis on which the regexp was
// the better choice. It read better. That was the whole of its case.
//
// WHAT THIS COSTS US. The pattern is no longer admin-tunable at runtime:
// changing the rule now means redeploying this realm. That is a fair
// trade at 7 GNOT a deploy, it was never a rule that should change
// casually, and SetLabelPattern refuses anything but the implemented
// pattern so the stored string can never describe rules the code does
// not enforce.

// labelRule is the pattern this realm implements, kept as a string so
// nsdata, the error messages and the site all quote the same thing.
const labelRule = `^[a-z0-9]+(-[a-z0-9]+)*$`

// matchesLabelRule is that pattern, by hand: lowercase letters and
// digits, single hyphens between them, none at either end.
func matchesLabelRule(s string) bool {
	if s == "" {
		return false
	}
	prevHyphen := true // a leading hyphen is not allowed
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			prevHyphen = false
		case c == '-':
			if prevHyphen {
				return false // leading, or two in a row
			}
			prevHyphen = true
		default:
			return false
		}
	}
	return !prevHyphen // nor a trailing one
}

// looksLikeAddress was `^g1[a-z0-9]{20,38}$`. Anything shaped like a real
// gno.land address is refused as a label, so a name can never be mistaken
// for a raw wallet address in a UI.
func looksLikeAddress(s string) bool {
	if len(s) < 22 || len(s) > 40 || !strings.HasPrefix(s, "g1") {
		return false
	}
	for i := 2; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

// validateLabel — same policy as the original single-realm build (see
// NOTES.md for the ENS/Starname/r/sys/users research behind it). The
// length bounds are still read from nsdata, so they survive a swap of
// this realm; the character rule is now this realm's own.
//
// Call sites, and why: RegisterName/RegisterDomain only (both the
// first-ever mint AND reclaiming a past-grace slot — a reclaim is a
// genuine new mint with a new owner). RenewName/RenewDomain deliberately
// do NOT call this — an already-registered name must keep renewing under
// whatever rule was in force when it was minted.
func validateLabel(label string) {
	minLen, maxLen := nsdata.GetLabelLength()
	if len(label) < minLen || len(label) > maxLen {
		panic(ufmt.Sprintf("nslogic: label must be %d-%d characters", minLen, maxLen))
	}
	// Structural invariant, enforced regardless of what the pattern
	// happens to allow: "*" is the separator in both the token ID
	// (label*domain) and nsdata's storage key (domain*label). A label or
	// domain containing one would make those encodings ambiguous and let
	// two different names collide onto a single record.
	if strings.Contains(label, "*") {
		panic("nslogic: label may not contain '*'")
	}
	if !matchesLabelRule(label) {
		panic("nslogic: a name is lowercase letters, digits and single hyphens between them — " + labelRule)
	}
	if looksLikeAddress(label) {
		panic("nslogic: label looks like a wallet address, not allowed")
	}
}
