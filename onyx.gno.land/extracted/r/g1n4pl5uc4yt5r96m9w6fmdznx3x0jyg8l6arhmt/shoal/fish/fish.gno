// Package fish is the Shoal collection. Each fish is a GRC721 on this realm.
// List, cancel, buy, and Bite live here too. Gno cannot pull a foreign token into
// Bazaar, so the book is not a second package.
//
// Deployed on onyx-1 at gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/shoal/fish.
// Init does not call bazaarv2 Reserve or Register. The older fish and fish2 packages stay as they were.
package fish

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/grc721/metadata/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/shoal/shoaltoken"
)

const (
	denom        = "ugnot"
	ugnot        = 1_000_000
	layFee         = 2 * ugnot
	fishUnit       = 1_000_000
	twapUgnot      = 20_000
	upgradeFishFee = 15 * fishUnit
	protocolBps    = 200
	maxRoyalty   = 1000
	maxPrice     = 1_000_000 * ugnot
	// stakeCeil is MaxInt64/10000 so a bps split cannot overflow int64. It is not a game cap.
	stakeCeil    = 922337203685477
	combatLockMs = 5000
	layBlocks    = 2
	listCap      = 50
)

type fishBody struct {
	id              int
	name            string
	rarity          string
	species         string
	size            string
	trait           string
	hp              int
	hpNow           int
	dodge           int
	bouts           int
	layBoutsUsed    int
	layOpen         bool
	layHeight       int64
	pool            int64
	inMatch         bool
	boutPaid        bool
	mustHeal        bool
	startUnix       int64
	endUnix         int64
	sx              int
	sz              int
	faceDx          int
	faceDz          int
	growth          int
	evolved         bool
	aspect          string
	aspectBps       int
	healDay         int64
	healsUsed       int
	healReadyAt     int64
	springBorn      int64
	nextMoveMilli   int64
	burstUntil      int64
	nextBurstAt     int64
	nextBiteMilli   int64
	lastCombatMilli int64
	bittenBy        int
	bittenUntil     int64
	owner           address
	seller          address
	price           int64
	listed          bool
	burned          bool
	image           string
}

var (
	bodies       []*fishBody
	nextID       int
	minted       int
	inited       bool
	token        *grc721.Token
	ledger       *grc721.PrivateLedger
	metaView     *metadata.Metadata
	metaLed      *metadata.Ledger
	tokenSeq     seqid.ID
	creator      address
	self         address
	upgradeSink  address
	lpSink       address
	burnSink     address
	teamSink     address
	protocolSink address
	seasonSink   address
	fishReserve  address
	royaltyBps   int64
	imageBase    string
	portrait     string
	colName      string
	colSymbol    string
	mintFee      int64 = 50 * ugnot
	stakeMin     int64 = 10 * ugnot
)

