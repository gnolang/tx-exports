package taproom

// Taproom realm: 2/3 Game round engine with stakes, permissionless settlement, pull payouts,
// and a time-window weekly streak. The commit-reveal lifecycle of each round (windows, sealed
// picks, reveals, who did not reveal) runs on the commitreveal package.

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1vxsg6ht4nklaud70yaszcgkhc9ttancr9nlzzq/commitreveal/v0"
	"gno.land/p/nt/avl/v0"
)

const (
	denom       = "ugnot"
	weekSeconds = int64(604800)
	// Unix time zero fell on a Thursday; 4 days shifts week boundaries to Monday 00:00 UTC.
	weekOffset = int64(345600)

	pointsPlay = int64(10)
	pointsWin  = int64(30)
	streakStep = int64(4)
	streakCap  = int64(20)
	freezeCost = int64(40)
	maxFreezes = 2

	// Caps: players per round, open rounds per creator, window bounds.
	maxPlayers    = 10
	maxOpenRounds = 3
	minWindow     = int64(60)
	maxWindow     = int64(86400)

	// Cosmetic slots: hat, outfit, held item, companion (Player.Equipped order).
	slotCount = 4

	// Board skins: 0 = Oak table (free, owned by everyone), 1 = Moonlit, 2 = Gold-trim.
	skinCount = 3

	// Target fraction of the average: fixed at 2/3 in the MVP, stored per round.
	entryFee = int64(1000000) // 1 GNOT per seat

	// Salts shorter than this let anyone guess a pick from its hash (there are only 101 picks).
	minSaltLen = 16
	maxSaltLen = 128 // salts are kept and shown in RoundJSON, so they stay short and printable

	targetNum = int64(2)
	targetDen = int64(3)

	// Protocol fee in basis points (50 = 0.5%), taken from the pot of a completed round only.
	feeBps   = int64(50)
	bpsTotal = int64(10000)
)

// skinPrice is the points price per board skin ID; Oak (0) is free.
var skinPrice = []int64{0, 150, 400}

var (
	feeRecipient address // set once at deploy; can only withdraw accrued fees
	feesAccrued  int64
)

func init() {
	feeRecipient = unsafe.OriginCaller()
}

// nowOverride lets tests control time; zero means use the block time.
var nowOverride int64

// Seat is one player's place at a round, in join order (the order of Seal.Players()). A short list
// per round instead of trees keyed by address: a round has at most maxPlayers seats.
type Seat struct {
	Commit string // the hash sealed at Join; kept for RoundJSON so anyone can re-check the reveal
	Pick   int64  // set at Reveal
	Salt   string // public once revealed
	Bonus  int64  // streak bonus earned at reveal; paid only if the round completes
}

type Round struct {
	ID        int
	Creator   address
	Start     int64
	Seal      *commitreveal.Session // windows, commits, reveals and join order
	Seats     []Seat                // one per player, in join order
	Settled   bool
	Pot       int64
	Fee       int64
	Winners   []address
	BoardSkin int
	Num, Den  int64 // target fraction of the average; 2/3 in the MVP
}

type Player struct {
	Lifetime  int64
	Spent     int64
	HasPlayed bool
	LastWeek  int64
	Streak    int64
	Freezes   int
	Skins     []int  // owned board skins other than the free Oak table
	Owned     []int  // cosmetic item IDs
	Equipped  [4]int // item ID per slot (hat, outfit, held, companion); 0 = nothing

	// Leaderboard stats, updated at Join and Settle.
	Net        int64 // ugnot credited minus entry fees paid
	Wins       int64 // completed rounds won (a split win counts)
	Scored     int64 // revealed picks in completed rounds
	DistSum100 int64 // sum of distances to the target in those rounds, in hundredths
	BestStreak int64 // longest weekly streak reached

	Joined bool // has joined a round; only such players are listed on boards
}

