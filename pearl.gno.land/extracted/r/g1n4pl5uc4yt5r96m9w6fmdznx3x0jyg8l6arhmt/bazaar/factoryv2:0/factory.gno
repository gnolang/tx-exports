package factoryv2

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	pkgPath          = "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/factoryv2"
	nativeDenom      = "ugnot"
	defaultLaunchFee = int64(1_000_000_000) // 1000 GNOT
	maxNameLen       = 64
	maxImageLen      = 200
	maxSupplyBound   = 1_000_000
	maxRoyaltyBps    = 1000
	maxSymbolLen     = 11
	maxSlugLen       = 11
	minSlugLen       = 2
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

var (
	bySlug    avl.Tree
	byPkg     avl.Tree
	pending   avl.Tree
	inited    bool
	admin     address
	self      address
	launchFee int64
	seenBank  int64
)

func Init(cur realm) {
	if inited {
		panic("factory: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("factory: EOA only")
	}
	admin = cur.Previous().Address()
	self = cur.Address()
	bySlug = avl.Tree{}
	byPkg = avl.Tree{}
	pending = avl.Tree{}
	launchFee = defaultLaunchFee
	seenBank = bankUgnot()
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

func CreditLaunchFee(cur realm) {
	requireInit()
	prev := cur.Previous()
	if !prev.IsCode() {
		panic("factory: collection realm")
	}
	pkg := prev.PkgPath()
	if pending.Has(pkg) {
		panic("factory: already credited")
	}
	if byPkg.Has(pkg) {
		panic("factory: already registered")
	}
	now := bankUgnot()
	if now < seenBank {
		panic("factory: bank")
	}
	if now-seenBank != launchFee {
		panic("factory: launch fee")
	}
	seenBank = now
	pending.Set(pkg, true)
	chain.Emit("CreditLaunchFee", "pkg", pkg)
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
	if !pending.Has(pkg) {
		panic("factory: launch fee")
	}
	pending.Remove(pkg)
	register(pkg, creatorRlm.Address(), name, symbol, cover, maxSupply, mintPrice, royaltyBps)
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
	if ugnot <= 0 {
		panic("factory: no funds")
	}
	seenBank = 0
	bk.SendCoins(self, admin, chain.Coins{{Denom: nativeDenom, Amount: ugnot}})
	chain.Emit("Withdraw", "amount", strconv.FormatInt(ugnot, 10))
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

func bankUgnot() int64 {
	return banker.NewReadonlyBanker().GetCoins(Address()).AmountOf(nativeDenom)
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
