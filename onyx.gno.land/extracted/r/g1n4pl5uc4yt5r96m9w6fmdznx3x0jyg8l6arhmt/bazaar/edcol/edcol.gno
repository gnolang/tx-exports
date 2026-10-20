// Package edcol is an edition collection. One id is one print run.
// List escrows an amount on this realm. Buy can take part of that amount.
// The book is efactory, not bazaarv5. Copies do not enter perk2.
package edcol

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"math"
	"strconv"
	"strings"

	"gno.land/p/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/fee/v1"
	"gno.land/p/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/grc1155/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/efactory"
)

const (
	nativeDenom = "ugnot"
	maxSupply   = int64(1_000_000_000)
	maxNameLen  = 64
	maxImageLen = 200
)

type edition struct {
	name      string
	image     string
	max       int64
	minted    int64
	mintPrice int64
}

type listing struct {
	amount int64
	unit   int64
}

var (
	inited   bool
	creator  address
	self     address
	name_    string
	symbol   string
	cover    string
	royalty  int64
	copies   int64
	ledger   *grc1155.Ledger
	editions avl.Tree
	listings avl.Tree
)

func Init(cur realm, name, symbol_, cover_ string, royaltyBps int64) {
	if inited {
		panic("edcol: already")
	}
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("edcol: EOA only")
	}
	caller := cur.Previous().Address()
	if !validName(name) || !validSymbol(symbol_) || !validImage(cover_) {
		panic("edcol: meta")
	}
	creator = caller
	self = cur.Address()
	name_ = name
	symbol = symbol_
	cover = cover_
	royalty = royaltyBps
	copies = 0
	ledger = grc1155.New(0, cur)
	editions = avl.Tree{}
	listings = avl.Tree{}
	efactory.Register(cross(cur), name, symbol_, cover_, royaltyBps)
	inited = true
}

// Create opens an edition. Only the creator can call it. max is the copy cap.
// mintPrice 0 means only the creator can mint.
func Create(cur realm, id, name, image string, max, mintPrice int64) {
	caller := requireUser(cur)
	if caller != creator {
		panic("edcol: creator")
	}
	if !validID(id) || !validName(name) || !validImage(image) {
		panic("edcol: meta")
	}
	if max <= 0 || max > maxSupply || mintPrice < 0 {
		panic("edcol: supply")
	}
	if editions.Has(id) {
		panic("edcol: exists")
	}
	editions.Set(id, &edition{name: name, image: image, max: max, mintPrice: mintPrice})
	chain.Emit("EditionCreate", "id", id, "max", strconv.FormatInt(max, 10))
}

