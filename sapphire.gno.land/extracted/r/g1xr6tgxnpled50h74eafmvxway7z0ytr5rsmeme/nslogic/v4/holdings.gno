package nslogic

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// Answering "what does this address hold" in ONE read.
//
// The site used to ask the chain for every name in the REGISTRY and then
// throw away the ones that did not match — one HTTP round trip per name
// in the world to draw one person's collection. Six names took three
// seconds, and it gets linearly worse for everybody every time anybody
// else registers anything.
//
// The scan itself is unavoidable: nsdata keys names by domain*label and
// has no index by owner, and nsdata is the permanent vault so no index
// can be added to it now. But the scan does not have to happen across
// the network. nslogic is swappable and can walk the same records inside
// a single query, which turns N round trips into one.
//
// Nothing is cached and nothing is trusted from the caller: every row is
// read from the vault at the moment of the query, exactly as before.
//
// Paged, because a query has a gas ceiling of its own and a registry
// with fifty thousand names in it must not become one enormous read that
// nobody can complete. `after` is the vault's own cursor, so paging here
// is the same paging ExportNames already does.
const maxHoldingsPage = 200

// NamesOwnedBy returns rows of `label*domain,registered,expires,streak,frozen`
// separated by ";", plus the cursor to continue from. Labels are
// restricted to [a-z0-9-] so neither separator can appear inside a field.
//
// `next` is empty when the scan has reached the end of the registry. It
// is NOT empty merely because this page found no matches: a page of two
// hundred names belonging to other people returns no rows and a cursor,
// and the caller keeps going.
func NamesOwnedBy(owner address, after string, limit int) (rows, next string) {
	if limit <= 0 || limit > maxHoldingsPage {
		limit = maxHoldingsPage
	}
	keys, nxt := nsdata.ExportNames("", after, limit)

	var b strings.Builder
	for _, key := range strings.Split(keys, ",") {
		if key == "" {
			continue
		}
		// The tree key is domain*label; the token ID is label*domain.
		at := strings.Index(key, "*")
		if at < 0 {
			continue
		}
		domainLabel, label := key[:at], key[at+1:]

		o, registered, expires, streak, frozen, _ := nsdata.GetNameInfo(label, domainLabel)
		if o != owner {
			continue
		}
		if b.Len() > 0 {
			b.WriteString(";")
		}
		b.WriteString(ufmt.Sprintf("%s*%s,%d,%d,%d,%t",
			label, domainLabel, registered, expires, streak, frozen))
	}
	return b.String(), nxt
}

// CountNamesOwnedBy is the same walk without the strings, for a header
// that wants a number before the list has finished arriving.
func CountNamesOwnedBy(owner address, after string, limit int) (n int, next string) {
	if limit <= 0 || limit > maxHoldingsPage {
		limit = maxHoldingsPage
	}
	keys, nxt := nsdata.ExportNames("", after, limit)
	for _, key := range strings.Split(keys, ",") {
		if key == "" {
			continue
		}
		at := strings.Index(key, "*")
		if at < 0 {
			continue
		}
		if nsdata.GetNameOwner(key[at+1:], key[:at]) == owner {
			n++
		}
	}
	return n, nxt
}
