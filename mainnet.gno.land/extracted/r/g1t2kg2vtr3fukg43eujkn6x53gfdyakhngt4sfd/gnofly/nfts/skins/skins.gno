package skins

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/grc721/v0"
)

// design is one skin of the catalog: what it looks like and how it sells.
type design struct {
	id        string
	name      string
	model     string // a model the client draws (web/src/world/planes.ts)
	pilot     string // none or gnome
	body      string // colours, "#rrggbb"
	wing      string
	accent    string
	price     int64 // ugnot
	maxSupply int64 // how many tokens of it can ever be minted, 0 for no limit
	minted    int64 // tokens minted so far, burned ones included
	listed    bool  // an unlisted design cannot be bought, owners keep theirs
}

// The state. Nothing is exported by reference: the ledger and the trees are
// /p/ types with mutator methods. The token itself is not exported either:
// its tellers move tokens, and a skin never moves (soulbound, see doc.gno).
var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger

	designs bptree.BPTree // design id -> *design

	// Per token, as little as possible: the skins are bought for a few GNOT
	// and every byte is a deposit. The ledger keeps the owner; tokenSkin the
	// design, as a string; owned answers "does addr own design x" and lists
	// the designs of addr, keyed "<addr>/<design>", value the token id.
	tokenSkin bptree.BPTree // token id -> design id
	owned     bptree.BPTree // "<addr>/<design>" -> token id

	nextID int64 // the id of the next token, 1 first

	webPath string // "/r/.../gnofly/nfts/skins", for the links of Render
)

const (
	tokenName   = "gnofly skins"
	tokenSymbol = "SKIN"
	payDenom    = "ugnot"
	maxPrice    = int64(1000000000000)

	// uriBase is where the website serves the metadata of each design: a
	// token's URI is <uriBase><design>.json. It is computed on read, not
	// stored per token.
	uriBase = "https://gnofly.xyz/nft/skins/"

	classic = "classic" // the free look, never a token
)

func init(cur realm) {
	bootstrap(0, cur)
}

// bootstrap (re)creates the state and seeds the catalog. The tests call it to
// start over.
func bootstrap(_ int, rlm realm) {
	token, ledger = grc721.NewToken(tokenName, tokenSymbol, 0, rlm)
	designs = bptree.BPTree{}
	tokenSkin = bptree.BPTree{}
	owned = bptree.BPTree{}
	nextID = 1
	webPath = webPathOf(rlm.PkgPath())
	for _, line := range strings.Split(catalog, "\n") {
		f := strings.Split(line, "|")
		if len(f) != 8 {
			panic(errBadCatalog)
		}
		price, err := strconv.ParseInt(f[7], 10, 64)
		if err != nil {
			panic(errBadCatalog)
		}
		putDesign(f[0], f[1], f[2], f[3], f[4], f[5], f[6], price, 0)
	}
}

// getDesign returns the design registered under id, or nil.
func getDesign(id string) *design {
	v := designs.Get(id)
	if v == nil {
		return nil
	}
	return v.(*design)
}

// putDesign validates and stores a design. An existing one keeps its count
// and its listed flag; a new one starts listed.
func putDesign(id, name, model, pilot, body, wing, accent string, price, maxSupply int64) {
	if !validID(id) {
		panic(errInvalidID)
	}
	if id == classic {
		panic(errReservedID)
	}
	if !validName(name) {
		panic(errInvalidName)
	}
	if !validModel(model) {
		panic(errInvalidModel)
	}
	if pilot != "none" && pilot != "gnome" {
		panic(errInvalidPilot)
	}
	if !validColor(body) || !validColor(wing) || !validColor(accent) {
		panic(errInvalidColor)
	}
	if price < 1 || price > maxPrice {
		panic(errInvalidPrice)
	}
	if maxSupply < 0 {
		panic(errInvalidSupply)
	}
	d := &design{id: id, listed: true}
	if old := getDesign(id); old != nil {
		d.minted, d.listed = old.minted, old.listed
	}
	d.name, d.model, d.pilot = name, model, pilot
	d.body, d.wing, d.accent = body, wing, accent
	d.price, d.maxSupply = price, maxSupply
	designs.Set(id, d)
}

// SetSkin creates or updates a design. Admin only.
//
// id is [a-z0-9-]{1,32} and not "classic", name [A-Za-z0-9 '.!-]{1,40}, model
// [a-z0-9-]{1,16}, pilot none or gnome, colours "#rrggbb" in lowercase, price
// 1 to 1e12 ugnot, maxSupply 0 for unlimited. A max supply under what is
// already minted stops the sales, it takes nothing back. Owners keep their
// tokens whatever happens to the design; its look is read from here, so a
// change of colours repaints every copy.
func SetSkin(cur realm, id, name, model, pilot, body, wing, accent string, price, maxSupply int64) {
	assertAdmin(0, cur)
	putDesign(id, name, model, pilot, body, wing, accent, price, maxSupply)
	chain.Emit("SkinSet", "id", id, "price", itoa(price), "maxSupply", itoa(maxSupply))
}

// SetSkinListed puts a design on or off sale. Admin only.
func SetSkinListed(cur realm, id string, listed bool) {
	assertAdmin(0, cur)
	d := getDesign(id)
	if d == nil {
		panic(errUnknownSkin)
	}
	d.listed = listed
	chain.Emit("SkinListed", "id", id, "listed", boolString(listed))
}

// webPathOf turns "gno.land/r/..." into "/r/...".
func webPathOf(pkgPath string) string {
	for i := 0; i < len(pkgPath); i++ {
		if pkgPath[i] == '/' {
			return pkgPath[i:]
		}
	}
	return ""
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}

func boolString(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
