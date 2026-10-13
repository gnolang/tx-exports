package bolo

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"math"
	"strconv"

	"gno.land/p/nt/seqid/v0"
)

// Donate gives to campaign id, and returns your receipt's ID. Send the gift and any
// tip together: tip is the part of what you send that goes to Bolo, in ugnot — 0 for
// none. message is optional, and public. anonymous, if true, keeps your address off
// Bolo's pages; the chain still shows it. In a direct campaign the gift goes straight
// to the beneficiary; in escrow, to the campaign's escrow, until the beneficiary
// withdraws it.
//
// Any user, by a direct transaction, the donor being the caller (API §3.2). The
// envelope is the gift plus the tip. The gift goes to the beneficiary, or to the
// campaign's escrow, and the tip to the tip recipient: the realm keeps nothing
// (INV-3), and coins found there are never credited (C4).
func Donate(cur realm, id string, tip int64, message string, anonymous bool) string {
	assertCurrent(cur)
	if !cur.Previous().IsUserCall() {
		panic(ErrNotUserCall)
	}
	runtime.AssertOriginCall()
	c := campaignOf(id)
	recordDeadline(cur, c)
	amount := checkGift(c, envelopeUgnot(), tip)
	message = checkText(message, 0, messageMax, false, ErrMessage)
	checkRoom(c, amount)

	donor := cur.Previous().Address()
	s := c.state
	s.raised += amount
	s.donationCount++
	s.lastDonationAt = now()
	key := donor.String()
	var k *contribution
	if v := c.contributions.Get(key); v != nil {
		k = v.(*contribution)
	} else {
		k = &contribution{}
		c.contributions.Set(key, k)
		s.donorCount++
	}
	k.amount += amount
	if !anonymous && !k.public {
		k.public = true
		byDonor.Set(key+"/"+c.id.Binary(), true)
	}
	seq := s.receiptSeq.Next()
	c.receipts.Set(seq.Binary(), &receipt{
		seq: uint64(seq), donor: donor, anonymous: anonymous, amount: amount, tip: tip,
		message: message, at: now(), raisedAfter: s.raised, refundedBefore: k.refunded,
	})
	s.recent[s.recentNext] = uint64(seq)
	s.recentNext = (s.recentNext + 1) % recentSize

	if c.mode == modeDirect {
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(realmAddr(), c.beneficiary, chain.NewCoins(chain.NewCoin("ugnot", amount)))
	} else {
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(realmAddr(), escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", amount)))
	}
	if tip > 0 {
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(realmAddr(), tipRecipient, chain.NewCoins(chain.NewCoin("ugnot", tip)))
	}
	chain.Emit(evDonated,
		"id", idString(c.id),
		"seq", idString(seq),
		"donor", key,
		"amount", itoa(amount),
		"tip", itoa(tip),
		"anonymous", strconv.FormatBool(anonymous),
	)
	return receiptID(c.id, seq)
}

// checkGift returns the gift in an envelope of total ugnot carrying tip, or panics
// (API §3.2), in this order: a negative tip, or nothing left for the gift; a
// campaign that isn't open; a paused Bolo; a gift under the minimum.
func checkGift(c *campaign, total, tip int64) int64 {
	if tip < 0 || total-tip <= 0 {
		panic(ErrBadAmount)
	}
	amount := total - tip
	assertOpen(c)
	if paused {
		panic(ErrPaused)
	}
	if amount < minDonation {
		panic(ErrBadAmount)
	}
	return amount
}

// checkRoom refuses a gift of amount that c can't take (API §3.2): one that would
// push Raised past int64, or, in escrow mode with a cap set, the tracked balance —
// never the bank's — past MaxEscrowBalance.
func checkRoom(c *campaign, amount int64) {
	if amount > math.MaxInt64-c.state.raised {
		panic(ErrBadAmount)
	}
	if c.mode == modeEscrow && escrowCap > 0 && trackedBalance(c)+amount > escrowCap {
		panic(ErrCapReached)
	}
}

// receiptID is a receipt's ID: its campaign's, a slash, and its sequence number
// (API C9).
func receiptID(campaign, seq seqid.ID) string { return idString(campaign) + "/" + idString(seq) }

// SweepStrays sends the coins someone sent to Bolo's own address by mistake to the
// tip recipient, and returns how much: anyone can.
//
// It sends the ugnot at the realm's address to the tip recipient (API §3.4). The
// realm holds nothing between transactions (INV-3), so all of it is strays; anyone
// may call, and with nothing there it sends nothing and emits nothing (Q3).
func SweepStrays(cur realm) int64 {
	assertCurrent(cur)
	amount := banker.NewReadonlyBanker().GetCoin(realmAddr(), "ugnot")
	if amount == 0 {
		return 0
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(realmAddr(), tipRecipient, chain.NewCoins(chain.NewCoin("ugnot", amount)))
	chain.Emit(evStraysSwept, "amount", itoa(amount), "to", tipRecipient.String())
	return amount
}
