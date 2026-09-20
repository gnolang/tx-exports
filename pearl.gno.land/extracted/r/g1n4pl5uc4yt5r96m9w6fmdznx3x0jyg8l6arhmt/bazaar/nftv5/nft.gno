package nftv5

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
	maxBioLen   = 200
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
	traits     string
	revealed   bool
	slot       int
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
	paused    bool
	bio       string
	website   string
	twitter   string
	discord   string
	loaded    int
	allowN    int
	mintCap   int
	hidden     bool
	drop       bool
	royaltyBps int
	wlPrice    int64
	wlSupply   int
	wlEnabled  bool
}

type dropSlot struct {
	name   string
	image  string
	rarity string
	traits string
}

const dropAddCap = 20
const allowAddCap = 50
const dropSlotHardCap = 10000
const maxSupplyBound = 1_000_000
const maxRoyaltyBps = 1000
const defaultLaunchFee = int64(1_000_000_000) // 1000 GNOT

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
	offers      avl.Tree
	pools       avl.Tree
	lpPos       avl.Tree
	nftPos      avl.Tree
	dropSlots   avl.Tree
	allowlist   avl.Tree
	mintedBy    avl.Tree
	actSeq      seqid.ID
	nextID      int
	inited      bool
	seeded      bool
	admin       address
	self        address
	fees        int64
	launchFee   int64
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
	offers = avl.Tree{}
	pools = avl.Tree{}
	lpPos = avl.Tree{}
	nftPos = avl.Tree{}
	dropSlots = avl.Tree{}
	allowlist = avl.Tree{}
	mintedBy = avl.Tree{}
	collections.Set("bazaar", &collection{slug: "bazaar", name: "Bazaar"})
	launchFee = defaultLaunchFee
	inited = true
	chain.Emit("Init", "admin", admin.String())
}

func CreateCollection(cur realm, slug, name, cover string) {
	putCollection(requireUser(cur), slug, name, cover, 0, 0, false)
	chain.Emit("CreateCollection", "slug", slug)
}

func CreateDrop(cur realm, slug, name, cover string, maxSupply int, mintPriceUgnot int64) {
	caller := requireUser(cur)
	takeLaunchFee()
	createDropInner(caller, slug, name, cover, maxSupply, mintPriceUgnot)
}

func createDropInner(caller address, slug, name, cover string, maxSupply int, mintPriceUgnot int64) {
	if maxSupply < 0 || maxSupply > maxSupplyBound {
		panic("nft: maxSupply")
	}
	if mintPriceUgnot < 0 {
		panic("nft: mintPrice")
	}
	putCollection(caller, slug, name, cover, maxSupply, mintPriceUgnot, true)
	chain.Emit("CreateDrop", "slug", slug)
	record("drop", slug, caller.String(), name, 0, mintPriceUgnot)
}

func SetLaunchFee(cur realm, ugnot int64) {
	caller := requireUser(cur)
	if caller != admin {
		panic("nft: not admin")
	}
	if ugnot < 0 {
		panic("nft: launch fee")
	}
	launchFee = ugnot
	chain.Emit("SetLaunchFee", "ugnot", strconv.FormatInt(ugnot, 10))
}

func LaunchFee() int64 {
	return launchFee
}

func Admin() string {
	return admin.String()
}

func LaunchCollection(cur realm, slug, name, cover, bio, website, twitter, discord string, maxSupply int, mintPriceUgnot int64) {
	CreateDrop(cur, slug, name, cover, maxSupply, mintPriceUgnot)
	if bio != "" {
		SetBio(cur, slug, bio)
	}
	if website != "" || twitter != "" || discord != "" {
		SetSocials(cur, slug, website, twitter, discord)
	}
}

func SetDropSale(cur realm, slug string, royaltyBps int, wlPrice int64, wlSupply int) {
	_, col := requireCreator(cur, slug)
	if !col.drop {
		panic("nft: not a drop")
	}
	if col.minted > 0 {
		panic("nft: minted")
	}
	if royaltyBps < 0 || royaltyBps > maxRoyaltyBps {
		panic("nft: royalty")
	}
	if wlPrice < 0 {
		panic("nft: wlPrice")
	}
	if wlSupply < 0 {
		panic("nft: wlSupply")
	}
	if col.maxSupply > 0 && wlSupply > col.maxSupply {
		panic("nft: wlSupply")
	}
	col.royaltyBps = royaltyBps
	col.wlPrice = wlPrice
	col.wlSupply = wlSupply
	col.wlEnabled = wlSupply > 0
	collections.Set(slug, col)
	chain.Emit("SetDropSale", "slug", slug)
}

