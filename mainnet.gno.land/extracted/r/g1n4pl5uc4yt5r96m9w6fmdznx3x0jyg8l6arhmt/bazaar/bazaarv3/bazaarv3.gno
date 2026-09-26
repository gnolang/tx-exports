package bazaarv3

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	pkgPath          = "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/bazaarv3"
	nativeDenom      = "ugnot"
	defaultLaunchFee = int64(1_000_000_000) // 1000 GNOT
	maxNameLen       = 64
	maxImageLen      = 200
	maxSupplyBound   = 1_000_000
	maxRoyaltyBps    = 1000
	maxSymbolLen     = 11
	maxSlugLen         = 11
	minSlugLen         = 2
	defaultProtocolBps = int64(200) // 2% Magic Eden
	maxProtocolBps     = int64(500)
)

type collection struct {
	slug       string
	name       string
	symbol     string
	cover      string
	pkg        string
	creator    address
	maxSupply  int
	mintPrice  int64
	minted     int
	royaltyBps int
}

type reservation struct {
	who  address
	paid int64
}

var (
	bySlug      avl.Tree
	byPkg       avl.Tree
	reserved    avl.Tree
	inited      bool
	admin         address
	self          address
	protocolSink  address
	launchFee        int64
	protocolBps      int64
	genesisPkg       string
	genesisSink      address
	genesisShareBps  int64
	holderDisc       avl.Tree
)

func Init(cur realm) {
	if inited {
		panic("factory: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("factory: EOA only")
	}
	admin = cur.Previous().Address()
	protocolSink = admin
	self = cur.Address()
	bySlug = avl.Tree{}
	byPkg = avl.Tree{}
	reserved = avl.Tree{}
	holderDisc = avl.Tree{}
	genesisPkg = ""
	genesisShareBps = 0
	var z address
	genesisSink = z
	launchFee = defaultLaunchFee
	protocolBps = defaultProtocolBps
	inited = true
	chain.Emit("Init", "admin", admin.String())
}

func Address() address {
	return chain.PackageAddress(pkgPath)
}

func LaunchFee() int64 {
	requireInit()
	return launchFee
}

func Admin() string {
	requireInit()
	return admin.String()
}

func SetLaunchFee(cur realm, ugnot int64) {
	requireAdmin(cur)
	if ugnot < 0 {
		panic("factory: launch fee")
	}
	launchFee = ugnot
	chain.Emit("SetLaunchFee", "ugnot", strconv.FormatInt(ugnot, 10))
}

func ProtocolBps() int64 {
	requireInit()
	if protocolBps <= 0 {
		return defaultProtocolBps
	}
	return protocolBps
}

func SetProtocolBps(cur realm, bps int64) {
	requireAdmin(cur)
	if bps < 0 || bps > maxProtocolBps {
		panic("factory: protocol bps")
	}
	protocolBps = bps
	chain.Emit("SetProtocolBps", "bps", strconv.FormatInt(bps, 10))
}

func ProtocolSink() address {
	requireInit()
	return protocolSink
}

func SetProtocolSink(cur realm, next address) {
	requireAdmin(cur)
	if !next.IsValid() {
		panic("factory: invalid address")
	}
	if next == protocolSink {
		panic("factory: already sink")
	}
	protocolSink = next
	chain.Emit("SetProtocolSink", "addr", next.String())
}

func GenesisPkg() string {
	requireInit()
	return genesisPkg
}

func GenesisSink() address {
	requireInit()
	return genesisSink
}

func GenesisShareBps() int64 {
	requireInit()
	if genesisPkg == "" {
		return 0
	}
	if genesisShareBps <= 0 {
		return 1100
	}
	return genesisShareBps
}

func HolderDiscount(owner string) int64 {
	requireInit()
	if genesisPkg == "" {
		return 0
	}
	v := holderDisc.Get(strings.ToLower(strings.TrimSpace(owner)))
	if v == nil {
		return 0
	}
	return v.(int64)
}

func AttachGenesis(cur realm) {
	requireInit()
	prev := cur.Previous()
	if !prev.IsCode() {
		panic("factory: genesis realm")
	}
	eoa := prev.Previous()
	if !eoa.IsUserCall() || eoa.Address() != admin {
		panic("factory: not admin")
	}
	pkg := prev.PkgPath()
	if pkg == "" {
		panic("factory: genesis pkg")
	}
	if genesisPkg != "" && genesisPkg != pkg {
		panic("factory: genesis set")
	}
	genesisPkg = pkg
	genesisSink = prev.Address()
	if genesisShareBps <= 0 {
		genesisShareBps = 1100
	}
	chain.Emit("AttachGenesis", "pkg", pkg)
}

func SetGenesis(cur realm, pkg string) {
	requireAdmin(cur)
	pkg = strings.TrimSpace(pkg)
	if pkg == "" || !strings.HasPrefix(pkg, "gno.land/r/") {
		panic("factory: genesis pkg")
	}
	genesisPkg = pkg
	genesisSink = chain.PackageAddress(pkg)
	if genesisShareBps <= 0 {
		genesisShareBps = 1100
	}
	chain.Emit("SetGenesis", "pkg", pkg)
}

func NoteHolderDiscount(cur realm, owner string, bps int64) {
	requireInit()
	prev := cur.Previous()
	if genesisPkg == "" || !prev.IsCode() || prev.PkgPath() != genesisPkg {
		panic("factory: not genesis")
	}
	if bps < 0 {
		panic("factory: discount")
	}
	who := strings.ToLower(strings.TrimSpace(owner))
	if who == "" {
		panic("factory: owner")
	}
	if bps == 0 {
		holderDisc.Remove(who)
		return
	}
	holderDisc.Set(who, bps)
}

func Register(cur realm, name, symbol, cover string, maxSupply int, mintPrice, royaltyBps int64) {
	requireInit()
	prev := cur.Previous()
	if !prev.IsCode() {
		panic("factory: collection realm")
	}
	creatorRlm := prev.Previous()
	if !creatorRlm.IsUserCall() {
		panic("factory: EOA creator")
	}
	pkg := prev.PkgPath()
	slug := lastElem(pkg)
	res := mustReserve(slug)
	if creatorRlm.Address() != res.who {
		panic("factory: reserved")
	}
	reserved.Remove(slug)
	register(pkg, creatorRlm.Address(), name, symbol, cover, maxSupply, mintPrice, royaltyBps)
}

func Reserve(cur realm, slug string) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("factory: EOA only")
	}
	slug = strings.ToLower(strings.TrimSpace(slug))
	if !validSlug(slug) {
		panic("factory: slug")
	}
	if bySlug.Has(slug) || reserved.Has(slug) {
		panic("factory: slug taken")
	}
	paid := launchFee
	takeFactorySend(paid)
	reserved.Set(slug, &reservation{who: cur.Previous().Address(), paid: paid})
	chain.Emit("Reserve", "slug", slug, "paid", strconv.FormatInt(paid, 10))
}

