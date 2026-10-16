// Package seafish is the tradable person-versus-person sea.
// CommitMint pays 150 GNOT and the whole fee goes to the wallet that called Init.
// RevealMint, once the chain is at least two blocks later, rolls rarity and trait
// from sha256 of the caller, the commit height, that fixed height plus two, and the id.
// Waiting longer does not change the roll. The player does not pass trait, size, or rarity.
// The revealed fish is a GRC721 owned by that player. TokenURI is the https portrait.
// Swim stays off chain. Register locks at least 10 GNOT. Leave returns it after 5 seconds.
// Settle pays one covered stake: 80% winner, 10% liquidity, 10% team. Dust stays with the team.
// There is no machine fish and no FISH draw. A seated, staked, or healing fish cannot be
// listed or transferred. List, UpdatePrice, Cancel, and Buy are the Nomaq trade.
// Buy pays the ask, in full, to the seller. RegisterCollection publishes the slug on bazaarv5.
// fishsea, fishnft, gnofish, and fishlive stay as deployed. This package does not move them.
// seafish-1. The mint cap is 10000. One wallet still seats only one fish.
package seafish

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"errors"
	"strconv"
	"time"

	"gno.land/p/nt/grc721/enumerable/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
	factory "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/bazaarv5"
)

const (
	denom            = "ugnot"
	mintFee    int64 = 150_000_000
	stakeMin   int64 = 10_000_000
	quietMs    int64 = 5_000
	maxMint          = 10_000
	maxAsk     int64 = 100_000_000_000_000
	listCap          = 50
	slug             = "seafish"
	imageIPFS        = "ipfs://bafybeifdmgbtq3nf7xuepvygotk6ulk4wo7xshsi2yr4xukglsdpzz7p2i/"
	imageHTTPS       = "https://gateway.pinata.cloud/ipfs/bafybeifdmgbtq3nf7xuepvygotk6ulk4wo7xshsi2yr4xukglsdpzz7p2i/"
	cover            = imageHTTPS + "common-fish.jpg"
)

var (
	hpBase   = [6]int{100, 122, 148, 178, 214, 256}
	biteBase = [6]int{24, 30, 37, 45, 54, 66}
	spdBase  = [6]int{108, 104, 100, 96, 92, 88}
	species  = [6]string{"Bubble", "Tideblade", "Abysswing", "Embermaw", "Aurelion", "Astravex"}
	rarities = [6]string{"common", "uncommon", "rare", "epic", "legendary", "mythic"}
	portrait = [6]string{"common-fish.jpg", "uncommon-fish.jpg", "race-fish.jpg", "epic-fish.jpg", "legendary-fish.jpg", "mythic-fish.jpg"}
	traits   = [3]string{"swift", "fang", "hide"}
)

type fish struct {
	owner    address
	name     string
	rarity   string
	trait    string
	file     string
	bite     int
	hpMax    int
	hp       int
	speed    int
	pool     int64
	bouts    int
	commitH  int64
	touched  int64
	inSea    bool
	revealed bool
	mustHeal bool
	seller   address
	ask      int64
	onSale   bool
}

var (
	inited  bool
	market  bool
	self    address
	mintTo  address
	lpSink  address
	team    address
	minted  int
	shown   int
	roster  []fish
	token   *grc721.Token
	ledger  *grc721.PrivateLedger
	teller  grc721.Teller
	indexed *enumerable.Enumerable
	seq     seqid.ID
)

// Init records the caller as the mint wallet, plus liquidity and team.
// Those three must be distinct. Call once, from an EOA, with no coins.
func Init(cur realm, lp, crew address) {
	if !cur.Previous().IsUserCall() {
		panic("seafish: eoa")
	}
	takeExact(0)
	caller := cur.Previous().Address()
	if inited || !caller.IsValid() || !lp.IsValid() || !crew.IsValid() || caller == lp || caller == crew || lp == crew {
		panic("seafish: init")
	}
	inited = true
	self = cur.Address()
	mintTo = caller
	lpSink = lp
	team = crew
	roster = []fish{{}}
	tok, led := grc721.NewToken("GnoFish Sea", "GSEA", seq.Next(), cur)
	token = tok
	ledger = led
	teller = led.CallerTeller()
	indexed, _ = enumerable.NewEnumerable(led)
	chain.Emit("Init", "mint", caller.String(), "lp", lp.String(), "team", crew.String())
}

