package shown

// Mainnet factory template: genesis p/nt/grc721 so Adena indexes NewToken/Transfer,
// plus List/Buy escrow on this realm. Listed OwnerOf is the collection (wallet hides
// the token until Cancel or Buy). Do not import p/bazaar/grc721 here.

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/grc721/metadata/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/factory"
)

const (
	maxNameLen      = 64
	maxImageLen     = 200
	maxSupplyBound  = 1_000_000
	maxRoyaltyBps   = 1000
	nativeDenom     = "ugnot"
	publicOrigin    = "https://bazaar-gno.vercel.app"
	dropAddCap      = 20
	dropSlotHardCap = 10000
	minSlugLen      = 2
)

type item struct {
	id       int
	name     string
	image    string
	owner    address
	seller   address
	price    int64
	listed   bool
	rarity   string
	traits   string
	revealed bool
	slot     int
}

type dropSlot struct {
	name   string
	image  string
	rarity string
	traits string
}

var (
	items      avl.Tree
	dropSlots  avl.Tree
	token      *grc721.Token
	ledger     *grc721.PrivateLedger
	metaView   *metadata.Metadata
	metaLed    *metadata.Ledger
	tokenSeq   seqid.ID
	nextID     int
	minted     int
	loaded     int
	maxSupply  int
	mintPrice  int64
	royaltyBps int
	paused     bool
	inited     bool
	creator    address
	self       address
	colName    string
	colSymbol  string
	colCover   string
	slug       string
)

func Init(cur realm, name, symbol, cover string, maxSupplyN int, mintPriceUgnot int64, royalty int64) {
	if !cur.Previous().IsUserCall() {
		panic("col: EOA only")
	}
	if !cur.IsCurrent() {
		panic("col: spoofed realm")
	}
	if len(symbol) < 1 || len(symbol) > grc721.MaxSymbolLen {
		panic("col: symbol")
	}
	pathSlug := lastElem(cur.PkgPath())
	if !validPkgName(pathSlug) {
		panic("col: slug")
	}
	if maxSupplyN < 0 || maxSupplyN > maxSupplyBound {
		panic("col: maxSupply")
	}
	if mintPriceUgnot < 0 {
		panic("col: mintPrice")
	}
	if royalty < 0 || royalty > maxRoyaltyBps {
		panic("col: royalty")
	}
	if !validName(name) {
		panic("col: name")
	}
	if !validImage(cover) {
		panic("col: cover")
	}
	if inited {
		panic("col: already initialized")
	}
	slug = pathSlug
	reservedWho := factory.ReservedCreator(slug)
	takeLaunchFee(cur)
	tok, led := grc721.NewToken(name, symbol, tokenSeq.Next(), cur)
	token = tok
	ledger = led
	metaView, metaLed = metadata.NewMetadata(led)
	creator = cur.Previous().Address()
	self = cur.Address()
	colName = name
	colSymbol = symbol
	colCover = cover
	maxSupply = maxSupplyN
	mintPrice = mintPriceUgnot
	royaltyBps = int(royalty)
	items = avl.Tree{}
	dropSlots = avl.Tree{}
	loaded = 0
	inited = true
	if reservedWho == "" {
		factory.CreditLaunchFee(cross(cur))
	}
	factory.Register(cross(cur), name, symbol, cover, maxSupplyN, mintPriceUgnot, royalty)
	chain.Emit("Init", "creator", creator.String(), "slug", slug)
}

func Mint(cur realm, name, imageURL string) int {
	caller := requireUser(cur)
	if caller != creator {
		panic("col: not creator")
	}
	id := mintTo(cur, caller, name, imageURL)
	writeTokenMeta(id)
	chain.Emit("Mint", "id", strconv.Itoa(id), "owner", caller.String())
	return id
}

