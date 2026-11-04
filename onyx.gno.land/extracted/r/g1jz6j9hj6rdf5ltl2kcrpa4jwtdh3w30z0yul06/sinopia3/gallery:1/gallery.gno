// Package gallery is the platform's gnoweb face (design §2.5.7): the
// product stays browsable on gno.land even without the website. It is
// private (re-deployable in place), read-only and holds nothing.
//
// Routes:
//
//	""                    latest collections
//	c/<cid>[?page=N]      one collection, 20 tokens per page
//	c/<cid>/t/<tid>       one token: art, traits, owner, listing, provenance
//	e/<engine pkgpath>    an engine's manifest and status
//	u/<name>              a registered user's collections and listings
//
// Every user-supplied string is rendered as plain text (plainText: RA M-9,
// SA-M4): no heading, link, image, HTML or autolink can come out of a name,
// description, trait or manifest field. Every list is paginated.
package gallery

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/sys/users"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/media/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/types/v1"
	assets "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/assets/v1"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core"
	upload "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/engines/upload"
	market "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/market/v1"
)

const (
	pageSize   = 20
	homeLimit  = 20
	maxPageNum = 500
)

func Render(path string) string {
	route, query, _ := strings.Cut(path, "?")
	parts := strings.Split(route, "/")
	switch {
	case route == "":
		return home()
	case len(parts) == 2 && parts[0] == "c":
		return collectionPage(parts[1], pageFrom(query))
	case len(parts) == 4 && parts[0] == "c" && parts[2] == "t":
		return tokenPage(parts[1], parts[3])
	case len(parts) > 1 && parts[0] == "e":
		return enginePage(strings.TrimPrefix(route, "e/"))
	case len(parts) == 2 && parts[0] == "u":
		return userPage(parts[1])
	}
	return "# Not found\n\n[Back to the gallery](" + base() + ")\n"
}

func home() string {
	n := core.CollectionCount()
	out := ufmt.Sprintf("# Gallery\n\n%d collections. Art is computed on chain from each collection's engine and revealed seed.\n\n", n)
	for id := n; id >= 1 && id > n-homeLimit; id-- {
		info := core.Info(itoa(id))
		out += ufmt.Sprintf("- [%s](%s) — %s, %d/%d minted\n",
			plainText(info.Name), link("c/"+info.ID), info.State.String(), info.Minted, info.MaxSupply)
	}
	return out
}

func collectionPage(cid string, page int64) string {
	info := core.Info(cid)
	out := "# " + plainText(info.Name) + " (" + plainText(info.Symbol) + ")\n\n"
	if info.Description != "" {
		out += plainText(info.Description) + "\n\n"
	}
	out += ufmt.Sprintf("- State: **%s**, %d/%d minted, royalty %d bps\n", info.State.String(), info.Minted, info.MaxSupply, info.RoyaltyBps)
	out += "- Creator: " + who(info.Creator) + "\n"
	out += "- Engine: [" + plainText(info.EngineID) + "](" + link("e/"+info.EngineID) + ")\n"
	if info.Badge != "" {
		out += "- Provenance: **" + info.Badge + "** — " + fairness(cid) + "\n"
	}
	if info.EngineID == upload.SelfPath() {
		out += uploadCollectionLines(cid)
	}
	if f := market.Floor(cid); f > 0 {
		out += ufmt.Sprintf("- Floor: %d ugnot\n", f)
	}
	out += "\n## Tokens\n\n"
	first := (page-1)*pageSize + 1
	for n := first; n < first+pageSize && n <= info.Minted; n++ {
		tid := itoa(n)
		owner, err := core.OwnerOf(cid, tid)
		if err != nil {
			continue
		}
		line := "- [#" + tid + "](" + link("c/"+cid+"/t/"+tid) + ") owned by " + who(owner)
		if _, price, ok := market.ActiveListing(cid, tid); ok {
			line += ufmt.Sprintf(", listed at %d ugnot", price)
		}
		out += line + "\n"
	}
	if first+pageSize <= info.Minted {
		out += "\n[Next page](" + link(ufmt.Sprintf("c/%s?page=%d", cid, page+1)) + ")\n"
	}
	return out
}

