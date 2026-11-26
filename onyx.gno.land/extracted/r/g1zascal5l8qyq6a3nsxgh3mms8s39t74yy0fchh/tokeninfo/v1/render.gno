package tokeninfo

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/fqname/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const pageSize = 50

// tokenName is a variable only so tests can stand in for grc20reg.
var tokenName = func(token string) string {
	if t := grc20reg.Get(token); t != nil {
		return t.GetName()
	}
	return ""
}

// Render serves the registry home at "" (with ?page=N) and one profile at
// its token path, e.g. :gno.land/r/gnoswap/gns.GNS.
func Render(path string) string {
	if path == "" || strings.HasPrefix(path, "?") {
		return renderHome(path)
	}
	return renderToken(path)
}

func renderHome(query string) string {
	page := 1
	if v := strings.TrimPrefix(query, "?page="); v != query {
		if n, err := strconv.Atoi(v); err == nil && n > 1 {
			page = n
		}
	}
	out := "# Token profiles\n\n" +
		"Official links for GRC20 tokens on gno.land, written on-chain by the people behind each token: " +
		"the owner of the namespace the token lives in, the token realm itself, or editors they add. " +
		"Apps read them with `Get` or `Fields`, so a project fills them in once and every explorer shows the same verified data.\n\n" +
		"**" + strconv.Itoa(Count()) + "** tokens have a profile.\n\n"
	list := List((page-1)*pageSize, pageSize)
	if len(list) == 0 {
		out += "_No profiles on this page._\n\n"
	} else {
		out += "| Token | Name | Updated at block |\n| --- | --- | --- |\n"
		for _, token := range list {
			_, symbol := fqname.Parse(token)
			updated := "hidden"
			if p, ok := Get(token); ok {
				updated = strconv.FormatInt(p.UpdatedAt, 10)
			}
			out += "| [" + sanitize.TableCell(symbol) + "](" + selfPath + ":" + token + ") | " +
				sanitize.TableCell(tokenName(token)) + " | " + updated + " |\n"
		}
		out += "\n"
	}
	if page > 1 {
		out += "[Previous page](" + selfPath + ":?page=" + strconv.Itoa(page-1) + ") "
	}
	if page*pageSize < Count() {
		out += "[Next page](" + selfPath + ":?page=" + strconv.Itoa(page+1) + ")"
	}
	out += "\n\n## Add your token\n\n" +
		"Sign from the address that owns the token's namespace (or from the token realm):\n\n" +
		"```\ngnokey maketx call -pkgpath " + runtime.ChainDomain() + selfPath + " -func SetProfile \\\n" +
		"  -args gno.land/r/<you>/<token>.<SYMBOL> -args \"<description>\" -args https://<website> \\\n" +
		"  -args https://<logo.png> -args <x handle> -args <telegram> -args https://discord.gg/<invite> -args <github> \\\n" +
		"  -gas-fee 1000000ugnot -gas-wanted 20000000 -broadcast -chainid <chain> -remote <rpc> <key>\n```\n\n" +
		"Or use the profile editor on any token page of [DexVision](https://dexvision.pro).\n"
	return out
}

func renderToken(token string) string {
	pkg, ns, ok := parseToken(token)
	if !ok {
		return "# Not a token path\n\nUse a path like `gno.land/r/gnoswap/gns.GNS`.\n"
	}
	_, symbol := fqname.Parse(token)
	head := "# " + sanitize.InlineText(symbol)
	if name := tokenName(token); name != "" {
		head += ": " + sanitize.InlineText(name)
	}
	out := head + "\n\n" + sanitize.InlineCode(token) + " · [source](" + strings.TrimPrefix(pkg, runtime.ChainDomain()) + "$source)\n\n"

	if reason := HiddenReason(token); reason != "" {
		return out + "> This profile was hidden by the moderator: " + sanitize.InlineText(reason) + "\n\n[All profiles](" + selfPath + ")\n"
	}
	p, found := Get(token)
	if !found {
		return out + "No profile yet. The owner of the `" + sanitize.InlineText(ns) + "` namespace can add one with `SetProfile`.\n\n[All profiles](" + selfPath + ")\n"
	}
	if logo := sanitize.ImageURL(p.Logo); logo != "" {
		out += "![" + sanitize.InlineText(symbol) + " logo](" + logo + ")\n\n"
	}
	if p.Description != "" {
		out += sanitize.InlineText(p.Description) + "\n\n"
	}
	out += link("Website", p.Website, p.Website)
	if p.X != "" {
		out += link("X", "@"+p.X, "https://x.com/"+p.X)
	}
	if p.Telegram != "" {
		out += link("Telegram", "@"+p.Telegram, "https://t.me/"+p.Telegram)
	}
	out += link("Discord", p.Discord, p.Discord)
	if p.GitHub != "" {
		out += link("GitHub", p.GitHub, "https://github.com/"+p.GitHub)
	}
	out += "\nUpdated at block " + strconv.FormatInt(p.UpdatedAt, 10) + " by " + sanitize.InlineCode(p.UpdatedBy.String()) + " (" + roleText(p.Role) + ").\n"
	if eds := Editors(token); len(eds) > 0 {
		out += "\nEditors:"
		for _, e := range eds {
			out += " " + sanitize.InlineCode(e.String())
		}
		out += "\n"
	}
	return out + "\n[All profiles](" + selfPath + ")\n"
}

func link(label, text, url string) string {
	safe := sanitize.URL(url)
	if text == "" || safe == "" {
		return ""
	}
	return "- " + label + ": [" + sanitize.InlineText(text) + "](" + safe + ")\n"
}

func roleText(role string) string {
	switch role {
	case RoleOwner:
		return "namespace owner"
	case RoleRealm:
		return "token realm"
	case RoleEditor:
		return "editor"
	}
	return role
}
