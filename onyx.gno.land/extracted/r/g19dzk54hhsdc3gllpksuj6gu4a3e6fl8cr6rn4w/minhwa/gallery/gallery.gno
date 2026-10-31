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
// Every user-supplied string goes through p/nt/markdown/sanitize (RA M-9);
// every list is paginated.
package gallery

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/sys/users"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/types/v1"
	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/core"
	market "gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/market/v1"
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
			sanitize.InlineText(info.Name), link("c/"+info.ID), info.State.String(), info.Minted, info.MaxSupply)
	}
	return out
}

func collectionPage(cid string, page int64) string {
	info := core.Info(cid)
	out := "# " + sanitize.InlineText(info.Name) + " (" + sanitize.InlineText(info.Symbol) + ")\n\n"
	if info.Description != "" {
		out += sanitize.Block(info.Description) + "\n\n"
	}
	out += ufmt.Sprintf("- State: **%s**, %d/%d minted, royalty %d bps\n", info.State.String(), info.Minted, info.MaxSupply, info.RoyaltyBps)
	out += "- Creator: " + who(info.Creator) + "\n"
	out += "- Engine: [" + sanitize.InlineText(info.EngineID) + "](" + link("e/"+info.EngineID) + ")\n"
	if info.Badge != "" {
		out += "- Provenance: **" + info.Badge + "**, verified: " + strconv.FormatBool(core.VerifyProvenance(cid)) + "\n"
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
	uri, _ := core.TokenURI(cid, tid)
	out := "# " + sanitize.InlineText(info.Name) + " #" + tid + "\n\n"
	out += "![" + sanitize.InlineText(info.Name) + " #" + tid + "](" + sanitize.ImageURL(uri) + ")\n\n"
	out += "- Owner: " + who(owner) + "\n"
	if id, price, ok := market.ActiveListing(cid, tid); ok {
		out += ufmt.Sprintf("- Listed: %d ugnot (listing %s)\n", price, id)
	}
	out += "\n## Traits\n\n"
	for _, t := range core.TokenTraitList(cid, tid) {
		out += "- " + sanitize.InlineText(t.Type) + ": " + sanitize.InlineText(t.Value) + "\n"
	}
	out += "\n## How to verify\n\n"
	if info.State != types.StateFinal {
		out += "The collection is not revealed yet; every token shows the same placeholder.\n"
		return out
	}
	out += "1. Read `Provenance(\"" + cid + "\")` on core from another RPC and recompute the commitments and the salt.\n"
	out += "2. Seed: `TokenSeed(\"" + cid + "\", \"" + tid + "\")` = sha256(\"" + "art|seed|v1|" + cid + "|" + tid + "|\" + salt).\n"
	out += "3. Render it yourself: `RenderWith(engine, params, seed)` must return this image.\n\n"
	out += "Provenance badge **" + info.Badge + "**, on-chain check: " + strconv.FormatBool(core.VerifyProvenance(cid)) + "\n"
	return out
}

func enginePage(id string) string {
	m := core.EngineManifest(id)
	out := "# Engine " + sanitize.InlineText(m.Name) + " " + sanitize.InlineText(m.Version) + "\n\n"
	out += "- Realm: `" + sanitize.InlineText(id) + "`\n"
	out += "- Author: " + who(m.Author) + "\n"
	out += "- Status: **" + core.EngineStatus(id) + "**, sample fingerprint intact: " + strconv.FormatBool(core.VerifyEngine(id)) + "\n"
	out += "- License: " + sanitize.InlineText(m.License) + "\n"
	out += "- Traits: " + sanitize.InlineText(strings.Join(m.TraitTypes, ", ")) + "\n\n"
	if m.Description != "" {
		out += sanitize.Block(m.Description) + "\n"
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