// Mint adds copies. The creator mints without payment. Anyone else pays mintPrice each.
func Mint(cur realm, id string, to address, amount int64) {
	caller := requireUser(cur)
	ed := mustEdition(id)
	if !to.IsValid() || to == self || amount <= 0 {
		panic("edcol: amount")
	}
	if amount > ed.max || ed.minted > ed.max-amount {
		panic("edcol: supply")
	}
	if caller == creator {
		takeExact(0)
	} else {
		if ed.mintPrice <= 0 {
			panic("edcol: creator")
		}
		takeExact(mul(ed.mintPrice, amount))
	}
	ledger.Mint(0, cur, to, id, amount)
	ed.minted += amount
	copies += amount
	editions.Set(id, ed)
	efactory.NoteMinted(cross(cur), copies)
	if caller != creator {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(self, creator, chain.Coins{{Denom: nativeDenom, Amount: mul(ed.mintPrice, amount)}})
	}
	chain.Emit("EditionMint", "id", id, "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// List escrows amount of id at a unit price. One open listing per seller and id.
func List(cur realm, id string, amount, unitPrice int64) {
	caller := requireUser(cur)
	mustEdition(id)
	if amount <= 0 || unitPrice <= 0 {
		panic("edcol: price")
	}
	key := listKey(caller, id)
	if listings.Has(key) {
		panic("edcol: listed")
	}
	if ledger.Balance(caller, id) < amount {
		panic("edcol: balance")
	}
	ledger.Move(0, cur, caller, self, id, amount)
	listings.Set(key, &listing{amount: amount, unit: unitPrice})
	chain.Emit("EditionList", "id", id, "seller", caller.String(), "amount", strconv.FormatInt(amount, 10), "price", strconv.FormatInt(unitPrice, 10))
}

func Cancel(cur realm, id string) {
	caller := requireUser(cur)
	key := listKey(caller, id)
	row := listings.Get(key)
	if row == nil {
		panic("edcol: not listed")
	}
	hold := row.(*listing)
	ledger.Move(0, cur, self, caller, id, hold.amount)
	listings.Remove(key)
	chain.Emit("EditionCancel", "id", id, "seller", caller.String())
}

// Buy takes amount copies from seller's listing. Payment is unit price times amount.
func Buy(cur realm, seller address, id string, amount int64) {
	caller := requireUser(cur)
	if !seller.IsValid() || caller == seller || amount <= 0 {
		panic("edcol: amount")
	}
	key := listKey(seller, id)
	row := listings.Get(key)
	if row == nil {
		panic("edcol: not listed")
	}
	hold := row.(*listing)
	if amount > hold.amount {
		panic("edcol: amount")
	}
	price := mul(hold.unit, amount)
	takeExact(price)
	sellerAmt, royal, sinkAmt := split(price)
	pay(cur, seller, sellerAmt, royal, sinkAmt)
	ledger.Move(0, cur, self, caller, id, amount)
	hold.amount -= amount
	if hold.amount == 0 {
		listings.Remove(key)
	} else {
		listings.Set(key, hold)
	}
	chain.Emit("EditionBuy", "id", id, "buyer", caller.String(), "seller", seller.String(), "amount", strconv.FormatInt(amount, 10))
}

func Transfer(cur realm, to address, id string, amount int64) {
	caller := requireUser(cur)
	if !to.IsValid() || to == caller || to == self || amount <= 0 {
		panic("edcol: amount")
	}
	mustEdition(id)
	if ledger.Balance(caller, id) < amount {
		panic("edcol: balance")
	}
	ledger.Move(0, cur, caller, to, id, amount)
}

func BalanceOf(addr string, id string) int64 {
	who, ok := parseAddr(addr)
	if !ok {
		return 0
	}
	return ledger.Balance(who, id)
}

func Supply(id string) int64 {
	if ledger == nil {
		return 0
	}
	return ledger.Supply(id)
}

func TokenURI(id string) string {
	ed := mustEdition(id)
	body := `{"name":` + jsonStr(ed.name) + `,"image":` + jsonStr(ed.image) + `,"edition":` + jsonStr(id) + `}`
	return "data:application/json;charset=utf-8," + pctURI(body)
}

func Listing(seller, id string) string {
	who, ok := parseAddr(seller)
	if !ok {
		return ""
	}
	row := listings.Get(listKey(who, id))
	if row == nil {
		return ""
	}
	hold := row.(*listing)
	return strconv.FormatInt(hold.amount, 10) + "|" + strconv.FormatInt(hold.unit, 10)
}

func Name() string  { return name_ }
func Symbol() string { return symbol }

// Editions is id|name|image|max|minted|mintPrice, one edition per line.
func Editions() string {
	if !inited {
		return ""
	}
	out := ""
	editions.Iterate("", "", func(key string, value any) bool {
		ed := value.(*edition)
		if out != "" {
			out += "\n"
		}
		out += key + "|" + ed.name + "|" + ed.image + "|" +
			strconv.FormatInt(ed.max, 10) + "|" +
			strconv.FormatInt(ed.minted, 10) + "|" +
			strconv.FormatInt(ed.mintPrice, 10)
		return false
	})
	return out
}

// OpenListings is seller|id|amount|unitPrice, one listing per line.
func OpenListings() string {
	out := ""
	listings.Iterate("", "", func(key string, value any) bool {
		hold := value.(*listing)
		if out != "" {
			out += "\n"
		}
		out += key + "|" + strconv.FormatInt(hold.amount, 10) + "|" + strconv.FormatInt(hold.unit, 10)
		return false
	})
	return out
}

func requireUser(cur realm) address {
	if !inited {
		panic("edcol: init")
	}
	if !cur.IsCurrent() {
		panic("edcol: spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("edcol: EOA only")
	}
	return cur.Previous().Address()
}

func mustEdition(id string) *edition {
	v := editions.Get(id)
	if v == nil {
		panic("edcol: unknown id")
	}
	return v.(*edition)
}

func listKey(seller address, id string) string {
	return seller.String() + "|" + id
}

func split(price int64) (sellerAmt, royal, sinkAmt int64) {
	proto := fee.ProtocolFee(price, efactory.ProtocolBps())
	if royalty > 0 {
		royal = fee.ProtocolFee(price, royalty)
	}
	if proto+royal > price {
		panic("edcol: fee")
	}
	sellerAmt = price - proto - royal
	sinkAmt = proto
	if sinkAmt > 0 && !efactory.ProtocolSink().IsValid() {
		panic("edcol: sink")
	}
	return
}

func pay(cur realm, seller address, sellerAmt, royal, sinkAmt int64) {
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if sellerAmt > 0 {
		bk.SendCoins(self, seller, chain.Coins{{Denom: nativeDenom, Amount: sellerAmt}})
	}
	if royal > 0 {
		bk.SendCoins(self, creator, chain.Coins{{Denom: nativeDenom, Amount: royal}})
	}
	if sinkAmt > 0 {
		bk.SendCoins(self, efactory.ProtocolSink(), chain.Coins{{Denom: nativeDenom, Amount: sinkAmt}})
	}
}

func takeExact(want int64) {
	sent := unsafe.OriginSend()
	if want == 0 {
		if len(sent) != 0 {
			panic("edcol: extra payment")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != nativeDenom || sent[0].Amount != want {
		panic("edcol: wrong payment")
	}
}

func mul(a, b int64) int64 {
	if a < 0 || b <= 0 {
		panic("edcol: amount")
	}
	if a == 0 {
		return 0
	}
	if a > math.MaxInt64/b {
		panic("edcol: overflow")
	}
	return a * b
}

func parseAddr(raw string) (address, bool) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return address(""), false
	}
	who := address(s)
	if !who.IsValid() {
		return address(""), false
	}
	return who, true
}

func validID(id string) bool {
	if len(id) < 1 || len(id) > 16 || id[0] < 'a' || id[0] > 'z' {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
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

func validSymbol(s string) bool {
	if len(s) < 1 || len(s) > 11 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
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
	rest := strings.TrimPrefix(u, "/samples/")
	return strings.HasPrefix(u, "/samples/") && rest != "" && rest != u
}

func jsonStr(s string) string {
	return `"` + s + `"`
}

func pctURI(s string) string {
	hex := "0123456789ABCDEF"
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
			out += string(rune(c))
			continue
		}
		out += "%" + string([]byte{hex[c>>4], hex[c&15]})
	}
	return out
}
