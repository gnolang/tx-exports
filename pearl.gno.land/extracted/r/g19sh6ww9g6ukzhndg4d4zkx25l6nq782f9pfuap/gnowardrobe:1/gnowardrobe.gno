// Package gnodrobe — GnoDrobe Collection, GRC-721 NFT minter realm.
//
// Пользователь собирает гнома (hat + beard) на сайте GnoDrobe и вызывает
// Mint(hatID, beardID), прикладывая к вызову ровно
// (hatPrice + beardPrice) ugnot. Средства сразу уходят владельцу
// коллекции (collectionOwner), а минтер получает NFT с on-chain
// метаданными (OpenSea-совместимый data URI: имя, описание, трейты).
//
// Ограничения: maxSupply (общий тираж), maxMintsPerWallet (лимит на
// один кошелёк), royalty 1% (декларируется в метаданных; полноценный
// сбор роялти при вторичных продажах — на маркетплейсе).
package gnowardrobe

import (
	"chain"
	"chain/banker"
	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"
	"strconv"
	"strings"

	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	CollectionName   = "GnoDrobe Collection"
	CollectionSymbol = "GDG"

	// MaxSupply — общий тираж коллекции (жёсткий потолок минтов).
	MaxSupply = 10000

	// MaxMintsPerWallet — сколько NFT максимум на один кошелёк.
	MaxMintsPerWallet = 10

	// RoyaltyPct — роялти с вторичных продаж, 1%.
	RoyaltyPct = 1

	// collectionOwner — владелец коллекции, получает платежи за минт.
	// = Harry (деплойер). Менять только owner-функцией SetOwner.
	collectionOwner = "g19sh6ww9g6ukzhndg4d4zkx25l6nq782f9pfuap"

	// realmRelPath — путь реалма (для рендера).
	realmRelPath = "/r/g19sh6ww9g6ukzhndg4d4zkx25l6nq782f9pfuap/gnowardrobe"
)

// Part — одна часть гнома (шапка или борода) с ценой в GNOT.
type Part struct {
	Name  string
	Price int64 // цена в GNOT (не ugnot)
}

// hats/beards — каталог ассетов GnoDrobe с ценами из assets-manifest.json.
// Индекс = ID, как в манифесте фронтенда. Порядок менять нельзя —
// сломает соответствие с UI.
var hats = []Part{
	{"Cardboard Crown", 2},
	{"Cosmic", 4},
	{"Crystal", 6},
	{"Denim", 2},
	{"Golden", 4},
	{"Grassy", 6},
	{"Jelly", 2},
	{"Leather", 4},
	{"Metallic", 6},
	{"Noodle", 2},
	{"Plank", 4},
	{"Spruce", 6},
	{"Straw", 2},
	{"Volcanic", 4},
}

var beards = []Part{
	{"Bone", 4},
	{"Cloudy", 6},
	{"Coin", 2},
	{"Cosmic", 4},
	{"Crystal", 6},
	{"Leafy", 2},
	{"Lightning", 4},
	{"Metallic", 6},
	{"Mushroom", 2},
	{"Piped", 4},
}

var (
	nft     *grc721.MetadataNFT
	owner   address = collectionOwner
	mintingOpen      = true
	mintsByWallet    = avl.NewTree() // addr -> int64 (сколько наминтил)
)

func init(cur realm) {
	nft = grc721.NewNFTWithMetadata(0, cur, CollectionName, CollectionSymbol)
}

// ---- Owner / конфиг ----

func Owner() address { return owner }

func SetOwner(cur realm, newOwner address) {
	if callerAddress() != owner {
		panic("only the collection owner can change the owner")
	}
	if newOwner == "" {
		panic("owner cannot be empty")
	}
	owner = newOwner
}

func MintingOpen() bool { return mintingOpen }

func SetMintingOpen(cur realm, open bool) {
	if callerAddress() != owner {
		panic("only the collection owner can change minting")
	}
	mintingOpen = open
}

// WithdrawFunds отправляет amount ugnot с баланса реалма владельцу.
func WithdrawFunds(cur realm, amountUgnot int64) {
	if callerAddress() != owner {
		panic("only the collection owner can withdraw")
	}
	if amountUgnot <= 0 {
		panic("amount must be positive")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), owner, chain.Coins{{Denom: "ugnot", Amount: amountUgnot}})
}

// ---- Каталог ----

func HatCount() int   { return len(hats) }
func BeardCount() int { return len(beards) }

func HatName(id int) string {
	if id < 0 || id >= len(hats) {
		return ""
	}
	return hats[id].Name
}

func BeardName(id int) string {
	if id < 0 || id >= len(beards) {
		return ""
	}
	return beards[id].Name
}

func HatPriceUgnot(id int) int64 {
	if id < 0 || id >= len(hats) {
		return 0
	}
	return hats[id].Price * 1_000_000
}

func BeardPriceUgnot(id int) int64 {
	if id < 0 || id >= len(beards) {
		return 0
	}
	return beards[id].Price * 1_000_000
}

// ---- Минт ----

