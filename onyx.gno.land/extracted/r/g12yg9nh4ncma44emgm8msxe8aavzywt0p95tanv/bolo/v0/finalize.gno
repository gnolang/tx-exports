package bolo

import (
	"chain"
	"chain/banker"
)

// Finalize completes closed campaign id: anyone can, once the campaign's page offers
// it. It returns the organizer's deposit, and sends the beneficiary the coins someone
// sent to the escrow outside Bolo. What donors can still reclaim stays theirs.
//
// It settles a closed campaign, and forwards what no donor is owed (API §3.4): anyone
// may call, with no identity. At its first call it settles the campaign;
// every call forwards the coins sent to the escrow outside Bolo to the beneficiary,
// and everything at the bond address but a bond still on hold to the organizer — the
// deposit, and the bond once its hold has ended. It never moves the tracked balance:
// that stays the donors' (INV-16).
func Finalize(cur realm, id string) {
	assertCurrent(cur)
	c := campaignOf(id)
	recordDeadline(cur, c)
	f := bookFinalize(c)
	if f.toBeneficiary > 0 {
		banker.NewBanker(banker.BankerTypeRealmSend, escrowSub(cur, c)).SendCoins(escrowAddr(c.id), c.beneficiary, chain.NewCoins(chain.NewCoin("ugnot", f.toBeneficiary)))
	}
	if f.toOrganizer > 0 {
		banker.NewBanker(banker.BankerTypeRealmSend, bondSub(cur, c)).SendCoins(bondAddr(c.id), c.organizer, chain.NewCoins(chain.NewCoin("ugnot", f.toOrganizer)))
	}
	if f.settled {
		chain.Emit(evSettled, "id", idString(c.id), "toOrganizer", itoa(f.toOrganizer), "toBeneficiary", itoa(f.toBeneficiary))
	}
	if f.released > 0 {
		chain.Emit(evBondReleased, "id", idString(c.id), "amount", itoa(f.released), "to", c.organizer.String())
	}
}

// settlement is what one Finalize call moves, and announces.
type settlement struct {
	toBeneficiary int64 // the untracked coins at the escrow
	toOrganizer   int64 // everything at the bond address but a bond still on hold
	released      int64 // the bond this call releases, or 0
	settled       bool  // this call settles the campaign
}

// bookFinalize checks a Finalize call on c and enters it in the books, before any coin
// moves (API §3.4): the first settles c, if checkFinalizable allows; every one works
// out what to forward, and releases a bond whose hold has ended.
func bookFinalize(c *campaign) settlement {
	s := c.state
	settled := false
	if s.status != statusSettled {
		checkFinalizable(c)
		s.status = statusSettled
		stats.settled++
		settled = true
	}
	f := pending(c)
	f.settled = settled
	if f.released > 0 {
		s.bondReleased = true
	}
	return f
}

// checkFinalizable refuses c's first settlement (API §3.4), with ErrNotFinalizable,
// unless it is closed and its FinalizableAt has come: at once in direct mode or with
// no tracked balance, else once its exit window opens. The view, CanFinalize and this
// share one rule, finalizableAt.
func checkFinalizable(c *campaign) {
	s := c.state
	if s.status != statusClosed {
		panic(ErrNotFinalizable)
	}
	if now() < finalizableAt(c, s.closedAt, trackedBalance(c)) {
		panic(ErrNotFinalizable)
	}
}

// pending works out what a Finalize call would move from c now, without writing: the
// escrow's coins above its books, to the beneficiary; the bond address's coins but a
// bond still on hold — not slashed, not released, its hold not ended — to the
// organizer, the bond itself included once its hold has ended. Books above the bank,
// at either address, are ErrBooksMismatch (INV-1, INV-7).
func pending(c *campaign) settlement {
	s := c.state
	var f settlement
	f.toBeneficiary = banker.NewReadonlyBanker().GetCoin(escrowAddr(c.id), "ugnot") - trackedBalance(c)
	held := int64(0)
	if s.bond > 0 && !s.bondSlashed && !s.bondReleased {
		if now() >= s.closedAt+c.params.BondHold {
			f.released = s.bond
		} else {
			held = s.bond
		}
	}
	f.toOrganizer = banker.NewReadonlyBanker().GetCoin(bondAddr(c.id), "ugnot") - held
	if f.toBeneficiary < 0 || f.toOrganizer < 0 {
		panic(ErrBooksMismatch)
	}
	return f
}

// CanFinalize says what Finalize(id) would do now (API §4), a passed deadline counted
// as recorded: true with "settle" for the first settlement, or "forward" on a settled
// campaign with something to move; false with "open", "not_yet" while a tracked balance
// waits for its exit window, or "settled" with nothing to move.
func CanFinalize(id string) (bool, string) {
	c := campaignOf(id)
	status, _, closedAt := effective(c)
	switch status {
	case statusOpen:
		return false, statusOpen
	case statusClosed:
		if now() < finalizableAt(c, closedAt, trackedBalance(c)) {
			return false, "not_yet"
		}
		return true, "settle"
	}
	if f := pending(c); f.toBeneficiary > 0 || f.toOrganizer > 0 {
		return true, "forward"
	}
	return false, statusSettled
}
