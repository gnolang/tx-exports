package kylix

import (
	"chain/runtime"
	"html"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nym-kylix000/ring/v0"
	"gno.land/r/sys/users"
)

const (
	pageOffers       = 50 // open offers per page, newest first
	maxFormAssetOpts = 50 // cap dropdown choices on the post page
	homeCollections  = 10 // collections listed on the home page
	pageCollections  = 50 // collections per page on the collections page
)

// Render serves Kylix's gnoweb pages:
//   - ""             Home: pitch, 3-step guide, ready rings, open offers, collections
//   - "offers/<id>"  Older open offers before <id>
//   - "offer/<id>"   One offer: details, readiness, approve step, matching rings, actions
//   - "ring/<ids>"   One ring (e.g. "ring/1,2,3"): large graph, swaps in words, readiness, settle
//   - "post"         Offer builder (approve address calculator + TxLinks + gnokey form)
//   - "collections"  Registered collections, official first (paged with ?after=<key>)
//   - "about"        How settlement works, custody model, GnoSwap fees, collection plug-in guide
//
// Home ("", "offers/<id>") never calls third-party collection code. It
// reads Kylix's own storage, token ledgers and official collections (to check
// that offers are still ready), and gno.land/r/sys/users for display names.
// Only a third-party item's own offer and ring pages, and settling, run that
// collection's code.
// Every string from a user or collection is sanitized for the slot it lands in.
func Render(path string) string {
	route, rawQuery, _ := strings.Cut(path, "?")
	switch {
	case route == "":
		return renderHome(0)
	case strings.HasPrefix(route, "offers/"):
		before, err := strconv.ParseUint(strings.TrimPrefix(route, "offers/"), 10, 64)
		if err != nil {
			return renderNotFound("No such page.")
		}
		return renderHome(before)
	case strings.HasPrefix(route, "offer/"):
		id, err := strconv.ParseUint(strings.TrimPrefix(route, "offer/"), 10, 64)
		if err != nil {
			return renderNotFound("No such offer.")
		}
		return renderOffer(id)
	case strings.HasPrefix(route, "ring/"):
		return renderRing(strings.TrimPrefix(route, "ring/"))
	case route == "post":
		return renderPost(rawQuery)
	case route == "collections":
		q, _ := url.ParseQuery(rawQuery)
		return renderCollections(q.Get("after"))
	case route == "about" || route == "how":
		return renderAbout()
	}
	return renderNotFound("Page not found.")
}

func renderNotFound(msg string) string {
	return "# Not found\n\n" + navBar("") + "\n\n" + msg + "\n\n[Back to Kylix](" + webPath() + ")\n"
}