func PublicMint(cur realm) int {
	caller := requireUser(cur)
	takeExact(mintPrice)
	name := colName + " #" + strconv.Itoa(minted+1)
	image := publicImage()
	var slot *dropSlot
	slotIndex := -1
	if loaded > 0 {
		if minted >= loaded {
			panic("col: no slot")
		}
		v := dropSlots.Get(slotKey(minted))
		if v == nil {
			panic("col: no slot")
		}
		slot = v.(*dropSlot)
		name = slot.name
		image = slot.image
		slotIndex = minted
	}
	id := mintTo(cur, caller, name, image)
	if slot != nil {
		applySlot(id, slot, slotIndex)
	}
	writeTokenMeta(id)
	if mintPrice > 0 {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(self, creator, chain.Coins{{Denom: nativeDenom, Amount: mintPrice}})
	}
	chain.Emit("PublicMint", "id", strconv.Itoa(id), "n", strconv.Itoa(minted))
	return id
}

func AddDropItems(cur realm, blob string) {
	caller := requireUser(cur)
	if caller != creator {
		panic("col: not creator")
	}
	lines := splitDropLines(blob)
	if len(lines) < 1 || len(lines) > dropAddCap {
		panic("col: slots")
	}
	if loaded+len(lines) > slotCap() {
		panic("col: slots")
	}
	for _, line := range lines {
		name, image, rarity, traits := parseDropLine(line)
		if !validName(name) {
			panic("col: name")
		}
		if !validImage(image) {
			panic("col: image")
		}
		if !validRarity(rarity) {
			panic("col: rarity")
		}
		if !validTraits(traits) {
			panic("col: traits")
		}
		dropSlots.Set(slotKey(loaded), &dropSlot{name: name, image: image, rarity: rarity, traits: traits})
		loaded++
	}
	chain.Emit("AddDropItems", "slug", slug, "loaded", strconv.Itoa(loaded))
}

