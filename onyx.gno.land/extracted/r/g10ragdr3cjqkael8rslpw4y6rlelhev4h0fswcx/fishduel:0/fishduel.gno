// Package fishduel is a two-person trial.
// Swim stays off chain. Settle pays one covered stake from three sealed samples.
// Each player binds an ed25519 mark key at Register. The realm cannot check a loose
// secp256k1 wallet signature. There is no machine fish and no FISH draw.
// shoal/fish stays the live collection. Mint is 1 GNOT and the stake floor is 1 GNOT.
// A sample note is bout:seq:height:id:x:z:time:secret:sig
// The mark signs the sha256 of bout,seq,height,id,x,z,time,secret joined by commas.
// secret is 32 lowercase hex chars. sig is 128 lowercase hex chars. The public key is 64.
package fishduel

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

const (
	denom          = "ugnot"
	unit     int64 = 1_000_000
	mintFee  int64 = 1_000_000
	stakeMin int64 = 1_000_000
	biteStat       = 69
	hpStat         = 88
	reach          = 2
	hitGap   int64 = 2_400
	cellMs   int64 = 320
	quietMs  int64 = 60_000
	seatMax        = 8
	box            = 32
	stepCap        = 16
	packMax        = 2_400
)

type swimmer struct {
	owner   address
	name    string
	pool    int64
	hp      int
	inSea   bool
	ended   bool
	markSet bool
	mark    [32]byte
}

type note struct {
	bout   int
	seq    int
	height int64
	id     int
	x      int
	z      int
	at     int64
	secret string
	sig    string
}

var (
	inited     bool
	self       address
	lpSink     address
	team       address
	burn       address
	minted     int
	openBout   int
	boutOpen   bool
	seatMilli  int64
	seatHeight int64
	roster     [seatMax + 1]swimmer
)

// Init records three GNOT sinks. They must be distinct. Call once, from an EOA, with no coins.
// The mint fee is 60/20/10 and the last tenth joins team. Kill cheer also joins team.
func Init(cur realm, lp, crew, ash address) {
	if !cur.Previous().IsUserCall() {
		panic("fishduel: eoa")
	}
	takeExact(0)
	if inited {
		panic("fishduel: init")
	}
	if !lp.IsValid() || !crew.IsValid() || !ash.IsValid() || lp == crew || lp == ash || crew == ash {
		panic("fishduel: addr")
	}
	inited = true
	self = cur.Address()
	lpSink = lp
	team = crew
	burn = ash
	chain.Emit("Init", "self", self.String())
}

// Mint sells one trial fish for 1 GNOT. The fee leaves this realm in the same call.
func Mint(cur realm, name string) int {
	caller := gate(cur, mintFee)
	if minted >= seatMax || !validName(name) {
		panic("fishduel: mint")
	}
	minted++
	roster[minted] = swimmer{owner: caller, name: name, hp: hpStat}
	payMint(mintFee, cur)
	chain.Emit("Mint", "id", strconv.Itoa(minted), "owner", caller.String())
	return minted
}

// Register seats a fish and binds its mark key. The attached coins are the stake.
func Register(cur realm, id int, stake int64, pub string) {
	caller := gate(cur, stake)
	if stake < stakeMin {
		panic("fishduel: stake")
	}
	fish := mustFish(id)
	if fish.owner != caller || fish.inSea || fish.ended || fish.markSet || seated(caller) || seatedCount() >= 2 {
		panic("fishduel: register")
	}
	raw := mustHex(pub, 32)
	for i := 0; i < 32; i++ {
		fish.mark[i] = raw[i]
	}
	fish.markSet = true
	fish.pool = stake
	fish.inSea = true
	if seatedCount() == 2 {
		openBout++
		boutOpen = true
		seatMilli = time.Now().UnixMilli()
		seatHeight = runtime.ChainHeight()
	}
	chain.Emit("Register", "id", strconv.Itoa(id), "bout", strconv.Itoa(openBout))
}

// Leave returns the seated stake. While the other fish is seated, Leave waits 60 seconds.
func Leave(cur realm, id int) {
	caller := gate(cur, 0)
	fish := mustFish(id)
	if fish.owner != caller || !fish.inSea {
		panic("fishduel: leave")
	}
	if otherSeated(id) && time.Now().UnixMilli() < seatMilli+quietMs {
		panic("fishduel: leave")
	}
	if otherSeated(id) {
		boutOpen = false
	}
	stake := fish.pool
	fish.pool = 0
	fish.inSea = false
	send(fish.owner, stake, cur)
	chain.Emit("Leave", "id", strconv.Itoa(id), "stake", strconv.FormatInt(stake, 10))
}