func CancelReserve(cur realm, slug string) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("factory: EOA only")
	}
	slug = strings.ToLower(strings.TrimSpace(slug))
	res := mustReserve(slug)
	if res.who != cur.Previous().Address() {
		panic("factory: not reserver")
	}
	if bySlug.Has(slug) {
		panic("factory: already registered")
	}
	reserved.Remove(slug)
	if res.paid > 0 {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(self, res.who, chain.Coins{{Denom: nativeDenom, Amount: res.paid}})
	}
	chain.Emit("CancelReserve", "slug", slug, "paid", strconv.FormatInt(res.paid, 10))
}

func ReservedCreator(slug string) string {
	requireInit()
	slug = strings.ToLower(strings.TrimSpace(slug))
	if !reserved.Has(slug) {
		return ""
	}
	return reserved.Get(slug).(*reservation).who.String()
}

func takeFactorySend(want int64) {
	sent := unsafe.OriginSend()
	if want == 0 {
		if len(sent) != 0 {
			panic("factory: extra denoms")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != nativeDenom || sent[0].Amount != want {
		panic("factory: wrong payment")
	}
}

func NoteMinted(cur realm, n int) {
	requireInit()
	if n < 0 {
		panic("factory: minted")
	}
	prev := cur.Previous()
	if !prev.IsCode() {
		panic("factory: collection realm")
	}
	c := mustByPkg(prev.PkgPath())
	c.minted = n
	byPkg.Set(c.pkg, c)
	bySlug.Set(c.slug, c)
}

func NoteRoyalty(cur realm, bps int) {
	requireInit()
	if bps < 0 || bps > maxRoyaltyBps {
		panic("factory: royalty")
	}
	prev := cur.Previous()
	if !prev.IsCode() {
		panic("factory: collection realm")
	}
	c := mustByPkg(prev.PkgPath())
	c.royaltyBps = bps
	byPkg.Set(c.pkg, c)
	bySlug.Set(c.slug, c)
}

func CollectionOf(slug string) string {
	requireInit()
	c := mustBySlug(slug)
	return c.pkg
}

func CollectionAddr(slug string) string {
	requireInit()
	c := mustBySlug(slug)
	return chain.PackageAddress(c.pkg).String()
}

func RoyaltyOf(slug string) int {
	requireInit()
	c := mustBySlug(slug)
	return c.royaltyBps
}

func ListCollections() string {
	requireInit()
	out := ""
	bySlug.Iterate("", "", func(_ string, value any) bool {
		c := value.(*collection)
		if out != "" {
			out += "\n"
		}
		out += c.slug + "|" + c.name + "|" + c.cover + "|" + c.pkg + "|" + strconv.FormatInt(c.mintPrice, 10) + "|" + strconv.Itoa(c.maxSupply) + "|" + strconv.Itoa(c.minted) + "|" + c.creator.String() + "|" + chain.PackageAddress(c.pkg).String() + "|" + strconv.Itoa(c.royaltyBps)
		return false
	})
	return out
}

func Withdraw(cur realm) {
	requireAdmin(cur)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	ugnot := bk.GetCoins(self).AmountOf(nativeDenom)
	locked := reservedPaid()
	avail := ugnot - locked
	if avail <= 0 {
		panic("factory: no funds")
	}
	bk.SendCoins(self, admin, chain.Coins{{Denom: nativeDenom, Amount: avail}})
	chain.Emit("Withdraw", "amount", strconv.FormatInt(avail, 10))
}

func TransferAdmin(cur realm, next address) {
	requireAdmin(cur)
	if !next.IsValid() {
		panic("factory: invalid address")
	}
	if next == admin {
		panic("factory: already admin")
	}
	admin = next
	chain.Emit("TransferAdmin", "addr", next.String())
}

func Render(_ string) string {
	if !inited {
		return "# Bazaar factory\n\nCall Init first.\n"
	}
	out := "# Bazaar factory\n\n"
	out += "- launch fee: " + strconv.FormatInt(launchFee, 10) + " ugnot\n"
	out += "- collections: " + strconv.Itoa(bySlug.Size()) + "\n\n"
	lines := ListCollections()
	if lines == "" {
		out += "_No collections._\n"
	} else {
		out += "```\n" + lines + "\n```\n"
	}
	return out
}

func register(pkg string, creator address, name, symbol, cover string, maxSupply int, mintPrice, royaltyBps int64) {
	if !strings.HasPrefix(pkg, "gno.land/r/") {
		panic("factory: pkg")
	}
	slug := lastElem(pkg)
	if !validSlug(slug) {
		panic("factory: slug")
	}
	if !validName(name) {
		panic("factory: name")
	}
	if !validSymbol(symbol) {
		panic("factory: symbol")
	}
	if !validImage(cover) {
		panic("factory: cover")
	}
	if maxSupply < 0 || maxSupply > maxSupplyBound {
		panic("factory: maxSupply")
	}
	if mintPrice < 0 {
		panic("factory: mintPrice")
	}
	if royaltyBps < 0 || royaltyBps > maxRoyaltyBps {
		panic("factory: royalty")
	}
	if bySlug.Has(slug) {
		panic("factory: slug taken")
	}
	if byPkg.Has(pkg) {
		panic("factory: pkg already registered")
	}
	c := &collection{
		slug:       slug,
		name:       name,
		symbol:     symbol,
		cover:      cover,
		pkg:        pkg,
		creator:    creator,
		maxSupply:  maxSupply,
		mintPrice:  mintPrice,
		royaltyBps: int(royaltyBps),
	}
	bySlug.Set(slug, c)
	byPkg.Set(pkg, c)
	chain.Emit("Register", "slug", slug, "pkg", pkg, "creator", creator.String())
}

func requireInit() {
	if !inited {
		panic("factory: call Init first")
	}
}

func requireAdmin(cur realm) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("factory: EOA only")
	}
	if cur.Previous().Address() != admin {
		panic("factory: not admin")
	}
}

