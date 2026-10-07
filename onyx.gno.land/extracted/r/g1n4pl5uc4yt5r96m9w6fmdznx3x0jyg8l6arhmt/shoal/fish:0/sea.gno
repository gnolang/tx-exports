package fish

import (
	"chain/runtime/unsafe"
	"math"
	"time"
)

// One shared sea. Cells are 8 world units. A sector center is the chain position.
// Springs and shelter discs use the same layout as the practice sea. No RNG.

const (
	seaRadius         = 360
	sector            = 8
	unitMilli         = 1000
	sectorMilli       = 8000
	mouthAlignNum     = 552264
	mouthContact      = 1000
	healsPerDay       = 2
	healPercent       = 40
	healCooldownMs    = 8 * 3600 * 1000
	ictOffsetMs       = 7 * 3600 * 1000
	dayMs             = 24 * 3600 * 1000
	springPeriodMs    = 20000
	springLifeMs      = 15000
	springRadiusMilli = 3000
	springHealPercent = 20
	shelterHPMax      = 64
	shelterRebuildMs  = 20000
	burstWindowMs     = 1000
	burstCoolMs       = 2000
	viewerShards      = 10
	viewerWatchMs     = 15000
	viewerWindowMs    = 30000
	minCheer          = ugnot
	growMediumAt      = 2
	growLargeAt       = 4
	growEvolveAt      = 6
)

type cheerRow struct {
	fish   int
	who    address
	amount int64
	live   bool
}

type claimRow struct {
	who     address
	amount  int64
	kind    string
	killAt  int64
	expires int64
	claimed bool
	killer  address
	victim  address
	killID  int
}

type watchRow struct {
	who   address
	since int64
}

type disc struct {
	x     int
	z     int
	r     int
	inner int
	kind  string
}

var (
	cheers      []cheerRow
	claims      []claimRow
	watches     []watchRow
	killSeq     int
	shelterHP   []int
	shelterDown []int64
	shelterTable = []disc{
		{x: 96_000, z: 8_000, inner: 5_200, kind: "reef"},
		{x: -120_000, z: 72_000, inner: 5_600, kind: "reef"},
		{x: 28_000, z: -110_000, inner: 4_400, kind: "cave"},
		{x: -140_000, z: 150_000, inner: 4_400, kind: "cave"},
	}
	rockTable = []disc{
		{x: 18_000, z: -24_000, r: 3_600},
		{x: -8_000, z: 48_000, r: 3_600},
		{x: 120_000, z: -48_000, r: 4_200},
	}
)