// Settle pays a kill from six notes, killer then victim, three samples, separated by slashes.
func Settle(cur realm, id, target int, pack string) {
	caller := gate(cur, 0)
	if !boutOpen || id == target || len(pack) == 0 || len(pack) > packMax {
		panic("fishduel: settle")
	}
	atk := mustFish(id)
	vic := mustFish(target)
	if atk.owner != caller || !atk.inSea || !vic.inSea || atk.owner == vic.owner || atk.pool < stakeMin || vic.pool < stakeMin {
		panic("fishduel: settle")
	}
	notes := strings.Split(pack, "/")
	if len(notes) != 6 {
		panic("fishduel: note")
	}
	var got [3][2]note
	for i := 0; i < 6; i++ {
		got[i/2][i%2] = parseNote(notes[i])
	}
	checkNotes(id, target, got)
	covered := atk.pool
	if vic.pool < covered {
		covered = vic.pool
	}
	excess := vic.pool - covered
	owner := vic.owner
	vic.hp = 0
	vic.pool = 0
	vic.inSea = false
	vic.ended = true
	boutOpen = false
	killer, lp, crew, buyback := splitKill(covered)
	send(atk.owner, killer, cur)
	send(lpSink, lp, cur)
	send(team, crew, cur)
	send(burn, buyback, cur)
	send(owner, excess, cur)
	chain.Emit("Kill", "id", strconv.Itoa(id), "target", strconv.Itoa(target), "covered", strconv.FormatInt(covered, 10))
}

// Strike is floor(bite * 100 / (hpMax + 100)), at least 1.
func Strike(bite, hpMax int) int {
	if bite < 1 {
		bite = 1
	}
	if hpMax < 0 {
		hpMax = 0
	}
	dmg := bite * 100 / (hpMax + 100)
	if dmg < 1 {
		return 1
	}
	return dmg
}

func Realm() address         { return self }
func Version() string        { return "fishduel-1" }
func MintPrice() int64       { return mintFee }
func StakeMin() int64        { return stakeMin }
func Minted() int            { return minted }
func Bout() int              { return openBout }
func BoutOpen() bool         { return boutOpen }
func SeatHeight() int64      { return seatHeight }
func Height() int64          { return runtime.ChainHeight() }
func Now() int64             { return time.Now().UnixMilli() }
func OwnerOf(id int) address { return mustFish(id).owner }
func PoolOf(id int) int64    { return mustFish(id).pool }
func HpOf(id int) int        { return mustFish(id).hp }
func InSea(id int) bool      { return mustFish(id).inSea }
func Ended(id int) bool      { return mustFish(id).ended }

func MarkOf(id int) string {
	fish := mustFish(id)
	if !fish.markSet {
		return ""
	}
	return hex.EncodeToString(fish.mark[:])
}

func Render(path string) string {
	if path != "" {
		return "# Fishduel\n\nUnknown path.\n"
	}
	return "# Fishduel\n\nTwo-person trial. Mint, Register, Settle, and Leave. This is not the shoal/fish collection.\n"
}

func gate(cur realm, pay int64) address {
	if !cur.Previous().IsUserCall() {
		panic("fishduel: eoa")
	}
	requireInit()
	takeExact(pay)
	return cur.Previous().Address()
}

func checkNotes(id, target int, got [3][2]note) {
	hp := hpStat
	var prevH int64
	var prevT int64
	var ax, az, bx, bz int
	for i := 0; i < 3; i++ {
		a := got[i][0]
		b := got[i][1]
		if a.bout != openBout || b.bout != openBout || a.seq != i+1 || b.seq != i+1 {
			panic("fishduel: sample")
		}
		if a.height != b.height || a.height < seatHeight || a.height > runtime.ChainHeight() {
			panic("fishduel: sample")
		}
		if i > 0 && (a.height <= prevH || a.at-prevT < hitGap) {
			panic("fishduel: sample")
		}
		if a.id != id || b.id != target || !inBox(a.x, a.z) || !inBox(b.x, b.z) {
			panic("fishduel: sample")
		}
		if gap(a.x, a.z, b.x, b.z) > reach {
			panic("fishduel: range")
		}
		if i > 0 && (gap(ax, az, a.x, a.z) > stepMax(a.at-prevT) || gap(bx, bz, b.x, b.z) > stepMax(a.at-prevT)) {
			panic("fishduel: step")
		}
		if !signed(id, a) || !signed(target, b) {
			panic("fishduel: sig")
		}
		dmg := Strike(biteStat, hpStat)
		if i < 2 {
			if hp <= dmg {
				panic("fishduel: hp")
			}
			hp -= dmg
		} else if hp > dmg || a.at > time.Now().UnixMilli() {
			panic("fishduel: hp")
		}
		prevH = a.height
		prevT = a.at
		ax, az, bx, bz = a.x, a.z, b.x, b.z
	}
}

