// Package gnofish is the GnoFish sale NFT.
// A listed wallet mints for free. Anyone else pays exactly 100 GNOT.
// An address may mint as many times as the 10000 cap allows.
// The portrait is rolled in the same call. Every NFT is owned by the admin.
// The whole 100 GNOT is sent to that admin. This realm does not add FISH liquidity.
// The height and the next id are public before the transaction, so the roll can be predicted. This is not drand.
// Adena reads OwnerOf, BalanceOf, TokenURI (the https image) and TokenMetadata
// (JSON, traitType). NewToken and Transfer come from the GRC721 ledger.
// This package does not swim, settle, or draw FISH. fishlive stays untouched.
// Nomaq lists with List, UpdatePrice, Cancel, and Buy. ItemLine and ListOpen feed the page.
// gnofish-1.
package gnofish

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"errors"
	"strconv"

	"gno.land/p/nt/grc721/enumerable/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	denom            = "ugnot"
	mintPrice  int64 = 100_000_000
	maxAsk     int64 = 100_000_000_000_000
	maxMint          = 10_000
	listCap          = 50
	slug             = "gnofish"
	imageIPFS        = "ipfs://bafybeifdmgbtq3nf7xuepvygotk6ulk4wo7xshsi2yr4xukglsdpzz7p2i/"
	imageHTTPS       = "https://gateway.pinata.cloud/ipfs/bafybeifdmgbtq3nf7xuepvygotk6ulk4wo7xshsi2yr4xukglsdpzz7p2i/"
)

var (
	species  = [6]string{"Bubble", "Tideblade", "Abysswing", "Embermaw", "Aurelion", "Astravex"}
	rarities = [6]string{"common", "uncommon", "rare", "epic", "legendary", "mythic"}
	portrait = [6]string{"common-fish.jpg", "uncommon-fish.jpg", "race-fish.jpg", "epic-fish.jpg", "legendary-fish.jpg", "mythic-fish.jpg"}
	traits   = [3]string{"swift", "fang", "hide"}
	biteBase = [6]int{24, 30, 37, 45, 54, 66}
	hpBase   = [6]int{100, 122, 148, 178, 214, 256}
	spdBase  = [6]int{108, 104, 100, 96, 92, 88}
)

type fish struct {
	owner    address
	payer    address
	name     string
	rarity   string
	trait    string
	file     string
	bite     int
	hp       int
	speed    int
	height   int64
	revealed bool
	seller   address
	ask      int64
	onSale   bool
}

var (
	inited bool
	self   address
	admin  address
	minted int
	roster []fish
	listed map[address]bool
	token   *grc721.Token
	ledger  *grc721.PrivateLedger
	teller  grc721.Teller
	indexed *enumerable.Enumerable
	seq     seqid.ID
)

// Init opens the sale. The caller becomes the admin and the owner of every mint. No coins.
func Init(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("fishdrop: eoa")
	}
	takeExact(0)
	if inited {
		panic("fishdrop: init")
	}
	inited = true
	self = cur.Address()
	admin = cur.Previous().Address()
	listed = map[address]bool{}
	roster = []fish{{}}
	tok, led := grc721.NewToken("GnoFish", "GFISH", seq.Next(), cur)
	token = tok
	ledger = led
	teller = led.CallerTeller()
	indexed, _ = enumerable.NewEnumerable(led)
	chain.Emit("Init", "admin", admin.String())
}

// Grant lets that wallet mint without paying. Admin only. There is no per-address cap.
func Grant(cur realm, who address) {
	adminOnly(cur)
	if !who.IsValid() {
		panic("fishdrop: addr")
	}
	listed[who] = true
	chain.Emit("Grant", "who", who.String())
}

// Revoke removes the free mint.
func Revoke(cur realm, who address) {
	adminOnly(cur)
	if !who.IsValid() {
		panic("fishdrop: addr")
	}
	listed[who] = false
	chain.Emit("Revoke", "who", who.String())
}

// TransferAdmin moves the wallet that receives NFTs and GNOT.
func TransferAdmin(cur realm, next address) {
	adminOnly(cur)
	if !next.IsValid() || next == admin {
		panic("fishdrop: addr")
	}
	admin = next
	chain.Emit("Admin", "who", next.String())
}

