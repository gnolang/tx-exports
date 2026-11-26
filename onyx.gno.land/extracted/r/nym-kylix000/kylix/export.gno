package kylix

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nym-kylix000/ring/v0"
)

const (
	// DefaultExportPage and MaxExportPage bound ExportGraphJSONPage, so one
	// query stays within the read-gas limit however large the book grows.
	DefaultExportPage = 100
	MaxExportPage     = 500
)

// ExportGraphJSON returns every open, unexpired offer and every registered
// collection as JSON, for off-chain solvers looking for rings. Its cost
// grows with the book; past a few hundred offers use ExportGraphJSONPage.
//
//	{"realm":"gno.land/r/...","height":123,
//	 "collections":[{"key":"gno.land/r/...","name":"...","adapter":false,
//	   "target":"","official":true,"approvalCheck":true}],
//	 "offers":[{"id":1,"owner":"g1...","nonce":1,"slot":"g1...","approve":"g1...",
//	   "give":{"kind":"fungible","key":"gno.land/r/x.FOO","id":"","amount":"100"},
//	   "want":{"kind":"item","key":"gno.land/r/y","id":"relic-7","amount":"0"},
//	   "expiry":12345,"viaSession":false}],
//	 "hasMore":false,"next":0,"total":1}
//
// Amounts are decimal strings because int64 does not fit a JSON number in
// most parsers. "approve" is the address the owner must have approved (see
// ApproveTarget); a solver can check it before proposing a ring, or ask
// Deliverable. Offers are in id order. "hasMore" says another page follows
// and "next" is the cursor to pass as `after` for it (0 when hasMore is
// false). "total" counts every open offer in the book, expired ones
// included until pruned, so it can exceed what the pages list.
func ExportGraphJSON() string {
	assertNotSettling()
	return exportJSON(0, -1)
}

// ExportGraphJSONPage returns at most limit open, unexpired offers with id
// greater than after (limit <= 0 means DefaultExportPage; at most
// MaxExportPage). It looks at no more than MaxExportPage offers, expired
// ones included, so its cost is bounded however many offers have expired;
// a page can therefore hold fewer than limit offers and still have
// "hasMore" set. "collections" is included only in the first page (after
// == 0). Page with "hasMore" and "next" as ExportGraphJSON describes.
func ExportGraphJSONPage(after uint64, limit int) string {
	assertNotSettling()
	if limit <= 0 {
		limit = DefaultExportPage
	}
	if limit > MaxExportPage {
		limit = MaxExportPage
	}
	return exportJSON(after, limit)
}

// exportJSON lists offers after the given id; limit < 0 means all, with no
// scan bound.
func exportJSON(after uint64, limit int) string {
	h := runtime.ChainHeight()
	var sb strings.Builder
	sb.WriteString(`{"realm":`)
	sb.WriteString(jsonString(selfPath))
	sb.WriteString(`,"height":`)
	sb.WriteString(strconv.FormatInt(h, 10))
	if after == 0 {
		writeCollectionsJSON(&sb, "", MaxExportCollections)
	}
	sb.WriteString(`,"offers":[`)
	paged := limit >= 0
	count, scanned := 0, 0
	var last, next uint64 // last: id of the last offer looked at
	eachOfferAfter(after, func(o *Offer) bool {
		if paged && scanned == MaxExportPage {
			next = last // scan bound reached; more offers may remain
			return true
		}
		scanned++
		if expired(o, h) {
			last = o.ID
			return false
		}
		if paged && count == limit {
			next = last // an unexpired offer remains; resume after the last one seen
			return true
		}
		last = o.ID
		if count > 0 {
			sb.WriteByte(',')
		}
		writeOfferJSON(&sb, o)
		count++
		return false
	})
	sb.WriteString(`],"hasMore":`)
	sb.WriteString(strconv.FormatBool(next != 0))
	sb.WriteString(`,"next":`)
	sb.WriteString(u64(next))
	sb.WriteString(`,"total":`)
	sb.WriteString(strconv.Itoa(offers.Size()))
	sb.WriteString(`}`)
	return sb.String()
}

func writeOfferJSON(sb *strings.Builder, o *Offer) {
	sb.WriteString(`{"id":`)
	sb.WriteString(u64(o.ID))
	sb.WriteString(`,"owner":`)
	sb.WriteString(jsonString(o.Owner.String()))
	sb.WriteString(`,"nonce":`)
	sb.WriteString(u64(o.Nonce))
	sb.WriteString(`,"slot":`)
	sb.WriteString(jsonString(SlotAddress(o.Owner, o.Nonce).String()))
	sb.WriteString(`,"approve":`)
	sb.WriteString(jsonString(ApproveTarget(o.Owner, o.Nonce, o.Give.Key).String()))
	sb.WriteString(`,"give":`)
	writeAssetJSON(sb, o.Give)
	sb.WriteString(`,"want":`)
	writeAssetJSON(sb, o.Want)
	sb.WriteString(`,"expiry":`)
	sb.WriteString(strconv.FormatInt(o.Expiry, 10))
	sb.WriteString(`,"viaSession":`)
	sb.WriteString(strconv.FormatBool(o.ViaSession))
	sb.WriteByte('}')
}