func signed(id int, n note) bool {
	fish := mustFish(id)
	if !fish.markSet || n.id != id {
		return false
	}
	sum := sha256.Sum256([]byte(canon(n)))
	sig := mustHex(n.sig, 64)
	return ed25519.Verify(fish.mark[:], sum[:], sig)
}

func canon(n note) string {
	return strconv.Itoa(n.bout) + "," + strconv.Itoa(n.seq) + "," + strconv.FormatInt(n.height, 10) + "," + strconv.Itoa(n.id) + "," + strconv.Itoa(n.x) + "," + strconv.Itoa(n.z) + "," + strconv.FormatInt(n.at, 10) + "," + n.secret
}

func parseNote(raw string) note {
	p := strings.Split(raw, ":")
	if len(p) != 9 || len(p[7]) != 32 || len(p[8]) != 128 {
		panic("fishduel: note")
	}
	return note{atoi(p[0]), atoi(p[1]), atoi64(p[2]), atoi(p[3]), atoi(p[4]), atoi(p[5]), atoi64(p[6]), p[7], p[8]}
}

func stepMax(dt int64) int {
	n := int(dt / cellMs)
	if n < 1 {
		return 1
	}
	if n > stepCap {
		return stepCap
	}
	return n
}

func gap(ax, az, bx, bz int) int {
	dx := ax - bx
	if dx < 0 {
		dx = -dx
	}
	dz := az - bz
	if dz < 0 {
		dz = -dz
	}
	if dx > dz {
		return dx
	}
	return dz
}

func inBox(x, z int) bool {
	return x >= -box && x <= box && z >= -box && z <= box
}

func splitKill(covered int64) (killer, lp, crew, buyback int64) {
	killer = covered * 80 / 100
	lp = covered * 10 / 100
	teamPart := covered * 3 / 100
	buyback = covered * 3 / 100
	cheer := covered * 4 / 100
	buyback += covered - killer - lp - teamPart - buyback - cheer
	crew = teamPart + cheer
	return
}

func payMint(fee int64, rlm realm) {
	lp := fee * 6000 / 10000
	crew := fee * 2000 / 10000
	ash := fee * 1000 / 10000
	send(lpSink, lp, rlm)
	send(team, crew+fee-lp-crew-ash, rlm)
	send(burn, ash, rlm)
}

func send(to address, amt int64, rlm realm) {
	if !rlm.IsCurrent() {
		panic("fishduel: realm")
	}
	if amt == 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: denom, Amount: amt}})
}

func mustFish(id int) *swimmer {
	requireInit()
	if id < 1 || id > minted {
		panic("fishduel: fish")
	}
	return &roster[id]
}

func seated(who address) bool {
	for i := 1; i <= minted; i++ {
		if roster[i].owner == who && roster[i].inSea {
			return true
		}
	}
	return false
}

func seatedCount() int {
	n := 0
	for i := 1; i <= minted; i++ {
		if roster[i].inSea {
			n++
		}
	}
	return n
}

func otherSeated(id int) bool {
	for i := 1; i <= minted; i++ {
		if i != id && roster[i].inSea {
			return true
		}
	}
	return false
}

func validName(name string) bool {
	if len(name) < 1 || len(name) > 16 {
		return false
	}
	for _, c := range name {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

func requireInit() {
	if !inited || self == address("") {
		panic("fishduel: init")
	}
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("fishduel: payment")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != n {
		panic("fishduel: payment")
	}
}

func mustHex(s string, n int) []byte {
	if len(s) != n*2 {
		panic("fishduel: hex")
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			panic("fishduel: hex")
		}
	}
	raw, err := hex.DecodeString(s)
	if err != nil || len(raw) != n {
		panic("fishduel: hex")
	}
	return raw
}

func atoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		panic("fishduel: note")
	}
	return n
}

func atoi64(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("fishduel: note")
	}
	return n
}
