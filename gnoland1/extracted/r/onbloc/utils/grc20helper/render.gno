package grc20helper

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/jeronimoalbi/mdform"
	"gno.land/p/moul/md"
	"gno.land/p/nt/avl/v0/pager"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/defi/grc20reg"
)

var (
	// chainDomain prefixes realm package paths; gnoweb URLs omit it.
	chainDomain = runtime.ChainDomain()

	// realmPath is this realm's own package path, captured at init time. It is
	// read here rather than inside Render because unsafe.CurrentRealm() follows
	// the calling realm, which is not necessarily this one.
	realmPath = unsafe.CurrentRealm().PkgPath()
)

// pageSize is how many registered tokens a listing page shows. The registry is
// an AVL tree keyed by "<realm path>.<symbol>", so listings are in
// lexicographic key order — the registry records no registration time or
// sequence, so "most recently registered" cannot be derived on-chain.
const pageSize = 20

// Render lists registered tokens when path is empty, and shows a single
// token's metadata plus a transfer form when path is a token key.
//
//	""                              -> token list (20 per page, ?page=N)
//	"gno.land/r/demo/foo20.FOO"     -> token detail + transfer form
func Render(path string) string {
	key, _ := splitQuery(path)
	if key == "" {
		return renderList(path)
	}

	return renderToken(key)
}

func renderList(path string) string {
	p := pager.NewPager(grc20reg.GetRegistry(), pageSize, false)
	page := p.MustGetPageByPath(path)

	out := md.H1("GRC20 Helper")
	out += "Flat GRC20 calls keyed by the " + md.Link("grc20reg", "/r/demo/defi/grc20reg") +
		" registry key.\n\n"

	if page.TotalItems == 0 {
		return out + md.Blockquote("No registered token.")
	}

	out += ufmt.Sprintf("%d registered token(s), sorted by key.\n\n", page.TotalItems)

	items := make([]string, 0, len(page.Items))
	for _, item := range page.Items {
		token, ok := item.Value.(*grc20.Token)
		if !ok {
			continue
		}
		items = append(items, ufmt.Sprintf(
			"%s (%s) — %s",
			md.Link(md.EscapeText(token.GetName()), tokenURL(item.Key)),
			md.EscapeText(token.GetSymbol()),
			md.InlineCode(item.Key),
		))
	}
	out += md.BulletList(items)

	if picker := page.Picker(path); picker != "" {
		out += "\n" + md.HorizontalRule() + picker + "\n"
	}
	return out
}

func renderToken(key string) string {
	token := grc20reg.Get(key)
	if token == nil {
		return md.H1("Unknown token") +
			md.Blockquote("No token registered under "+md.InlineCode(key)+".") +
			"\n" + md.Link("← Back to the token list", listURL()) + "\n"
	}

	out := md.H1(md.EscapeText(token.GetName()))
	out += md.BulletList([]string{
		"symbol: " + md.Bold(md.EscapeText(token.GetSymbol())),
		"decimals: " + ufmt.Sprintf("%d", token.GetDecimals()),
		"total supply: " + ufmt.Sprintf("%d", token.TotalSupply()),
		"registry key: " + md.InlineCode(key),
	})

	out += "\n" + md.H2("Transfer")
	out += md.Blockquote(
		"Submitting shows a `gnokey maketx call` command to copy and run — " +
			"gnoweb does not broadcast the transaction for you.")
	out += "\n" + transferForm(key)

	out += "\n" + md.Link("← Back to the token list", listURL()) + "\n"

	return out
}

// transferForm builds the inline form for Transfer.
//
// Form fields map to call arguments BY ORDER, not by name, and the leading
// `cur realm` parameter is never passed as an argument — so the fields must be
// exactly tokenKey, to, amount, in that order.
func transferForm(key string) string {
	form := mdform.New("exec", "Transfer")
	form.Input("tokenKey",
		"placeholder", "Registry key",
		"value", key,
		"readonly", "true",
		"required", "true",
	)
	form.Input("to",
		"placeholder", "g1... recipient address",
		"description", "Recipient address",
		"required", "true",
	)
	form.Input("amount",
		"type", mdform.InputTypeNumber,
		"placeholder", "Amount in base units",
		"description", "Amount, in base units (not adjusted for decimals)",
		"required", "true",
	)
	return form.String()
}

// listURL is the absolute gnoweb path of this realm's token list, and tokenURL
// the path of a single token's subpage.
//
// The path is taken from realmPath rather than from the calling realm: Render
// must always link back to this realm, whoever invoked it. Absolute paths
// matter because a relative ":key" link resolves against the browser's current
// URL, which already carries a token key once a subpage is open.
func listURL() string {
	return strings.TrimPrefix(realmPath, chainDomain)
}

func tokenURL(key string) string {
	return listURL() + ":" + key
}

// splitQuery splits a render path into its path and query string parts.
func splitQuery(path string) (string, string) {
	for i := 0; i < len(path); i++ {
		if path[i] == '?' {
			return path[:i], path[i+1:]
		}
	}
	return path, ""
}
