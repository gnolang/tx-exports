package bolo

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"math/bits"

	"gno.land/p/nt/seqid/v0"
)

// The refund windows' names: Refund's kind, GetContribution's window (API §3.2).
const (
	windowOpen = "open"
	windowExit = "exit"
)

// Withdraw sends everything campaign id's escrow holds to its beneficiary, and returns
// how much: the beneficiary only, until the exit window opens — the campaign's page
// says when.
//
// The beneficiary only — a user by a direct transaction, or a deployed realm, through
// C11's realm branch (API §3.3). The tracked part counts as Withdrawn,
// and only it ends the open refund window; coins sent to the escrow outside Bolo go
// along, recorded apart.
func Withdraw(cur realm, id string) int64 {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	c := campaignOf(id)
	recordDeadline(cur, c)
	if cur.Previous().Address() != c.beneficiary {
		panic(ErrNotBeneficiary)
	}
	w := bookWithdrawal(c)
	total := w.amount + w.untracked
	banker.NewBanker(banker.BankerTypeRealmSend, escrowSub(cur, c)).SendCoins(escrowAddr(c.id), c.beneficiary, chain.NewCoins(chain.NewCoin("ugnot", total)))
	chain.Emit(evWithdrawn,
		"id", idString(c.id),
		"seq", idString(seqid.ID(w.seq)),
		"to", w.to.String(),
		"amount", itoa(w.amount),
		"untracked", itoa(w.untracked),
	)
	return total
}

// bookWithdrawal checks a withdrawal from c and enters it in the books, before any
// coin moves (API §3.3): the refusals of checkWithdrawable; nothing at the escrow;
// INV-1. Everything at the escrow goes, the tracked part as Withdrawn — ending the
// open refund window only when above 0 — and the rest recorded apart. It returns the
// stored record.
func bookWithdrawal(c *campaign) *withdrawal {
	checkWithdrawable(c)
	total := banker.NewReadonlyBanker().GetCoin(escrowAddr(c.id), "ugnot")
	if total == 0 {
		panic(ErrNothingToWithdraw)
	}
	assertBooks(c)
	s := c.state
	tracked := trackedBalance(c)
	s.withdrawn += tracked
	if tracked > 0 {
		s.everWithdrawn = true
	}
	seq := s.withdrawalSeq.Next()
	w := &withdrawal{seq: uint64(seq), amount: tracked, untracked: total - tracked, at: now(), to: c.beneficiary}
	c.withdrawals.Set(seq.Binary(), w)
	return w
}

// checkWithdrawable refuses a withdrawal from c (API §3.3), in this order: a direct
// campaign, a settled one, and a closed one whose exit window has opened — what is
// left belongs to the exit process then.
func checkWithdrawable(c *campaign) {
	if c.mode != modeEscrow {
		panic(ErrWrongMode)
	}
	s := c.state
	if s.status == statusSettled {
		panic(ErrCampaignSettled)
	}
	if s.status == statusClosed && now() >= s.closedAt+c.params.ExitDelay {
		panic(ErrExitOpen)
	}
}

// Refund gives you back, from campaign id's escrow, what you can take back now, and
// returns how much: your whole gift until the beneficiary first withdraws, or, once
// the beneficiary's window after the campaign closes has passed, your share of what
// they left uncollected. The campaign's page offers it when a donor can.
//
// It pays the caller back from their own contribution to the campaign (API §3.2,
// INV-13): a donor, by a direct transaction, while a refund window is open to them.
// The open window — no tracked withdrawal ever — pays everything not yet refunded.
func Refund(cur realm, id string) int64 {
	assertCurrent(cur)
	if !cur.Previous().IsUserCall() {
		panic(ErrNotUserCall)
	}
	runtime.AssertOriginCall()
	c := campaignOf(id)
	recordDeadline(cur, c)
	donor := cur.Previous().Address()
	r := bookRefund(c, donor)
	banker.NewBanker(banker.BankerTypeRealmSend, escrowSub(cur, c)).SendCoins(escrowAddr(c.id), donor, chain.NewCoins(chain.NewCoin("ugnot", r.amount)))
	chain.Emit(evRefunded,
		"id", idString(c.id),
		"seq", idString(seqid.ID(r.seq)),
		"donor", donor.String(),
		"amount", itoa(r.amount),
		"kind", r.kind,
	)
	return r.amount
}