func StartPublic(cur realm, slug string) {
	_, col := requireCreator(cur, slug)
	if col.wlSupply <= 0 || col.minted >= col.wlSupply {
		panic("nft: public")
	}
	col.wlSupply = col.minted
	collections.Set(slug, col)
	chain.Emit("StartPublic", "slug", slug)
}

func DropSaleOf(slug string) string {
	col := mustCollection(slug)
	phase := "public"
	if col.wlSupply > 0 && col.minted < col.wlSupply {
		phase = "whitelist"
	}
	return strconv.Itoa(col.royaltyBps) + "|" + strconv.FormatInt(col.wlPrice, 10) + "|" + strconv.Itoa(col.wlSupply) + "|" + phase + "|" + strconv.FormatInt(col.mintPrice, 10)
}

func RoyaltyOf(slug string) int {
	return mustCollection(slug).royaltyBps
}

func AddDropItems(cur realm, slug, blob string) {
	_, col := requireCreator(cur, slug)
	if !col.drop {
		panic("nft: not a drop")
	}
	lines := splitDropLines(blob)
	if len(lines) < 1 || len(lines) > dropAddCap {
		panic("nft: slots")
	}
	if col.loaded+len(lines) > slotCap(col) {
		panic("nft: slots")
	}
	for _, line := range lines {
		name, image, rarity, traits := parseDropLine(line)
		if !validName(name) {
			panic("nft: name")
		}
		if !validImage(image) {
			panic("nft: image")
		}
		if !validRarity(rarity) {
			panic("nft: rarity")
		}
		if !validTraits(traits) {
			panic("nft: traits")
		}
		dropSlots.Set(slotKey(slug, col.loaded), &dropSlot{name: name, image: image, rarity: rarity, traits: traits})
		col.loaded++
	}
	collections.Set(slug, col)
	chain.Emit("AddDropItems", "slug", slug, "loaded", strconv.Itoa(col.loaded))
}

func ListDropSlots(slug string) string {
	col := mustCollection(slug)
	if col.hidden {
		return ""
	}
	out := ""
	for i := 0; i < col.loaded; i++ {
		v := dropSlots.Get(slotKey(slug, i))
		if v == nil {
			continue
		}
		s := v.(*dropSlot)
		if out != "" {
			out += "\n"
		}
		out += strconv.Itoa(i) + "|" + s.name + "|" + s.image + "|" + s.rarity + "|" + s.traits
	}
	return out
}

func LoadedOf(slug string) int {
	return mustCollection(slug).loaded
}

func HiddenOf(slug string) bool {
	return mustCollection(slug).hidden
}

func SetHidden(cur realm, slug string, hidden bool) {
	_, col := requireCreator(cur, slug)
	if hidden && col.loaded < 1 {
		panic("nft: no slots")
	}
	col.hidden = hidden
	collections.Set(slug, col)
	chain.Emit("SetHidden", "slug", slug)
}

func Revealed(id int) bool {
	return mustItem(id).revealed
}

func Reveal(cur realm, id int) {
	caller := requireUser(cur)
	it := mustItem(id)
	if caller != it.owner {
		panic("nft: not owner")
	}
	if it.revealed {
		panic("nft: revealed")
	}
	if it.slot < 0 {
		panic("nft: no slot")
	}
	v := dropSlots.Get(slotKey(it.collection, it.slot))
	if v == nil {
		panic("nft: no slot")
	}
	applySlot(id, v.(*dropSlot))
	chain.Emit("Reveal", "id", strconv.Itoa(id))
}

func slotKey(slug string, i int) string {
	return slug + ":" + strconv.Itoa(i)
}

func splitDropLines(blob string) []string {
	raw := strings.Split(blob, "\n")
	out := make([]string, 0, len(raw))
	for _, line := range raw {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		out = append(out, line)
	}
	return out
}

func parseDropLine(line string) (string, string, string, string) {
	parts := strings.Split(line, "|")
	name := ""
	image := ""
	rarity := ""
	traits := ""
	if len(parts) > 0 {
		name = strings.TrimSpace(parts[0])
	}
	if len(parts) > 1 {
		image = strings.TrimSpace(parts[1])
	}
	if len(parts) > 2 {
		rarity = strings.TrimSpace(parts[2])
	}
	if len(parts) > 3 {
		traits = strings.TrimSpace(parts[3])
	}
	return name, image, rarity, traits
}

func SetMintPrice(cur realm, slug string, priceUgnot int64) {
	if priceUgnot < 0 {
		panic("nft: mintPrice")
	}
	_, col := requireCreator(cur, slug)
	col.mintPrice = priceUgnot
	collections.Set(slug, col)
	chain.Emit("SetMintPrice", "slug", slug, "price", strconv.FormatInt(priceUgnot, 10))
}