func renderHome(before uint64) string {
	cache := map[string]string{}
	var sb strings.Builder
	sb.WriteString("# Kylix\n\n")
	sb.WriteString(navBar("home") + "\n\n")
	sb.WriteString("Swap tokens and collectibles in a circle: post what you offer and what you want, and when two to six offers close a ring, everyone swaps in one transaction — with nothing leaving your wallet until settlement.\n\n")

	sb.WriteString(gnoButton(webPath()+":post", "Post an offer", "success") + " ")
	sb.WriteString(gnoButton(demoWebPath(), "Get free demo assets", "outline") + " ")
	sb.WriteString(gnoButton(webPath()+":about", "How it works", "outline") + "\n\n")

	h := runtime.ChainHeight()
	var table string
	var next uint64

	if before == 0 {
		// One B+ tree pass feeds both the open offers table (the newest
		// pageOffers) and the ring search window, which may read further
		// back (see newestUnexpiredOffers).
		page := make([]*Offer, 0, pageOffers)
		w := newWindow(true)
		eachOfferBefore(0, func(o *Offer) bool {
			if len(page) == pageOffers && next == 0 {
				next = o.ID + 1
			}
			if len(page) < pageOffers {
				page = append(page, o)
			}
			w.consider(o, h)
			return len(page) == pageOffers && next != 0 && w.done()
		})

		sb.WriteString("<gno-columns>\n")
		sb.WriteString("<gno-frame>\n### 1. Approve\nAllow your offer's own address to move only the token amount or item you offer. Your assets stay in your wallet.\n</gno-frame>\n")
		sb.WriteString("<gno-columns-sep />\n")
		sb.WriteString("<gno-frame>\n### 2. Post your offer\nState what you give and the minimum you want back. You can cancel an open offer at any time.\n</gno-frame>\n")
		sb.WriteString("<gno-columns-sep />\n")
		sb.WriteString("<gno-frame>\n### 3. Settle the ring\nWhen two to six offers form a closed circle, anyone can settle it. Every swap happens together, or nothing moves.\n</gno-frame>\n")
		sb.WriteString("</gno-columns>\n\n")

		sb.WriteString("## Ready to settle\n\n")
		rings := findHomeRingsFrom(w)
		if len(rings) == 0 {
			sb.WriteString("No 2- or 3-offer direct ring of ready offers is open among the newest offers right now. [Post a matching offer](" + webPath() + ":post) or grab test tokens and a Relic from the [demo faucet](" +
				demoWebPath() + ").\n\n")
		} else {
			writeRingCards(&sb, rings, cache)
			sb.WriteString("Showing 2- and 3-offer direct rings found among the newest open offers, every offer checked ready just now. ")
			sb.WriteString("This page checks items of official collections only; rings with other collections' items are listed on those offers' own pages. ")
			sb.WriteString("Longer rings (up to 6 offers) and rings that need a GnoSwap swap are found by programs that search off chain.\n\n")
		}
		table = renderOfferRows(page, h, cache)
	} else {
		table, next = offerTableWithCache(before, pageOffers, cache)
	}

	sb.WriteString("## Open offers\n\n")
	if n := offers.Size(); n > 0 {
		sb.WriteString(strconv.Itoa(n) + " open " + pluralWord(n, "offer", "offers") + " in the book")
		if before != 0 {
			sb.WriteString(" · [← Newest offers](" + webPath() + ")")
		}
		sb.WriteString(".\n\n")
	}
	sb.WriteString(table)
	if next != 0 {
		sb.WriteString("\n[Older offers →](" + webPath() + ":offers/" + u64(next) + ")\n")
	}

	sb.WriteString("\n## Collections\n\n")
	sb.WriteString(collectionList())
	sb.WriteString("\n[Collection details & adapter trust guide →](" + webPath() + ":collections)\n\n")

	sb.WriteString("> [!TIP] Try Kylix in two minutes\n")
	sb.WriteString("> Claim free OBOL, DRACHMA and a Kylix Relic from the [demo faucet](" + demoWebPath() + "), then post an offer. ")
	sb.WriteString("Want browser alerts when your offers settle? Opt in on [gnotif](https://gnotif.xyz).\n")
	return sb.String()
}

func writeRingCards(sb *strings.Builder, rings [][]*Offer, cache map[string]string) {
	for i := 0; i < len(rings); i += 2 {
		sb.WriteString("<gno-columns>\n")
		writeOneRingCard(sb, rings[i], cache)
		if i+1 < len(rings) {
			sb.WriteString("<gno-columns-sep />\n")
			writeOneRingCard(sb, rings[i+1], cache)
		}
		sb.WriteString("</gno-columns>\n\n")
	}
}

func writeOneRingCard(sb *strings.Builder, r []*Offer, cache map[string]string) {
	ids := offerIDList(r)
	hops := make([]ring.GraphHop, len(r))
	for i, o := range r {
		hops[i] = ring.GraphHop{
			From:    ownerPlain(o.Owner, cache),
			Give:    graphAsset(o.Give),
			Note:    svgHint(assetHint(o.Give)),
			OfferID: o.ID,
		}
	}
	uri := ring.GraphDataURI(hops, ring.GraphThumb)
	sb.WriteString("<gno-frame>\n")
	sb.WriteString("### " + strconv.Itoa(len(r)) + "-offer ring (" + ids + ")\n\n")
	if uri != "" {
		sb.WriteString("![Ring " + ids + "](" + uri + ")\n\n")
	}
	for i, o := range r {
		next := r[(i+1)%len(r)]
		sb.WriteString("- " + ownerMarkdown(o.Owner, cache) + " gives **" + sanitize.InlineText(shortAsset(o.Give)) +
			"** to " + ownerMarkdown(next.Owner, cache) + "\n")
	}
	// The button leads to the ring page, which shows every asset's full key
	// and the settle command, rather than settling from here.
	sb.WriteString("\n" + gnoButton(webPath()+":ring/"+ids, "Review and settle", "success") + "\n")
	sb.WriteString("</gno-frame>\n")
}