// Mint чеканит NFT гнома из hatID+beardID вызывающему.
// К вызову нужно приложить ровно (HatPriceUgnot(hatID)+BeardPriceUgnot(beardID)).
func Mint(cur realm, hatID, beardID int) string {
	caller := callerAddress()

	if !mintingOpen {
		panic("minting is closed")
	}
	if nft.TokenCount() >= MaxSupply {
		panic("max supply reached")
	}
	if maxPerWalletReached(caller) {
		panic("wallet mint limit reached")
	}
	if hatID < 0 || hatID >= len(hats) {
		panic("invalid hat id")
	}
	if beardID < 0 || beardID >= len(beards) {
		panic("invalid beard id")
	}

	priceUgnot := HatPriceUgnot(hatID) + BeardPriceUgnot(beardID)

	// Оплата: приложенные ugnot должны ровно совпадать с ценой.
	if priceUgnot > 0 {
		runtime.AssertOriginCall()
		if !unsaferealm.PreviousRealm().IsUserCall() {
			panic("payment verification requires a direct user call")
		}
		got := unsaferealm.OriginSend().AmountOf("ugnot")
		if got != priceUgnot {
			panic(ufmt.Sprintf(
				"payment required: exactly %d ugnot, got %d",
				priceUgnot, got,
			))
		}
		// Сразу пересылаем владельцу.
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), owner, chain.Coins{{Denom: "ugnot", Amount: got}})
	}

	tid := grc721.TokenID(strconv.FormatInt(nft.TokenCount()+1, 10))
	checkErr(nft.Mint(caller, tid))
	checkErr(nft.SetTokenMetadata(caller, tid, grc721.Metadata{
		Name:        ufmt.Sprintf("%s #%s", CollectionName, tid.String()),
		Description: "A gnome from the GnoDrobe Collection, assembled from hat + beard on-chain traits.",
		Attributes: []grc721.Trait{
			{TraitType: "Hat", Value: hats[hatID].Name},
			{TraitType: "Beard", Value: beards[beardID].Name},
			{TraitType: "Royalty", Value: "1%"},
		},
	}))
	incMintCount(caller)

	chain.Emit(
		"GnoDrobeMinted",
		"tokenId", tid.String(),
		"hat", hats[hatID].Name,
		"beard", beards[beardID].Name,
		"to", caller.String(),
	)

	return tid.String()
}

// ---- View-функции для фронтенда ----

func Name() string  { return nft.Name() }
func Symbol() string { return nft.Symbol() }
func TotalMinted() int64 { return nft.TokenCount() }
func MaxSupply() int64   { return MaxSupply }

func TokenURI(tid grc721.TokenID) (string, error) { return nft.TokenURI(tid) }
func OwnerOf(tid grc721.TokenID) (address, error) { return nft.OwnerOf(tid) }
func BalanceOf(addr address) (int64, error)       { return nft.BalanceOf(addr) }
func TokenMetadata(tid grc721.TokenID) (grc721.Metadata, error) {
	return nft.TokenMetadata(tid)
}

// TokensOf возвращает список tokenID, принадлежащих addr (по возрастанию).
// Реализовано через обход всех токенов — для тестнета норм
// (макс 10k токенов, qeval читает без газа).
func TokensOf(addr address) []string {
	out := []string{}
	for i := int64(1); i <= nft.TokenCount(); i++ {
		tid := grc721.TokenID(strconv.FormatInt(i, 10))
		o, err := nft.OwnerOf(tid)
		if err == nil && o == addr {
			out = append(out, tid.String())
		}
	}
	return out
}

// ---- Рендер ----

func Render(path string) string {
	var b strings.Builder
	b.WriteString("# GnoDrobe Collection\n\n")
	b.WriteString(ufmt.Sprintf("Symbol: %s\n", CollectionSymbol))
	b.WriteString(ufmt.Sprintf("Minted: %d / %d\n", nft.TokenCount(), MaxSupply))
	b.WriteString(ufmt.Sprintf("Owner: %s\n", owner.String()))
	b.WriteString(ufmt.Sprintf("Royalty: %d%%\n", RoyaltyPct))
	b.WriteString(ufmt.Sprintf("Mint price: %d ugnot (hat) + %d ugnot (beard) per part\n\n",
		hats[0].Price*1_000_000, beards[0].Price*1_000_000))

	b.WriteString("## Parts\n\n")
	b.WriteString("### Hats\n")
	for i, h := range hats {
		b.WriteString(ufmt.Sprintf("%d. %s — %d GNOT\n", i, h.Name, h.Price))
	}
	b.WriteString("\n### Beards\n")
	for i, bd := range beards {
		b.WriteString(ufmt.Sprintf("%d. %s — %d GNOT\n", i, bd.Name, bd.Price))
	}
	b.WriteString("\n## Tokens\n")
	for i := int64(1); i <= nft.TokenCount(); i++ {
		tid := grc721.TokenID(strconv.FormatInt(i, 10))
		o, err := nft.OwnerOf(tid)
		if err != nil {
			continue
		}
		md, err := nft.TokenMetadata(tid)
		if err != nil {
			continue
		}
		hat := ""
		beard := ""
		for _, t := range md.Attributes {
			if t.TraitType == "Hat" {
				hat = t.Value
			}
			if t.TraitType == "Beard" {
				beard = t.Value
			}
		}
		b.WriteString(ufmt.Sprintf("- #%s: %s + %s, owner %s\n",
			tid.String(), hat, beard, o.String()))
	}
	return b.String()
}

// ---- Хелперы ----

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func maxPerWalletReached(addr address) bool {
	v := mintsByWallet.Get(addr.String())
	if v == nil {
		return false
	}
	return v.(int64) >= MaxMintsPerWallet
}

func incMintCount(addr address) {
	v := mintsByWallet.Get(addr.String())
	if v == nil {
		mintsByWallet.Set(addr.String(), int64(1))
		return
	}
	mintsByWallet.Set(addr.String(), v.(int64)+1)
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
