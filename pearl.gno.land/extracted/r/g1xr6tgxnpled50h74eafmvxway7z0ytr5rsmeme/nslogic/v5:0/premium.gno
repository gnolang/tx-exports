package nslogic

import (
	"strconv"
	"strings"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// Global pricing layers that sit ACROSS every domain rather than inside
// one — see SPEC.md §27.
//
// Two of them, and they work at different points:
//
//   GLOBAL LENGTH RULES are a FLOOR beneath each domain's own length
//   rules, consulted only when the domain has nothing to say about that
//   length. "three-character names cost $5 everywhere" becomes one entry
//   instead of an edit to all twenty-seven domains, and a domain that
//   wants its own answer still overrides it.
//
//   GLOBAL NAME PREMIUMS are an ADJUSTMENT applied after the price has
//   already resolved. Making `og` premium is one entry covering
//   `og*degen`, `og*meme` and every domain invented later. Deliberately
//   not the per-name override, which REPLACES a price outright: "this
//   name costs exactly X here" and "this name is worth more everywhere"
//   are different tools and both are worth having.
//
// Full order, most specific first:
//
//   1. per-name override      (domain "nm")
//   2. per-domain length rule (domain "len")
//   3. global length rule     (global "glen")
//   4. domain base price      (domain "price")
//   5. global default         (global "defaultPrice")
//   then the global name premium modifies the result,
//   then any referral discount comes off what is left.
const (
	keyGlobalLens = "glen"    // global length rules
	keyPremium    = "premium" // premium1, premium2, ... see below

	// The vault caps an extension value at maxExtraValueLen (512 bytes),
	// which is roughly 40-60 premium entries. The list is therefore split
	// across numbered keys rather than pretending one will do; a list
	// that silently truncated at the 512th byte would drop exactly the
	// entries nobody checked.
	maxPremiumKeys = 8
)

// GlobalLengthRule returns the global rule for a label length, if any.
func GlobalLengthRule(n int) (string, bool) {
	return lookupRule(nsdata.GetGlobal(keyGlobalLens), strconv.Itoa(n))
}

// PremiumFor returns the raw modifier for a name across all premium
// keys, or "" when the name is not premium anywhere.
func PremiumFor(label string) string {
	for i := 1; i <= maxPremiumKeys; i++ {
		csv := nsdata.GetGlobal(keyPremium + strconv.Itoa(i))
		if csv == "" {
			continue
		}
		if v, ok := lookupRule(csv, label); ok {
			return v
		}
	}
	return ""
}

// applyPremium adjusts an already-resolved price.
//
// ZERO ALWAYS STAYS ZERO. A fixed "+$2.00" would otherwise silently undo
// a giveaway tier set months earlier, and a free tier that quietly stops
// being free is worse than never having offered one. This is decided
// explicitly rather than inherited from the percentage case happening to
// work out at zero.
//
// Forms: "%5" / "+%5" five percent more · "-%10" ten percent less ·
// "2.00" two dollars more · "-0.25" twenty-five cents less ·
// "=5.00" exactly five dollars, ignoring everything resolved above.
func applyPremium(mod string, price int64) int64 {
	mod = strings.TrimSpace(mod)
	if mod == "" || price <= 0 {
		return price
	}

	// "=X" replaces outright. Checked before the sign handling because
	// an exact price is not a delta and has no direction.
	if strings.HasPrefix(mod, "=") {
		v, ok := parseUSD(mod[1:])
		if !ok || v < 0 {
			return price
		}
		return v
	}

	neg := false
	switch {
	case strings.HasPrefix(mod, "-"):
		neg, mod = true, mod[1:]
	case strings.HasPrefix(mod, "+"):
		mod = mod[1:]
	}

	var delta int64
	if strings.HasPrefix(mod, "%") {
		pct, err := strconv.ParseInt(mod[1:], 10, 64)
		if err != nil || pct < 0 {
			return price
		}
		delta = price * pct / 100
	} else {
		v, ok := parseUSD(mod)
		if !ok || v < 0 {
			return price
		}
		delta = v
	}

	if neg {
		// A discount may take a name to free, but never below it: a
		// negative price would be a payout, and this realm never pays
		// anybody to register.
		if delta >= price {
			return 0
		}
		return price - delta
	}
	return price + delta
}

// parseUSD reads a human dollar figure — "2", "2.5", "2.50", "0.069" —
// into micro-USD. Written by hand rather than with floats: a float would
// make "0.07" cost a different number of micro-dollars depending on the
// platform, and prices must be exact.
func parseUSD(s string) (int64, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	whole, frac := s, ""
	if i := strings.IndexByte(s, '.'); i >= 0 {
		whole, frac = s[:i], s[i+1:]
	}
	if whole == "" {
		whole = "0"
	}
	w, err := strconv.ParseInt(whole, 10, 64)
	if err != nil || w < 0 {
		return 0, false
	}
	// Pad or truncate the fraction to exactly six digits of micro-USD.
	if len(frac) > 6 {
		frac = frac[:6]
	}
	for len(frac) < 6 {
		frac += "0"
	}
	var f int64
	if frac != "" {
		f, err = strconv.ParseInt(frac, 10, 64)
		if err != nil || f < 0 {
			return 0, false
		}
	}
	return w*microUSD + f, true
}

// normalizePremiums validates a premium list before storage. Same
// reasoning as normalizeRules: a malformed entry must never reach the
// vault, because every later lookup would carry it.
func normalizePremiums(csv string) string {
	if strings.TrimSpace(csv) == "" {
		return ""
	}
	var out []string
	seen := map[string]bool{}
	for _, pair := range strings.Split(csv, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		parts := strings.SplitN(pair, ":", 2)
		if len(parts) != 2 {
			panic("nslogic: bad premium, want name:modifier — got " + pair)
		}
		k, v := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
		if k == "" || strings.ContainsAny(k, "*, \t\n") {
			panic("nslogic: invalid name in premium — " + k)
		}
		if seen[k] {
			panic("nslogic: duplicate premium name — " + k)
		}
		if !validPremiumValue(v) {
			panic("nslogic: bad premium modifier for " + k + " — " + v)
		}
		seen[k] = true
		out = append(out, k+":"+v)
	}
	return strings.Join(out, ",")
}

func validPremiumValue(v string) bool {
	if v == "" {
		return false
	}
	if strings.HasPrefix(v, "=") {
		_, ok := parseUSD(v[1:])
		return ok
	}
	if strings.HasPrefix(v, "-") || strings.HasPrefix(v, "+") {
		v = v[1:]
	}
	if strings.HasPrefix(v, "%") {
		p, err := strconv.ParseInt(v[1:], 10, 64)
		return err == nil && p >= 0
	}
	_, ok := parseUSD(v)
	return ok
}
