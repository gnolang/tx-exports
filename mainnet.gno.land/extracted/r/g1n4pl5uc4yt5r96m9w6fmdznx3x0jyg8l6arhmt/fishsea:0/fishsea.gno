// Package fishsea is the person-versus-person sea.
// CommitMint pays 150 GNOT and the whole fee goes to the wallet that called Init.
// RevealMint, once the chain is at least two blocks later, rolls rarity and trait
// from sha256 of the caller, the commit height, that fixed height plus two, and the id.
// Waiting longer does not change the roll. The player does not pass trait, size, or rarity.
// Swim stays off chain. Register locks at least 10 GNOT. Leave returns it after 5 seconds.
// Settle pays one covered stake: 80% winner, 10% liquidity, 10% team.
// There is no machine fish and no FISH draw.
// A seated wallet can settle any other seated fish. The realm does not replay the bite.
// fishlive stays as deployed. This package does not move it.
// fishsea-1.
package fishsea

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"strconv"
	"time"
)

const (
	denom          = "ugnot"
	mintFee  int64 = 150_000_000
	stakeMin int64 = 10_000_000
	quietMs  int64 = 5_000
	capFish        = 128
)

var (
	hpBase   = [6]int{100, 122, 148, 178, 214, 256}
	biteBase = [6]int{24, 30, 37, 45, 54, 66}
	spdBase  = [6]int{108, 104, 100, 96, 92, 88}
	species  = [6]string{"Bubble", "Tideblade", "Abysswing", "Embermaw", "Aurelion", "Astravex"}
	rarities = [6]string{"common", "uncommon", "rare", "epic", "legendary", "mythic"}
	traits   = [3]string{"swift", "fang", "hide"}
)

type fish struct {
	owner    address
	name     string
	rarity   string
	trait    string
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
}

var (
	inited  bool
	self    address
	mintTo  address
	lpSink  address
	team    address
	minted  int
	roster  []fish
)

// Init records the caller as the mint wallet, plus liquidity and team.
// Those three must be distinct. Call once, from an EOA, with no coins.
func Init(cur realm, lp, crew address) {
	if !cur.Previous().IsUserCall() {
		panic("fishsea: eoa")
	}
	takeExact(0)
	caller := cur.Previous().Address()
	if inited || !caller.IsValid() || !lp.IsValid() || !crew.IsValid() || caller == lp || caller == crew || lp == crew {
		panic("fishsea: init")
	}
	inited = true
	self = cur.Address()
	mintTo = caller
	lpSink = lp
	team = crew
	chain.Emit("Init", "mint", caller.String(), "lp", lp.String(), "team", crew.String())
}

// CommitMint sells one unrevealed fish for 150 GNOT. The fee leaves this realm in the same call.
func CommitMint(cur realm) int {
	caller := gate(cur, mintFee)
	if minted >= capFish || pending(caller) != 0 {
		panic("fishsea: mint")
	}
	height := runtime.ChainHeight()
	if height < 1 {
		panic("fishsea: mint")
	}
	id := grow()
	roster[id].owner = caller
	roster[id].commitH = height
	payMint(mintFee, cur)
	chain.Emit("Commit", "id", strconv.Itoa(id), "owner", caller.String())
	return id
}

// RevealMint assigns rarity, trait, and the species name. Entropy is the commit height plus two.
func RevealMint(cur realm, id int) {
	caller := gate(cur, 0)
	row := mustFish(id)
	entropyH := row.commitH + 2
	if row.owner != caller || row.revealed || runtime.ChainHeight() < entropyH {
		panic("fishsea: reveal")
	}
	rarity, trait, bite, hp, speed := Roll(caller, row.commitH, entropyH, id)
	row.rarity = rarity
	row.trait = trait
	row.bite = bite
	row.hpMax = hp
	row.hp = hp
	row.speed = speed
	row.name = pickName(tierOf(rarity))
	row.revealed = true
	chain.Emit("Reveal", "id", strconv.Itoa(id), "rarity", rarity, "trait", trait, "name", row.name)
}