// CommitMint sells one unrevealed fish for 150 GNOT. The fee leaves this realm in the same call.
// The player owns the fish. The GRC721 is minted at RevealMint, when the portrait exists.
func CommitMint(cur realm) int {
	caller := gate(cur, mintFee)
	if minted >= maxMint || pending(caller) != 0 {
		panic("seafish: mint")
	}
	height := runtime.ChainHeight()
	if height < 1 {
		panic("seafish: mint")
	}
	id := grow()
	roster[id].owner = caller
	roster[id].commitH = height
	payMint(mintFee, cur)
	chain.Emit("Commit", "id", strconv.Itoa(id), "owner", caller.String())
	return id
}

// RevealMint assigns rarity, trait, the species name, and the portrait.
// Entropy is the commit height plus two. The NFT is minted to the caller.
func RevealMint(cur realm, id int) {
	caller := gate(cur, 0)
	row := mustFish(id)
	entropyH := row.commitH + 2
	if row.owner != caller || row.revealed || runtime.ChainHeight() < entropyH {
		panic("seafish: reveal")
	}
	rarity, trait, bite, hp, speed := Roll(caller, row.commitH, entropyH, id)
	row.rarity = rarity
	row.trait = trait
	row.bite = bite
	row.hpMax = hp
	row.hp = hp
	row.speed = speed
	row.name = pickName(tierOf(rarity))
	row.file = portrait[tierOf(rarity)]
	row.revealed = true
	if err := ledger.Mint(caller, tidOf(id)); err != nil {
		panic("seafish: mint")
	}
	shown++
	chain.Emit("Reveal", "id", strconv.Itoa(id), "rarity", rarity, "trait", trait, "name", row.name, "file", row.file)
	noteSupply(cur)
}

// Register seats one revealed fish the caller still owns. The attached coins are the stake.
// A listed fish, or a second fish from a wallet that is already seated, is refused.
func Register(cur realm, id int, stake int64) {
	caller := gate(cur, stake)
	row := mustFish(id)
	if stake < stakeMin || row.owner != caller || !row.revealed || row.inSea || row.mustHeal || row.onSale || row.pool != 0 || seated(caller) {
		panic("seafish: register")
	}
	row.pool = stake
	row.inSea = true
	row.touched = time.Now().UnixMilli()
	chain.Emit("Register", "id", strconv.Itoa(id), "stake", strconv.FormatInt(stake, 10))
}

// Leave returns the seated stake once 5 seconds have passed since Register.
func Leave(cur realm, id int) {
	caller := gate(cur, 0)
	row := mustFish(id)
	if row.owner != caller || !row.inSea || time.Now().UnixMilli() < row.touched+quietMs {
		panic("seafish: leave")
	}
	stake := row.pool
	row.pool = 0
	row.inSea = false
	send(caller, stake, cur)
	chain.Emit("Leave", "id", strconv.Itoa(id), "stake", strconv.FormatInt(stake, 10))
}

