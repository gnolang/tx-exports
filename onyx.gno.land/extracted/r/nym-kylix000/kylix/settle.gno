package kylix

import (
	"chain"
	"chain/runtime"
	"strconv"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nym-kylix000/ring/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// SettleRing settles a ring of open offers. ids lists offer ids in ring
// order, comma-separated: the first offer's asset goes to the second offer's
// owner, and so on, and the last offer's asset goes to the first owner.
// Anyone may call it; the realm checks everything.
//
// A hop that gives one token where the receiver wants a different token is
// bridged by a GnoSwap swap (bridge.gno); a ring may contain one such hop.
// SettleRing picks the pool itself (see bridgeFee). That is a convenience:
// for a pair with several pools anyone can add liquidity that makes it pick
// a pool which cannot pay the receiver's minimum, and then the ring aborts.
// A settler who knows which pool to use calls SettleRingVia instead.
//
// Order of work:
//  1. Read and check: every offer is open and not expired, the ring is valid
//     (p/ring), every owner can deliver right now (balance and slot
//     allowance for a token; current ownership, and approval where the
//     collection registered a check, for an item), and a pool exists for a
//     bridged hop. This phase writes nothing to Kylix, and a failure names
//     the leg and offer at fault.
//  2. Take the re-entrancy lock and mark every offer settled by deleting it
//     from the book.
//  3. Move each leg's asset from its owner straight to the next owner, acting
//     as that offer's slot. After each item move, check that the next owner
//     really holds the item.
//
// If anything fails the transaction aborts and the chain rolls back every
// write, so the offers in the ring stay open and nothing has moved.
//
// SETTLERS PAY FOR COLLECTION CODE. For every item in the ring, phases 1 and
// 3 call that collection's registered functions. They run with their own
// realm's storage authority and may write to it, and the chain charges the
// transaction's sender the storage deposit for every realm whose storage
// grows. A hostile collection can therefore make settling its items cost up
// to the sender's deposit limit, and recover that deposit later. Settle with
// a tight -max-deposit, and be careful with third-party collections.
func SettleRing(cur realm, ids string) {
	settleRing(cur, ids, 0)
}

// SettleRingVia settles a ring like SettleRing, swapping its bridged hop
// through the GnoSwap pool with this fee tier (100, 500, 3000 or 10000,
// i.e. 0.01%, 0.05%, 0.3% or 1%). The pool must exist, and the ring must
// have a bridged hop. A solver chooses the pool off chain, for instance with
// the router's DrySwapRoute.
func SettleRingVia(cur realm, ids string, fee uint32) {
	if !isFeeTier(fee) {
		panic("kylix: fee must be one of GnoSwap's tiers: 100, 500, 3000 or 10000")
	}
	settleRing(cur, ids, fee)
}

// settleRing is SettleRing with an optional fee tier (0: choose).
func settleRing(cur realm, ids string, viaFee uint32) {
	guard(cur)
	idList, err := ring.ParseOfferIDs(ids)
	if err != nil {
		panic("kylix: " + err.Error())
	}

	height := runtime.ChainHeight()
	n := len(idList)
	offs := make([]*Offer, n)
	legs := make([]ring.Leg, n)
	for i, id := range idList {
		o := loadOffer(id)
		if o == nil {
			panic(legMsg(i, id, "offer is not open (unknown, settled, cancelled or pruned)"))
		}
		if expired(o, height) {
			panic(legMsg(i, id, "offer expired at height "+strconv.FormatInt(o.Expiry, 10)))
		}
		offs[i] = o
		legs[i] = ring.Leg{Offer: o.ID, Owner: o.Owner, Give: o.Give, Want: o.Want}
	}
	hops, err := ring.VerifyWithBridge(legs)
	if err != nil {
		panic("kylix: " + err.Error())
	}
	var fee uint32
	bridged := false
	for i, o := range offs {
		if why := undeliverable(o); why != "" {
			panic(legMsg(i, o.ID, why))
		}
		h := hops[i]
		if !h.Bridged {
			continue
		}
		bridged = true
		if viaFee != 0 {
			if !poolExists(h.Asset.Key, h.Want.Key, viaFee) {
				panic(legMsg(i, o.ID, "no GnoSwap pool with fee tier "+strconv.FormatUint(uint64(viaFee), 10)+
					" to swap "+h.Asset.Key+" for "+h.Want.Key))
			}
			fee = viaFee
			continue
		}
		var ok bool
		if fee, ok = bridgeFee(h.Asset.Key, h.Want.Key); !ok {
			panic(legMsg(i, o.ID, "no GnoSwap pool with reserves to swap "+h.Asset.Key+" for "+h.Want.Key))
		}
	}
	if viaFee != 0 && !bridged {
		panic("kylix: this ring has no swap through GnoSwap; use SettleRing")
	}

	locked = true
	for _, o := range offs {
		removeOffer(o.ID)
	}

	var bridgedGot int64
	for i, h := range hops {
		o := offs[i]
		slot := cur.Sub(slotPath(o.Owner, o.Nonce))
		to := offs[h.To].Owner
		if h.Bridged {
			settle := cur.Sub(settlePath)
			before := tokenOf(h.Want.Key).BalanceOf(to)
			bridgeHop(0, slot, settle, i, o, h, to, fee)
			bridgedGot = tokenOf(h.Want.Key).BalanceOf(to) - before
		} else {
			executeHop(0, slot, i, o, h, to)
		}
	}
	locked = false

	ringIDs := ring.FormatOfferIDs(idList)
	chain.Emit("RingSettled",
		"ids", ringIDs,
		"legs", strconv.Itoa(n),
		"settler", cur.Previous().Address().String(),
	)
	for i, o := range offs {
		in := (i + n - 1) % n
		received := hops[in].Asset.String()
		if hops[in].Bridged {
			received = ring.Asset{Kind: ring.Fungible, Key: hops[in].Want.Key, Amount: bridgedGot}.String()
		}
		chain.Emit(OfferSettledEvent,
			"owner", o.Owner.String(),
			"id", u64(o.ID),
			"ring", ringIDs,
			"gave", o.Give.String(),
			"received", received,
		)
	}
}

// executeHop moves one direct leg's asset. slot is the offer's own
// sub-realm token, minted from SettleRing's cur; it is never stored and
// never handed to foreign code except as the identity of a crossing call.
func executeHop(_ int, slot realm, i int, o *Offer, h ring.Hop, to address) {
	switch h.Asset.Kind {
	case ring.Fungible:
		// The slot is the spender, so only this offer's allowance can pay.
		grc20reg.TransferFrom(0, slot, h.Asset.Key, o.Owner, to, h.Asset.Amount)
	case ring.Item:
		c := getCollection(h.Asset.Key)
		if err := c.move(cross(slot), o.Owner, to, h.Asset.ID); err != nil {
			panic(legMsg(i, o.ID, "collection refused the move: "+err.Error()))
		}
		if got := c.ownerOf(ItemID(h.Asset.ID)); got != to {
			panic(legMsg(i, o.ID, "collection reported a move but item "+h.Asset.ID+" is owned by "+got.String()+", not "+to.String()))
		}
	default:
		panic(legMsg(i, o.ID, "unknown asset kind"))
	}
}

// undeliverable returns "" if o's owner could deliver o's asset right now,
// otherwise the reason not. It writes nothing to Kylix. For an item it calls
// the collection's OwnerFn and, if registered, its ApprovedFn; both run
// without crossing, so they cannot call back into Kylix's entry points, but
// they run with their own realm's storage authority and may write there, at
// the transaction sender's expense (see SettleRing). Without an ApprovedFn an
// item approval is only tested by the move itself.
func undeliverable(o *Offer) string {
	switch o.Give.Kind {
	case ring.Fungible:
		tok := tokenOf(o.Give.Key)
		if tok == nil {
			return "token is not in grc20reg"
		}
		need := o.Give.Amount
		if bal := tok.BalanceOf(o.Owner); bal < need {
			return "owner holds " + i64(bal) + " of " + o.Give.Key + ", offer gives " + i64(need)
		}
		// The allowance must equal the amount exactly. A larger one is not
		// used up, so the token realm keeps its entry and the settler, who
		// pays for every receiver's new balance entry, gets no refund for it.
		slot := SlotAddress(o.Owner, o.Nonce)
		if al := tok.Allowance(o.Owner, slot); al != need {
			return "slot " + slot.String() + " may spend " + i64(al) + " of " + o.Give.Key +
				"; approve exactly " + i64(need) + ", the amount this offer gives"
		}
	case ring.Item:
		c := getCollection(o.Give.Key)
		if c == nil {
			return "collection is not registered"
		}
		if got := c.ownerOf(ItemID(o.Give.ID)); got != o.Owner {
			return "owner no longer holds item " + o.Give.ID
		}
		if c.approved != nil {
			spender := ApproveTarget(o.Owner, o.Nonce, o.Give.Key)
			if !c.approved(ItemID(o.Give.ID), spender) {
				return "item " + o.Give.ID + " cannot be moved by " + spender.String() +
					" now (not approved, held by its collection, or refused by the collection's own rules)"
			}
		}
	default:
		return "unknown asset kind"
	}
	return ""
}

func tokenOf(key string) *grc20.Token { return grc20reg.Get(key) }

func legMsg(i int, id uint64, msg string) string {
	return "kylix: leg " + strconv.Itoa(i) + " (offer " + u64(id) + "): " + msg
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }
