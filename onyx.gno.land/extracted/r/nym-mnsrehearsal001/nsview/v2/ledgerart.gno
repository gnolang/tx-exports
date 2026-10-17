package nsview

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/r/nym-mnsrehearsal001/nsdata/v2"
	"gno.land/r/nym-mnsrehearsal001/nsnft/v2"
	"gno.land/r/nym-mnsrehearsal001/nsskin/v2"
)

/*
THIS REALM DRAWS THE NAMES IN WALLETS.

A wallet asks the LEDGER, nsnft, for TokenURI and TokenMetadata, because
the collection id names it. nsnft can never change, so it does not draw:
it holds a Renderer handed to it by the one view realm it has approved,
and that realm is this one. Swapping the art is deploying a new nsview and
approving it on nsnft (a timelocked change), nothing more.

The renderer's methods run with THIS realm's authority (gno's
declaring-realm borrow), so drawing for the ledger can read anything and
write nothing of the ledger's. This realm holds no state worth writing
anyway; selfPath is set once, at init.
*/

// selfPath is this realm's path without the chain domain, for links to
// its own gnoweb pages. Set at init, because inside a renderer call the
// realm context belongs to whoever asked, not to this realm.
var selfPath string

type ledgerArt struct{}

// TokenImage is nsview's TokenURI: the full card, drawn now.
func (ledgerArt) TokenImage(tid string) string { return TokenURI(tid) }

func (ledgerArt) TokenMetadata(tid string) string { return tokenMetadata(tid) }

func init(cur realm) {
	selfPath = strings.TrimPrefix(cur.PkgPath(), runtime.ChainDomain())
	// Register only when this realm is the approved one. Registering
	// unconditionally would make deploying a NEW view generation fail
	// until its approval had cleared the timelock; this way it deploys,
	// and RegisterWithLedger finishes the job once it is approved.
	if nsnft.RendererPath() == cur.PkgPath() {
		nsnft.RegisterRenderer(cross(cur), ledgerArt{})
	}
}

// RegisterWithLedger hands the ledger this realm's renderer. Anyone may
// call it: it only ever registers THIS realm's own drawing, and the ledger
// refuses unless this realm is the one it has approved.
func RegisterWithLedger(cur realm) {
	// This realm has no banker and no way to return coins.
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("nsview: this call takes no payment")
	}
	nsnft.RegisterRenderer(cross(cur), ledgerArt{})
}

/*
tokenMetadata is the camelCase JSON Adena reads: name, description,
externalUrl, attributes of {traitType, value}. Everything in it is read
from the registry at the moment of asking, like the card, so a renewal or
a sale shows up without anybody writing anything.
*/
func tokenMetadata(tid string) string {
	label, dom := splitTokenID(tid)
	if label == "" || dom == "" || !nsdata.NameExists(label, dom) {
		return `{"name":"` + escapeJSON(tid) + `","description":"A name on the Meme Name Service.","attributes":[]}`
	}
	_, registered, expires, _, frozen, paid := nsdata.GetNameInfo(label, dom)
	status, _ := statusFields(expires, frozen)
	tier := "paid"
	if !paid {
		tier = "free tier"
	}
	skin := "none"
	if worn := nsskin.SkinOnName(label, dom); worn != "" && nsskin.ArtForName(label, dom) != "" {
		skin = worn
	}
	out := `{"name":"` + escapeJSON(label+"*"+dom) + `",` +
		`"description":"A name on the Meme Name Service. You own a word now. Renew it, or somebody else will.",`
	if selfPath != "" {
		out += `"externalUrl":"` + escapeJSON("https://"+runtime.ChainDomain()+selfPath+":"+label+"*"+dom) + `",`
	}
	out += `"attributes":[` +
		attr("Domain", "*"+dom) + `,` +
		attr("Length", strconv.Itoa(len(label))) + `,` +
		attr("Status", strings.ToLower(status)) + `,` +
		attr("Registered", time.Unix(registered, 0).UTC().Format("2006-01-02")) + `,` +
		attr("Expires", time.Unix(expires, 0).UTC().Format("2006-01-02")) + `,` +
		attr("Tier", tier) + `,` +
		attr("Skin", skin) + `]}`
	return out
}

func attr(k, v string) string {
	return `{"traitType":"` + escapeJSON(k) + `","value":"` + escapeJSON(v) + `"}`
}

func escapeJSON(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c < 0x20:
			const hex = "0123456789abcdef"
			b.WriteString(`\u00`)
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&0xf])
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}