// Mint rolls one fish and gives it to the admin. A listed wallet sends nothing. Everyone else sends 100 GNOT, and that full amount goes to the admin.
func Mint(cur realm) int {
	if !cur.Previous().IsUserCall() {
		panic("fishdrop: eoa")
	}
	if !inited {
		panic("fishdrop: init")
	}
	caller := cur.Previous().Address()
	free := listed[caller]
	if free {
		takeExact(0)
	} else {
		takeExact(mintPrice)
	}
	if minted >= maxMint {
		panic("fishdrop: mint")
	}
	height := runtime.ChainHeight()
	if height < 1 {
		panic("fishdrop: mint")
	}
	id := grow()
	row := &roster[id]
	rarity, trait, bite, hp, speed, tier := Roll(caller, height, id)
	row.owner = admin
	row.payer = caller
	row.rarity = rarity
	row.trait = trait
	row.bite = bite
	row.hp = hp
	row.speed = speed
	row.height = height
	row.name = pickName(tier)
	row.file = portrait[tier]
	row.revealed = true
	if err := ledger.Mint(admin, grc721.TokenID(strconv.Itoa(id))); err != nil {
		panic("fishdrop: mint")
	}
	if !free {
		send(admin, mintPrice, cur)
	}
	chain.Emit("Mint", "id", strconv.Itoa(id), "payer", caller.String(), "owner", admin.String(), "rarity", rarity, "file", row.file)
	return id
}

// Transfer moves a fish the caller owns. The call sends no coins.
func Transfer(cur realm, to address, id int) {
	from := gate(cur)
	move(cur, from, to, id)
}

// TransferFrom moves a fish. The caller must own it or be approved for it.
func TransferFrom(cur realm, from, to address, id int) {
	gate(cur)
	move(cur, from, to, id)
}

// Approve lets to move this fish once. The caller must own it.
func Approve(cur realm, to address, id int) {
	gate(cur)
	if err := teller.Approve(0, cur, to, tidOf(id)); err != nil {
		panic("fishdrop: approve")
	}
}

// SetApprovalForAll lets operator move every fish of the caller, or revokes it.
func SetApprovalForAll(cur realm, operator address, approved bool) {
	gate(cur)
	if err := teller.SetApprovalForAll(0, cur, operator, approved); err != nil {
		panic("fishdrop: approve")
	}
}