// Settle pays the smaller stake. The NFT stays. HP falls to 30% and must heal.
// The caller has to own the killer. This realm does not check who bit whom.
func Settle(cur realm, id int, target int) {
	caller := gate(cur, 0)
	if id == target {
		panic("seafish: settle")
	}
	atk := mustFish(id)
	vic := mustFish(target)
	if atk.owner != caller || !atk.inSea || !vic.inSea || atk.owner == vic.owner || atk.pool < stakeMin || vic.pool < stakeMin {
		panic("seafish: settle")
	}
	covered := atk.pool
	if vic.pool < covered {
		covered = vic.pool
	}
	excess := vic.pool - covered
	owner := vic.owner
	vic.pool = 0
	vic.inSea = false
	vic.mustHeal = true
	vic.hp = vic.hpMax * 30 / 100
	if vic.hp < 1 {
		vic.hp = 1
	}
	atk.bouts++
	vic.bouts++
	killer, lp, crew := splitKill(covered)
	send(atk.owner, killer, cur)
	send(lpSink, lp, cur)
	send(team, crew, cur)
	send(owner, excess, cur)
	chain.Emit("Kill", "id", strconv.Itoa(id), "target", strconv.Itoa(target), "covered", strconv.FormatInt(covered, 10))
}

// Heal clears mustHeal outside the sea so Register, List, and Transfer can run again.
func Heal(cur realm, id int) {
	caller := gate(cur, 0)
	row := mustFish(id)
	if row.owner != caller || row.inSea || row.onSale || !row.mustHeal || !row.revealed {
		panic("seafish: heal")
	}
	row.mustHeal = false
	row.hp = row.hpMax
	chain.Emit("Heal", "id", strconv.Itoa(id))
}

// Transfer moves a fish the caller owns. A seated, staked, healing, or listed fish stays put.
func Transfer(cur realm, to address, id int) {
	from := gate(cur, 0)
	move(cur, from, to, id)
}

// TransferFrom moves a fish. The caller must own it or be approved for it.
func TransferFrom(cur realm, from, to address, id int) {
	gate(cur, 0)
	move(cur, from, to, id)
}

// Approve lets to move this fish once. The caller must own it. The call sends no coins.
func Approve(cur realm, to address, id int) {
	gate(cur, 0)
	if err := teller.Approve(0, cur, to, tidOf(id)); err != nil {
		panic("seafish: approve")
	}
}

// SetApprovalForAll lets operator move every fish of the caller, or revokes it.
func SetApprovalForAll(cur realm, operator address, approved bool) {
	gate(cur, 0)
	if err := teller.SetApprovalForAll(0, cur, operator, approved); err != nil {
		panic("seafish: approve")
	}
}