func tokenPage(cid, tid string) string {
	info := core.Info(cid)
	owner, err := core.OwnerOf(cid, tid)
	if err != nil {
		return "# Token not found\n"
	}
	isUpload := info.EngineID == upload.SelfPath()
	uri, _ := core.TokenURI(cid, tid)
	var art media.Artwork
	var slot, edition int64
	ready := false
	if isUpload {
		ready, slot, edition, art = upload.Assignment(cid, tid)
		if ready && art.Kind == media.KindChain {
			uri = upload.TokenImage(cid, tid) // the stored file itself (data: URI, gnoweb img-src data:)
		}
	}
	out := "# " + plainText(info.Name) + " #" + tid + "\n\n"
	out += "![" + plainText(info.Name) + " #" + tid + "](" + sanitize.ImageURL(uri) + ")\n\n"
	out += "- Owner: " + who(owner) + "\n"
	if isUpload {
		out += uploadTokenLines(cid, ready, edition, art)
	}
	if id, price, ok := market.ActiveListing(cid, tid); ok {
		out += ufmt.Sprintf("- Listed: %d ugnot (listing %s)\n", price, id)
	}
	out += "\n## Traits\n\n"
	traits := core.TokenTraitList(cid, tid)
	if isUpload {
		traits = upload.TokenTraitList(cid, tid)
		out += "Tier and traits assigned by the creator.\n\n"
	}
	for _, t := range traits {
		out += "- " + plainText(t.Type) + ": " + plainText(t.Value) + "\n"
	}
	out += "\n## How to verify\n\n"
	if info.State != types.StateFinal {
		out += "The collection is not revealed yet; every token shows the same placeholder.\n"
		return out
	}
	if isUpload {
		return out + uploadVerifySteps(cid, tid, ready, slot, art)
	}
	out += "1. Read `Provenance(\"" + cid + "\")` on core from another RPC and recompute the commitments and the salt.\n"
	out += "2. Seed: `TokenSeed(\"" + cid + "\", \"" + tid + "\")` = sha256(\"" + "art|seed|v1|" + cid + "|" + tid + "|\" + salt).\n"
	out += "3. Render it yourself: `RenderWith(engine, params, seed)` must return this image.\n\n"
	out += "Provenance badge **" + info.Badge + "**, on-chain check: " + strconv.FormatBool(core.VerifyProvenance(cid)) +
		"; " + fairness(cid) + "\n"
	return out
}

// --- uploaded collections (docs/uploaded-collections.md §5.4, §9) -------------

// badgeLabel is the site's storage badge text (§9).
func badgeLabel(b string) string {
	switch b {
	case "onchain":
		return "On-chain"
	case "ipfs":
		return "IPFS · hash-locked"
	case "mixed":
		return "Mixed (on-chain and IPFS)"
	case "computed":
		return "Computed on-chain"
	}
	return "Not ready"
}

func uploadCollectionLines(cid string) string {
	ready, reason, store, badge := upload.Readiness(cid)
	out := "- Storage: **" + badgeLabel(badge) + "**\n"
	if !ready {
		out += "- **Not ready (" + reason + ")**: the artwork set is not locked to this collection; do not mint.\n"
	}
	if store == "" {
		return out
	}
	si := assets.Info(store)
	out += ufmt.Sprintf("- Artwork set: store %s, %d artworks, %d slots (%d on-chain, %d IPFS); verifiable on chain / IPFS\n",
		store, si.Artworks, si.Slots, si.OnchainN, si.IPFSN)
	tiers, slots, untiered := assets.TierSlots(store)
	if len(tiers) > 0 {
		var parts []string
		for i := len(tiers) - 1; i >= 0; i-- { // high -> low, like a drop table
			if slots[i] > 0 {
				parts = append(parts, ufmt.Sprintf("%d %s", slots[i], plainText(tiers[i])))
			}
		}
		if untiered > 0 {
			parts = append(parts, ufmt.Sprintf("%d untiered", untiered))
		}
		out += "- Set composition (creator-assigned tiers, slots of " + itoa(si.Slots) + "): " +
			strings.Join(parts, " · ") + "\n"
	}
	return out
}

func uploadTokenLines(cid string, ready bool, edition int64, a media.Artwork) string {
	_, _, _, badge := upload.Readiness(cid)
	out := "- Storage: **" + badgeLabel(badge) + "**\n"
	if !ready {
		return out
	}
	if a.Title != "" {
		out += "- Artwork: " + plainText(a.Title) + "\n"
	}
	if a.Tier != "" {
		out += "- Tier: **" + plainText(a.Tier) + "** (assigned by the creator)\n"
	}
	if a.Editions > 1 {
		out += ufmt.Sprintf("- Edition %d of %d\n", edition, a.Editions)
	}
	out += ufmt.Sprintf("- File: %s, %d bytes, sha256 `%s`\n", media.MimeType(a.Mime), a.Size, a.SHA256)
	if a.Kind != media.KindChain {
		// never a remote image (SA-M4): the address is escaped text
		out += "- IPFS: " + plainText("ipfs://"+a.CID) + " (fetch it from any gateway and check the sha256)\n"
	}
	return out
}