// List escrows the fish to this realm and puts it on sale. The caller sends no coins.
func List(cur realm, id int, priceUgnot int64) {
	caller := gate(cur)
	row := must(id)
	if priceUgnot <= 0 || priceUgnot > maxAsk || !row.revealed || row.onSale || row.owner != caller {
		panic("fishdrop: list")
	}
	ledgerMove(caller, caller, self, id)
	row.onSale = true
	row.seller = caller
	row.ask = priceUgnot
	row.owner = self
	chain.Emit("List", "id", strconv.Itoa(id), "seller", caller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

// UpdatePrice changes the ask of a fish the caller is selling.
func UpdatePrice(cur realm, id int, priceUgnot int64) {
	caller := gate(cur)
	row := must(id)
	if priceUgnot <= 0 || priceUgnot > maxAsk || !row.onSale || row.seller != caller {
		panic("fishdrop: list")
	}
	row.ask = priceUgnot
	chain.Emit("List", "id", strconv.Itoa(id), "seller", caller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

// Cancel returns a listed fish to its seller. The call sends no coins.
func Cancel(cur realm, id int) {
	caller := gate(cur)
	row := must(id)
	if !row.onSale || row.seller != caller {
		panic("fishdrop: list")
	}
	ledgerMove(self, self, caller, id)
	row.onSale = false
	row.owner = caller
	row.seller = address("")
	row.ask = 0
	chain.Emit("Cancel", "id", strconv.Itoa(id))
}

// Buy pays the ask, in full, to the seller and gives the fish to the buyer.
func Buy(cur realm, id int) {
	if !cur.Previous().IsUserCall() {
		panic("fishdrop: eoa")
	}
	if !inited {
		panic("fishdrop: init")
	}
	row := must(id)
	buyer := cur.Previous().Address()
	if !row.onSale || buyer == row.seller {
		panic("fishdrop: list")
	}
	price := row.ask
	seller := row.seller
	takeExact(price)
	ledgerMove(self, self, buyer, id)
	row.onSale = false
	row.owner = buyer
	row.seller = address("")
	row.ask = 0
	send(seller, price, cur)
	chain.Emit("Buy", "id", strconv.Itoa(id), "buyer", buyer.String(), "price", strconv.FormatInt(price, 10))
}

func Version() string   { return "gnofish-1" }
func Name() string      { return "GnoFish" }
func GrcName() string   { return Name() }
func Symbol() string    { return "GFISH" }
func GrcSymbol() string { return Symbol() }
func Creator() string {
	if !inited {
		return ""
	}
	return admin.String()
}
func MintPrice() int64 { return mintPrice }
func MaxMint() int     { return maxMint }
func Minted() int      { return minted }
func Realm() address   { return self }
func Admin() string    { return admin.String() }
func Whitelisted(who string) bool {
	addr := address(who)
	return addr.IsValid() && listed[addr]
}

func Listed(id int) bool { return revealed(id).onSale }
func PriceOf(id int) int64 { return revealed(id).ask }
func SellerOf(id int) string {
	row := revealed(id)
	if !row.seller.IsValid() {
		return ""
	}
	return row.seller.String()
}

func ItemLine(id int) string {
	row := revealed(id)
	traits := "Species:" + speciesOf(row.rarity) + ";Rarity:" + row.rarity + ";Trait:" + row.trait + ";Bite:" + strconv.Itoa(row.bite) + ";HP:" + strconv.Itoa(row.hp) + ";Speed:" + strconv.Itoa(row.speed)
	return strconv.Itoa(id) + "|" + row.name + "|" + row.owner.String() + "|" + SellerOf(id) + "|" + strconv.FormatInt(row.ask, 10) + "|" + strconv.FormatBool(row.onSale) + "|" + imageHTTPS + row.file + "|" + slug + "|" + row.rarity + "|" + traits + "|true|-1"
}

func ListOpen() string {
	if !inited {
		return ""
	}
	out := ""
	n := 0
	for id := 1; id <= minted && n < listCap; id++ {
		if !roster[id].onSale {
			continue
		}
		if out != "" {
			out += "\n"
		}
		out += ItemLine(id)
		n++
	}
	return out
}

func TokensOf(owner address) string {
	if !inited || !owner.IsValid() {
		return ""
	}
	out := ""
	for id := 1; id <= minted; id++ {
		if roster[id].owner != owner {
			continue
		}
		if out != "" {
			out += ","
		}
		out += strconv.Itoa(id)
	}
	return out
}
func PayerOf(id int) string { return revealed(id).payer.String() }

func OwnerOf(tid grc721.TokenID) (address, error) {
	if token == nil {
		return "", errors.New("fishdrop: init")
	}
	return token.OwnerOf(tid)
}

func BalanceOf(addr address) (int64, error) {
	if token == nil {
		return 0, errors.New("fishdrop: init")
	}
	return token.BalanceOf(addr)
}

func TotalSupply() int64 {
	if token == nil {
		return 0
	}
	return token.TotalSupply()
}

func GetApproved(tid grc721.TokenID) (address, error) {
	if token == nil {
		return "", errors.New("fishdrop: init")
	}
	addr, err := token.GetApproved(tid)
	if err == grc721.ErrTokenIdNotApproved {
		return "", nil
	}
	return addr, err
}

func IsApprovedForAll(owner, operator address) bool {
	if token == nil {
		return false
	}
	return token.IsApprovedForAll(owner, operator)
}

func TokenByIndex(index int64) (grc721.TokenID, error) {
	if indexed == nil {
		return "", errors.New("fishdrop: init")
	}
	return indexed.TokenByIndex(index)
}

func TokenOfOwnerByIndex(owner address, index int64) (grc721.TokenID, error) {
	if indexed == nil {
		return "", errors.New("fishdrop: init")
	}
	return indexed.TokenOfOwnerByIndex(owner, index)
}

func RarityOf(id int) string { return revealed(id).rarity }
func TraitOf(id int) string  { return revealed(id).trait }
func NameOf(id int) string   { return revealed(id).name }
func ImageOf(id int) string  { return imageHTTPS + revealed(id).file }

// TokenURI is the https image Adena puts in an img tag.
func TokenURI(tid grc721.TokenID) (string, error) {
	row, err := byToken(tid)
	if err != nil {
		return "", err
	}
	return imageHTTPS + row.file, nil
}

// TokenMetadata is the JSON Adena reads. Attribute keys are traitType.
func TokenMetadata(tid grc721.TokenID) (string, error) {
	row, err := byToken(tid)
	if err != nil {
		return "", err
	}
	return `{"name":"` + row.name + `","description":"` + row.name + `, a ` + row.rarity + ` GnoFish.","image":"` + imageHTTPS + row.file + `","attributes":[` +
		attr("species", speciesOf(row.rarity)) + `,` +
		attr("rarity", row.rarity) + `,` +
		attr("trait", row.trait) + `,` +
		attr("bite", strconv.Itoa(row.bite)) + `,` +
		attr("hp", strconv.Itoa(row.hp)) + `,` +
		attr("speed", strconv.Itoa(row.speed)) + `,` +
		attr("ipfs", imageIPFS+row.file) + `]}`, nil
}

// Roll is sha256 of caller|height|id.
// mythic 1/10000, legendary 3, epic 10, rare 40, uncommon 200, the rest common.
func Roll(caller address, height int64, id int) (rarity string, trait string, bite int, hp int, speed int, tier int) {
	if id < 1 || height < 1 {
		panic("fishdrop: roll")
	}
	raw := caller.String() + "|" + strconv.FormatInt(height, 10) + "|" + strconv.Itoa(id)
	sum := sha256.Sum256([]byte(raw))
	n := (int(sum[0])<<8 | int(sum[1])) % 10000
	tier = 0
	if n == 0 {
		tier = 5
	} else if n < 4 {
		tier = 4
	} else if n < 14 {
		tier = 3
	} else if n < 54 {
		tier = 2
	} else if n < 254 {
		tier = 1
	}
	kind := int(sum[2]) % 3
	bite = biteBase[tier]
	hp = hpBase[tier]
	speed = spdBase[tier]
	if kind == 0 {
		speed = (speed*112 + 50) / 100
	} else if kind == 1 {
		bite = (bite*112 + 50) / 100
	} else {
		hp = (hp*112 + 50) / 100
	}
	return rarities[tier], traits[kind], bite, hp, speed, tier
}

func Render(path string) string {
	if path != "" {
		return "# GnoFish\n\nUnknown path.\n"
	}
	if !inited {
		return "# GnoFish\n\nNot opened.\n"
	}
	return "# GnoFish\n\nWhitelist mint is free. Public mint is 100 GNOT, paid entirely to the admin. Every NFT is minted to the admin and revealed in that same call. An address may mint more than once. This realm does not add liquidity.\n"
}

func adminOnly(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("fishdrop: eoa")
	}
	takeExact(0)
	if !inited || cur.Previous().Address() != admin {
		panic("fishdrop: admin")
	}
}

func gate(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("fishdrop: eoa")
	}
	takeExact(0)
	if !inited {
		panic("fishdrop: init")
	}
	return cur.Previous().Address()
}

func send(to address, amt int64, rlm realm) {
	if !rlm.IsCurrent() {
		panic("fishdrop: realm")
	}
	if amt == 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: denom, Amount: amt}})
}