// offerTable renders up to limit open offers with id < before (all when
// before is 0), newest first, as a markdown table. next is the before value
// for the following page, or 0 when there is none.
func offerTable(before uint64, limit int) (md string, next uint64) {
	return offerTableWithCache(before, limit, map[string]string{})
}

func offerTableWithCache(before uint64, limit int, cache map[string]string) (md string, next uint64) {
	h := runtime.ChainHeight()
	page := make([]*Offer, 0, limit)
	eachOfferBefore(before, func(o *Offer) bool {
		if len(page) == limit {
			next = o.ID + 1 // an older offer exists; the next page starts at it
			return true
		}
		page = append(page, o)
		return false
	})
	if len(page) == 0 && before != 0 {
		// A page past the oldest offer: the book may still hold newer ones.
		return "No older open offers.\n", 0
	}
	return renderOfferRows(page, h, cache), next
}

func renderOfferRows(page []*Offer, h int64, cache map[string]string) string {
	if len(page) == 0 {
		return "No open offers yet. [Post the first offer](" + webPath() + ":post).\n"
	}
	var sb strings.Builder
	sb.WriteString("| Offer | Owner | Gives | Wants | Expiry |\n|---|---|---|---|---|\n")
	for _, o := range page {
		sb.WriteString("| [" + u64(o.ID) + "](" + webPath() + ":offer/" + u64(o.ID) + ") | ")
		sb.WriteString(ownerTableCell(o.Owner, cache) + " | ")
		sb.WriteString(sanitize.TableCell(shortAsset(o.Give)) + " | ")
		sb.WriteString(sanitize.TableCell(shortWant(o.Want)) + " | ")
		sb.WriteString(expiryString(o, h) + " |\n")
	}
	return sb.String()
}

// collectionList renders the registered collections as a markdown list,
// official ones first, at most homeCollections of them, with a link to the
// collections page for the rest.
func collectionList() string {
	if collections.Size() == 0 {
		return "No collections registered.\n"
	}
	var sb strings.Builder
	keys, more := collectionKeys("", homeCollections)
	for _, key := range keys {
		c := getCollection(key)
		sb.WriteString("- **" + sanitize.InlineText(c.name) + "** (" + sanitize.InlineCode(key) + "): " +
			collectionLabel(key) + "\n")
	}
	if more {
		sb.WriteString("- … and " + strconv.Itoa(collections.Size()-len(keys)) + " more on the [collections page](" + webPath() + ":collections)\n")
	}
	return sb.String()
}

// collectionKeys lists up to limit collection keys, official ones (under
// Kylix's own namespace) first, then the others in key order, starting
// after the key after ("" for the start). more reports whether any follow.
func collectionKeys(after string, limit int) (keys []string, more bool) {
	ns := namespacePrefix()
	type span struct{ start, end string }
	spans := []span{{"", ""}}
	if ns != "" {
		nsEnd := ns + "\xff"
		spans = []span{{ns, nsEnd}, {"", ns}, {nsEnd, ""}}
	}
	in := func(sp span, k string) bool { return k >= sp.start && (sp.end == "" || k < sp.end) }
	from := 0
	if after != "" {
		for i, sp := range spans {
			if in(sp, after) {
				from = i
				spans[i].start = after + "\x00"
				break
			}
		}
	}
	for _, sp := range spans[from:] {
		collections.Iterate(sp.start, sp.end, func(key string, _ any) bool {
			if len(keys) >= limit {
				more = true
				return true
			}
			keys = append(keys, key)
			return false
		})
		if more {
			break
		}
	}
	return keys, more
}

