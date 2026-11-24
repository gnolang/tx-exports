// Package lastorders auctions the last round of the night: the highest bidder
// buys the round and has a toast written on the tavern wall.
//
// An auction has to end at a set time, and a realm cannot wake itself to end
// it. So every round posts a one-shot Lamplighter job due at its closing
// time: whoever runs that job settles the round, moving the winning bid to the
// seller, and is paid a fee the seller put up when opening the round.
//
// It shows what the taproom example does not: a job per item rather than one
// per realm, a realm funding its own job from coins it was sent
// (registry.Credit), and an owner cleaning up a job that is done.
//
// There is no separate "settle by hand" for a round nobody came for, because
// none is needed: running the job is open to everyone, the seller and the
// winner included.
package lastorders

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"time"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
)

const (
	denom = "ugnot"

	// LampFee is what the seller puts up when opening a round. It pays
	// whoever settles the round on time.
	LampFee int64 = 50000

	// MinBid is the smallest opening bid.
	MinBid int64 = 100000

	// A bid must beat the leading one by at least this many percent.
	raisePercent = 5

	// A round stays open for MinSeconds to MaxSeconds.
	MinSeconds int64 = 60
	MaxSeconds int64 = 7 * 24 * 60 * 60

	maxTitleLen = 60
	maxToastLen = 120
)

// round is one auction.
type round struct {
	id       uint64
	title    string
	seller   address
	closesAt int64
	job      uint64 // the Lamplighter job that settles this round

	leader address
	bid    int64
	toast  string
	bids   int

	settled   bool
	reclaimed bool // the seller has cancelled the finished job
}

var (
	rounds avl.Tree // zero-padded round id -> *round
	byJob  avl.Tree // zero-padded job id -> *round, for the callback
	nextID uint64   = 1
)

// Open starts a round that closes after the given number of seconds. The
// caller is the seller and must send exactly LampFee, which pays whoever
// settles the round on time.
func Open(cur realm, title string, seconds int64) uint64 {
	runtime.AssertOriginCall() // the coins sent are only the caller's on a direct call
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent.AmountOf(denom) != LampFee {
		panic("send exactly " + itoa(LampFee) + " " + denom + ": it pays whoever settles the round on time")
	}
	if !printable(title, maxTitleLen) {
		panic("title must be 1 to " + strconv.Itoa(maxTitleLen) + " bytes of printable text")
	}
	if seconds < MinSeconds || seconds > MaxSeconds {
		panic("a round lasts " + itoa(MinSeconds) + " to " + itoa(MaxSeconds) + " seconds")
	}

	r := &round{
		id:       nextID,
		title:    title,
		seller:   cur.Previous().Address(),
		closesAt: time.Now().Unix() + seconds,
	}
	nextID++

	// Post the job that will settle this round, then fund it: hand the fee
	// to the registry and have it credited to the job, in this same call.
	r.job = registry.Register(cross(cur), "Last Orders: settle round "+utoa(r.id), r.closesAt, 0, LampFee, settleJob)
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), chain.PackageAddress(registry.Path()), chain.Coins{{denom, LampFee}})
	registry.Credit(cross(cur), r.job, LampFee)

	rounds.Set(key(r.id), r)
	byJob.Set(key(r.job), r)

	chain.Emit("RoundOpened", "id", utoa(r.id), "seller", r.seller.String(), "closesAt", itoa(r.closesAt), "job", utoa(r.job))
	return r.id
}

// Bid places a bid of the coins sent with the call, and sets the toast that
// goes on the wall if it wins. The bidder it outbids is refunded at once.
func Bid(cur realm, id uint64, toast string) {
	runtime.AssertOriginCall()
	r := mustRound(id)
	if r.settled || time.Now().Unix() >= r.closesAt {
		panic("the round is closed")
	}
	sent := unsafe.OriginSend()
	amount := sent.AmountOf(denom)
	if len(sent) != 1 || amount < minNextBid(r) {
		panic("bid at least " + itoa(minNextBid(r)) + " " + denom)
	}
	if !printable(toast, maxToastLen) {
		panic("toast must be 1 to " + strconv.Itoa(maxToastLen) + " bytes of printable text")
	}

	previous, refund := r.leader, r.bid
	r.leader = cur.Previous().Address()
	r.bid = amount
	r.toast = toast
	r.bids++

	// Paying an account runs no code, so this cannot call back in here.
	if refund > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), previous, chain.Coins{{denom, refund}})
	}

	chain.Emit("BidPlaced", "id", utoa(id), "bidder", r.leader.String(), "amount", itoa(amount))
}

// settleJob is the callback the registry holds for every round.
//
// The registry runs any callback for anyone, so "the registry called me" is
// not enough. The job id must be one this realm posted, and it says which
// round to settle.
func settleJob(cur realm, job uint64) error {
	if cur.Previous().PkgPath() != registry.Path() {
		return errors.New("only the lamplighter registry runs this")
	}
	r, ok := byJob.Get(key(job)).(*round)
	if !ok {
		return errors.New("not a job of this realm")
	}
	if r.settled {
		return errors.New("round " + utoa(r.id) + " is already settled")
	}
	if time.Now().Unix() < r.closesAt {
		return errors.New("round " + utoa(r.id) + " is still open")
	}
	settle(cur, r)
	return nil
}

// settle closes a round: the winning bid goes to the seller.
//
// It frees nothing. Whoever sends a transaction that frees state is paid the
// storage deposit that state had locked, so cleaning up here would hand the
// seller's deposit to whoever happened to run the job. Reclaim does it.
func settle(cur realm, r *round) {
	r.settled = true
	if r.bid > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), r.seller, chain.Coins{{denom, r.bid}})
	}
	chain.Emit("RoundSettled", "id", utoa(r.id), "winner", r.leader.String(), "amount", itoa(r.bid))
}

// Reclaim cancels the finished job of a settled round. Opening the round
// locked a storage deposit from the seller for that job's state; cancelling
// the job frees the state and the chain releases the deposit to the sender of
// this transaction. Only the seller can call it.
func Reclaim(cur realm, id uint64) {
	r := mustRound(id)
	if cur.Previous().Address() != r.seller {
		panic("only the seller can reclaim the deposit of a round")
	}
	if !r.settled {
		panic("the round is not settled yet")
	}
	if r.reclaimed {
		panic("already reclaimed")
	}
	r.reclaimed = true
	byJob.Remove(key(r.job))
	registry.Cancel(cross(cur), r.job, r.seller)
}

// minNextBid is the smallest bid a round will accept next.
func minNextBid(r *round) int64 {
	if r.bid == 0 {
		return MinBid
	}
	return r.bid + (r.bid*raisePercent+99)/100
}

// Leader returns the leading bidder and bid of a round.
func Leader(id uint64) (address, int64) {
	r := mustRound(id)
	return r.leader, r.bid
}

// Settled reports whether a round has been settled.
func Settled(id uint64) bool { return mustRound(id).settled }

// JobOf returns the Lamplighter job that settles a round.
func JobOf(id uint64) uint64 { return mustRound(id).job }

func mustRound(id uint64) *round {
	r, ok := rounds.Get(key(id)).(*round)
	if !ok {
		panic("unknown round " + utoa(id))
	}
	return r
}

// printable reports whether s is 1 to max bytes of valid, printable text.
func printable(s string, max int) bool {
	if s == "" || len(s) > max || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

func key(id uint64) string {
	s := utoa(id)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func utoa(n uint64) string { return strconv.FormatUint(n, 10) }
func itoa(n int64) string  { return strconv.FormatInt(n, 10) }
