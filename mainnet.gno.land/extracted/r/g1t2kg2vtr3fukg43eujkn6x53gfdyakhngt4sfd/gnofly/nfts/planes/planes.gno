package planes

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/grc721/royalty/v0"
	"gno.land/p/nt/grc721/v0"
)

// The read side of the collection, exported for other realms and for
// vm/qeval, as GRC721 tokens are on gno.land. Neither type has a mutator: a
// Token hands out tellers that act as the calling realm and go through the
// ledger's approval checks, Royalty only reads. There is no metadata
// extension: the traits are in the table, read with TokenMetadata(tid) and
// PlaneJSON(id), and the token URI, the image, is computed by TokenURI(tid).
//
//	planes.TokenMetadata("42")
//	planes.Token.RealmTeller(0, cur).TransferFrom(0, cur, from, to, "42")
var (
	Token     *grc721.Token    // name, symbol, owners, balances, approvals
	Royalties *royalty.Royalty // EIP-2981 royalty
)

// The rest of the state. Everything is unexported and nothing below is ever
// returned by reference: the ledgers and the trees are /p/ types with mutator
// methods, so handing one out would be handing out write access to the
// collection.
var (
	ledger        *grc721.PrivateLedger // the collection, write side: mint, burn
	teller        grc721.Teller         // acts as the caller of this realm: transfers and approvals
	royaltyLedger *royalty.Ledger       // royalty, write side

	mintCount int64  // planes minted so far, burned ones included; the ids left are in pool (draw.gno)
	price     int64  // ugnot, what a mint costs
	mintOpen  bool   // whether Mint is accepting calls
	mintCap   int64  // how many planes one wallet may mint, over its lifetime
	imageBase string // "https://gnofly.xyz/nft/collections/planes/", the image of plane 42 is at <base>042.png

	mints      bptree.BPTree // minter address -> int64, planes minted so far, for the cap
	tierMinted [4]int64      // planes minted so far per tier, in the order of tiers
	recent     [5]int64      // the last ids minted, newest first, 0 for none, for Render

	webPath string // "/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/nfts/planes", used to build links in Render
)

// The collection, and the settings at deploy.
const (
	supply      = int64(777)
	tokenName   = "gnofly planes"
	tokenSymbol = "PLANE"
	payDenom    = "ugnot" // the only coin planes are sold for

	defaultPrice     = int64(77000000) // 77 GNOT
	minPrice         = int64(1000000)
	maxPrice         = int64(10000000000)
	defaultMintCap   = int64(7)
	defaultImageBase = "https://gnofly.xyz/nft/collections/planes/"

	defaultRoyaltyBps = int64(500)  // 5% of a resale, to the treasury
	maxRoyaltyBps     = int64(1000) // the most SetRoyaltyBps accepts

	// Models are what the game client renders, tiers are what the table
	// says. Both are validated against these lists.
	models = "prop,biplane,stunt,jet,seaplane,twin,delta,glider,supergnome"
	pilots = "none,gnome"
	tiers  = "common,rare,epic,legendary"
)

// tierSupply is how many planes of each tier the table holds, in the order
// of tiers. The tests check it against the table.
var tierSupply = [4]int64{500, 200, 70, 7}

// tierIndex returns the position of tier in tiers, or -1.
func tierIndex(tier string) int {
	for i, t := range strings.Split(tiers, ",") {
		if t == tier {
			return i
		}
	}
	return -1
}

// init runs once, when the package is added to the chain. The realm has
// nothing to remember about its deployer: it has no role of its own.
func init(cur realm) {
	bootstrap(0, cur)
}