var (
	roundTree     = avl.NewTree() // roundKey(id) -> *Round
	roundCount    int
	openRounds    = avl.NewTree() // roundKey(id) -> true while the round is not settled
	openByCreator = avl.NewTree() // address -> int, open rounds per creator (the 3-round cap)
	recentSettled []int           // the last 5 completed round IDs, oldest first
	players       = avl.NewTree() // address -> *Player
	claimable     = avl.NewTree() // address -> int64
)

// roundKey pads round IDs so the tree keeps them in numeric order.
func roundKey(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func openCount(a address) int {
	if v := openByCreator.Get(a.String()); v != nil {
		return v.(int)
	}
	return 0
}

// visibleASCII reports whether s has only printable ASCII characters other than space.
func visibleASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x21 || s[i] > 0x7e {
			return false
		}
	}
	return true
}

func now() int64 {
	if nowOverride != 0 {
		return nowOverride
	}
	return time.Now().Unix()
}

// weekIndex returns the Monday-00:00-UTC-aligned week number of a Unix timestamp.
func weekIndex(ts int64) int64 {
	d := ts - weekOffset
	w := d / weekSeconds
	if d%weekSeconds < 0 {
		w--
	}
	return w
}

// CommitHash is the value a player submits when joining round roundID:
// hex(sha256("<roundID>:<player address>:<pick>:<salt>")). Binding the round and the player means
// a hash copied from someone else's Join cannot be opened by the copier, nor reused in another round.
func CommitHash(roundID int, player address, pick int64, salt string) string {
	return commitreveal.Hash(sealedValue(roundID, player, pick), salt)
}

// sealedValue is what a round's Seal commits to for a player's pick.
func sealedValue(roundID int, player address, pick int64) string {
	return strconv.Itoa(roundID) + ":" + player.String() + ":" + strconv.FormatInt(pick, 10)
}

// mustUser requires a direct wallet call that sends no coins: only Join takes a deposit, and coins
// sent with any other call would be stranded in the realm.
func mustUser(cur realm) address {
	a := mustUserCall(cur)
	noCoins()
	return a
}

func mustUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("direct user call required")
	}
	return cur.Previous().Address()
}

func noCoins() {
	if len(unsafe.OriginSend()) != 0 {
		panic("this call takes no coins")
	}
}

func getRound(id int) *Round {
	if id < 0 || id >= roundCount {
		panic("unknown round")
	}
	return roundTree.Get(roundKey(id)).(*Round)
}

// seatOf returns the index of a's seat in r (join order), or -1.
func seatOf(r *Round, a address) int {
	for i, p := range r.Seal.Players() {
		if p == a {
			return i
		}
	}
	return -1
}

func getPlayer(a address) *Player {
	v := players.Get(a.String())
	if v == nil {
		p := &Player{}
		players.Set(a.String(), p)
		return p
	}
	return v.(*Player)
}

func credit(a address, amt int64) {
	cur := int64(0)
	if v := claimable.Get(a.String()); v != nil {
		cur = v.(int64)
	}
	claimable.Set(a.String(), cur+amt)
	getPlayer(a).Net += amt
}

// ownsSkin reports whether a may use a board skin: Oak (0) is free for everyone.
func ownsSkin(a address, skin int) bool {
	if skin == 0 {
		return true
	}
	v := players.Get(a.String())
	if v == nil {
		return false
	}
	for _, s := range v.(*Player).Skins {
		if s == skin {
			return true
		}
	}
	return false
}