func grow() int {
	if minted >= maxMint || len(roster) != minted+1 {
		panic("fishdrop: mint")
	}
	roster = append(roster, fish{})
	minted++
	return minted
}

func must(id int) *fish {
	if !inited || id < 1 || id > minted || id >= len(roster) {
		panic("fishdrop: fish")
	}
	return &roster[id]
}

func revealed(id int) *fish {
	row := must(id)
	if !row.revealed {
		panic("fishdrop: uri")
	}
	return row
}

func pickName(tier int) string {
	base := species[tier]
	if !nameTaken(base) {
		return base
	}
	for n := 2; n <= maxMint; n++ {
		candidate := base + strconv.Itoa(n)
		if !nameTaken(candidate) {
			return candidate
		}
	}
	panic("fishdrop: name")
}

func nameTaken(name string) bool {
	for i := 1; i <= minted; i++ {
		if roster[i].revealed && roster[i].name == name {
			return true
		}
	}
	return false
}

func move(cur realm, from, to address, id int) {
	row := must(id)
	if row.onSale || !row.revealed || !to.IsValid() || to == from {
		panic("fishdrop: transfer")
	}
	if err := teller.TransferFrom(0, cur, from, to, tidOf(id)); err != nil {
		panic("fishdrop: transfer")
	}
	row.owner = to
}

func ledgerMove(spender, from, to address, id int) {
	if err := ledger.TransferFrom(spender, from, to, tidOf(id)); err != nil {
		panic("fishdrop: transfer")
	}
}

func tidOf(id int) grc721.TokenID {
	return grc721.TokenID(strconv.Itoa(id))
}

func byToken(tid grc721.TokenID) (*fish, error) {
	if token == nil {
		return nil, errors.New("fishdrop: init")
	}
	if _, err := token.OwnerOf(tid); err != nil {
		return nil, err
	}
	id, err := strconv.Atoi(string(tid))
	if err != nil || id < 1 || id > minted || id >= len(roster) || !roster[id].revealed {
		return nil, errors.New("fishdrop: fish")
	}
	return &roster[id], nil
}

func speciesOf(rarity string) string {
	for i := 0; i < len(rarities); i++ {
		if rarities[i] == rarity {
			return species[i]
		}
	}
	return ""
}

func attr(key, value string) string {
	return `{"traitType":"` + key + `","value":"` + value + `"}`
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("fishdrop: payment")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != n {
		panic("fishdrop: payment")
	}
}