// MaxExportCollections bounds the collections listed in one export: the
// first offers page carries up to this many, official ones first, and
// ExportCollectionsJSON pages through the rest.
const MaxExportCollections = 100

// ExportCollectionsJSON lists up to limit registered collections (at most
// MaxExportCollections; 0 for that maximum), official ones first, starting
// after the key after ("" for the start):
//
//	{"collections":[...],"collectionsHasMore":true,"collectionsNext":"gno.land/r/..."}
//
// Pass collectionsNext as after for the next page.
func ExportCollectionsJSON(after string, limit int) string {
	assertNotSettling()
	if limit <= 0 || limit > MaxExportCollections {
		limit = MaxExportCollections
	}
	var sb strings.Builder
	writeCollectionsJSON(&sb, after, limit)
	return "{" + strings.TrimPrefix(sb.String(), ",") + "}"
}

// writeCollectionsJSON writes `,"collections":[...],"collectionsHasMore":b,
// "collectionsNext":"key"`.
func writeCollectionsJSON(sb *strings.Builder, after string, limit int) {
	keys, more := collectionKeys(after, limit)
	sb.WriteString(`,"collections":[`)
	for i, key := range keys {
		if i > 0 {
			sb.WriteByte(',')
		}
		writeCollectionJSON(sb, describe(key, getCollection(key)))
	}
	sb.WriteString(`],"collectionsHasMore":`)
	sb.WriteString(strconv.FormatBool(more))
	next := ""
	if more {
		next = keys[len(keys)-1]
	}
	sb.WriteString(`,"collectionsNext":`)
	sb.WriteString(jsonString(next))
}

func writeCollectionJSON(sb *strings.Builder, c Collection) {
	sb.WriteString(`{"key":`)
	sb.WriteString(jsonString(c.Key))
	sb.WriteString(`,"name":`)
	sb.WriteString(jsonString(c.Name))
	sb.WriteString(`,"adapter":`)
	sb.WriteString(strconv.FormatBool(c.Adapter))
	sb.WriteString(`,"target":`)
	sb.WriteString(jsonString(c.Target))
	sb.WriteString(`,"official":`)
	sb.WriteString(strconv.FormatBool(c.Official))
	sb.WriteString(`,"label":`)
	sb.WriteString(jsonString(c.Label))
	sb.WriteString(`,"approvalCheck":`)
	sb.WriteString(strconv.FormatBool(c.ApprovalCheck))
	sb.WriteByte('}')
}

func writeAssetJSON(sb *strings.Builder, a ring.Asset) {
	sb.WriteString(`{"kind":`)
	sb.WriteString(jsonString(a.Kind.String()))
	sb.WriteString(`,"key":`)
	sb.WriteString(jsonString(a.Key))
	sb.WriteString(`,"id":`)
	sb.WriteString(jsonString(a.ID))
	sb.WriteString(`,"amount":"`)
	sb.WriteString(strconv.FormatInt(a.Amount, 10))
	sb.WriteString(`"}`)
}

// jsonString quotes s as a JSON string. Besides what JSON requires, it
// escapes <, >, & and U+2028/U+2029 so the output is also safe to embed in
// HTML or a JavaScript literal. Invalid UTF-8 becomes U+FFFD.
func jsonString(s string) string {
	const hex = "0123456789abcdef"
	var sb strings.Builder
	sb.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			sb.WriteString(`\"`)
		case r == '\\':
			sb.WriteString(`\\`)
		case r == '\n':
			sb.WriteString(`\n`)
		case r == '\r':
			sb.WriteString(`\r`)
		case r == '\t':
			sb.WriteString(`\t`)
		case r < 0x20, r == '<', r == '>', r == '&', r == 0x2028, r == 0x2029:
			sb.WriteString(`\u`)
			sb.WriteByte(hex[(r>>12)&0xf])
			sb.WriteByte(hex[(r>>8)&0xf])
			sb.WriteByte(hex[(r>>4)&0xf])
			sb.WriteByte(hex[r&0xf])
		default:
			sb.WriteRune(r)
		}
	}
	sb.WriteByte('"')
	return sb.String()
}
