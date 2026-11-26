// Package barkeep is a trustless bounty board on Gno.land.
//
// Post a task with a GNOT reward attached, a hunter claims it, submits proof,
// and the realm pays out when the poster approves. Rewards sit in this realm's
// escrow the whole time: there is no admin key and nobody can move them except
// through the rules below.
//
//   - Post:    send the reward (ugnot) with the call; it is locked in escrow.
//   - Claim:   reserve an open bounty for its claim window.
//   - Submit:  hand in a link/PR/tx as proof.
//   - Approve: poster accepts; the hunter is paid immediately.
//   - Reject:  poster declines; the bounty reopens for everyone.
//   - Collect: if the poster ghosts for the review window, the hunter can take the reward.
//   - Release: anyone can reopen a bounty whose claim expired.
//   - Unclaim: the hunter gives the bounty back.
//   - Cancel:  poster withdraws an open bounty and gets a full refund.
//
// The board logic lives in the reusable pure package gno.land/p/g1vx95s9pfwpg2flkw6x8z35546espgqemks8zkm/bounty/v0.
package barkeep

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/g1vx95s9pfwpg2flkw6x8z35546espgqemks8zkm/bounty/v0"
)

const denom = "ugnot"

var board = bounty.NewBoard(bounty.Config{
	MinReward:      1_000_000, // 1 GNOT
	MinClaimWindow: time.Hour,
	MaxClaimWindow: 30 * 24 * time.Hour,
	ReviewWindow:   72 * time.Hour,
})

// Post creates a bounty. Attach the reward as ugnot (e.g. -send 5000000ugnot
// for 5 GNOT). claimHours is how long a hunter has to deliver after claiming.
func Post(cur realm, title, description string, claimHours int) uint64 {
	// Only a direct user call (wallet / gnokey maketx call) carries the coins
	// to this realm, so only then does OriginSend describe what we received.
	if !cur.Previous().IsUserCall() {
		panic("barkeep: Post must be called directly by a user wallet")
	}
	poster := cur.Previous().Address()
	reward := receivedReward()

	b, err := board.Post(poster, title, description, reward, hours(claimHours), time.Now())
	check(err)
	chain.Emit("BountyPosted",
		"id", idStr(b.ID),
		"poster", poster.String(),
		"reward", strconv.FormatInt(reward, 10),
	)
	return b.ID
}

// Claim reserves an open bounty for the caller.
func Claim(cur realm, id uint64) {
	assertNoSend(cur)
	hunter := cur.Previous().Address()
	b, err := board.Claim(id, hunter, time.Now())
	check(err)
	chain.Emit("BountyClaimed", "id", idStr(b.ID), "hunter", hunter.String())
}

// Unclaim gives a claimed bounty back so others can take it.
func Unclaim(cur realm, id uint64) {
	assertNoSend(cur)
	hunter := cur.Previous().Address()
	b, err := board.Unclaim(id, hunter, time.Now())
	check(err)
	chain.Emit("BountyReleased", "id", idStr(b.ID), "by", hunter.String())
}

// Submit hands in proof of work (a URL, PR, tx hash …, max 280 chars).
func Submit(cur realm, id uint64, proof string) {
	assertNoSend(cur)
	hunter := cur.Previous().Address()
	b, err := board.Submit(id, hunter, proof, time.Now())
	check(err)
	chain.Emit("BountySubmitted", "id", idStr(b.ID), "hunter", hunter.String())
}

// Approve accepts the submission and pays the hunter from escrow.
func Approve(cur realm, id uint64) {
	assertNoSend(cur)
	poster := cur.Previous().Address()
	b, err := board.Approve(id, poster, time.Now())
	check(err)
	payout(cur, b.Hunter, b.Reward)
	chain.Emit("BountyPaid", "id", idStr(b.ID), "hunter", b.Hunter.String(),
		"reward", strconv.FormatInt(b.Reward, 10))
}

// Reject declines the submission; the bounty reopens for everyone.
func Reject(cur realm, id uint64, reason string) {
	assertNoSend(cur)
	poster := cur.Previous().Address()
	b, err := board.Reject(id, poster, reason, time.Now())
	check(err)
	chain.Emit("BountyRejected", "id", idStr(b.ID))
}

// Collect pays the hunter when the poster did not review the submission
// within the review window (72h).
func Collect(cur realm, id uint64) {
	assertNoSend(cur)
	hunter := cur.Previous().Address()
	b, err := board.Collect(id, hunter, time.Now())
	check(err)
	payout(cur, b.Hunter, b.Reward)
	chain.Emit("BountyPaid", "id", idStr(b.ID), "hunter", b.Hunter.String(),
		"reward", strconv.FormatInt(b.Reward, 10), "auto", "true")
}

// Release reopens a bounty whose claim window expired. Anyone can call it.
func Release(cur realm, id uint64) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	b, err := board.Release(id, caller, time.Now())
	check(err)
	chain.Emit("BountyReleased", "id", idStr(b.ID), "by", caller.String())
}

// Cancel withdraws an open bounty and refunds the reward to the poster.
func Cancel(cur realm, id uint64) {
	assertNoSend(cur)
	poster := cur.Previous().Address()
	b, err := board.Cancel(id, poster, time.Now())
	check(err)
	payout(cur, b.Poster, b.Reward)
	chain.Emit("BountyCancelled", "id", idStr(b.ID))
}

// --- read-only helpers (usable by other realms and clients) ---

// GetBounty returns a copy of a bounty's main fields.
func GetBounty(id uint64) (title string, poster address, reward int64, status string, hunter address) {
	b, ok := board.Get(id)
	if !ok {
		panic(bounty.ErrNotFound.Error())
	}
	return b.Title, b.Poster, b.Reward, b.Status.String(), b.Hunter
}

// Reputation returns the hunter stats of addr.
func Reputation(addr address) (completed int, earned int64, score int) {
	s := board.Stats(addr)
	return s.Completed, s.Earned, s.Score()
}

// Escrowed is the total ugnot currently locked for open bounties.
func Escrowed() int64 { return board.Escrowed() }

// --- internals ---

func payout(cur realm, to address, amount int64) {
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.Coins{{denom, amount}})
}

// receivedReward returns the ugnot attached to the call and refuses any
// other denom (the transaction reverts, so nothing gets stuck).
func receivedReward() int64 {
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != denom {
			panic("barkeep: only " + denom + " can be used as a reward")
		}
	}
	amount := sent.AmountOf(denom)
	if amount <= 0 {
		panic("barkeep: attach the reward as ugnot, e.g. 5000000ugnot for 5 GNOT")
	}
	return amount
}

func assertNoSend(cur realm) {
	if cur.Previous().IsUserCall() && !unsafe.OriginSend().IsZero() {
		panic("barkeep: this function does not take coins")
	}
}

func hours(h int) time.Duration {
	if h <= 0 || h > 24*365 {
		panic(bounty.ErrBadWindow.Error())
	}
	return time.Duration(h) * time.Hour
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}

func idStr(id uint64) string { return strconv.FormatUint(id, 10) }
