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

// Everything the profile page draws, in ONE read.
//
// It was making seventeen queries: three to establish that the name
// exists and when it expires, then fourteen more — one per extension
// slot — that could not start until the first three had come back. Two
// waves, and the node serves only a few at a time, so a profile took
// seconds to assemble out of values that all live in the same record.
//
// Values come back in the ORDER THE KEYS WERE ASKED FOR rather than as
// key=value pairs. An extension key is allowed to contain "=" (only
// commas and newlines are forbidden), so a pair encoding would have an
// ambiguous split; positional has none.
//
// Line 0 is the record: owner, registered, expires, streak, frozen, and
// the grace period, which is global but is one more query the page would
// otherwise have to make on its own.
//
// An empty return means the name is not registered. That is a real
// answer rather than an error: asking about a name nobody owns is the
// normal case on a profile URL somebody typed.
func ProfileOf(label, domainLabel, keys string) string {
	if !nsdata.NameExists(label, domainLabel) {
		return ""
	}
	owner, registered, expires, streak, frozen, _ := nsdata.GetNameInfo(label, domainLabel)

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("%s,%d,%d,%d,%t,%d",
		owner.String(), registered, expires, streak, frozen, nsdata.GetGracePeriod()))

	for _, k := range strings.Split(keys, ",") {
		b.WriteString("\n")
		if k == "" {
			continue
		}
		v := nsdata.GetNameExtra(label, domainLabel, k)

		// THE GNO.LAND ADDRESS ANSWERS EVEN WHEN NOBODY SAVED ONE.
		//
		// A name is an NFT held by an address, so the owner is already
		// public — it is the first field of the record above. Returning
		// it here as well costs no storage and means a name can be paid
		// without its holder ever having opened a profile editor, which
		// is most of them, and without a transaction to back-fill the
		// ones registered before this existed.
		//
		// Doing it in the realm rather than in the website is the whole
		// point: any client asking this realm for the gno key gets the
		// same answer our pages do. A front end that derived it locally
		// would leave every other reader with nothing.
		//
		// "off" is the opt-out, and it has to be a sentinel. An empty
		// value is indistinguishable from never having set one, so an
		// empty gno field would simply hand the derived address back on
		// the next read.
		if k == "gno" {
			if v == "off" {
				v = ""
			} else if v == "" {
				v = owner.String()
			}
		}
		b.WriteString(escapeValue(v))
	}
	return b.String()
}

// Extension VALUES are free text — a bio can hold anything a person can
// type, newlines included — so they cannot be newline-separated raw.
// Escaping is done here rather than stripping, because silently eating a
// line break out of somebody's bio is data loss on a read path.
func escapeValue(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	return strings.ReplaceAll(s, "\r", `\r`)
}

// RecentNames answers "what has just been registered" in one read.
//
// The site used to build this by listing every key and then reading each
// record one at a time — the same shape NamesOwnedBy replaced for a
// wallet's holdings, and the same problem: fine at thirteen names, one
// query per name forever after. A feed that gets slower every time
// somebody registers is a feed that eventually stops loading on the busy
// day you most wanted it.
//
// Returns rows of "label*domain,registered,expires,owner", newest first,
// and a cursor. Sorting happens across a PAGE, not the whole registry:
// the vault stores names alphabetically and there is no index by date,
// so a caller that wants the true newest reads every page and merges.
// That is one query per 200 names instead of one per name — enough of a
// difference to stop mattering, without pretending the vault has an
// index it does not have.
func RecentNames(after string, limit int) (rows, next string) {
	if limit <= 0 || limit > maxHoldingsPage {
		limit = maxHoldingsPage
	}
	keys, nxt := nsdata.ExportNames("", after, limit)

	type row struct {
		text string
		at   int64
	}
	var found []row
	for _, key := range strings.Split(keys, ",") {
		if key == "" {
			continue
		}
		// The tree key is domain*label; the token ID is label*domain.
		at := strings.Index(key, "*")
		if at < 1 {
			continue
		}
		domainLabel, label := key[:at], key[at+1:]
		owner, registered, expires, _, _, _ := nsdata.GetNameInfo(label, domainLabel)
		found = append(found, row{
			text: ufmt.Sprintf("%s*%s,%d,%d,%s", label, domainLabel, registered, expires, owner.String()),
			at:   registered,
		})
	}

	// Insertion sort, newest first. The page is at most 200 entries and
	// gno has no sort in scope here; anything cleverer would be more code
	// than the problem deserves.
	for i := 1; i < len(found); i++ {
		v := found[i]
		j := i - 1
		for j >= 0 && found[j].at < v.at {
			found[j+1] = found[j]
			j--
		}
		found[j+1] = v
	}

	var b strings.Builder
	for _, r := range found {
		if b.Len() > 0 {
			b.WriteString(";")
		}
		b.WriteString(r.text)
	}
	return b.String(), nxt
}
