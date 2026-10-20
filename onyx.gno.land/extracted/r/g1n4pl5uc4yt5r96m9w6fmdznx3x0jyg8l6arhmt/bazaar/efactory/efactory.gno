// Package efactory registers edition collections. It does not share a book
// with bazaarv5, and it does not pay perk2.
package efactory

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	nativeDenom        = "ugnot"
	defaultLaunchFee   = int64(1_000_000_000)
	defaultProtocolBps = int64(200)
	maxProtocolBps     = int64(500)
	maxRoyaltyBps      = int64(1000)
	maxNameLen         = 64
	maxImageLen        = 200
	maxSymbolLen       = 11
	maxSlugLen         = 11
	minSlugLen         = 2
)

type collection struct {
	slug       string
	name       string
	symbol     string
	cover      string
	pkg        string
	creator    address
	minted     int64
	royaltyBps int64
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
	admin       address
	self        address
	protocolSink address
	launchFee   int64
	protocolBps int64
)

func Init(cur realm) {
	if inited {
		panic("efactory: already")
	}
	if !cur.Previous().IsUserCall() {
		panic("efactory: EOA only")
	}
	admin = cur.Previous().Address()
	protocolSink = admin
	self = cur.Address()
	bySlug = avl.Tree{}
	byPkg = avl.Tree{}
	reserved = avl.Tree{}
	launchFee = defaultLaunchFee
	protocolBps = defaultProtocolBps
	inited = true
	chain.Emit("EditionFactory", "admin", admin.String())
}

func SetLaunchFee(cur realm, fee int64) {
	requireAdmin(cur)
	if fee < 0 {
		panic("efactory: fee")
	}
	launchFee = fee
}

func SetProtocolBps(cur realm, bps int64) {
	requireAdmin(cur)
	if bps < 0 || bps > maxProtocolBps {
		panic("efactory: bps")
	}
	protocolBps = bps
}

func SetProtocolSink(cur realm, sink address) {
	requireAdmin(cur)
	if !sink.IsValid() || sink == self {
		panic("efactory: sink")
	}
	protocolSink = sink
}

func ProtocolBps() int64 {
	requireInit()
	return protocolBps
}

func LaunchFee() int64 {
	requireInit()
	return launchFee
}

func ProtocolSink() address {
	requireInit()
	return protocolSink
}

func Reserve(cur realm, slug string) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("efactory: EOA only")
	}
	slug = strings.ToLower(strings.TrimSpace(slug))
	if !validSlug(slug) {
		panic("efactory: slug")
	}
	if bySlug.Has(slug) || reserved.Has(slug) {
		panic("efactory: slug taken")
	}
	caller := cur.Previous().Address()
	paid := launchFee
	if caller == admin {
		paid = 0
	}
	takeSend(paid)
	reserved.Set(slug, &reservation{who: caller, paid: paid})
	chain.Emit("EditionReserve", "slug", slug, "paid", strconv.FormatInt(paid, 10))
}

func Register(cur realm, name, symbol, cover string, royaltyBps int64) {
	requireInit()
	prev := cur.Previous()
	if !prev.IsCode() {
		panic("efactory: collection realm")
	}
	creatorRlm := prev.Previous()
	if !creatorRlm.IsUserCall() {
		panic("efactory: EOA creator")
	}
	if royaltyBps < 0 || royaltyBps > maxRoyaltyBps {
		panic("efactory: royalty")
	}
	if !validName(name) || !validSymbol(symbol) || !validImage(cover) {
		panic("efactory: meta")
	}
	pkg := prev.PkgPath()
	slug := lastElem(pkg)
	res := reserved.Get(slug)
	if res == nil {
		panic("efactory: reserved")
	}
	hold := res.(*reservation)
	if creatorRlm.Address() != hold.who {
		panic("efactory: reserved")
	}
	reserved.Remove(slug)
	row := &collection{
		slug:       slug,
		name:       name,
		symbol:     symbol,
		cover:      cover,
		pkg:        pkg,
		creator:    creatorRlm.Address(),
		royaltyBps: royaltyBps,
	}
	byPkg.Set(pkg, row)
	bySlug.Set(slug, row)
	chain.Emit("EditionRegister", "slug", slug, "pkg", pkg)
}

func NoteMinted(cur realm, n int64) {
	requireInit()
	if n < 0 {
		panic("efactory: minted")
	}
	prev := cur.Previous()
	if !prev.IsCode() {
		panic("efactory: collection realm")
	}
	row := mustByPkg(prev.PkgPath())
	row.minted = n
	byPkg.Set(row.pkg, row)
	bySlug.Set(row.slug, row)
}

func ListEditions() string {
	requireInit()
	out := ""
	bySlug.Iterate("", "", func(_ string, value any) bool {
		c := value.(*collection)
		if out != "" {
			out += "\n"
		}
		out += c.slug + "|" + c.name + "|" + c.cover + "|" + c.pkg + "|" +
			strconv.FormatInt(c.minted, 10) + "|" + c.creator.String() + "|" +
			chain.PackageAddress(c.pkg).String() + "|" + strconv.FormatInt(c.royaltyBps, 10)
		return false
	})
	return out
}

func CollectionOf(slug string) string {
	requireInit()
	return mustBySlug(slug).pkg
}

func RoyaltyOf(slug string) int64 {
	requireInit()
	return mustBySlug(slug).royaltyBps
}

func Withdraw(cur realm) {
	requireAdmin(cur)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	avail := bk.GetCoins(self).AmountOf(nativeDenom) - reservedPaid()
	if avail <= 0 {
		panic("efactory: no funds")
	}
	bk.SendCoins(self, admin, chain.Coins{{Denom: nativeDenom, Amount: avail}})
}

func requireInit() {
	if !inited {
		panic("efactory: init")
	}
}

func requireAdmin(cur realm) {
	requireInit()
	if !cur.Previous().IsUserCall() || cur.Previous().Address() != admin {
		panic("efactory: admin")
	}
}

func takeSend(want int64) {
	sent := unsafe.OriginSend()
	if want == 0 {
		if len(sent) != 0 {
			panic("efactory: extra payment")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != nativeDenom || sent[0].Amount != want {
		panic("efactory: wrong payment")
	}
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
	v := bySlug.Get(strings.ToLower(strings.TrimSpace(slug)))
	if v == nil {
		panic("efactory: unknown")
	}
	return v.(*collection)
}

func mustByPkg(pkg string) *collection {
	v := byPkg.Get(pkg)
	if v == nil {
		panic("efactory: unknown")
	}
	return v.(*collection)
}

func lastElem(pkg string) string {
	i := strings.LastIndex(pkg, "/")
	if i < 0 || i+1 >= len(pkg) {
		panic("efactory: pkg")
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
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

func validSymbol(s string) bool {
	if len(s) < 1 || len(s) > maxSymbolLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}

func validName(name string) bool {
	if len(name) < 1 || len(name) > maxNameLen {
		return false
	}
	return !strings.ContainsAny(name, "\n\r|\"\\")
}

func validImage(u string) bool {
	if u == "" {
		return true
	}
	if len(u) > maxImageLen || strings.ContainsAny(u, " \t\n\r|<>\"'`") {
		return false
	}
	if strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") {
		return true
	}
	return strings.HasPrefix(u, "/samples/") && len(u) > len("/samples/")
}