// collectionKind is a collection's trust label, the same words on every
// page, in ring captions and in the export: "official collection" or
// "official adapter" for one registered under Kylix's own namespace,
// "third-party collection" or "third-party adapter" for any other.
// Official is a label, not a gate: anyone may register a collection under
// their own namespace, and pick any display name.
func collectionKind(key string) string {
	c := getCollection(key)
	switch {
	case c == nil:
		return "unregistered"
	case c.target == "" && IsOfficial(key):
		return "official collection"
	case c.target == "":
		return "third-party collection"
	case IsOfficial(key):
		return "official adapter"
	}
	return "third-party adapter"
}

// collectionLabel is collectionKind, naming an adapter's target.
func collectionLabel(key string) string {
	c := getCollection(key)
	if c == nil || c.target == "" {
		return collectionKind(key)
	}
	return collectionKind(key) + " for " + sanitize.InlineText(c.target)
}

func wantString(a ring.Asset) string {
	if a.Kind == ring.Fungible {
		return "at least " + a.String()
	}
	return a.String()
}

func shortWant(a ring.Asset) string {
	if a.Kind == ring.Fungible {
		return "at least " + shortAsset(a)
	}
	return shortAsset(a)
}

// shortAsset names an asset in words with a hint of the realm it lives in,
// because symbols and display names are chosen by whoever deploys: anyone
// can make a token called GNS or a collection called Kylix Relics. Tokens:
// "100 OBOL (nym-kylix000/kylixdemo)". Items carry their collection's label
// too: "Kylix Relics #relic-2 (official collection, nym-kylix000/kylixdemo)".
// Pages where someone decides to sign show the full key as well (keyedAsset).
func shortAsset(a ring.Asset) string {
	if a.Kind == ring.Item {
		return graphAsset(a) + " (" + collectionKind(a.Key) + ", " + realmHint(a.Key) + ")"
	}
	return graphAsset(a) + " (" + realmHint(tokenRealmPath(a.Key)) + ")"
}

// keyedAsset is for the pages where someone decides: the short name in bold,
// then the label and the full key in code. Markdown, already escaped.
func keyedAsset(a ring.Asset, atLeast bool) string {
	name := graphAsset(a)
	if atLeast && a.Kind == ring.Fungible {
		name = "at least " + name
	}
	if a.Kind == ring.Item {
		return "**" + sanitize.InlineText(name) + "** (" + collectionKind(a.Key) + " " + sanitize.InlineCode(a.Key) + ")"
	}
	return "**" + sanitize.InlineText(name) + "** (token " + sanitize.InlineCode(a.Key) + ")"
}

// graphAsset is the bare name, for the ring pictures, which draw the realm
// hint (assetHint) on a second line.
func graphAsset(a ring.Asset) string {
	if a.Kind == ring.Item {
		if name := CollectionName(a.Key); name != "" {
			return name + " #" + a.ID
		}
		return a.Key + "#" + a.ID
	}
	return strconv.FormatInt(a.Amount, 10) + " " + shortTokenSymbol(a.Key)
}

// assetHint is the realm hint of an asset: its token realm or collection.
func assetHint(a ring.Asset) string {
	if a.Kind == ring.Item {
		return realmHint(a.Key)
	}
	return realmHint(tokenRealmPath(a.Key))
}

// svgHint fits a realm hint into a ring picture without making it
// ambiguous. The namespace is what tells owners apart: a name namespace is
// kept whole, and only a namespace that is a valid address (checked as an
// address, not by its look: a registered name may start with "g1") keeps its
// first 8 and last 6 characters, the end being checksum, so matching both
// means grinding about 2^60 keys. Only the rest of the path, which the same
// owner controls anyway, is shortened. A hint is then at most 64 + 15 runes,
// under the picture's 80-rune limit for notes.
func svgHint(hint string) string {
	ns, rest, _ := strings.Cut(hint, "/")
	if address(ns).IsValid() {
		ns = ns[:8] + "…" + ns[len(ns)-6:]
	}
	if rest == "" {
		return ns
	}
	if r := []rune(rest); len(r) > 14 {
		rest = "…" + string(r[len(r)-13:])
	}
	return ns + "/" + rest
}