// bootstrap (re)creates the initial state: the token, its extensions and the
// settings. The tests call it to start from a clean slate. rlm is the live
// realm of the caller: grc721 records its package path as the home of the
// Token.
func bootstrap(_ int, rlm realm) {
	// A table of the wrong shape is refused before anything is written, so
	// that a bad hand edit fails at publish rather than at the first mint.
	if first, last := rowID(0), rowID(len(table)-1); first != 1 || last != supply {
		panic(errBadTable)
	}

	Token, ledger = grc721.NewToken(tokenName, tokenSymbol, 0, rlm)
	// Minted from the ledger: the frame-relative teller is confined to this
	// realm, which is where it is used.
	teller = ledger.CallerTeller()
	Royalties, royaltyLedger = royalty.NewRoyalty(ledger, maxRoyaltyBps)

	mintCount = 0
	resetPool(rlm.PkgPath())
	recent = [5]int64{}
	price = defaultPrice
	mintOpen = false
	mintCap = defaultMintCap
	imageBase = defaultImageBase
	mints = bptree.BPTree{}
	tierMinted = [4]int64{}
	webPath = webPathOf(rlm.PkgPath())

	// Under `gno test` the game realm has no treasury yet (see roles.gno):
	// the tests set one and call bootstrap again.
	if roles.Treasury().IsValid() {
		setRoyalty(defaultRoyaltyBps)
	}
}

// setRoyalty points the royalty of every plane at the treasury of the game
// realm, as it is now, at bps basis points.
func setRoyalty(bps int64) {
	if err := royaltyLedger.SetDefaultRoyalty(roles.Treasury(), bps); err != nil {
		panic(err)
	}
}

// SetMintOpen opens or closes the mint. Admin only. The mint starts closed.
func SetMintOpen(cur realm, open bool) {
	assertAdmin(0, cur)
	mintOpen = open
	chain.Emit("MintOpen", "open", boolString(open))
}

// SetPrice sets what a mint costs, from 1 to 10000 GNOT. Admin only. It
// applies to the next mint.
func SetPrice(cur realm, ugnot int64) {
	assertAdmin(0, cur)
	if ugnot < minPrice || ugnot > maxPrice {
		panic(errInvalidPrice)
	}
	price = ugnot
	chain.Emit("PriceSet", "price", itoa(ugnot))
}

// SetMintCap sets how many planes one wallet may mint over its lifetime, from
// 1 to 777. Admin only. A wallet already over a lowered cap keeps its planes
// and mints no more.
func SetMintCap(cur realm, n int64) {
	assertAdmin(0, cur)
	if n < 1 || n > supply {
		panic(errInvalidCap)
	}
	mintCap = n
	chain.Emit("MintCapSet", "cap", itoa(n))
}

// SetImageBase sets where the images and the metadata of the planes are
// served from: the image of plane 42 is <base>042.png and its token URI is
// <base>42.json. Admin only.
//
// It applies at once to every plane: the URLs are computed on read, nothing
// is stored per token.
func SetImageBase(cur realm, base string) {
	assertAdmin(0, cur)
	if !validBase(base) {
		panic(errInvalidBase)
	}
	imageBase = base
	chain.Emit("ImageBaseSet", "base", base)
}

// SetRoyaltyBps sets the royalty of a resale, from 0 to 1000 basis points,
// and points it at the treasury of the game realm as it is now. Admin only.
//
// The royalty is advisory, as EIP-2981 is: a marketplace reads RoyaltyInfo
// and pays it, the realm cannot enforce it on a transfer.
func SetRoyaltyBps(cur realm, bps int64) {
	assertAdmin(0, cur)
	if bps < 0 || bps > maxRoyaltyBps {
		panic(errInvalidRoyalty)
	}
	setRoyalty(bps)
}

// Minted returns how many planes were minted so far, burned ones included.
// Planes are drawn at random, so it says nothing of which ids. The
// settings (price, open, cap, image base, royalty) are read with
// CollectionJSON: every exported function costs storage at deploy, measured
// at about 650 bytes each, so there is no getter per setting.
func Minted() int64 {
	return mintCount
}

// webPathOf turns "gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/nfts/planes" into "/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/nfts/planes".
func webPathOf(pkgPath string) string {
	for i := 0; i < len(pkgPath); i++ {
		if pkgPath[i] == '/' {
			return pkgPath[i:]
		}
	}
	return ""
}

// imageURL returns where the image of plane id is: <image base><id>.png,
// the id on three digits, "042.png", as the image files are named. The token
// URI keeps the plain id, "42.json".
func imageURL(id int64) string {
	return imageBase + pad3(id) + ".png"
}

// pad3 writes an id of 1 to 777 on three digits: 7 -> "007", 42 -> "042".
func pad3(id int64) string {
	s := itoa(id)
	for len(s) < 3 {
		s = "0" + s
	}
	return s
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