func Init(cur realm, name, symbol, images string, royalty int64, upgrade, lp, burn, team, protocol, season address) {
	if !cur.IsCurrent() {
		panic("fish: realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("fish: eoa")
	}
	if inited {
		panic("fish: init")
	}
	takeExact(0)
	if !validCollectionName(name) || !validSymbol(symbol) {
		panic("fish: name")
	}
	if !strings.HasPrefix(images, "https://") || strings.Contains(images, "|") || len(images) > 160 {
		panic("fish: image")
	}
	if royalty < 0 || royalty > maxRoyalty {
		panic("fish: royalty")
	}
	if !upgrade.IsValid() || !lp.IsValid() || !burn.IsValid() || !team.IsValid() || !protocol.IsValid() || !season.IsValid() {
		panic("fish: sink")
	}
	tok, led := grc721.NewToken(name, symbol, tokenSeq.Next(), cur)
	token = tok
	ledger = led
	metaView, metaLed = metadata.NewMetadata(led)
	creator = cur.Previous().Address()
	self = cur.Address()
	upgradeSink = upgrade
	lpSink = lp
	burnSink = burn
	teamSink = team
	protocolSink = protocol
	seasonSink = season
	fishReserve = address("")
	royaltyBps = royalty
	imageBase = images
	colName = name
	colSymbol = symbol
	bodies = []*fishBody{nil}
	nextID = 0
	minted = 0
	inited = true
	chain.Emit("Init", "creator", creator.String(), "symbol", symbol)
}

func Mint(cur realm, name, size, trait string) int {
	caller := requireUser(cur)
	if unplayed(caller) {
		panic("fish: unplayed")
	}
	if !validFishName(name) {
		panic("fish: name")
	}
	if !validSize(size) {
		panic("fish: size")
	}
	if !validTrait(trait) {
		panic("fish: trait")
	}
	takeExact(mintFee)
	payMint(mintFee, cur)
	return issue(caller, name, "common", size, trait)
}

// SetArt sets one https image on every unburned fish. The creator may call it again.
func SetArt(cur realm, image string) {
	caller := requireUser(cur)
	requireInit()
	if caller != creator {
		panic("fish: owner")
	}
	takeExact(0)
	if !validArt(image) {
		panic("fish: image")
	}
	portrait = image
	for _, body := range bodies {
		if body == nil || body.burned {
			continue
		}
		body.image = image
		writeURI(body)
	}
	chain.Emit("SetArt", "image", image)
}

func Portrait() string {
	requireInit()
	return portrait
}

func Transfer(cur realm, to address, id int) {
	caller := requireUser(cur)
	takeExact(0)
	if !to.IsValid() || to == caller || to == self {
		panic("fish: addr")
	}
	body := must(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	guardMovable(body)
	moveToken(caller, caller, to, id)
	body.owner = to
}

func TransferFrom(cur realm, from, to, tid string) {
	caller := requireUser(cur)
	takeExact(0)
	id := parseID(tid)
	src := address(from)
	dst := address(to)
	if !src.IsValid() || !dst.IsValid() || dst == self {
		panic("fish: addr")
	}
	body := must(id)
	if body.owner != src {
		panic("fish: owner")
	}
	guardMovable(body)
	moveToken(caller, src, dst, id)
	body.owner = dst
}

func Approve(cur realm, to, tid string) {
	caller := requireUser(cur)
	takeExact(0)
	id := parseID(tid)
	body := must(id)
	guardMovable(body)
	who := address(to)
	if to != "" && !who.IsValid() {
		panic("fish: addr")
	}
	if err := ledger.Approve(caller, who, tokenID(id)); err != nil {
		panic("fish: approve")
	}
}

func SetApprovalForAll(cur realm, operator string, approved bool) {
	caller := requireUser(cur)
	takeExact(0)
	op := address(operator)
	if !op.IsValid() {
		panic("fish: addr")
	}
	if err := ledger.SetApprovalForAll(caller, op, approved); err != nil {
		panic("fish: approve")
	}
}

func OwnerOf(tid string) (address, error) {
	requireInit()
	id, err := strconv.Atoi(tid)
	if err != nil || id < 1 || id >= len(bodies) || bodies[id] == nil || bodies[id].burned {
		return address(""), errors.New("fish: unknown")
	}
	return bodies[id].owner, nil
}

func Name() string {
	requireInit()
	return token.GetName()
}

func Symbol() string {
	requireInit()
	return token.GetSymbol()
}

func GrcName() string   { return Name() }
func GrcSymbol() string { return Symbol() }

func BalanceOf(addr string) int64 {
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

func GrcBalanceOf(addr string) int64 { return BalanceOf(addr) }

func TokenURI(tid string) string {
	id := parseID(tid)
	must(id)
	uri, err := metaView.TokenURI(tokenID(id))
	if err != nil || uri == "" {
		panic("fish: uri")
	}
	return uri
}

func TokensOf(owner string) string {
	requireInit()
	who := address(owner)
	if !who.IsValid() {
		return ""
	}
	out := ""
	for _, body := range bodies {
		if body == nil || body.burned || body.owner != who {
			continue
		}
		if out != "" {
			out += ","
		}
		out += strconv.Itoa(body.id)
	}
	return out
}

func TokenOfOwnerByIndex(owner string, index int64) string {
	requireInit()
	who := address(owner)
	if !who.IsValid() {
		panic("fish: addr")
	}
	if index < 0 {
		panic("fish: index")
	}
	var seen int64
	for _, body := range bodies {
		if body == nil || body.burned || body.owner != who {
			continue
		}
		if seen == index {
			return strconv.Itoa(body.id)
		}
		seen++
	}
	panic("fish: index")
}

func TotalSupply() int64 {
	requireInit()
	return token.TotalSupply()
}

func GetApproved(id int) string {
	requireInit()
	who, err := token.GetApproved(tokenID(id))
	if err != nil || !who.IsValid() {
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

func MintPrice() int64   { return mintFee }
func StakeMin() int64    { return stakeMin }
func StakeCeil() int64   { return stakeCeil }
func Version() string    { return "fish-3" }

// SetFishReserve names the address whose FISH allowance pays a kill.
// The reserve must approve this realm. This does not mint FISH.
func SetFishReserve(cur realm, who address) {
	caller := requireUser(cur)
	takeExact(0)
	requireInit()
	if caller != creator {
		panic("fish: owner")
	}
	if !who.IsValid() {
		panic("fish: sink")
	}
	fishReserve = who
	chain.Emit("SetFishReserve", "who", who.String())
}

func FishReserve() address { return fishReserve }

// SetMintFee changes the next mint price. The default is 50 GNOT.
func SetMintFee(cur realm, next int64) {
	caller := requireUser(cur)
	takeExact(0)
	requireInit()
	if caller != creator {
		panic("fish: owner")
	}
	if next < ugnot || next > 1000*ugnot {
		panic("fish: fee")
	}
	mintFee = next
	chain.Emit("SetMintFee", "ugnot", strconv.FormatInt(next, 10))
}

// SetStakeMin changes the sea floor. There is no product maximum. stakeCeil stays the integer ceiling.
func SetStakeMin(cur realm, next int64) {
	caller := requireUser(cur)
	takeExact(0)
	requireInit()
	if caller != creator {
		panic("fish: owner")
	}
	if next < ugnot || next > stakeCeil {
		panic("fish: stake")
	}
	stakeMin = next
	chain.Emit("SetStakeMin", "ugnot", strconv.FormatInt(next, 10))
}
func MaxSupply() int     { return 0 }
func Minted() int        { return minted }
func RoyaltyBps() int64  { return royaltyBps }
func Creator() address   { return creator }
func ProtocolBps() int64 { return protocolBps }

func BoutsOf(id int) int      { return must(id).bouts }
func PoolOf(id int) int64     { return must(id).pool }
func Listed(id int) bool      { return must(id).listed }
func InMatch(id int) bool     { return must(id).inMatch }
func LayOpen(id int) bool     { return must(id).layOpen }
func RarityOf(id int) string  { return must(id).rarity }
func SizeOf(id int) string    { return must(id).size }
func TraitOf(id int) string   { return must(id).trait }
func SpeciesOf(id int) string { return must(id).species }

func issue(to address, name, rarity, size, trait string) int {
	nextID++
	id := nextID
	maxHP := hpOf(rarity, size, trait)
	body := &fishBody{
		id:      id,
		name:    name,
		rarity:  rarity,
		species: speciesOf(rarity),
		size:    size,
		trait:   trait,
		hp:      maxHP,
		hpNow:   maxHP,
		dodge:           dodgeOf(size),
		faceDx:          0,
		faceDz:          -1,
		aspectBps:       10000,
		springBorn:      -1,
		lastCombatMilli: -1,
		owner:           to,
		image:   artOf(rarity),
	}
	for len(bodies) <= id {
		bodies = append(bodies, nil)
	}
	bodies[id] = body
	minted++
	mintGRC(to, body)
	return id
}

func mintGRC(to address, body *fishBody) {
	tid := tokenID(body.id)
	if err := ledger.Mint(to, tid); err != nil {
		panic("fish: mint")
	}
	writeURI(body)
}

func writeURI(body *fishBody) {
	if err := metaLed.SetTokenURI(tokenID(body.id), tokenJSON(body)); err != nil {
		panic("fish: uri")
	}
}

func artOf(rarity string) string {
	if portrait != "" {
		return portrait
	}
	return imageBase + "/" + rarity + ".png"
}

func burnGRC(id int) {
	if err := ledger.Burn(tokenID(id)); err != nil {
		panic("fish: burn")
	}
}

func moveToken(spender, from, to address, id int) {
	if err := ledger.TransferFrom(spender, from, to, tokenID(id)); err != nil {
		panic("fish: transfer")
	}
}

func tokenJSON(body *fishBody) string {
	return "data:application/json;charset=utf-8," +
		`{"name":"` + body.name + `","description":"Shoal fish","image":"` + body.image +
		`","attributes":[{"trait_type":"Species","value":"` + body.species +
		`"},{"trait_type":"Size","value":"` + body.size +
		`"},{"trait_type":"Trait","value":"` + body.trait +
		`"},{"trait_type":"Rarity","value":"` + body.rarity +
		`"},{"trait_type":"HP","value":"` + strconv.Itoa(body.hp) + `"}]}`
}

func requireUser(cur realm) address {
	if !cur.IsCurrent() {
		panic("fish: realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("fish: eoa")
	}
	return cur.Previous().Address()
}

func requireInit() {
	if !inited || token == nil {
		panic("fish: init")
	}
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("fish: payment")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != n {
		panic("fish: payment")
	}
}

func payMint(fee int64, rlm realm) {
	up := fee * 6000 / 10000
	lp := fee * 2000 / 10000
	team := fee * 1000 / 10000
	burn := fee - up - lp - team
	send(upgradeSink, up, rlm)
	send(lpSink, lp, rlm)
	send(teamSink, team, rlm)
	send(burnSink, burn, rlm)
}

func fishTokenReady() bool {
	return self != address("") && shoaltoken.Sealed() && shoaltoken.Spender() == self
}

func send(to address, amt int64, rlm realm) {
	if amt == 0 {
		return
	}
	if !to.IsValid() {
		panic("fish: sink")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: denom, Amount: amt}})
}

func must(id int) *fishBody {
	requireInit()
	if id < 1 || id >= len(bodies) || bodies[id] == nil || bodies[id].burned {
		panic("fish: unknown")
	}
	return bodies[id]
}

func guardMovable(body *fishBody) {
	if body.listed {
		panic("fish: listed")
	}
	if body.inMatch {
		panic("fish: match")
	}
	if body.pool != 0 {
		panic("fish: pool")
	}
	if body.layOpen {
		panic("fish: lay")
	}
}

func unplayed(owner address) bool {
	for _, body := range bodies {
		if body == nil || body.burned || body.bouts >= 1 {
			continue
		}
		if body.owner == owner || (body.listed && body.seller == owner) {
			return true
		}
	}
	return false
}

func tokenID(id int) grc721.TokenID {
	return grc721.TokenID(strconv.Itoa(id))
}

func parseID(tid string) int {
	id, err := strconv.Atoi(tid)
	if err != nil || id < 1 {
		panic("fish: unknown")
	}
	return id
}

func validFishName(name string) bool {
	if len(name) < 1 || len(name) > 20 {
		return false
	}
	for _, c := range name {
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') && c != ' ' {
			return false
		}
	}
	return true
}

func validCollectionName(name string) bool {
	return name != "" && len(name) <= 64 && !strings.Contains(name, "|")
}

func validArt(image string) bool {
	if !strings.HasPrefix(image, "https://") || len(image) > 160 || strings.Contains(image, "|") {
		return false
	}
	if strings.Contains(image, `"`) || strings.Contains(image, "\n") || strings.Contains(image, "\\") {
		return false
	}
	return true
}

func validSymbol(symbol string) bool {
	if symbol == "" || len(symbol) > grc721.MaxSymbolLen {
		return false
	}
	for _, c := range symbol {
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

func validSize(size string) bool {
	return size == "small" || size == "medium" || size == "large"
}

func validTrait(trait string) bool {
	return trait == "swift" || trait == "fang" || trait == "hide"
}

func speciesOf(rarity string) string {
	switch rarity {
	case "common":
		return "Minnow"
	case "uncommon":
		return "Mackerel"
	case "rare":
		return "Snapper"
	case "epic":
		return "Angler"
	case "legendary":
		return "Koi Dragon"
	case "mythic":
		return "Abyss Leviathan"
	default:
		panic("fish: rarity")
	}
}

func hpBase(rarity string) int {
	switch rarity {
	case "common":
		return 100
	case "uncommon":
		return 112
	case "rare":
		return 126
	case "epic":
		return 142
	case "legendary":
		return 160
	case "mythic":
		return 180
	default:
		panic("fish: rarity")
	}
}

func hpOf(rarity, size, trait string) int {
	hp := hpBase(rarity)
	if size == "small" {
		hp = hp * 88 / 100
	}
	if size == "large" {
		hp = hp * 120 / 100
	}
	if trait == "hide" {
		hp = hp * 112 / 100
	}
	if hp < 1 {
		hp = 1
	}
	return hp
}

func dodgeOf(size string) int {
	if size == "small" {
		return 24
	}
	return 0
}

func arenaStake(stake int64) bool {
	return stake >= stakeMin && stake <= stakeCeil
}
