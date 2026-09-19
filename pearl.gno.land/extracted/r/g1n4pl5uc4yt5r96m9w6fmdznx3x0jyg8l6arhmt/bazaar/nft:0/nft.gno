package nft

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	maxNameLen  = 64
	maxImageLen = 200
)

type item struct {
	id         int
	name       string
	image      string
	owner      address
	seller     address
	price      int64
	listed     bool
	collection string
	rarity     string
}

type collection struct {
	slug      string
	name      string
	cover     string
	count     int
	creator   address
	maxSupply int
	mintPrice int64
	minted    int
}

type act struct {
	kind  string
	id    int
	slug  string
	actor string
	name  string
	price int64
}

var (
	items       avl.Tree
	collections avl.Tree
	acts        avl.Tree
	actSeq      seqid.ID
	nextID      int
	inited      bool
	seeded      bool
	admin       address
	self        address
	fees        int64
)

func Init(cur realm) {
	if inited {
		panic("nft: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("nft: EOA only")
	}
	admin = cur.Previous().Address()
	self = cur.Address()
	items = avl.Tree{}
	collections = avl.Tree{}
	collections.Set("bazaar", &collection{slug: "bazaar", name: "Bazaar"})
	inited = true
	chain.Emit("Init", "admin", admin.String())
}

func CreateCollection(cur realm, slug, name, cover string) {
	putCollection(requireUser(cur), slug, name, cover, 0, 0)
	chain.Emit("CreateCollection", "slug", slug)
}

func CreateDrop(cur realm, slug, name, cover string, maxSupply int, mintPriceUgnot int64) {
	caller := requireUser(cur)
	if maxSupply < 1 || maxSupply > 3000 {
		panic("nft: maxSupply")
	}
	if mintPriceUgnot < 0 {
		panic("nft: mintPrice")
	}
	putCollection(caller, slug, name, cover, maxSupply, mintPriceUgnot)
	chain.Emit("CreateDrop", "slug", slug)
	record("drop", slug, caller.String(), name, 0, mintPriceUgnot)
}

func Mint(cur realm, name, imageURL string) int {
	return mintTo(requireUser(cur), "bazaar", name, imageURL)
}

func MintIn(cur realm, slug, name, imageURL string) int {
	return mintTo(requireUser(cur), slug, name, imageURL)
}

func Transfer(cur realm, to address, id int) {
	caller := requireUser(cur)
	if !to.IsValid() {
		panic("nft: invalid address")
	}
	if to == self {
		panic("nft: invalid address")
	}
	it := mustItem(id)
	if it.owner != caller {
		panic("nft: not owner")
	}
	it.owner = to
	items.Set(itemKey(id), it)
	chain.Emit("Transfer", "id", strconv.Itoa(id), "to", to.String())
}

func OwnerOf(id int) address {
	return mustItem(id).owner
}

func SellerOf(id int) address {
	return mustItem(id).seller
}

func PriceOf(id int) int64 {
	return mustItem(id).price
}

func NameOf(id int) string {
	return mustItem(id).name
}

func ImageOf(id int) string {
	return mustItem(id).image
}

func Listed(id int) bool {
	return mustItem(id).listed
}

func NextID() int {
	return nextID
}

func ItemLine(id int) string {
	it := mustItem(id)
	return strconv.Itoa(it.id) + "|" + it.name + "|" + it.owner.String() + "|" + it.seller.String() + "|" + strconv.FormatInt(it.price, 10) + "|" + strconv.FormatBool(it.listed) + "|" + it.image + "|" + it.collection + "|" + it.rarity
}

func RarityOf(id int) string {
	return mustItem(id).rarity
}

func CollectionOf(id int) string {
	return mustItem(id).collection
}

func ListCollections() string {
	out := ""
	collections.Iterate("", "", func(_ string, value any) bool {
		col := value.(*collection)
		if out != "" {
			out += "\n"
		}
		out += collectionLine(col)
		return false
	})
	return out
}

func DropLine(slug string) string {
	return collectionLine(mustCollection(slug))
}

func ListByCollection(slug string) string {
	_ = mustCollection(slug)
	out := ""
	n := 0
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if !it.listed || it.collection != slug {
			return false
		}
		if n >= 50 {
			return true
		}
		if out != "" {
			out += "\n"
		}
		out += ItemLine(it.id)
		n++
		return false
	})
	return out
}

func ListItemsByCollection(slug string) string {
	_ = mustCollection(slug)
	out := ""
	n := 0
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if it.collection != slug {
			return false
		}
		if n >= 50 {
			return true
		}
		if out != "" {
			out += "\n"
		}
		out += ItemLine(it.id)
		n++
		return false
	})
	return out
}

func Activity() string {
	return activityLines("")
}

func ActivityByCollection(slug string) string {
	return activityLines(slug)
}

func SalesTape(slug string) string {
	return saleTape(slug, 0, false)
}

func ItemTape(id int) string {
	return saleTape("", id, true)
}

func ListingRules() string {
	return "Path A: CreateDrop then PublicMint on this realm. Collectors pay exact ugnot; primary fee is 0 and GNOT goes to the creator.\n" +
		"Path B: If you already own an item here and it is not listed, List it at a GNOT price. Buyers Buy; protocol 50 bps.\n" +
		"Path C: Bazaar cannot pull an NFT from another realm. There is no external GRC721 listing. Launch here (Path A) or list an item you own here (Path B)."
}

func TokensOf(owner address) string {
	out := ""
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if it.owner != owner {
			return false
		}
		if out != "" {
			out += ","
		}
		out += strconv.Itoa(it.id)
		return false
	})
	return out
}

func requireInit() {
	if !inited {
		panic("nft: call Init first")
	}
}