// bookRefund checks a refund of donor's contribution to c and enters it in the
// books, before any coin moves (API §3.2): the refusals of checkRefund, then INV-1,
// on the books as they stand. An exit claim freezes the pool and its base if it is
// the first, uses the donor's one claim, and may not exceed the tracked balance
// (INV-17). It returns the stored record.
func bookRefund(c *campaign, donor address) *refund {
	k, window, amount := checkRefund(c, donor)
	assertBooks(c)
	s := c.state
	if window == windowExit {
		if !s.exitFrozen {
			s.exitFrozen, s.exitPool, s.exitBase = true, trackedBalance(c), s.raised-s.refunded
		}
		if amount > trackedBalance(c) {
			panic(ErrBooksMismatch)
		}
		k.exitClaimed = true
	}
	k.refunded += amount
	s.refunded += amount
	s.refundCount++
	seq := s.refundSeq.Next()
	r := &refund{seq: uint64(seq), amount: amount, at: now(), donor: donor, kind: window}
	c.refunds.Set(seq.Binary(), r)
	return r
}

// checkRefund returns donor's contribution to c, the window Refund would use and what
// it would pay, or panics (API §3.2), in this order: a direct campaign; nothing to
// refund; no window open, a used exit claim included; an exit claim that rounds down
// to 0.
func checkRefund(c *campaign, donor address) (*contribution, string, int64) {
	if c.mode != modeEscrow {
		panic(ErrWrongMode)
	}
	k := contributionOf(c, donor)
	if k == nil || k.amount-k.refunded <= 0 {
		panic(ErrNothingToRefund)
	}
	window, amount := refundable(c, k)
	if window == "" {
		panic(ErrRefundWindowClosed)
	}
	if amount == 0 {
		panic(ErrNothingToRefund)
	}
	return k, window, amount
}

// refundable returns the window Refund would use for k now, and what it would pay
// (API §3.2). The open window, while no tracked withdrawal ever happened, pays all not
// yet refunded. After one, the exit window opens once the campaign is closed and
// ExitDelay has passed, while a tracked balance is left: one claim per donor, pro-rata
// against the pool and base the first claim froze — or would freeze now. It reads the
// effective status, as GetContribution can't record a passed deadline.
func refundable(c *campaign, k *contribution) (string, int64) {
	left := k.amount - k.refunded
	if c.mode != modeEscrow || left <= 0 {
		return "", 0
	}
	s := c.state
	if !s.everWithdrawn {
		return windowOpen, left
	}
	status, _, closedAt := effective(c)
	if status == statusOpen || now() < closedAt+c.params.ExitDelay || k.exitClaimed || trackedBalance(c) <= 0 {
		return "", 0
	}
	pool, base := s.exitPool, s.exitBase
	if !s.exitFrozen {
		pool, base = trackedBalance(c), s.raised-s.refunded
	}
	return windowExit, exitClaim(left, pool, base)
}

// exitClaim is left × pool / base, rounded down (API §3.2): computed in 128 bits, as
// both factors fit in 63 bits but their product doesn't. A claimant's left is part of
// the base, so the base is above 0 and the quotient at most the pool, and Div64's own
// panics, keyless, can't be reached; both conditions are asserted first.
func exitClaim(left, pool, base int64) int64 {
	if base <= 0 || left > base || pool < 0 {
		panic(ErrBooksMismatch)
	}
	hi, lo := bits.Mul64(uint64(left), uint64(pool))
	quo, _ := bits.Div64(hi, lo, uint64(base))
	return int64(quo)
}

// assertBooks panics with ErrBooksMismatch when c's books hold more than its escrow
// does (INV-1). It runs before every payout from an escrow, on the books as they
// stand, so a bug in the books stops a payment instead of paying out coins they
// can't account for.
func assertBooks(c *campaign) {
	if banker.NewReadonlyBanker().GetCoin(escrowAddr(c.id), "ugnot") < trackedBalance(c) {
		panic(ErrBooksMismatch)
	}
}

// contributionOf returns donor's record in c, or nil.
func contributionOf(c *campaign, donor address) *contribution {
	if v := c.contributions.Get(donor.String()); v != nil {
		return v.(*contribution)
	}
	return nil
}

// ContributionView is one donor's record in one campaign (API §2.4), with what Refund
// would pay them now: a copy.
type ContributionView struct {
	Amount, Refunded, RefundableNow int64
	Window                          string // "open", "exit", or "" for none: the window Refund would use now
	ExitClaimed                     bool
}

// GetContribution returns donor's record in campaign id (API §4): zeros and no
// window for an address that never gave, and no window for an exit claim that rounds
// to 0, which Refund refuses. An address is compared as given (C12).
func GetContribution(id string, donor address) ContributionView {
	c := campaignOf(id)
	k := contributionOf(c, donor)
	if k == nil {
		return ContributionView{}
	}
	window, pay := refundable(c, k)
	if pay == 0 {
		window = ""
	}
	return ContributionView{Amount: k.amount, Refunded: k.refunded, RefundableNow: pay, Window: window, ExitClaimed: k.exitClaimed}
}