func PauseMint(cur realm, slug string) {
	_, col := requireCreator(cur, slug)
	col.paused = true
	collections.Set(slug, col)
	chain.Emit("PauseMint", "slug", slug)
}

func ResumeMint(cur realm, slug string) {
	_, col := requireCreator(cur, slug)
	col.paused = false
	collections.Set(slug, col)
	chain.Emit("ResumeMint", "slug", slug)
}

func AddAllowlist(cur realm, slug, blob string) {
	_, col := requireCreator(cur, slug)
	if !col.drop {
		panic("nft: not a drop")
	}
	lines := splitDropLines(blob)
	if len(lines) < 1 || len(lines) > allowAddCap {
		panic("nft: allowlist")
	}
	for _, line := range lines {
		who := strings.ToLower(strings.TrimSpace(line))
		if !validG1(who) {
			panic("nft: address")
		}
		k := allowKey(slug, who)
		if allowlist.Get(k) != nil {
			continue
		}
		allowlist.Set(k, true)
		col.allowN++
	}
	collections.Set(slug, col)
	chain.Emit("AddAllowlist", "slug", slug, "n", strconv.Itoa(col.allowN))
}

func SetMintCap(cur realm, slug string, n int) {
	if n < 0 {
		panic("nft: mintCap")
	}
	_, col := requireCreator(cur, slug)
	col.mintCap = n
	collections.Set(slug, col)
	chain.Emit("SetMintCap", "slug", slug, "cap", strconv.Itoa(n))
}

func AllowCount(slug string) int {
	return mustCollection(slug).allowN
}

func MintCapOf(slug string) int {
	return mustCollection(slug).mintCap
}

func OnAllowlist(slug, addr string) bool {
	mustCollection(slug)
	return allowlist.Get(allowKey(slug, strings.ToLower(strings.TrimSpace(addr)))) != nil
}

func MintedBy(slug, addr string) int {
	mustCollection(slug)
	v := mintedBy.Get(allowKey(slug, strings.ToLower(strings.TrimSpace(addr))))
	if v == nil {
		return 0
	}
	return v.(int)
}

func allowKey(slug, addr string) string {
	return slug + ":" + addr
}

func validG1(s string) bool {
	if len(s) < 39 || len(s) > 64 {
		return false
	}
	if s[0] != 'g' || s[1] != '1' {
		return false
	}
	return asciiSet(s, "abcdefghijklmnopqrstuvwxyz0123456789")
}

func checkMintCap(slug string, caller address) {
	col := mustCollection(slug)
	if col.mintCap <= 0 {
		return
	}
	k := allowKey(slug, caller.String())
	have := 0
	if v := mintedBy.Get(k); v != nil {
		have = v.(int)
	}
	if have >= col.mintCap {
		panic("nft: mint cap")
	}
}

func noteMint(slug string, caller address) {
	k := allowKey(slug, caller.String())
	have := 0
	if v := mintedBy.Get(k); v != nil {
		have = v.(int)
	}
	mintedBy.Set(k, have+1)
}

func requireAllow(slug string, caller address) {
	col := mustCollection(slug)
	if col.wlEnabled && col.wlSupply > 0 && col.minted < col.wlSupply {
		if col.allowN <= 0 {
			panic("nft: allowlist")
		}
		if allowlist.Get(allowKey(slug, caller.String())) == nil {
			panic("nft: not allowed")
		}
		return
	}
	if col.wlEnabled {
		return
	}
	if col.allowN <= 0 {
		return
	}
	if allowlist.Get(allowKey(slug, caller.String())) == nil {
		panic("nft: not allowed")
	}
}

func SetBio(cur realm, slug, bio string) {
	if !validBio(bio) {
		panic("nft: bio")
	}
	_, col := requireCreator(cur, slug)
	col.bio = bio
	collections.Set(slug, col)
	chain.Emit("SetBio", "slug", slug)
}

func SetSocials(cur realm, slug, website, twitter, discord string) {
	if !validSocial(website) || !validSocial(twitter) || !validSocial(discord) {
		panic("nft: socials")
	}
	_, col := requireCreator(cur, slug)
	col.website = website
	col.twitter = twitter
	col.discord = discord
	collections.Set(slug, col)
	chain.Emit("SetSocials", "slug", slug)
}

func Socials(slug string) string {
	col := mustCollection(slug)
	return col.website + "|" + col.twitter + "|" + col.discord
}

func SetCover(cur realm, slug, cover string) {
	if !validImage(cover) {
		panic("nft: cover")
	}
	_, col := requireCreator(cur, slug)
	col.cover = cover
	collections.Set(slug, col)
	chain.Emit("SetCover", "slug", slug)
}

