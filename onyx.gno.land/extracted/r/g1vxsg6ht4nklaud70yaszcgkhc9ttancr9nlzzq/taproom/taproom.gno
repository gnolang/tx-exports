package taproom

// Feasibility spike: 2/3 Game round engine with stakes, commit-reveal,
// permissionless settlement, pull payouts, and a time-window weekly streak.

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

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

	// Protocol fee in basis points (50 = 0.5%), taken from the pot of a completed round only.
	feeBps   = int64(50)
	bpsTotal = int64(10000)
)

var entryFee int64 = 1000000

var (
	feeRecipient address // set once at deploy; can only withdraw accrued fees
	feesAccrued  int64
)

func init() {
	feeRecipient = unsafe.OriginCaller()
}

// nowOverride lets tests control time; zero means use the block time.
var nowOverride int64

type Entry struct {
	Commit   string
	Revealed bool
	Pick     int64
}

type Round struct {
	ID        int
	CommitEnd int64
	RevealEnd int64
	Players   []address
	Entries   *avl.Tree // address -> *Entry
	Settled   bool
	Pot       int64
	Fee       int64
	Winners   []address
}

type Player struct {
	Lifetime  int64
	Spent     int64
	HasPlayed bool
	LastWeek  int64
	Streak    int64
	Freezes   int
}

var (
	rounds    []*Round
	players   = avl.NewTree() // address -> *Player
	claimable = avl.NewTree() // address -> int64
)

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

// CommitHash is the value a player submits when joining: sha256("<pick>:<salt>") as hex.
func CommitHash(pick int64, salt string) string {
	sum := sha256.Sum256([]byte(strconv.FormatInt(pick, 10) + ":" + salt))
	return hex.EncodeToString(sum[:])
}

func mustUser(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("direct user call required")
	}
	return cur.Previous().Address()
}

func getRound(id int) *Round {
	if id < 0 || id >= len(rounds) {
		panic("unknown round")
	}
	return rounds[id]
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
}

// NewRound opens a round. commitSecs and revealSecs are window lengths in seconds.
func NewRound(cur realm, commitSecs, revealSecs int64) int {
	if commitSecs <= 0 || revealSecs <= 0 {
		panic("windows must be positive")
	}
	t := now()
	r := &Round{
		ID:        len(rounds),
		CommitEnd: t + commitSecs,
		RevealEnd: t + commitSecs + revealSecs,
		Entries:   avl.NewTree(),
	}
	rounds = append(rounds, r)
	return r.ID
}

// Join deposits the entry fee and stores a hidden pick.
func Join(cur realm, roundID int, commit string) {
	caller := mustUser(cur)
	r := getRound(roundID)
	if now() >= r.CommitEnd {
		panic("commit window closed")
	}
	if len(commit) != 64 {
		panic("commit must be 64 hex chars")
	}
	if r.Entries.Has(caller.String()) {
		panic("already joined")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != entryFee {
		panic("must send exactly the entry fee in ugnot")
	}
	r.Entries.Set(caller.String(), &Entry{Commit: commit})
	r.Players = append(r.Players, caller)
	r.Pot += entryFee
}

// Reveal opens the pick; it must match the commit. Counts as a play for points and streak.
func Reveal(cur realm, roundID int, pick int64, salt string) {
	caller := mustUser(cur)
	r := getRound(roundID)
	t := now()
	if t < r.CommitEnd || t >= r.RevealEnd {
		panic("not in reveal window")
	}
	v := r.Entries.Get(caller.String())
	if v == nil {
		panic("not a player in this round")
	}
	e := v.(*Entry)
	if e.Revealed {
		panic("already revealed")
	}
	if pick < 0 || pick > 100 {
		panic("pick must be 0..100")
	}
	if CommitHash(pick, salt) != e.Commit {
		panic("reveal does not match commit")
	}
	e.Revealed = true
	e.Pick = pick
	awardPlay(caller, t)
}

// Settle can be called by anyone once the reveal window has closed.
func Settle(cur realm, roundID int) {
	r := getRound(roundID)
	if now() < r.RevealEnd {
		panic("reveal window still open")
	}
	if r.Settled {
		panic("already settled")
	}
	r.Settled = true // effects before any payout bookkeeping

	var revealers []address
	var sum int64
	for _, p := range r.Players {
		e := r.Entries.Get(p.String()).(*Entry)
		if e.Revealed {
			revealers = append(revealers, p)
			sum += e.Pick
		}
	}
	n := int64(len(revealers))

	// Fewer than two reveals: void round, everyone is refunded.
	if n < 2 {
		for _, p := range r.Players {
			credit(p, entryFee)
		}
		return
	}

	// Winner is closest to 2/3 of the average: minimise |3*n*pick - 2*sum| (integer math).
	best := int64(-1)
	var winners []address
	for _, p := range revealers {
		e := r.Entries.Get(p.String()).(*Entry)
		d := 3*n*e.Pick - 2*sum
		if d < 0 {
			d = -d
		}
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
	}
	r.Winners = winners
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

func awardPlay(a address, ts int64) {
	p := getPlayer(a)
	w := weekIndex(ts)
	if !p.HasPlayed {
		p.Streak = 1
		p.LastWeek = w
	} else {
		g := w - p.LastWeek
		if g >= 1 {
			if g == 1 {
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
	p.HasPlayed = true
	bonus := streakStep * p.Streak
	if bonus > streakCap {
		bonus = streakCap
	}
	p.Lifetime += pointsPlay + bonus
}

// BuyFreeze spends points on a streak freeze (max 2 held).
func BuyFreeze(cur realm) {
	caller := mustUser(cur)
	p := getPlayer(caller)
	if p.Freezes >= maxFreezes {
		panic("freeze limit reached")
	}
	if p.Lifetime-p.Spent < freezeCost {
		panic("not enough points")
	}
	p.Spent += freezeCost
	p.Freezes++
}

// Views (non-crossing)

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

func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("# Taproom spike\n\n")
	sb.WriteString("Rounds: " + strconv.Itoa(len(rounds)) + "\n\n")
	for _, r := range rounds {
		status := "open"
		if r.Settled {
			status = "settled"
		}
		sb.WriteString("- round " + strconv.Itoa(r.ID) + ": " + status +
			", players " + strconv.Itoa(len(r.Players)) +
			", pot " + strconv.FormatInt(r.Pot, 10) + " ugnot\n")
	}
	return sb.String()
}