func uploadVerifySteps(cid, tid string, ready bool, slot int64, a media.Artwork) string {
	if !ready {
		return "This uploaded collection is not bound to a sealed artwork set; no artwork is assigned.\n"
	}
	store := upload.StoreOf(cid)
	out := "1. Read `Provenance(\"" + cid + "\")` on core from another RPC and recompute the commitments and the salt.\n"
	out += "2. Key: `K = sha256(\"art|upload|perm|v1|" + cid + "|\" + salt)`, slot: `Permute(K, slots, " + tid +
		" - 1)` (media/v1; a single-artwork store uses slot = " + tid + " - 1).\n"
	out += ufmt.Sprintf("3. `SlotArtwork(\"%s\", %d)` on the asset store gives artwork %d; its sha256 must be the file's.\n",
		store, slot, a.Index)
	out += "\nProvenance badge **" + core.Info(cid).Badge + "**, on-chain check: " +
		strconv.FormatBool(core.VerifyProvenance(cid)) + "; " + fairness(cid) + "\n"
	return out
}

// fairness never calls a collection "verified" unless it is a fair launch
// (core.FairLaunch): a consistent record is not enough when one party could
// choose the map (SA-M2).
func fairness(cid string) string {
	if core.FairLaunch(cid) {
		return "fair launch, verified on chain"
	}
	if !core.VerifyProvenance(cid) {
		return "NOT verified: the provenance record does not check out"
	}
	return "not a fair launch: one party could choose the map (record consistent)"
}

// plainText renders user text as inert markdown: sanitize.InlineText escapes
// every inline-active character (\ * _ [ ] ( ) ~ > - + . ! ` # < &) and folds
// newlines, and escaping ':' breaks bare-URL autolinks ("https\://…"), which
// InlineText leaves alone (SA-M4).
func plainText(s string) string {
	return strings.ReplaceAll(sanitize.InlineText(s), ":", "\\:")
}

func enginePage(id string) string {
	m := core.EngineManifest(id)
	out := "# Engine " + plainText(m.Name) + " " + plainText(m.Version) + "\n\n"
	out += "- Realm: " + sanitize.InlineCode(id) + "\n"
	out += "- Author: " + who(m.Author) + "\n"
	out += "- Status: **" + core.EngineStatus(id) + "**, sample fingerprint intact: " + strconv.FormatBool(core.VerifyEngine(id)) + "\n"
	out += "- License: " + plainText(m.License) + "\n"
	out += "- Traits: " + plainText(strings.Join(m.TraitTypes, ", ")) + "\n\n"
	if m.Description != "" {
		out += plainText(m.Description) + "\n"
	}
	return out
}

func userPage(name string) string {
	u, _ := users.ResolveName(name)
	if u == nil {
		return "# Unknown user\n"
	}
	addr := u.Addr()
	return "# @" + sanitize.InlineText(u.Name()) + "\n\n`" + addr.String() + "`\n\n" +
		"Collections and listings of this address: reader realm, `Profile(" + addr.String() + ")`.\n"
}

// who renders an address as its r/sys/users name when it has one.
func who(addr address) string {
	if u := users.ResolveAddress(addr); u != nil {
		return "[@" + sanitize.InlineText(u.Name()) + "](/u/" + sanitize.InlineText(u.Name()) + ")"
	}
	return "`" + addr.String() + "`"
}

func pageFrom(query string) int64 {
	for _, kv := range strings.Split(query, "&") {
		if strings.HasPrefix(kv, "page=") {
			if n, err := strconv.ParseInt(strings.TrimPrefix(kv, "page="), 10, 64); err == nil && n >= 1 && n <= maxPageNum {
				return n
			}
		}
	}
	return 1
}

// selfPath is captured at deploy; links are gnoweb paths without the domain.
var selfPath string

func init(cur realm) {
	selfPath = cur.PkgPath()
}

func base() string {
	return strings.TrimPrefix(selfPath, "gno.land")
}

func link(route string) string { return base() + ":" + route }

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