func requireUser(cur realm) address {
	requireInit()
	if !cur.IsCurrent() {
		panic("nft: spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("nft: EOA only")
	}
	return cur.Previous().Address()
}

func putCollection(caller address, slug, name, cover string, maxSupply int, mintPrice int64) {
	if !validSlug(slug) {
		panic("nft: slug")
	}
	if !validName(name) {
		panic("nft: name")
	}
	if !validImage(cover) {
		panic("nft: cover")
	}
	if collections.Has(slug) {
		panic("nft: collection exists")
	}
	collections.Set(slug, &collection{
		slug:      slug,
		name:      name,
		cover:     cover,
		creator:   caller,
		maxSupply: maxSupply,
		mintPrice: mintPrice,
	})
}

func collectionLine(col *collection) string {
	return col.slug + "|" + col.name + "|" + col.cover + "|" + strconv.Itoa(col.count) + "|" + strconv.FormatInt(col.mintPrice, 10) + "|" + strconv.Itoa(col.maxSupply) + "|" + strconv.Itoa(col.minted) + "|" + col.creator.String()
}

func mintTo(caller address, slug, name, imageURL string) int {
	if !validName(name) {
		panic("nft: name")
	}
	if !validImage(imageURL) {
		panic("nft: image")
	}
	col := mustCollection(slug)
	nextID++
	id := nextID
	it := &item{
		id:         id,
		name:       name,
		image:      imageURL,
		owner:      caller,
		rarity:     rarityOf(id),
		collection: slug,
	}
	items.Set(itemKey(id), it)
	col.count++
	collections.Set(slug, col)
	chain.Emit("Mint", "id", strconv.Itoa(id), "owner", caller.String(), "collection", slug)
	record("mint", slug, caller.String(), name, id, 0)
	return id
}

func record(kind, slug, actor, name string, id int, price int64) {
	key := actSeq.Next().String()
	acts.Set(key, &act{
		kind:  kind,
		id:    id,
		slug:  slug,
		actor: actor,
		name:  name,
		price: price,
	})
	if acts.Size() > 50 {
		old, _ := acts.GetByIndex(0)
		acts.Remove(old)
	}
}

func activityLines(slug string) string {
	out := ""
	n := 0
	acts.ReverseIterate("", "", func(_ string, value any) bool {
		a := value.(*act)
		if slug != "" && a.slug != slug {
			return false
		}
		if n >= 50 {
			return true
		}
		if out != "" {
			out += "\n"
		}
		out += a.kind + "|" + strconv.Itoa(a.id) + "|" + a.slug + "|" + a.actor + "|" + strconv.FormatInt(a.price, 10) + "|" + a.name
		n++
		return false
	})
	return out
}

func saleTape(slug string, id int, byID bool) string {
	out := ""
	n := 0
	acts.ReverseIterate("", "", func(_ string, value any) bool {
		a := value.(*act)
		if !saleTapeKind(a) {
			return false
		}
		if slug != "" && a.slug != slug {
			return false
		}
		if byID && a.id != id {
			return false
		}
		if n >= 50 {
			return true
		}
		if out != "" {
			out += "\n"
		}
		out += a.kind + "|" + strconv.Itoa(a.id) + "|" + strconv.FormatInt(a.price, 10) + "|" + a.name
		n++
		return false
	})
	return out
}

func saleTapeKind(a *act) bool {
	if a.kind == "buy" {
		return true
	}
	return a.kind == "list" && a.price > 0
}

func mustItem(id int) *item {
	v := items.Get(itemKey(id))
	if v == nil {
		panic("nft: unknown item")
	}
	return v.(*item)
}

func mustCollection(slug string) *collection {
	v := collections.Get(slug)
	if v == nil {
		panic("nft: unknown collection")
	}
	return v.(*collection)
}

func itemKey(id int) string {
	return strconv.Itoa(id)
}

// rarityOf is deterministic from id (not RNG). 1 Common, 2 Uncommon, 3 Rare, 4 Epic, 0 Legendary.
func rarityOf(id int) string {
	r := id % 10
	if r == 0 {
		return "Legendary"
	}
	if r == 1 {
		return "Common"
	}
	if r == 2 {
		return "Uncommon"
	}
	if r == 3 {
		return "Rare"
	}
	if r == 4 {
		return "Epic"
	}
	if r <= 7 {
		return "Uncommon"
	}
	return "Common"
}

func setRarity(id int, rarity string) {
	it := mustItem(id)
	it.rarity = rarity
	items.Set(itemKey(id), it)
}

func validName(name string) bool {
	if len(name) < 1 || len(name) > maxNameLen {
		return false
	}
	return !strings.ContainsAny(name, "\n\r|")
}

func validSlug(s string) bool {
	if len(s) < 2 || len(s) > 16 {
		return false
	}
	return asciiSet(s, "abcdefghijklmnopqrstuvwxyz0123456789-")
}

func validImage(u string) bool {
	if u == "" {
		return true
	}
	if len(u) > maxImageLen {
		return false
	}
	if strings.ContainsAny(u, " \t\n\r|<>\"'`") {
		return false
	}
	if strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") {
		return true
	}
	// local demo files under web/public/samples/
	const prefix = "/samples/"
	if !strings.HasPrefix(u, prefix) {
		return false
	}
	rest := u[len(prefix):]
	if rest == "" {
		return false
	}
	return asciiSet(rest, "abcdefghijklmnopqrstuvwxyz0123456789._-")
}

func asciiSet(s, allowed string) bool {
	for i := 0; i < len(s); i++ {
		if !strings.ContainsRune(allowed, rune(s[i])) {
			return false
		}
	}
	return true
}
