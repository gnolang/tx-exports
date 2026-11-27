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
// description, trait or manifest field. Every list is paginated. The only
// images are core's checked data URIs (art, card, placeholder, or a media
// engine's checked file), never a remote address.
//
// sinopia4 (M-30): art, traits and media come from core only, so the
// gallery imports no engine, upload or asset realm and ships in the first
// package wave. Upload-only views (drop table, storage badge) are on the
// website, which reads the upload adapter.
package gallery

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/sys/users"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/types/v2"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/core"
	market "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/market/v1"
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
	cid = info.ID // "c/<cid>" (K-1) renders and links as the bare id
	out := "# " + plainText(info.Name) + " (" + plainText(info.Symbol) + ")\n\n"
	if info.Description != "" {
		out += plainText(info.Description) + "\n\n"
	}
	out += ufmt.Sprintf("- State: **%s**, %d/%d minted, royalty %d bps\n", info.State.String(), info.Minted, info.MaxSupply, info.RoyaltyBps)
	out += "- Creator: " + who(info.Creator) + "\n"
	out += "- Engine: [" + plainText(info.EngineID) + "](" + link("e/"+info.EngineID) + ")\n"
	if isMedia(info.EngineID) {
		out += "- Media collection: each token's file is checked by core (PNG, WebP, JPEG header and size, SVG allowlist, " +
			"sha256, IPFS CIDv1) before it is served; anything else shows the engine's card\n"
	}
	if len(info.TraitTypes) > 0 {
		out += "- Trait types: " + plainText(strings.Join(info.TraitTypes, ", ")) + "\n"
	}
	if info.Mode == types.ModeOpen {
		out += "- Open edition: no reveal; the seed of every token is public from the launch\n"
	}
	if info.Soulbound {
		out += "- Non-transferable: tokens stay with the address they were minted to (no transfers, no market); " +
			"an owner may burn theirs after the reveal\n"
	}
	if info.Badge != "" {
		out += "- Provenance: **" + info.Badge + "** — " + fairness(cid) + "\n"
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
	cid = info.ID
	owner, err := core.OwnerOf(cid, tid)
	if err != nil {
		return "# Token not found\n"
	}
	img, fileLine := tokenImage(info, cid, tid)
	out := "# " + plainText(info.Name) + " #" + tid + "\n\n"
	out += "![" + plainText(info.Name) + " #" + tid + "](" + sanitize.ImageURL(img) + ")\n\n"
	out += "- Owner: " + who(owner) + "\n"
	if first := core.FirstOwner(cid, tid); first != owner {
		out += "- First owner: " + who(first) + "\n"
	}
	out += fileLine
	if id, price, ok := market.ActiveListing(cid, tid); ok {
		out += ufmt.Sprintf("- Listed: %d ugnot (listing %s)\n", price, id)
	}
	out += "\n## Traits\n\n"
	for _, t := range core.TokenTraitList(cid, tid) {
		out += "- " + plainText(t.Type) + ": " + plainText(t.Value) + "\n"
	}
	out += "\n## How to verify\n\n"
	if info.State != types.StateFinal {
		out += "The collection is not revealed yet; every token shows the same placeholder.\n"
		return out
	}
	if info.Mode == types.ModeOpen {
		out += "1. Open edition: the salt is public, `Salt(\"" + cid + "\")` = sha256(\"art|open|v1|" + runtime.ChainID() +
			"|" + cid + "\").\n"
	} else {
		out += "1. Read `Provenance(\"" + cid + "\")` on core from another RPC and recompute the commitments and the salt.\n"
	}
	out += "2. Seed: `TokenSeed(\"" + cid + "\", \"" + tid + "\")` = sha256(\"" + "art|seed|v1|" + cid + "|" + tid + "|\" + salt).\n"
	if isMedia(info.EngineID) {
		out += "3. `TokenMediaInfo(\"" + cid + "\", \"" + tid + "\")` names the file core serves and its sha256; " +
			"`TokenURI` returns the checked bytes (or the IPFS address), `TokenCard` the card.\n\n"
	} else {
		out += "3. Render it yourself: `RenderWith(engine, params, seed)` must return this image.\n\n"
	}
	out += "Provenance badge **" + info.Badge + "**, on-chain check: " + strconv.FormatBool(core.VerifyProvenance(cid)) +
		"; " + fairness(cid) + "\n"
	return out
}

// --- media (engine/v2 KindMedia, read through core only: M-30, I-15) ---------