func ListDropSlots() string {
	requireInit()
	out := ""
	for i := 0; i < loaded; i++ {
		v := dropSlots.Get(slotKey(i))
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

func LoadedOf() int {
	requireInit()
	return loaded
}

func PauseMint(cur realm) {
	caller := requireUser(cur)
	if caller != creator {
		panic("col: not creator")
	}
	paused = true
	chain.Emit("PauseMint", "slug", slug)
}

func ResumeMint(cur realm) {
	caller := requireUser(cur)
	if caller != creator {
		panic("col: not creator")
	}
	paused = false
	chain.Emit("ResumeMint", "slug", slug)
}

// Adena IIFE: owner, err := OwnerOf("1"); owner.String() == wallet
func OwnerOf(tid string) (address, error) {
	requireInit()
	id, err := strconv.Atoi(tid)
	if err != nil || id < 1 {
		return address(""), errors.New("col: tid")
	}
	v := items.Get(itemKey(id))
	if v == nil {
		return address(""), errors.New("col: unknown item")
	}
	return v.(*item).owner, nil
}

func GrcName() string {
	requireInit()
	return token.GetName()
}

func GrcSymbol() string {
	requireInit()
	return token.GetSymbol()
}

func GrcBalanceOf(addr string) int64 {
	requireInit()
	who := address(addr)
	if !who.IsValid() {
		return 0
	}
	n, err := token.BalanceOf(who)
	if err != nil {
		return 0
	}
	return n
}

func GrcOwnerOf(id int) string {
	requireInit()
	owner, err := token.OwnerOf(itemTid(id))
	if err != nil {
		panic("col: owner")
	}
	return owner.String()
}

func Name() string {
	return GrcName()
}

func Symbol() string {
	return GrcSymbol()
}

func BalanceOf(addr string) int64 {
	return GrcBalanceOf(addr)
}

func TokenURI(tid string) string {
	id := parseTid(tid)
	mustItem(id)
	if metaView != nil {
		u, err := metaView.TokenURI(itemTid(id))
		if err == nil && u != "" {
			return u
		}
	}
	return tokenJSON(mustItem(id))
}

func guardUnlisted(id int) {
	if mustItem(id).listed {
		panic("col: listed")
	}
}

func Approve(cur realm, to, tid string) {
	caller := requireUser(cur)
	id := parseTid(tid)
	guardUnlisted(id)
	who := address(to)
	if to != "" && !who.IsValid() {
		panic("col: addr")
	}
	if err := ledger.Approve(caller, who, itemTid(id)); err != nil {
		panic("col: approve")
	}
}

func SetApprovalForAll(cur realm, operator string, approved bool) {
	caller := requireUser(cur)
	op := address(operator)
	if !op.IsValid() {
		panic("col: addr")
	}
	if err := ledger.SetApprovalForAll(caller, op, approved); err != nil {
		panic("col: approve")
	}
}

func TransferFrom(cur realm, from, to, tid string) {
	caller := requireUser(cur)
	id := parseTid(tid)
	guardUnlisted(id)
	src := address(from)
	dst := address(to)
	if !src.IsValid() || !dst.IsValid() {
		panic("col: addr")
	}
	if err := ledger.TransferFrom(caller, src, dst, itemTid(id)); err != nil {
		panic("col: transfer")
	}
	it := mustItem(id)
	it.owner = dst
	items.Set(itemKey(id), it)
}

func GetApproved(id int) string {
	requireInit()
	who, err := token.GetApproved(itemTid(id))
	if err != nil {
		return ""
	}
	return who.String()
}

func IsApprovedForAll(owner, operator string) bool {
	requireInit()
	a := address(owner)
	b := address(operator)
	if !a.IsValid() || !b.IsValid() {
		return false
	}
	return token.IsApprovedForAll(a, b)
}

func TotalSupply() int64 {
	requireInit()
	return token.TotalSupply()
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

func CollectionOf(_ int) string {
	requireInit()
	return slug
}

func ItemLine(id int) string {
	it := mustItem(id)
	return strconv.Itoa(it.id) + "|" + it.name + "|" + it.owner.String() + "|" + it.seller.String() + "|" + strconv.FormatInt(it.price, 10) + "|" + strconv.FormatBool(it.listed) + "|" + it.image + "|" + slug + "|" + it.rarity + "|" + it.traits + "|" + strconv.FormatBool(it.revealed) + "|" + strconv.Itoa(it.slot)
}

func ListOpen() string {
	requireInit()
	out := ""
	n := 0
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if !it.listed {
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

func TokensOf(owner string) string {
	requireInit()
	who := address(owner)
	if !who.IsValid() {
		return ""
	}
	out := ""
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if it.owner != who {
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

func TokenOfOwnerByIndex(owner string, index int64) string {
	requireInit()
	who := address(owner)
	if !who.IsValid() {
		panic("col: addr")
	}
	if index < 0 {
		panic("col: index")
	}
	var n int64
	found := ""
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if it.owner != who {
			return false
		}
		if n == index {
			found = strconv.Itoa(it.id)
			return true
		}
		n++
		return false
	})
	if found == "" {
		panic("col: index")
	}
	return found
}

func TokenByIndex(index int64) string {
	requireInit()
	if index < 0 {
		panic("col: index")
	}
	var n int64
	found := ""
	items.Iterate("", "", func(_ string, value any) bool {
		if n == index {
			found = strconv.Itoa(value.(*item).id)
			return true
		}
		n++
		return false
	})
	if found == "" {
		panic("col: index")
	}
	return found
}

func Creator() string {
	requireInit()
	return creator.String()
}

func MintPrice() int64 {
	requireInit()
	return mintPrice
}

func MaxSupply() int {
	requireInit()
	return maxSupply
}

func Minted() int {
	requireInit()
	return minted
}

func RoyaltyBps() int {
	requireInit()
	return royaltyBps
}

func SetRoyalty(cur realm, bps int) {
	caller := requireUser(cur)
	if caller != creator {
		panic("col: not creator")
	}
	if minted != 0 {
		panic("col: minted")
	}
	if bps < 0 || bps > maxRoyaltyBps {
		panic("col: royalty")
	}
	royaltyBps = bps
	factory.NoteRoyalty(cross(cur), bps)
	chain.Emit("SetRoyalty", "slug", slug, "bps", strconv.Itoa(bps))
}

func RarityOf(id int) string {
	return mustItem(id).rarity
}

func TraitsOf(id int) string {
	return mustItem(id).traits
}

func Render(_ string) string {
	if !inited {
		return "# Collection\n\nCall Init first.\n"
	}
	out := "# " + colName + " ($" + colSymbol + ")\n\n"
	out += "- minted: " + strconv.Itoa(minted) + "\n"
	out += "- mint price: " + strconv.FormatInt(mintPrice, 10) + " ugnot\n\n"
	open := ListOpen()
	if open == "" {
		out += "_No open listings._\n"
	} else {
		out += "```\n" + open + "\n```\n"
	}
	return out
}

func mintTo(cur realm, caller address, name, imageURL string) int {
	requireInit()
	if !cur.IsCurrent() {
		panic("col: spoofed realm")
	}
	if paused {
		panic("col: paused")
	}
	if maxSupply > 0 && minted >= maxSupply {
		panic("col: sold out")
	}
	if !validName(name) {
		panic("col: name")
	}
	if !validImage(imageURL) {
		panic("col: image")
	}
	nextID++
	id := nextID
	it := &item{
		id:       id,
		name:     name,
		image:    imageURL,
		owner:    caller,
		rarity:   rarityOf(id),
		revealed: true,
		slot:     -1,
	}
	items.Set(itemKey(id), it)
	err := ledger.Mint(caller, itemTid(id))
	if err != nil {
		panic("col: mint")
	}
	minted++
	factory.NoteMinted(cross(cur), minted)
	return id
}

func takeLaunchFee(cur realm) {
	fee := factory.LaunchFee()
	who := factory.ReservedCreator(lastElem(cur.PkgPath()))
	if who != "" && who == cur.Previous().Address().String() {
		takeExact(0)
		return
	}
	takeExact(fee)
	if fee > 0 {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(cur.Address(), factory.Address(), chain.Coins{{Denom: nativeDenom, Amount: fee}})
	}
}

func takeExact(want int64) {
	sent := unsafe.OriginSend()
	if want == 0 {
		if len(sent) != 0 {
			panic("col: extra denoms")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != nativeDenom || sent[0].Amount != want {
		panic("col: wrong payment")
	}
}

func publicImage() string {
	img := "/samples/" + slug + "-0" + strconv.Itoa(minted+1) + ".png"
	if validImage(img) {
		return img
	}
	return colCover
}

func requireInit() {
	if !inited {
		panic("col: call Init first")
	}
}

func requireUser(cur realm) address {
	requireInit()
	if !cur.IsCurrent() {
		panic("col: spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("col: EOA only")
	}
	return cur.Previous().Address()
}

func itemTid(id int) grc721.TokenID {
	return grc721.TokenID(strconv.Itoa(id))
}

func parseTid(tid string) int {
	id, err := strconv.Atoi(tid)
	if err != nil || id < 1 {
		panic("col: tid")
	}
	return id
}

func mustItem(id int) *item {
	v := items.Get(itemKey(id))
	if v == nil {
		panic("col: unknown item")
	}
	return v.(*item)
}

func itemKey(id int) string {
	return strconv.Itoa(id)
}

func lastElem(pkg string) string {
	i := strings.LastIndex(pkg, "/")
	if i < 0 || i+1 >= len(pkg) {
		panic("col: pkg")
	}
	return pkg[i+1:]
}

func slotKey(i int) string {
	return strconv.Itoa(i)
}

func slotCap() int {
	if maxSupply > 0 {
		return maxSupply
	}
	return dropSlotHardCap
}

func applySlot(id int, s *dropSlot, slotIndex int) {
	it := mustItem(id)
	it.name = s.name
	it.image = s.image
	if s.rarity != "" {
		it.rarity = s.rarity
	}
	it.traits = s.traits
	it.revealed = true
	it.slot = slotIndex
	items.Set(itemKey(id), it)
}

func writeTokenMeta(id int) {
	it := mustItem(id)
	uri := tokenJSON(it)
	if metaLed == nil {
		return
	}
	if err := metaLed.SetTokenURI(itemTid(id), uri); err != nil {
		panic("col: tokenURI")
	}
	if err := metaLed.SetTokenMetadata(itemTid(id), metadata.Data{
		Name:        it.name,
		Description: colName + " #" + strconv.Itoa(id),
		Image:       absImage(it.image),
		Attributes:  traitAttrs(it),
	}); err != nil {
		panic("col: metadata")
	}
}

func tokenJSON(it *item) string {
	attrs := ""
	for _, tr := range traitAttrs(it) {
		if attrs != "" {
			attrs += ","
		}
		attrs += `{"trait_type":` + jsonStr(tr.TraitType) + `,"value":` + jsonStr(tr.Value) + `}`
	}
	body := `{"name":` + jsonStr(it.name) + `,"description":` + jsonStr(colName+" #"+strconv.Itoa(it.id)) + `,"image":` + jsonStr(absImage(it.image)) + `,"attributes":[` + attrs + `]}`
	return "data:application/json;charset=utf-8," + pctURI(body)
}

func traitAttrs(it *item) []metadata.Trait {
	out := []metadata.Trait{}
	if it.rarity != "" {
		out = append(out, metadata.Trait{TraitType: "Rarity", Value: it.rarity})
	}
	for _, part := range strings.Split(it.traits, ";") {
		part = strings.TrimSpace(part)
		colon := strings.Index(part, ":")
		if colon <= 0 || colon >= len(part)-1 {
			continue
		}
		key := strings.TrimSpace(part[:colon])
		val := strings.TrimSpace(part[colon+1:])
		if key == "" || val == "" {
			continue
		}
		out = append(out, metadata.Trait{TraitType: key, Value: val})
	}
	return out
}

func absImage(u string) string {
	if u == "" {
		return u
	}
	if strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") || strings.HasPrefix(u, "ipfs://") {
		return u
	}
	if strings.HasPrefix(u, "/") {
		return publicOrigin + u
	}
	return u
}

func jsonStr(s string) string {
	out := `"`
	for _, r := range s {
		switch r {
		case '"':
			out += `\"`
		case '\\':
			out += `\\`
		case '\n':
			out += `\n`
		case '\r':
			out += `\r`
		case '\t':
			out += `\t`
		default:
			if r < 0x20 {
				out += `\u00`
				hex := "0123456789abcdef"
				out += string([]byte{hex[r>>4], hex[r&15]})
			} else {
				out += string(r)
			}
		}
	}
	return out + `"`
}

func pctURI(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
			out += string(c)
			continue
		}
		hex := "0123456789ABCDEF"
		out += "%"
		out += string([]byte{hex[c>>4], hex[c&15]})
	}
	return out
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

func validPkgName(s string) bool {
	if len(s) < minSlugLen || len(s) > grc721.MaxSymbolLen {
		return false
	}
	if s[0] < 'a' || s[0] > 'z' {
		return false
	}
	return asciiSet(s, "abcdefghijklmnopqrstuvwxyz0123456789")
}

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

func validName(name string) bool {
	if len(name) < 1 || len(name) > maxNameLen {
		return false
	}
	if strings.ContainsAny(name, "\n\r|\t\"\\") {
		return false
	}
	for _, r := range name {
		if r < 0x20 {
			return false
		}
	}
	return true
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