// Register seats one revealed fish. The attached coins are the stake.
func Register(cur realm, id int, stake int64) {
	caller := gate(cur, stake)
	row := mustFish(id)
	if stake < stakeMin || row.owner != caller || !row.revealed || row.inSea || row.mustHeal || seated(caller) {
		panic("fishsea: register")
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
		panic("fishsea: leave")
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
		panic("fishsea: settle")
	}
	atk := mustFish(id)
	vic := mustFish(target)
	if atk.owner != caller || !atk.inSea || !vic.inSea || atk.owner == vic.owner || atk.pool < stakeMin || vic.pool < stakeMin {
		panic("fishsea: settle")
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

// Heal clears mustHeal outside the sea so Register can run again.
func Heal(cur realm, id int) {
	caller := gate(cur, 0)
	row := mustFish(id)
	if row.owner != caller || row.inSea || !row.mustHeal || !row.revealed {
		panic("fishsea: heal")
	}
	row.mustHeal = false
	row.hp = row.hpMax
	chain.Emit("Heal", "id", strconv.Itoa(id))
}

// Roll is the reveal hash. entropyH must be commitH+2. Trait adds 12%, half up.
func Roll(caller address, commitH int64, entropyH int64, id int) (rarity string, trait string, bite int, hp int, speed int) {
	if id < 1 || commitH < 1 || entropyH != commitH+2 {
		panic("fishsea: roll")
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

func Realm() address    { return self }
func MintTo() address   { return mintTo }
func Version() string   { return "fishsea-1" }
func Name() string      { return "GnoFish Sea" }
func Symbol() string    { return "SEA" }
func MintPrice() int64  { return mintFee }
func StakeMin() int64   { return stakeMin }
func Minted() int       { return minted }
func Height() int64     { return runtime.ChainHeight() }

func OwnerOf(id string) string {
	return mustFish(atoi(id)).owner.String()
}

func TokenURI(id string) string {
	row := mustFish(atoi(id))
	if !row.revealed {
		panic("fishsea: uri")
	}
	return `{"name":"` + row.name + `","image":""}`
}

func TokensOf(owner string) string {
	who := address(owner)
	if !who.IsValid() {
		return ""
	}
	out := ""
	for i := 1; i <= minted; i++ {
		if roster[i].owner != who {
			continue
		}
		if out != "" {
			out += ","
		}
		out += strconv.Itoa(i)
	}
	return out
}

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

func Pending(owner string) int {
	who := address(owner)
	if !who.IsValid() {
		return 0
	}
	return pending(who)
}

func Render(path string) string {
	if path != "" {
		return "# GnoFish Sea\n\nUnknown path.\n"
	}
	return "# GnoFish Sea\n\nPerson versus person. The mint fee goes to the deploy wallet. A win pays 80% to the winner, 10% to liquidity, and 10% to the team.\n"
}

func gate(cur realm, pay int64) address {
	if !cur.Previous().IsUserCall() {
		panic("fishsea: eoa")
	}
	if !inited || self == address("") {
		panic("fishsea: init")
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
		panic("fishsea: realm")
	}
	if amt == 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: denom, Amount: amt}})
}

func grow() int {
	if len(roster) == 0 {
		roster = append(roster, fish{})
	}
	if minted >= capFish || len(roster) != minted+1 {
		panic("fishsea: mint")
	}
	roster = append(roster, fish{})
	minted++
	return minted
}

func mustFish(id int) *fish {
	if !inited || id < 1 || id > minted || id >= len(roster) {
		panic("fishsea: fish")
	}
	return &roster[id]
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

func pickName(tier int) string {
	base := species[tier]
	if !nameTaken(base) {
		return base
	}
	for n := 2; n <= capFish; n++ {
		candidate := base + strconv.Itoa(n)
		if !nameTaken(candidate) {
			return candidate
		}
	}
	panic("fishsea: name")
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
	panic("fishsea: roll")
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("fishsea: payment")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != n {
		panic("fishsea: payment")
	}
}

func atoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		panic("fishsea: fish")
	}
	return n
}