// NewRound opens a round. commitSecs and revealSecs are window lengths in seconds.
// The creator must own boardSkin (Oak table, ID 0, is owned by everyone).
func NewRound(cur realm, commitSecs, revealSecs int64, boardSkin int) int {
	creator := mustUser(cur)
	if commitSecs < minWindow || revealSecs < minWindow || commitSecs > maxWindow || revealSecs > maxWindow {
		panic("windows must be 1 minute to 24 hours")
	}
	if boardSkin < 0 || boardSkin >= skinCount {
		panic("unknown board skin")
	}
	if !ownsSkin(creator, boardSkin) {
		panic("creator does not own this board skin")
	}
	open := openCount(creator)
	if open >= maxOpenRounds {
		panic("you already have 3 open rounds")
	}
	t := now()
	r := &Round{
		ID:        roundCount,
		Creator:   creator,
		Start:     t,
		Seal:      commitreveal.New(t, commitSecs, revealSecs),
		BoardSkin: boardSkin,
		Num:       targetNum,
		Den:       targetDen,
	}
	roundTree.Set(roundKey(r.ID), r)
	roundCount++
	openRounds.Set(roundKey(r.ID), true)
	openByCreator.Set(creator.String(), open+1)
	return r.ID
}

// Join deposits the entry fee and stores a hidden pick.
func Join(cur realm, roundID int, commit string) {
	caller := mustUserCall(cur) // the one call that takes coins: exactly the entry fee, checked below
	r := getRound(roundID)
	t := now()
	if r.Seal.Phase(t) != commitreveal.CommitPhase {
		panic("commit window closed")
	}
	if r.Seal.Has(caller) {
		panic("already joined")
	}
	if r.Seal.Count() >= maxPlayers {
		panic("round is full")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != entryFee {
		panic("must send exactly the entry fee in ugnot")
	}
	if commit != strings.ToLower(commit) {
		panic("commit must be lowercase hex") // Reveal compares against lowercase sha256 hex
	}
	if err := r.Seal.Commit(t, caller, commit); err != nil {
		panic(err.Error())
	}
	r.Seats = append(r.Seats, Seat{Commit: commit})
	r.Pot += entryFee
	pl := getPlayer(caller)
	pl.Net -= entryFee
	pl.Joined = true
	reindex(caller)
}

// Reveal opens the pick; it must match the commit. It moves the streak (in block-time order)
// and records the bonus; points are paid at Settle, and only if the round completes.
func Reveal(cur realm, roundID int, pick int64, salt string) {
	caller := mustUser(cur)
	r := getRound(roundID)
	t := now()
	if pick < 0 || pick > 100 {
		panic("pick must be 0..100")
	}
	if len(salt) < minSaltLen || len(salt) > maxSaltLen || !visibleASCII(salt) {
		panic("salt must be 16 to 128 visible ASCII characters")
	}
	if err := r.Seal.Reveal(t, caller, sealedValue(roundID, caller, pick), salt); err != nil {
		panic(err.Error())
	}
	i := seatOf(r, caller)
	r.Seats[i].Pick, r.Seats[i].Salt, r.Seats[i].Bonus = pick, salt, updateStreak(caller, t)
	reindex(caller)
}

// Settle can be called by anyone once the reveal window has closed, including other realms and
// scripts (a keeper or scheduler, for example): it reads no caller and pays the same whoever calls.
// It is the one write without mustUser. A wallet calling it directly must still send no coins.
func Settle(cur realm, roundID int) {
	if cur.Previous().IsUserCall() {
		noCoins()
	}
	r := getRound(roundID)
	if now() < r.Seal.RevealEnd {
		panic("reveal window still open")
	}
	if r.Settled {
		panic("already settled")
	}
	r.Settled = true // effects before any payout bookkeeping
	openRounds.Remove(roundKey(r.ID))
	openByCreator.Set(r.Creator.String(), openCount(r.Creator)-1)
	defer func() { // board positions move with the credits and points below
		for _, p := range r.Seal.Players() {
			reindex(p)
		}
	}()

	var revealers []address
	var sum int64
	for _, o := range r.Seal.Revealed() { // join order
		revealers = append(revealers, o.Who)
		sum += r.Seats[seatOf(r, o.Who)].Pick
	}
	n := int64(len(revealers))

	// Fewer than two reveals: void round, everyone is refunded. No points.
	if n < 2 {
		for _, p := range r.Seal.Players() {
			credit(p, entryFee)
		}
		return
	}

	// Completed round: every revealer gets play points plus the bonus recorded at reveal.
	for _, p := range revealers {
		getPlayer(p).Lifetime += pointsPlay + r.Seats[seatOf(r, p)].Bonus
	}

	// Winner is closest to num/den of the average: minimise |den*n*pick - num*sum| (integer math).
	best := int64(-1)
	var winners []address
	for _, p := range revealers {
		d := r.Den*n*r.Seats[seatOf(r, p)].Pick - r.Num*sum
		if d < 0 {
			d = -d
		}
		// distance to the target = d / (den*n); kept in hundredths for the Sharpest guesses board
		pl := getPlayer(p)
		pl.Scored++
		pl.DistSum100 += (d*200 + r.Den*n) / (2 * r.Den * n) // rounded to the nearest hundredth
		if best < 0 || d < best {
			best = d
			winners = []address{p}
		} else if d == best {
			winners = append(winners, p)
		}
	}

	// Completed round (at least two reveals): take the fee, split the rest.
	fee := r.Pot * feeBps / bpsTotal
	r.Fee = fee
	feesAccrued += fee
	prize := r.Pot - fee

	count := int64(len(winners))
	share := prize / count
	rem := prize - share*count
	for i, w := range winners {
		amt := share
		if i == 0 {
			amt += rem
		}
		credit(w, amt)
		getPlayer(w).Lifetime += pointsWin - pointsPlay
		getPlayer(w).Wins++
	}
	r.Winners = winners

	// Recent results list completed rounds only, so empty or void rounds cannot push them off.
	recentSettled = append(recentSettled, r.ID)
	if len(recentSettled) > 5 {
		recentSettled = recentSettled[len(recentSettled)-5:]
	}
}

// Claim pays out the caller's balance (pull payment).
func Claim(cur realm) {
	caller := mustUser(cur)
	v := claimable.Get(caller.String())
	if v == nil || v.(int64) <= 0 {
		panic("nothing to claim")
	}
	amt := v.(int64)
	claimable.Set(caller.String(), int64(0)) // effects before interaction
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), caller, chain.NewCoins(chain.NewCoin(denom, amt)))
}

