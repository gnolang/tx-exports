package nslogic

import (
	"strconv"
	"strings"

	"gno.land/r/g17l06jwgez8aun250609y6ej4048e6d78zfle3s/nsdata"
)

// Pricing lives here, not in the vault. The vault stores the numbers as
// opaque strings in a domain's extension slot and has no opinion about
// what they mean — which is what lets the whole pricing model be
// replaced by swapping this realm, rather than being frozen forever at
// deployment.
//
// Domain extension keys:
//   "price" — flat price in ugnot, applied when no tier matches
//   "tiers" — "length:price,length:price,…" e.g. "3:50000000,4:20000000"
// Global key:
//   "defaultPrice" — fallback when a domain sets no price of its own
const (
	keyPrice        = "price"
	keyTiers        = "tiers"
	keyDefaultPrice = "defaultPrice"

	fallbackPrice = int64(1_000_000)
	maxTiers      = 64
)

// NamePrice resolves what a given label costs under a given domain:
// a length-tier match if one exists, else the domain's flat price, else
// the global default.
func NamePrice(domainLabel, label string) int64 {
	if tiers := nsdata.GetDomainExtra(domainLabel, keyTiers); tiers != "" {
		if p, ok := lookupTier(tiers, len(label)); ok {
			return p
		}
	}
	if flat := nsdata.GetDomainExtra(domainLabel, keyPrice); flat != "" {
		if v, err := strconv.ParseInt(flat, 10, 64); err == nil && v > 0 {
			return v
		}
	}
	return DefaultPrice()
}

func DefaultPrice() int64 {
	if v := nsdata.GetGlobal(keyDefaultPrice); v != "" {
		if p, err := strconv.ParseInt(v, 10, 64); err == nil && p > 0 {
			return p
		}
	}
	return fallbackPrice
}

func lookupTier(tiersCSV string, length int) (int64, bool) {
	want := strconv.Itoa(length)
	for _, pair := range strings.Split(tiersCSV, ",") {
		parts := strings.Split(strings.TrimSpace(pair), ":")
		if len(parts) != 2 || strings.TrimSpace(parts[0]) != want {
			continue
		}
		if p, err := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64); err == nil && p > 0 {
			return p, true
		}
	}
	return 0, false
}

// normalizeTiers validates a tier string before it is stored. Parsing on
// write means a malformed string can never reach storage and break every
// later price lookup.
func normalizeTiers(tiersCSV string) string {
	var out []string
	seen := map[string]bool{}
	for _, pair := range strings.Split(tiersCSV, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		parts := strings.Split(pair, ":")
		if len(parts) != 2 {
			panic("nslogic: bad tier format, want length:price")
		}
		lenStr := strings.TrimSpace(parts[0])
		n, err := strconv.Atoi(lenStr)
		if err != nil || n <= 0 {
			panic("nslogic: bad tier length: " + lenStr)
		}
		priceStr := strings.TrimSpace(parts[1])
		p, err := strconv.ParseInt(priceStr, 10, 64)
		if err != nil || p <= 0 {
			panic("nslogic: bad tier price: " + priceStr)
		}
		if seen[lenStr] {
			panic("nslogic: duplicate tier length: " + lenStr)
		}
		seen[lenStr] = true
		out = append(out, lenStr+":"+priceStr)
		if len(out) > maxTiers {
			panic("nslogic: too many tiers")
		}
	}
	if len(out) == 0 {
		panic("nslogic: no valid tiers given")
	}
	return strings.Join(out, ",")
}