// realmHint shortens a realm path to what identifies it: the namespace and
// the rest of the path, without "gno.land/r/". The namespace comes first,
// and only its owner can deploy under it, so a look-alike cannot share the
// hint's beginning: "gnoland/wugnot" vs "evil/gnoland/wugnot".
func realmHint(pkgPath string) string {
	s := strings.TrimPrefix(pkgPath, "gno.land/")
	s = strings.TrimPrefix(s, "r/")
	if s == "" {
		return pkgPath
	}
	return s
}

func shortTokenSymbol(key string) string {
	if i := strings.LastIndex(key, "."); i >= 0 && i+1 < len(key) {
		return key[i+1:]
	}
	return key
}

func tokenRealmPath(key string) string {
	if i := strings.LastIndex(key, "."); i > 0 {
		return key[:i]
	}
	return ""
}

func assetNote(a ring.Asset) string {
	if a.Kind != ring.Item {
		return ""
	}
	c := getCollection(a.Key)
	if c == nil {
		return ""
	}
	return " (" + sanitize.InlineText(c.name) + ", " + collectionLabel(a.Key) + ")"
}

// expiryString is the short form for tables: "in about 3 days" or
// "expired".
func expiryString(o *Offer, h int64) string {
	if expired(o, h) {
		return "expired"
	}
	return blocksAhead(o.Expiry - h)
}

// expiryLong adds the block height: "in about 3 days (block height 1234)".
func expiryLong(o *Offer, h int64) string {
	if expired(o, h) {
		return "expired at block height " + strconv.FormatInt(o.Expiry, 10)
	}
	return blocksAhead(o.Expiry-h) + " (block height " + strconv.FormatInt(o.Expiry, 10) + ")"
}

// blocksAhead says roughly how long n blocks take, assuming BlocksPerDay,
// rounded to the nearest hour or day (a 7-day offer a few blocks old still
// reads "in about 7 days").
func blocksAhead(n int64) string {
	const perHour = BlocksPerDay / 24
	hours := (n + perHour/2) / perHour
	days := (n + BlocksPerDay/2) / BlocksPerDay
	switch {
	case hours < 1:
		return "in less than an hour"
	case hours == 1:
		return "in about an hour"
	case hours < 24:
		return "in about " + strconv.FormatInt(hours, 10) + " hours"
	case days == 1:
		return "in about a day"
	}
	return "in about " + strconv.FormatInt(days, 10) + " days"
}

// expiryInputHint explains PostIntent's expiry argument on the post forms.
func expiryInputHint() string {
	h := runtime.ChainHeight()
	return "Expiry block height: 0 for the default of about 7 days, at most about 30 days ahead (now " +
		strconv.FormatInt(h, 10) + ", latest " + strconv.FormatInt(h+MaxExpiryBlocks, 10) + ")"
}

// webPath is this realm's gnoweb path, e.g. "/r/nym-kylix000/kylix".
func webPath() string {
	return pkgWebPath(selfPath)
}

func pkgWebPath(pkgPath string) string {
	if i := strings.Index(pkgPath, "/"); i >= 0 {
		return pkgPath[i:]
	}
	return pkgPath
}

func demoRealmPath() string {
	ns := namespacePrefix()
	if ns == "" {
		return ""
	}
	return ns + "kylixdemo"
}

func demoWebPath() string {
	p := demoRealmPath()
	if p == "" {
		return "/r/nym-kylix000/kylixdemo"
	}
	return pkgWebPath(p)
}