// WithdrawFees sends accrued protocol fees to the fee recipient. It touches nothing else.
func WithdrawFees(cur realm) {
	caller := mustUser(cur)
	if caller != feeRecipient {
		panic("only the fee recipient can withdraw fees")
	}
	amt := feesAccrued
	if amt <= 0 {
		panic("no fees to withdraw")
	}
	feesAccrued = 0 // effects before interaction
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), caller, chain.NewCoins(chain.NewCoin(denom, amt)))
}

// updateStreak moves the weekly streak for a play at ts and returns that play's bonus.
// Calls arrive in block-time order because Reveal calls it.
func updateStreak(a address, ts int64) int64 {
	p := getPlayer(a)
	w := weekIndex(ts)
	if !p.HasPlayed {
		p.Streak = 1
		p.LastWeek = w
	} else {
		g := w - p.LastWeek
		if g >= 1 {
			if p.Streak == 0 {
				// the streak was already reset for missed weeks: start again, keep any freezes
				p.Streak = 1
			} else if g == 1 {
				p.Streak++
			} else {
				missed := int(g - 1)
				if p.Freezes >= missed {
					p.Freezes -= missed
					p.Streak++
				} else {
					// not enough freezes: the streak resets and every held freeze is used up
					p.Streak = 1
					p.Freezes = 0
				}
			}
			p.LastWeek = w
		}
	}
	if p.Streak > p.BestStreak {
		p.BestStreak = p.Streak
	}
	p.HasPlayed = true
	bonus := streakStep * p.Streak
	if bonus > streakCap {
		bonus = streakCap
	}
	return bonus
}