func Turn(cur realm, id, dx, dz int) {
	caller := requireUser(cur)
	takeExact(0)
	body := must(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	if !body.inMatch || body.pool <= 0 {
		panic("fish: match")
	}
	if dx < -1 || dx > 1 || dz < -1 || dz > 1 || (dx == 0 && dz == 0) {
		panic("fish: face")
	}
	body.faceDx = dx
	body.faceDz = dz
}

func Move(cur realm, id int) {
	caller := requireUser(cur)
	takeExact(0)
	body := swimming(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	now := time.Now().UnixMilli()
	if now < body.nextMoveMilli {
		panic("fish: move")
	}
	stepFish(body, now)
}

func Burst(cur realm, id int) {
	caller := requireUser(cur)
	takeExact(0)
	body := swimming(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	now := time.Now().UnixMilli()
	if now < body.nextBurstAt {
		return
	}
	body.burstUntil = now + burstWindowMs
	body.nextBurstAt = body.burstUntil + burstCoolMs
}

func Heal(cur realm, id int) {
	caller := requireUser(cur)
	takeExact(0)
	body := must(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	if body.inMatch {
		panic("fish: match")
	}
	now := time.Now().UnixMilli()
	day, used, ready := rolledHeal(body, now)
	if body.hpNow >= body.hp && !body.mustHeal {
		panic("fish: hp")
	}
	if used >= healsPerDay || now < ready {
		panic("fish: heal")
	}
	used++
	if used >= healsPerDay {
		ready = now + healCooldownMs
	}
	writeHeal(body, day, used, ready)
	gain := body.hp * healPercent / 100
	body.hpNow += gain
	if body.hpNow > body.hp {
		body.hpNow = body.hp
	}
	if body.hpNow < 1 {
		body.hpNow = 1
	}
	body.mustHeal = false
}

func RushHeal(cur realm, id int) {
	caller := requireUser(cur)
	body := must(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	now := time.Now().UnixMilli()
	day, used, ready := rolledHeal(body, now)
	if used < healsPerDay || now >= ready {
		panic("fish: heal")
	}
	remaining := ready - now
	cost := int64(tierOf(body.rarity)) * remaining * ugnot / (16 * 3_600_000)
	takeExact(cost)
	writeHeal(body, day, healsPerDay-1, 0)
	send(burnSink, cost, cur)
}

// Cheer locks ugnot on a fish already in the sea. The deposit comes back when
// that fish leaves or is downed. It does not change bite.
func Cheer(cur realm, id int) {
	caller := requireUser(cur)
	body := must(id)
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount < minCheer {
		panic("fish: payment")
	}
	amount := sent[0].Amount
	if caller == body.owner {
		panic("fish: cheer")
	}
	if !liveFish(body, time.Now().Unix()) {
		panic("fish: match")
	}
	if cheerLocked(id)+amount > body.pool/2 {
		panic("fish: cap")
	}
	cheers = append(cheers, cheerRow{fish: id, who: caller, amount: amount, live: true})
}

func Watch(cur realm, on bool) {
	caller := requireUser(cur)
	takeExact(0)
	if !on {
		dropWatch(caller)
		return
	}
	for i := range watches {
		if watches[i].who == caller {
			return
		}
	}
	watches = append(watches, watchRow{who: caller, since: time.Now().UnixMilli()})
}

func Claim(cur realm, id int) {
	caller := requireUser(cur)
	takeExact(0)
	if id < 1 || id > len(claims) {
		panic("fish: claim")
	}
	row := &claims[id-1]
	if row.claimed {
		panic("fish: claim")
	}
	now := time.Now().UnixMilli()
	if row.expires > 0 && now >= row.expires {
		amt := row.amount
		row.claimed = true
		row.amount = 0
		send(seasonSink, amt, cur)
		return
	}
	if row.kind == "watch" {
		if caller == row.killer || caller == row.victim {
			panic("fish: claim")
		}
		if !watchEligible(caller, row.killAt) {
			panic("fish: watch")
		}
		if watchClaimed(caller, row.killID) {
			panic("fish: claim")
		}
		row.who = caller
	} else if row.who != caller {
		panic("fish: owner")
	}
	amt := row.amount
	row.claimed = true
	row.amount = 0
	send(caller, amt, cur)
}

func swimming(id int) *fishBody {
	body := must(id)
	if !liveFish(body, time.Now().Unix()) {
		panic("fish: match")
	}
	if body.mustHeal {
		panic("fish: heal")
	}
	return body
}

func walletInSea(owner address) bool {
	for _, body := range bodies {
		if body == nil || body.burned || !body.inMatch {
			continue
		}
		if body.owner == owner {
			return true
		}
	}
	return false
}

func tooHurt(body *fishBody) bool {
	if body.hp <= 0 {
		return true
	}
	return body.hpNow*100 < body.hp*30
}

func placeSwimmer(body *fishBody) {
	ensureSea()
	for sx := 0; sx < 90; sx++ {
		if tryPlace(body, sx, 0) {
			return
		}
	}
	for sz := 1; sz < 40; sz++ {
		for sx := -40; sx < 40; sx++ {
			if tryPlace(body, sx, sz) {
				return
			}
		}
	}
	panic("fish: sea")
}

func tryPlace(body *fishBody, sx, sz int) bool {
	if spawnBlocked(sx, sz) || cellTaken(sx, sz, body.id) {
		return false
	}
	body.sx = sx
	body.sz = sz
	body.faceDx = 0
	body.faceDz = -1
	return true
}

func stepFish(body *fishBody, now int64) {
	if body.faceDx == 0 && body.faceDz == 0 {
		panic("fish: face")
	}
	nx := body.sx + body.faceDx
	nz := body.sz + body.faceDz
	if !sectorInSea(nx, nz) {
		panic("fish: sea")
	}
	if cellBlocked(nx, nz, body.size, now) {
		panic("fish: cover")
	}
	body.sx = nx
	body.sz = nz
	body.nextMoveMilli = now + moveDelay(body, now)
	touchSpring(body, now)
}

func sectorInSea(sx, sz int) bool {
	x, z := cellMilli(sx, sz)
	dx := int64(x)
	dz := int64(z)
	limit := int64(seaRadius * unitMilli)
	return dx*dx+dz*dz <= limit*limit
}

func cellTaken(sx, sz, self int) bool {
	for _, body := range bodies {
		if body == nil || body.burned || body.id == self || !body.inMatch {
			continue
		}
		if body.sx == sx && body.sz == sz {
			return true
		}
	}
	return false
}

func spawnBlocked(sx, sz int) bool {
	if !sectorInSea(sx, sz) {
		return true
	}
	ensureSea()
	for i := range rockTable {
		if discHolds(sx, sz, rockTable[i].x, rockTable[i].z, rockTable[i].r) {
			return true
		}
	}
	now := time.Now().UnixMilli()
	for i := range shelterTable {
		refreshShelter(i, now)
		if shelterHP[i] <= 0 {
			continue
		}
		if discHolds(sx, sz, shelterTable[i].x, shelterTable[i].z, shelterTable[i].inner) {
			return true
		}
	}
	return false
}

func cellBlocked(sx, sz int, size string, now int64) bool {
	if !sectorInSea(sx, sz) {
		return true
	}
	ensureSea()
	for i := range rockTable {
		if discHolds(sx, sz, rockTable[i].x, rockTable[i].z, rockTable[i].r) {
			return true
		}
	}
	for i := range shelterTable {
		refreshShelter(i, now)
		if shelterHP[i] <= 0 || shelterAdmits(shelterTable[i].kind, size) {
			continue
		}
		if discHolds(sx, sz, shelterTable[i].x, shelterTable[i].z, shelterTable[i].inner) {
			return true
		}
	}
	return false
}

func cellMilli(sx, sz int) (int, int) {
	return sx*sectorMilli + sectorMilli/2, sz*sectorMilli + sectorMilli/2
}

func insideDisc(x, z, cx, cz, r int) bool {
	dx := int64(x - cx)
	dz := int64(z - cz)
	rr := int64(r)
	return dx*dx+dz*dz <= rr*rr
}

func ensureSea() {
	if len(shelterHP) == len(shelterTable) && len(shelterDown) == len(shelterTable) {
		return
	}
	shelterHP = make([]int, len(shelterTable))
	shelterDown = make([]int64, len(shelterTable))
	for i := range shelterHP {
		shelterHP[i] = shelterHPMax
	}
}

func refreshShelter(i int, now int64) {
	ensureSea()
	if shelterHP[i] > 0 {
		return
	}
	if shelterDown[i] > 0 && now >= shelterDown[i] {
		shelterHP[i] = shelterHPMax
		shelterDown[i] = 0
	}
}

func shelterAdmits(kind, size string) bool {
	if size == "large" {
		return false
	}
	if kind == "cave" {
		return size == "small"
	}
	return size == "small" || size == "medium"
}

func coverIndex(body *fishBody, now int64) int {
	ensureSea()
	for i := range shelterTable {
		refreshShelter(i, now)
		if shelterHP[i] <= 0 || !shelterAdmits(shelterTable[i].kind, body.size) {
			continue
		}
		if discHolds(body.sx, body.sz, shelterTable[i].x, shelterTable[i].z, shelterTable[i].inner) {
			return i
		}
	}
	return -1
}

func redirectShelter(atk, vic *fishBody, now int64) bool {
	idx := coverIndex(vic, now)
	if idx < 0 || shelterAdmits(shelterTable[idx].kind, atk.size) {
		return false
	}
	if discHolds(atk.sx, atk.sz, shelterTable[idx].x, shelterTable[idx].z, shelterTable[idx].inner) {
		return false
	}
	dmg := strikeDamage(biteNow(atk), shelterHPMax, atk.size, "medium")
	if dmg > shelterHP[idx] {
		dmg = shelterHP[idx]
	}
	shelterHP[idx] -= dmg
	if shelterHP[idx] <= 0 {
		shelterHP[idx] = 0
		shelterDown[idx] = now + shelterRebuildMs
	}
	return true
}

func mouthHit(atk, def *fishBody) bool {
	return mouthAimed(atk, def, def.dodge)
}

// shelterMouth is a bite against the pocket, not against the fish's dodge.
// The attacker must stand outside, must not fit inside, and must face the fish.
func shelterMouth(atk, vic *fishBody, now int64) bool {
	idx := coverIndex(vic, now)
	if idx < 0 || shelterAdmits(shelterTable[idx].kind, atk.size) {
		return false
	}
	if discHolds(atk.sx, atk.sz, shelterTable[idx].x, shelterTable[idx].z, shelterTable[idx].inner) {
		return false
	}
	return mouthAimed(atk, vic, 0)
}

// Sector centers sit off the practice discs, same as a spring on z = 0.
// The cell that holds the point counts as inside.
func discHolds(sx, sz, cx, cz, r int) bool {
	x, z := cellMilli(sx, sz)
	if insideDisc(x, z, cx, cz, r) {
		return true
	}
	px := int(math.Floor(float64(cx) / float64(sectorMilli)))
	pz := int(math.Floor(float64(cz) / float64(sectorMilli)))
	return sx == px && sz == pz
}

func mouthAimed(atk, def *fishBody, dodge int) bool {
	if !inReachDodge(atk, def, dodge) {
		return false
	}
	ax, az := cellMilli(atk.sx, atk.sz)
	bx, bz := cellMilli(def.sx, def.sz)
	dx := bx - ax
	dz := bz - az
	dist2 := int64(dx)*int64(dx) + int64(dz)*int64(dz)
	if dist2 <= int64(mouthContact)*int64(mouthContact) {
		return true
	}
	fx, fz := faceMilli(atk.faceDx, atk.faceDz)
	lead := mouthLead(atk.size)
	mx := dx - fx*lead/1000
	mz := dz - fz*lead/1000
	mouth2 := int64(mx)*int64(mx) + int64(mz)*int64(mz)
	if mouth2 == 0 {
		return true
	}
	dot := int64(mx)*int64(fx) + int64(mz)*int64(fz)
	if dot <= 0 {
		return false
	}
	return dot*dot >= int64(mouthAlignNum)*mouth2
}

func faceMilli(dx, dz int) (int, int) {
	if dx == 0 && dz == 0 {
		return 0, -1000
	}
	span := dx*dx + dz*dz
	if span == 1 {
		return dx * 1000, dz * 1000
	}
	if span == 2 {
		sx := 707
		sz := 707
		if dx < 0 {
			sx = -707
		}
		if dz < 0 {
			sz = -707
		}
		return sx, sz
	}
	return 0, -1000
}

func mouthLead(size string) int {
	switch size {
	case "small":
		return 700
	case "large":
		return 1450
	default:
		return 1000
	}
}

func biteNow(body *fishBody) int {
	b := biteOf(body.rarity, body.size, body.trait)
	if body.evolved && body.aspectBps > 0 {
		b = (b*body.aspectBps + 5000) / 10000
	}
	if b < 1 {
		return 1
	}
	return b
}

func strikeFought(bite, hpMax int, atkSize, defSize, atkR, defR string) int {
	dmg := bite * 100 / (hpMax + 100)
	if dmg < 1 {
		dmg = 1
	}
	if defR == preyOf(atkR) {
		dmg = dmg * 3 / 2
		if dmg < 1 {
			dmg = 1
		}
		return dmg
	}
	if sizeIndex(atkSize)-sizeIndex(defSize) >= 2 {
		dmg = dmg * 5000 / 10000
		if dmg < 1 {
			dmg = 1
		}
	}
	if atkR == preyOf(defR) {
		dmg = dmg * 2 / 3
		if dmg < 1 {
			dmg = 1
		}
	}
	return dmg
}

func preyOf(rarity string) string {
	switch rarity {
	case "common":
		return "mythic"
	case "uncommon":
		return "common"
	case "rare":
		return "uncommon"
	case "epic":
		return "rare"
	case "legendary":
		return "epic"
	case "mythic":
		return "legendary"
	default:
		panic("fish: rarity")
	}
}

func nextRarity(rarity string) string {
	switch rarity {
	case "common":
		return "uncommon"
	case "uncommon":
		return "rare"
	case "rare":
		return "epic"
	case "epic":
		return "legendary"
	case "legendary":
		return "mythic"
	default:
		return ""
	}
}

func growFromKill(atk, vic *fishBody) {
	if sizeIndex(vic.size) >= sizeIndex(atk.size)+1 {
		atk.growth += 2
	} else {
		atk.growth++
	}
	next := atk.size
	if next == "small" && atk.growth >= growMediumAt {
		next = "medium"
	}
	if next == "medium" && atk.growth >= growLargeAt {
		next = "large"
	}
	if next != atk.size {
		old := atk.hp
		if old < 1 {
			old = 1
		}
		atk.size = next
		atk.hp = hpOf(atk.rarity, next, atk.trait)
		atk.dodge = dodgeOf(next)
		atk.hpNow = atk.hpNow * atk.hp / old
		if atk.hpNow < 1 {
			atk.hpNow = 1
		}
		if atk.hpNow > atk.hp {
			atk.hpNow = atk.hp
		}
	}
	if atk.evolved || atk.size != "large" || atk.growth < growEvolveAt {
		return
	}
	aspect := nextRarity(atk.rarity)
	if aspect == "" {
		return
	}
	atk.evolved = true
	atk.aspect = aspect
	atk.aspectBps = 10800
	atk.hp = (atk.hp*108 + 50) / 100
	if atk.hp < 1 {
		atk.hp = 1
	}
	atk.hpNow = (atk.hpNow*108 + 50) / 100
	if atk.hpNow < 1 {
		atk.hpNow = 1
	}
	if atk.hpNow > atk.hp {
		atk.hpNow = atk.hp
	}
}

func worldSpeed(body *fishBody) int {
	base := 100
	switch body.rarity {
	case "common":
		base = 100
	case "uncommon":
		base = 97
	case "rare":
		base = 94
	case "epic":
		base = 91
	case "legendary":
		base = 88
	case "mythic":
		base = 85
	default:
		panic("fish: rarity")
	}
	units := base * 220 / 1000
	if body.size == "small" {
		units = units * 116 / 100
	}
	if body.size == "large" {
		units = units * 88 / 100
	}
	if body.trait == "swift" {
		units = units * 112 / 100
	}
	if units < 1 {
		return 1
	}
	return units
}

func moveDelay(body *fishBody, now int64) int64 {
	units := worldSpeed(body)
	if now < body.burstUntil {
		units = units * 7 / 4
	}
	if units < 1 {
		units = 1
	}
	delay := int64(sector*1000) / int64(units)
	if delay < 1 {
		return 1
	}
	return delay
}

func tierOf(rarity string) int {
	switch rarity {
	case "common":
		return 1
	case "uncommon":
		return 2
	case "rare":
		return 3
	case "epic":
		return 4
	case "legendary":
		return 5
	case "mythic":
		return 6
	default:
		panic("fish: rarity")
	}
}

func rolledHeal(body *fishBody, now int64) (day int64, used int, ready int64) {
	day = (now + ictOffsetMs) / dayMs
	used = body.healsUsed
	ready = body.healReadyAt
	if body.healDay != day {
		used = 0
		ready = 0
	}
	if used >= healsPerDay && ready > 0 && now >= ready {
		used = healsPerDay - 1
		ready = 0
	}
	return
}

func writeHeal(body *fishBody, day int64, used int, ready int64) {
	body.healDay = day
	body.healsUsed = used
	body.healReadyAt = ready
}

func cheerLocked(id int) int64 {
	var n int64
	for i := range cheers {
		if cheers[i].live && cheers[i].fish == id {
			n += cheers[i].amount
		}
	}
	return n
}

func returnCheers(body *fishBody, rlm realm) {
	for i := range cheers {
		if !cheers[i].live || cheers[i].fish != body.id {
			continue
		}
		amt := cheers[i].amount
		who := cheers[i].who
		cheers[i].live = false
		cheers[i].amount = 0
		send(who, amt, rlm)
	}
}

func bookCheerClaims(atk, vic *fishBody, cheer, now int64) int64 {
	if cheer <= 0 {
		return 0
	}
	var weights []int
	var owners []address
	for i := range cheers {
		if !cheers[i].live || cheers[i].fish != atk.id || cheers[i].amount <= 0 {
			continue
		}
		weights = append(weights, int(cheers[i].amount))
		owners = append(owners, cheers[i].who)
	}
	if len(weights) == 0 {
		return 0
	}
	shares := splitWeights(cheer, weights, owners[0], owners)
	killSeq++
	var placed int64
	for i, share := range shares {
		if share <= 0 {
			continue
		}
		claims = append(claims, claimRow{
			who:     owners[i],
			amount:  share,
			kind:    "cheer",
			killAt:  now,
			killer:  atk.owner,
			victim:  vic.owner,
			killID:  killSeq,
		})
		placed += share
	}
	return placed
}

func bookWatchClaims(atk, vic *fishBody, viewer, now int64) int64 {
	if viewer <= 0 || !anyEligible(atk.owner, vic.owner, now) {
		return 0
	}
	shard := viewer / int64(viewerShards)
	if shard <= 0 {
		return 0
	}
	killSeq++
	var placed int64
	for i := 0; i < viewerShards; i++ {
		claims = append(claims, claimRow{
			amount:  shard,
			kind:    "watch",
			killAt:  now,
			expires: now + viewerWindowMs,
			killer:  atk.owner,
			victim:  vic.owner,
			killID:  killSeq,
		})
		placed += shard
	}
	return placed
}

func anyEligible(killer, victim address, killAt int64) bool {
	for i := range watches {
		if watchEligible(watches[i].who, killAt) && watches[i].who != killer && watches[i].who != victim {
			return true
		}
	}
	return false
}

func watchEligible(who address, killAt int64) bool {
	for i := range watches {
		if watches[i].who == who && watches[i].since <= killAt-viewerWatchMs {
			return true
		}
	}
	return false
}

func watchClaimed(who address, killID int) bool {
	for i := range claims {
		if claims[i].claimed && claims[i].kind == "watch" && claims[i].killID == killID && claims[i].who == who {
			return true
		}
	}
	return false
}

func dropWatch(who address) {
	next := make([]watchRow, 0, len(watches))
	for i := range watches {
		if watches[i].who != who {
			next = append(next, watches[i])
		}
	}
	watches = next
}

func springMilli(now int64) (x, z int, born int64, ok bool) {
	if now < 0 {
		return 0, 0, 0, false
	}
	slot := now / springPeriodMs
	born = slot * springPeriodMs
	if now >= born+springLifeMs {
		return 0, 0, born, false
	}
	angle := math.Mod(float64(slot)*2.399963, 2*math.Pi)
	radius := 48 + (slot*17)%9*22
	x = int(math.Floor(math.Cos(angle)*float64(radius)*1000 + 0.5))
	z = int(math.Floor(math.Sin(angle)*float64(radius)*1000 + 0.5))
	return x, z, born, true
}

func springTouches(sx, sz, springX, springZ int) bool {
	fx, fz := cellMilli(sx, sz)
	dx := int64(fx - springX)
	dz := int64(fz - springZ)
	limit := int64(springRadiusMilli)
	if dx*dx+dz*dz <= limit*limit {
		return true
	}
	ssx := int(math.Floor(float64(springX) / float64(sectorMilli)))
	ssz := int(math.Floor(float64(springZ) / float64(sectorMilli)))
	return sx == ssx && sz == ssz
}

func touchSpring(body *fishBody, now int64) {
	if body == nil || body.burned || body.mustHeal || !body.inMatch || body.pool <= 0 {
		return
	}
	x, z, born, ok := springMilli(now)
	if !ok || body.springBorn == born {
		return
	}
	if !springTouches(body.sx, body.sz, x, z) {
		return
	}
	body.springBorn = born
	gain := body.hp * springHealPercent / 100
	if gain < 1 {
		gain = 1
	}
	body.hpNow += gain
	if body.hpNow > body.hp {
		body.hpNow = body.hp
	}
}