// List escrows the fish to this realm and puts it on sale. The caller sends no coins.
// Refused while the fish is seated, still holds a stake, or must heal.
func List(cur realm, id int, priceUgnot int64) {
	caller := gate(cur, 0)
	row := mustFish(id)
	if priceUgnot <= 0 || priceUgnot > maxAsk || !row.revealed || row.onSale || row.owner != caller || busy(row) {
		panic("seafish: list")
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
	caller := gate(cur, 0)
	row := mustFish(id)
	if priceUgnot <= 0 || priceUgnot > maxAsk || !row.onSale || row.seller != caller {
		panic("seafish: list")
	}
	row.ask = priceUgnot
	chain.Emit("List", "id", strconv.Itoa(id), "seller", caller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

// Cancel returns a listed fish to its seller. The call sends no coins.
func Cancel(cur realm, id int) {
	caller := gate(cur, 0)
	row := mustFish(id)
	if !row.onSale || row.seller != caller {
		panic("seafish: list")
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
		panic("seafish: eoa")
	}
	if !inited {
		panic("seafish: init")
	}
	row := mustFish(id)
	buyer := cur.Previous().Address()
	if !row.onSale || buyer == row.seller {
		panic("seafish: list")
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

// RegisterCollection publishes this realm on bazaarv5. The caller must be the Init wallet,
// the same wallet that reserved slug seafish, and must send no coins. Call it once, after Init.
func RegisterCollection(cur realm) {
	caller := gate(cur, 0)
	if caller != mintTo || market {
		panic("seafish: admin")
	}
	factory.Register(cross(cur), "GnoFish Sea", "GSEA", cover, maxMint, mintFee, 0)
	market = true
	factory.NoteMinted(cross(cur), shown)
}

// Roll is the reveal hash. entropyH must be commitH+2. Trait adds 12%, half up.
func Roll(caller address, commitH int64, entropyH int64, id int) (rarity string, trait string, bite int, hp int, speed int) {
	if id < 1 || commitH < 1 || entropyH != commitH+2 {
		panic("seafish: roll")
	}
	raw := caller.String() + "|" + strconv.FormatInt(commitH, 10) + "|" + strconv.FormatInt(entropyH, 10) + "|" + strconv.Itoa(id)
	sum := sha256.Sum256([]byte(raw))
	n := (int(sum[0])<<8 | int(sum[1])) % 10000
	tier := 0
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
	return rarities[tier], traits[kind], bite, hp, speed
}

func Realm() address     { return self }
func MintTo() address    { return mintTo }
func Liquidity() address { return lpSink }
func Team() address      { return team }
func Version() string    { return "seafish-1" }
func Name() string       { return "GnoFish Sea" }
func GrcName() string    { return Name() }
func Symbol() string     { return "GSEA" }
func GrcSymbol() string  { return Symbol() }
func MintPrice() int64   { return mintFee }
func StakeMin() int64    { return stakeMin }
func MaxMint() int       { return maxMint }
func Minted() int        { return minted }
func Shown() int         { return shown }
func MarketOpen() bool   { return market }
func Height() int64      { return runtime.ChainHeight() }

func TraitOf(id int) string  { return mustFish(id).trait }
func RarityOf(id int) string { return mustFish(id).rarity }
func SizeOf(id int) string {
	mustFish(id)
	return "medium"
}
func BoutsOf(id int) int    { return mustFish(id).bouts }
func InMatch(id int) bool   { return mustFish(id).inSea }
func PoolOf(id int) int64   { return mustFish(id).pool }
func Revealed(id int) bool  { return mustFish(id).revealed }
func MustHeal(id int) bool  { return mustFish(id).mustHeal }
func CommitOf(id int) int64 { return mustFish(id).commitH }
func HpOf(id int) int       { return mustFish(id).hp }
func BiteOf(id int) int     { return mustFish(id).bite }
func SpeedOf(id int) int    { return mustFish(id).speed }
func NameOf(id int) string  { return mustFish(id).name }
func Listed(id int) bool    { return revealedFish(id).onSale }
func PriceOf(id int) int64  { return revealedFish(id).ask }
func ImageOf(id int) string { return imageHTTPS + revealedFish(id).file }

func SellerOf(id int) string {
	row := revealedFish(id)
	if !row.seller.IsValid() {
		return ""
	}
	return row.seller.String()
}

func ItemLine(id int) string {
	row := revealedFish(id)
	line := "Species:" + speciesOf(row.rarity) + ";Rarity:" + row.rarity + ";Trait:" + row.trait + ";Bite:" + strconv.Itoa(row.bite) + ";HP:" + strconv.Itoa(row.hp) + ";Speed:" + strconv.Itoa(row.speed)
	return strconv.Itoa(id) + "|" + row.name + "|" + row.owner.String() + "|" + SellerOf(id) + "|" + strconv.FormatInt(row.ask, 10) + "|" + strconv.FormatBool(row.onSale) + "|" + imageHTTPS + row.file + "|" + slug + "|" + row.rarity + "|" + line + "|true|-1"
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

func Pending(owner string) int {
	who := address(owner)
	if !who.IsValid() {
		return 0
	}
	return pending(who)
}

func OwnerOf(tid grc721.TokenID) (address, error) {
	if token == nil {
		return "", errors.New("seafish: init")
	}
	return token.OwnerOf(tid)
}

func BalanceOf(addr address) (int64, error) {
	if token == nil {
		return 0, errors.New("seafish: init")
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
		return "", errors.New("seafish: init")
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
		return "", errors.New("seafish: init")
	}
	return indexed.TokenByIndex(index)
}

func TokenOfOwnerByIndex(owner address, index int64) (grc721.TokenID, error) {
	if indexed == nil {
		return "", errors.New("seafish: init")
	}
	return indexed.TokenOfOwnerByIndex(owner, index)
}

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

func Render(path string) string {
	if path != "" {
		return "# GnoFish Sea\n\nUnknown path.\n"
	}
	return "# GnoFish Sea\n\nPerson versus person. The mint fee goes to the deploy wallet. A win pays 80% to the winner, 10% to liquidity, and 10% to the team. Portraits are https images. A seated fish cannot be listed.\n"
}

func gate(cur realm, pay int64) address {
	if !cur.Previous().IsUserCall() {
		panic("seafish: eoa")
	}
	if !inited || self == address("") {
		panic("seafish: init")
	}
	takeExact(pay)
	return cur.Previous().Address()
}

func payMint(fee int64, rlm realm) {
	send(mintTo, fee, rlm)
}

func splitKill(covered int64) (killer int64, lp int64, crew int64) {
	killer = covered * 80 / 100
	lp = covered * 10 / 100
	crew = covered - killer - lp
	return
}

func send(to address, amt int64, rlm realm) {
	if !rlm.IsCurrent() {
		panic("seafish: realm")
	}
	if amt == 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: denom, Amount: amt}})
}

func noteSupply(cur realm) {
	if !market {
		return
	}
	factory.NoteMinted(cross(cur), shown)
}

func grow() int {
	if minted >= maxMint || len(roster) != minted+1 {
		panic("seafish: mint")
	}
	roster = append(roster, fish{})
	minted++
	return minted
}

func mustFish(id int) *fish {
	if !inited || id < 1 || id > minted || id >= len(roster) {
		panic("seafish: fish")
	}
	return &roster[id]
}

func revealedFish(id int) *fish {
	row := mustFish(id)
	if !row.revealed {
		panic("seafish: uri")
	}
	return row
}

func pending(who address) int {
	for i := 1; i <= minted; i++ {
		if roster[i].owner == who && !roster[i].revealed {
			return i
		}
	}
	return 0
}

func seated(who address) bool {
	for i := 1; i <= minted; i++ {
		if roster[i].owner == who && roster[i].inSea {
			return true
		}
	}
	return false
}

func busy(row *fish) bool {
	return row.inSea || row.pool != 0 || row.mustHeal
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
	panic("seafish: name")
}

func nameTaken(name string) bool {
	for i := 1; i <= minted; i++ {
		if roster[i].revealed && roster[i].name == name {
			return true
		}
	}
	return false
}

func tierOf(rarity string) int {
	for i := 0; i < len(rarities); i++ {
		if rarities[i] == rarity {
			return i
		}
	}
	panic("seafish: roll")
}

func move(cur realm, from, to address, id int) {
	row := mustFish(id)
	if row.onSale || !row.revealed || busy(row) || !to.IsValid() || to == from {
		panic("seafish: transfer")
	}
	if err := teller.TransferFrom(0, cur, from, to, tidOf(id)); err != nil {
		panic("seafish: transfer")
	}
	row.owner = to
}

func ledgerMove(spender, from, to address, id int) {
	if err := ledger.TransferFrom(spender, from, to, tidOf(id)); err != nil {
		panic("seafish: transfer")
	}
}

func tidOf(id int) grc721.TokenID {
	return grc721.TokenID(strconv.Itoa(id))
}

func byToken(tid grc721.TokenID) (*fish, error) {
	if token == nil {
		return nil, errors.New("seafish: init")
	}
	if _, err := token.OwnerOf(tid); err != nil {
		return nil, err
	}
	id, err := strconv.Atoi(string(tid))
	if err != nil || id < 1 || id > minted || id >= len(roster) || !roster[id].revealed {
		return nil, errors.New("seafish: fish")
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
			panic("seafish: payment")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != n {
		panic("seafish: payment")
	}
}