// applyMissedWeeks spends freezes on weeks already missed before week w, as the next Reveal would.
// With too few freezes the streak drops to 0 and every freeze is used up; the next play starts week 1.
func applyMissedWeeks(p *Player, w int64) {
	if !p.HasPlayed || p.Streak == 0 {
		return
	}
	missed := int(w - p.LastWeek - 1)
	if missed <= 0 {
		return
	}
	if p.Freezes >= missed {
		p.Freezes -= missed
	} else {
		p.Streak = 0
		p.Freezes = 0
	}
	p.LastWeek = w - 1
}

// BuyFreeze spends points on a streak freeze (max 2 held). Weeks already missed are applied first,
// so a new freeze cannot cover a past week and a stale count cannot block the purchase.
func BuyFreeze(cur realm) {
	caller := mustUser(cur)
	p := getPlayer(caller)
	applyMissedWeeks(p, weekIndex(now()))
	if p.Freezes >= maxFreezes {
		panic("freeze limit reached")
	}
	if p.Lifetime-p.Spent < freezeCost {
		panic("not enough points")
	}
	p.Spent += freezeCost
	p.Freezes++
}

// BuySkin spends points on a board skin (Moonlit or Gold-trim). Oak is free and always owned.
func BuySkin(cur realm, skin int) {
	caller := mustUser(cur)
	if skin <= 0 || skin >= skinCount {
		panic("unknown or free board skin")
	}
	if ownsSkin(caller, skin) {
		panic("skin already owned")
	}
	p := getPlayer(caller)
	price := skinPrice[skin]
	if p.Lifetime-p.Spent < price {
		panic("not enough points")
	}
	p.Spent += price
	p.Skins = append(p.Skins, skin)
}

// itemPrice returns the points price of a cosmetic item, or -1 for an unknown ID.
// itemID = slotBase + n with slotBase 100 hat, 200 outfit, 300 held, 400 companion and n = 1..12.
// Rarity by n: 1, 5, 6 common 40; 2, 7, 8 rare 150; 3, 9, 10 epic 400; 4, 11, 12 legendary 1000.
func itemPrice(id int) int64 {
	slot, n := id/100, id%100
	if slot < 1 || slot > slotCount || n < 1 || n > 12 {
		return -1
	}
	switch n {
	case 1, 5, 6:
		return 40
	case 2, 7, 8:
		return 150
	case 3, 9, 10:
		return 400
	}
	return 1000
}

func ownsItem(p *Player, id int) bool {
	for _, o := range p.Owned {
		if o == id {
			return true
		}
	}
	return false
}

// BuyItem spends points on a cosmetic item. Items cannot be traded and never affect outcomes.
func BuyItem(cur realm, itemID int) {
	caller := mustUser(cur)
	price := itemPrice(itemID)
	if price < 0 {
		panic("unknown item")
	}
	p := getPlayer(caller)
	if ownsItem(p, itemID) {
		panic("item already owned")
	}
	if p.Lifetime-p.Spent < price {
		panic("not enough points")
	}
	p.Spent += price
	p.Owned = append(p.Owned, itemID)
}

// Equip wears an owned item in its slot (0 hat, 1 outfit, 2 held, 3 companion); itemID 0 takes it off.
func Equip(cur realm, slot int, itemID int) {
	caller := mustUser(cur)
	if slot < 0 || slot >= slotCount {
		panic("unknown slot")
	}
	p := getPlayer(caller)
	if itemID != 0 {
		if !ownsItem(p, itemID) {
			panic("item not owned")
		}
		if itemID/100 != slot+1 {
			panic("item does not fit this slot")
		}
	}
	p.Equipped[slot] = itemID
	reindex(caller)
}

// Views (non-crossing)

func OwnsSkin(a address, skin int) bool { return ownsSkin(a, skin) }

func Claimable(a address) int64 {
	if v := claimable.Get(a.String()); v != nil {
		return v.(int64)
	}
	return 0
}

func PlayerStats(a address) (lifetime, spendable, streak int64, freezes int) {
	v := players.Get(a.String())
	if v == nil {
		return 0, 0, 0, 0
	}
	p := v.(*Player)
	return p.Lifetime, p.Lifetime - p.Spent, p.Streak, p.Freezes
}
