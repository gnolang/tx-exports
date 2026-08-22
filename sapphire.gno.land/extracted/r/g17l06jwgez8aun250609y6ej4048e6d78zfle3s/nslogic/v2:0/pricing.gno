package nslogic

import (
	"strconv"
	"strings"

	"gno.land/r/g17l06jwgez8aun250609y6ej4048e6d78zfle3s/nsdata"
)

// Pricing lives here, not in the vault. The vault stores numbers as
// opaque strings and has no opinion about what they mean, so the whole
// model can be replaced by swapping this realm.
//
// PRICES ARE DENOMINATED IN USD, held as MICRO-USD (1 USD = 1_000_000)
// so fractions of a cent are expressible — a name that costs about a
// gumball needs that. Nothing is stored in ugnot: the chain's token is
// just the settlement rail, converted at payment time from a stored
// rate. Accepting a second token later is then only a second rate, not
// a second price list.
//
// PRECEDENCE — most specific wins:
//
//   1. per-name override      (keyNames: "420:5000000,gm:%500")
//   2. per-length rule        (keyLens:  "3:2000000,4:%150,5:0")
//   3. domain base price      (keyPrice: "500000"  = $0.50)
//   4. global default         (global keyDefaultPrice)
//
// A rule value is either an absolute micro-USD amount or "%N", meaning N
// percent of that domain's base — so repricing a domain once carries
// every relative rule under it. "0" means free, which is how giveaway
// tiers are expressed: "all five-character names under *pleb are free"
// is just a length rule resolving to zero.
//
// Rules are stored as CSV in ONE key each rather than one key per rule.
// The vault caps extension keys at 32 bytes and 24 entries per record; a
// key like "nm:somelongname" breaks the first and a few dozen premium
// names break the second. Two CSV keys sidestep both.
const (
	keyPrice        = "price" // domain base, micro-USD
	keyLens         = "len"   // length rules
	keyNames        = "nm"    // per-name overrides
	keyOpen         = "open"  // "0" closes the domain to new names
	keyDefaultPrice = "defaultPrice"
	keyRate         = "rateUgnotPerUsd" // ugnot equal to 1 USD

	microUSD          = int64(1_000_000)
	fallbackPriceUSD  = int64(500_000) // $0.50
	// TESTNET PEG: $0.069 per GNOT, so 1 USD = 1/0.069 GNOT = 14.492753
	// GNOT = 14_492_753 ugnot. Deliberately a fixed number while we are on
	// a testnet whose token has no market price at all -- a "real" rate
	// there would be fiction dressed as precision. Replaced with a genuine
	// conversion before mainnet; tracked in MAINNET.md.
	fallbackRate      = int64(14_492_753)
	maxRules          = 64
)

// DomainOpen reports whether names may currently be registered under a
// domain. An absent key means open — a domain created before this
// existed must not silently close.
func DomainOpen(domainLabel string) bool {
	return nsdata.GetDomainExtra(domainLabel, keyOpen) != "0"
}

// -- USD side --

func DefaultPriceUSD() int64 {
	if v := nsdata.GetGlobal(keyDefaultPrice); v != "" {
		if p, err := strconv.ParseInt(v, 10, 64); err == nil && p >= 0 {
			return p
		}
	}
	return fallbackPriceUSD
}

func DomainBasePriceUSD(domainLabel string) int64 {
	if v := nsdata.GetDomainExtra(domainLabel, keyPrice); v != "" {
		if p, err := strconv.ParseInt(v, 10, 64); err == nil && p >= 0 {
			return p
		}
	}
	return DefaultPriceUSD()
}

// NamePriceUSD resolves the four inputs in precedence order and returns
// micro-USD. This is the authoritative price; ugnot is derived from it.
func NamePriceUSD(domainLabel, label string) int64 {
	base := DomainBasePriceUSD(domainLabel)
	if v, ok := lookupRule(nsdata.GetDomainExtra(domainLabel, keyNames), label); ok {
		return applyRule(v, base)
	}
	if v, ok := lookupRule(nsdata.GetDomainExtra(domainLabel, keyLens), strconv.Itoa(len(label))); ok {
		return applyRule(v, base)
	}
	return base
}

// -- settlement side --

// RateUgnotPerUsd is how many ugnot one USD buys.
//
// This is a MANUALLY MAINTAINED rate, not a market oracle: an admin
// writes it and it sits there until rewritten. That is a real
// operational hazard — a stale rate during a sharp move sells names at
// the wrong price in whichever direction hurts — and the mitigation is
// keeping it fresh, not anything this code can do. Kept as one global so
// a future logic realm can swap in a real oracle without touching the
// vault or restating a single price.
func RateUgnotPerUsd() int64 {
	if v := nsdata.GetGlobal(keyRate); v != "" {
		if r, err := strconv.ParseInt(v, 10, 64); err == nil && r > 0 {
			return r
		}
	}
	return fallbackRate
}

// NamePrice converts the USD price to ugnot for settlement. Rounds UP,
// so rounding never sells a name below its listed price; a free name
// stays exactly free.
func NamePrice(domainLabel, label string) int64 {
	usd := NamePriceUSD(domainLabel, label)
	if usd <= 0 {
		return 0
	}
	rate := RateUgnotPerUsd()
	return (usd*rate + microUSD - 1) / microUSD
}

// -- rule plumbing --

func applyRule(v string, base int64) int64 {
	if strings.HasPrefix(v, "%") {
		pct, err := strconv.ParseInt(v[1:], 10, 64)
		if err != nil || pct < 0 {
			return base
		}
		return base * pct / 100
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 0 {
		return base
	}
	return n
}

func lookupRule(csv, want string) (string, bool) {
	if csv == "" {
		return "", false
	}
	for _, pair := range strings.Split(csv, ",") {
		parts := strings.SplitN(strings.TrimSpace(pair), ":", 2)
		if len(parts) != 2 {
			continue
		}
		if strings.TrimSpace(parts[0]) == want {
			return strings.TrimSpace(parts[1]), true
		}
	}
	return "", false
}

// normalizeRules validates and canonicalises a rule string before it is
// stored, so a malformed entry can never reach storage and poison every
// later lookup.
func normalizeRules(csv string, numericKeys bool) string {
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
			panic("nslogic: bad rule, want key:value — got " + pair)
		}
		k, v := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
		if k == "" {
			panic("nslogic: empty rule key")
		}
		if numericKeys {
			if n, err := strconv.Atoi(k); err != nil || n <= 0 {
				panic("nslogic: length must be a positive number — got " + k)
			}
		} else if strings.ContainsAny(k, "*, \t\n") {
			panic("nslogic: invalid name in rule — " + k)
		}
		if strings.HasPrefix(v, "%") {
			if p, err := strconv.ParseInt(v[1:], 10, 64); err != nil || p < 0 {
				panic("nslogic: bad percentage — " + v)
			}
		} else if n, err := strconv.ParseInt(v, 10, 64); err != nil || n < 0 {
			panic("nslogic: bad amount — " + v)
		}
		if seen[k] {
			panic("nslogic: duplicate rule key — " + k)
		}
		seen[k] = true
		out = append(out, k+":"+v)
		if len(out) > maxRules {
			panic("nslogic: too many rules (max 64)")
		}
	}
	return strings.Join(out, ",")
}