// tokenImage is the image the page embeds and the file line under it. An
// SVG engine's token is its art (TokenURI). A media engine's token is the
// checked file when core serves it as a data URI (TokenURI), otherwise the
// engine's checked SVG card (TokenCard): never a remote image (SA-M4); an
// IPFS address is escaped text. TokenMediaInfo is read first, so a 256 KiB
// file is encoded only when it is shown.
func tokenImage(info types.CollectionInfo, cid, tid string) (string, string) {
	if !isMedia(info.EngineID) {
		uri, _ := core.TokenURI(cid, tid)
		return uri, ""
	}
	showFile, line := mediaView(core.TokenMediaInfo(cid, tid))
	var uri string
	if showFile {
		uri, _ = core.TokenURI(cid, tid)
	} else {
		uri, _ = core.TokenCard(cid, tid)
	}
	return uri, line
}

// mediaView decides from core.TokenMediaInfo whether the page embeds the
// file itself (core serves it as a data URI: source "data") or the card,
// and writes the file line. Every value is escaped as text.
func mediaView(mi string) (showFile bool, line string) {
	mime, sha := jsonStr(mi, "mime"), jsonStr(mi, "sha256")
	switch jsonStr(mi, "source") {
	case "data":
		return true, "- File: " + plainText(mime) + ", " + jsonNum(mi, "bytes") + " bytes on chain, sha256 " +
			sanitize.InlineCode(sha) + "\n"
	case "ipfs":
		line = "- IPFS: " + plainText(jsonStr(mi, "uri")) + " (" + plainText(mime)
		if sha != "" {
			line += ", sha256 " + sanitize.InlineCode(sha)
		}
		return false, line + "); fetch it from any gateway and check the hash. The image here is the on-chain card.\n"
	case "card":
		return false, "- File: not served (the engine gave no file core accepts); showing the engine's card\n"
	}
	return false, "" // placeholder before Final
}

// isMedia: the engine serves files (engine/v2 KindMedia).
func isMedia(engineID string) bool {
	return core.EngineManifest(engineID).Kind == engine.KindMedia
}

// jsonStr reads a string field of a flat JSON object written by core's
// safe.JSONWriter (keys are ours; the values read here — source, mime,
// sha256, an ipfs:// CIDv1 — never contain an escaped quote).
func jsonStr(js, key string) string {
	k := `"` + key + `":"`
	i := strings.Index(js, k)
	if i < 0 {
		return ""
	}
	rest := js[i+len(k):]
	if j := strings.IndexByte(rest, '"'); j >= 0 {
		return rest[:j]
	}
	return ""
}

// jsonNum reads a non-negative integer field of the same JSON ("0" if absent).
func jsonNum(js, key string) string {
	k := `"` + key + `":`
	i := strings.Index(js, k)
	if i < 0 {
		return "0"
	}
	j := i + len(k)
	e := j
	for e < len(js) && js[e] >= '0' && js[e] <= '9' {
		e++
	}
	if e == j {
		return "0"
	}
	return js[j:e]
}

// fairness never calls a collection "verified" unless it is a fair launch
// (core.FairLaunch): a consistent record is not enough when one party could
// choose the map (SA-M2). An open edition (I-17) is never a fair launch.
//
// SEC-F2: the committed beacon's secret is derived by the Sinopia operator,
// so a fair badge on that path trusts the operator: beacon-only means the
// operator alone knew the map while minting, and 2/2 assumes the operator
// did not collude with the creator. Only a randomness provider (a public
// round nobody knows in advance) needs no such trust.
func fairness(cid string) string {
	if core.FairLaunch(cid) {
		if src := jsonStr(core.Provenance(cid), "beaconSource"); src != "" && src != types.BeaconCommitted {
			return "fair launch, verified on chain (public randomness: " + src + ")"
		}
		if core.Info(cid).Badge == core.BadgeBeaconOnly {
			return "verified on chain; fair only if you trust the Sinopia beacon operator (the creator did not reveal)"
		}
		return "fair launch, verified on chain (creator + Sinopia beacon; trusts the beacon operator not to collude with the creator)"
	}
	if core.Info(cid).Mode == types.ModeOpen {
		if !core.VerifyProvenance(cid) {
			return "NOT verified: the provenance record does not check out"
		}
		return "open edition: no reveal, the seed was public from the launch (not a fair launch)"
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
	out += "- Kind: " + plainText(m.Kind) + ", collections: " + jsonNum(core.Engine(id), "collections") + "\n"
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