func navBar(active string) string {
	items := []struct {
		key, label, href string
	}{
		{"home", "Home", webPath()},
		{"post", "Post an offer", webPath() + ":post"},
		{"collections", "Collections", webPath() + ":collections"},
		{"about", "How it works", webPath() + ":about"},
		{"demo", "Demo faucet", demoWebPath()},
	}
	var parts []string
	for _, it := range items {
		if it.key == active {
			parts = append(parts, "**"+it.label+"**")
		} else {
			parts = append(parts, "["+it.label+"]("+it.href+")")
		}
	}
	return strings.Join(parts, " · ")
}

func lookupUsername(addr address, cache map[string]string) string {
	s := addr.String()
	if name, ok := cache[s]; ok {
		return name
	}
	var name string
	if u := users.ResolveAddress(addr); u != nil {
		name = sanitize.UserName(u.Name())
	}
	cache[s] = name
	return name
}

func ownerPlain(addr address, cache map[string]string) string {
	if name := lookupUsername(addr, cache); name != "" {
		return "@" + name
	}
	return shortAddr(addr)
}

func ownerMarkdown(addr address, cache map[string]string) string {
	if name := lookupUsername(addr, cache); name != "" {
		return "[@" + sanitize.InlineText(name) + "](/u/" + url.PathEscape(name) + ")"
	}
	return "`" + shortAddr(addr) + "`"
}

func ownerFullMarkdown(addr address, cache map[string]string) string {
	if name := lookupUsername(addr, cache); name != "" {
		return "[@" + sanitize.InlineText(name) + "](/u/" + url.PathEscape(name) + ") (`" + addr.String() + "`)"
	}
	return "`" + addr.String() + "`"
}

func ownerTableCell(addr address, cache map[string]string) string {
	if name := lookupUsername(addr, cache); name != "" {
		return "[@" + sanitize.TableCell(name) + "](/u/" + url.PathEscape(name) + ")"
	}
	return "`" + shortAddr(addr) + "`"
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 13 {
		return s
	}
	return s[:6] + "…" + s[len(s)-4:]
}

func offerIDList(offs []*Offer) string {
	ids := make([]uint64, len(offs))
	for i, o := range offs {
		ids[i] = o.ID
	}
	return ring.FormatOfferIDs(ids)
}

// txLink builds a GnoConnect / gnoweb $help transaction link with query-escaped
// argument pairs (k1, v1, k2, v2, ...).
func txLink(realmWebPath, fn string, kv ...string) string {
	var sb strings.Builder
	sb.WriteString(realmWebPath)
	sb.WriteString("$help&func=")
	sb.WriteString(url.QueryEscape(fn))
	for i := 0; i+1 < len(kv); i += 2 {
		sb.WriteByte('&')
		sb.WriteString(url.QueryEscape(kv[i]))
		sb.WriteByte('=')
		sb.WriteString(url.QueryEscape(kv[i+1]))
	}
	return sb.String()
}

func gnoButton(href, label, variant string) string {
	s := `<gno-button href="` + attrEscape(href) + `" label="` + attrEscape(label) + `"`
	if variant != "" {
		s += ` variant="` + attrEscape(variant) + `"`
	}
	return s + ` />`
}

func gnoInput(name, placeholder, value string, required, readonly bool) string {
	s := `<gno-input name="` + attrEscape(name) + `" placeholder="` + attrEscape(placeholder) + `"`
	if value != "" {
		s += ` value="` + attrEscape(value) + `"`
	}
	if required {
		s += ` required="true"`
	}
	if readonly {
		s += ` readonly="true"`
	}
	return s + " />\n"
}

func gnoSelectOpt(name, value, description string, selected, required bool) string {
	s := `<gno-select name="` + attrEscape(name) + `" value="` + attrEscape(value) + `"`
	if description != "" {
		s += ` description="` + attrEscape(description) + `"`
	}
	if selected {
		s += ` selected="true"`
	}
	if required {
		s += ` required="true"`
	}
	return s + " />\n"
}

func attrEscape(s string) string {
	return html.EscapeString(sanitize.StripBidiAndZeroWidth(s))
}

func pluralWord(n int, singular, plural string) string {
	if n == 1 {
		return singular
	}
	return plural
}