func mustReserve(slug string) *reservation {
	v := reserved.Get(slug)
	if v == nil {
		panic("factory: not reserved")
	}
	return v.(*reservation)
}

func reservedPaid() int64 {
	var n int64
	reserved.Iterate("", "", func(_ string, value any) bool {
		n += value.(*reservation).paid
		return false
	})
	return n
}

func mustBySlug(slug string) *collection {
	v := bySlug.Get(slug)
	if v == nil {
		panic("factory: unknown collection")
	}
	return v.(*collection)
}

func mustByPkg(pkg string) *collection {
	v := byPkg.Get(pkg)
	if v == nil {
		panic("factory: unknown collection")
	}
	return v.(*collection)
}

func lastElem(pkg string) string {
	i := strings.LastIndex(pkg, "/")
	if i < 0 || i+1 >= len(pkg) {
		panic("factory: pkg")
	}
	return pkg[i+1:]
}

func validSlug(s string) bool {
	if len(s) < minSlugLen || len(s) > maxSlugLen {
		return false
	}
	if s[0] < 'a' || s[0] > 'z' {
		return false
	}
	return asciiSet(s, "abcdefghijklmnopqrstuvwxyz0123456789")
}

func validSymbol(s string) bool {
	if len(s) < 1 || len(s) > maxSymbolLen {
		return false
	}
	return asciiSet(s, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
}

func validName(name string) bool {
	if len(name) < 1 || len(name) > maxNameLen {
		return false
	}
	return !strings.ContainsAny(name, "\n\r|")
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