func Mint(cur realm, name, imageURL string) int {
	return mintTo(requireUser(cur), "bazaar", name, imageURL)
}

func MintIn(cur realm, slug, name, imageURL string) int {
	caller := requireUser(cur)
	col := mustCollection(slug)
	if col.creator != caller {
		panic("nft: not creator")
	}
	return mintTo(caller, slug, name, imageURL)
}

func Transfer(cur realm, to address, id int) {
	caller := requireUser(cur)
	if !to.IsValid() {
		panic("nft: invalid address")
	}
	if to == caller || to == self {
		panic("nft: invalid address")
	}
	it := mustItem(id)
	if it.listed {
		panic("nft: listed")
	}
	if it.owner != caller {
		panic("nft: not owner")
	}
	it.owner = to
	items.Set(itemKey(id), it)
	chain.Emit("Transfer", "id", strconv.Itoa(id), "to", to.String())
	record("transfer", it.collection, caller.String(), it.name, id, 0)
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
	return strconv.Itoa(it.id) + "|" + it.name + "|" + it.owner.String() + "|" + it.seller.String() + "|" + strconv.FormatInt(it.price, 10) + "|" + strconv.FormatBool(it.listed) + "|" + it.image + "|" + it.collection + "|" + it.rarity + "|" + it.traits + "|" + strconv.FormatBool(it.revealed) + "|" + strconv.Itoa(it.slot)
}

func TraitsOf(id int) string {
	return mustItem(id).traits
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

func requireCreator(cur realm, slug string) (address, *collection) {
	caller := requireUser(cur)
	col := mustCollection(slug)
	if col.creator != caller {
		panic("nft: not creator")
	}
	return caller, col
}

func putCollection(caller address, slug, name, cover string, maxSupply int, mintPrice int64, drop bool) {
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
		drop:      drop,
	})
}

func slotCap(col *collection) int {
	if col.maxSupply > 0 {
		return col.maxSupply
	}
	return dropSlotHardCap
}

func collectionLine(col *collection) string {
	return col.slug + "|" + col.name + "|" + col.cover + "|" + strconv.Itoa(col.count) + "|" + strconv.FormatInt(col.mintPrice, 10) + "|" + strconv.Itoa(col.maxSupply) + "|" + strconv.Itoa(col.minted) + "|" + col.creator.String() + "|" + strconv.FormatBool(col.paused) + "|" + strconv.FormatBool(col.drop) + "|" + col.bio
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
		revealed:   true,
		slot:       -1,
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

func hideMint(id, slotIndex int, cover string) {
	it := mustItem(id)
	it.name = "Unrevealed"
	it.image = cover
	it.rarity = ""
	it.traits = ""
	it.revealed = false
	it.slot = slotIndex
	items.Set(itemKey(id), it)
}

func applySlot(id int, s *dropSlot) {
	it := mustItem(id)
	it.name = s.name
	it.image = s.image
	if s.rarity != "" {
		it.rarity = s.rarity
	}
	it.traits = s.traits
	it.revealed = true
	items.Set(itemKey(id), it)
}

func validRarity(s string) bool {
	if s == "" {
		return true
	}
	return s == "Common" || s == "Uncommon" || s == "Rare" || s == "Epic" || s == "Legendary"
}

func validTraits(s string) bool {
	if s == "" {
		return true
	}
	if len(s) > 200 {
		return false
	}
	if strings.ContainsAny(s, "\n\r|") {
		return false
	}
	n := 0
	for _, part := range strings.Split(s, ";") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		colon := strings.Index(part, ":")
		if colon <= 0 || colon >= len(part)-1 {
			return false
		}
		key := strings.TrimSpace(part[:colon])
		val := strings.TrimSpace(part[colon+1:])
		if key == "" || val == "" {
			return false
		}
		if !asciiSet(key, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-") {
			return false
		}
		if !asciiSet(val, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-") {
			return false
		}
		n++
		if n > 8 {
			return false
		}
	}
	return n >= 1
}

func validName(name string) bool {
	if len(name) < 1 || len(name) > maxNameLen {
		return false
	}
	return !strings.ContainsAny(name, "\n\r|")
}

func validBio(bio string) bool {
	if len(bio) > maxBioLen {
		return false
	}
	return !strings.ContainsAny(bio, "\n\r|")
}

func validSocial(s string) bool {
	if s == "" {
		return true
	}
	if len(s) > 120 {
		return false
	}
	if strings.ContainsAny(s, " \t\n\r|<>\"'`") {
		return false
	}
	if strings.HasPrefix(s, "https://") || strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "@") {
		return true
	}
	return asciiSet(s, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
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
