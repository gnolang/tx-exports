package zdex

import "chain"

// PlaceBid escrows ugnot (OriginSend) for `wantAmt` of the pool token at a
// fixed limit. Partial fills keep the original ratio. expireH=0 means never.
func PlaceBid(cur realm, poolID string, giveU, wantAmt, expireH int64, allOrNone bool) uint64 {
	assertNotPaused()
	require(giveU > 0 && wantAmt > 0, "zdex: amounts")
	_ = getPool(poolID)
	if expireH > 0 {
		require(expireH > height(), "zdex: already expired")
	}
	takeUgnot(cur, giveU)
	id := uint64(nextOrd.Next())
	orders.Set(itoa(int64(id)), &Order{
		ID:        id,
		Maker:     cur.Previous().Address(),
		PoolID:    poolID,
		GiveUgnot: true,
		GiveAmt:   giveU,
		WantAmt:   wantAmt,
		ExpireH:   expireH,
		AllOrNone: allOrNone,
	})
	chain.Emit("PlaceBid", "id", itoa(int64(id)), "pool", poolID, "give", itoa(giveU), "want", itoa(wantAmt))
	return id
}

// PlaceAsk escrows the pool token, wanting ugnot.
func PlaceAsk(cur realm, poolID string, giveT, wantU, expireH int64, allOrNone bool) uint64 {
	assertNotPaused()
	require(giveT > 0 && wantU > 0, "zdex: amounts")
	p := getPool(poolID)
	if expireH > 0 {
		require(expireH > height(), "zdex: already expired")
	}
	caller := cur.Previous().Address()
	pullUserToken(0, cur, p.Symbol, caller, giveT)
	id := uint64(nextOrd.Next())
	orders.Set(itoa(int64(id)), &Order{
		ID:        id,
		Maker:     caller,
		PoolID:    poolID,
		GiveUgnot: false,
		GiveAmt:   giveT,
		WantAmt:   wantU,
		ExpireH:   expireH,
		AllOrNone: allOrNone,
	})
	chain.Emit("PlaceAsk", "id", itoa(int64(id)), "pool", poolID, "give", itoa(giveT), "want", itoa(wantU))
	return id
}

// FillOrder lets a taker take up to `giveAmt` of what they pay.
// Bids: taker pays token (pulled), receives ugnot.
// Asks: taker pays ugnot (OriginSend), receives token.
func FillOrder(cur realm, orderID uint64, giveAmt int64) (paid, received int64) {
	assertNotPaused()
	require(giveAmt > 0, "zdex: giveAmt")
	o := getOrder(orderID)
	require(o.GiveAmt > 0, "zdex: filled")
	if o.ExpireH > 0 {
		require(height() <= o.ExpireH, "zdex: expired")
	}
	p := getPool(o.PoolID)
	taker := cur.Previous().Address()

	if o.GiveUgnot {
		// Bid: taker sells token, receives ugnot.
		// fill fraction of remaining want.
		wantTake := giveAmt
		if wantTake > o.WantAmt {
			wantTake = o.WantAmt
		}
		if o.AllOrNone {
			require(wantTake == o.WantAmt, "zdex: all-or-none")
		}
		payU := MulDiv(o.GiveAmt, wantTake, o.WantAmt)
		if payU <= 0 {
			payU = 1
		}
		if payU > o.GiveAmt {
			payU = o.GiveAmt
		}
		pullUserToken(0, cur, p.Symbol, taker, wantTake)
		sendUgnot(0, cur, taker, payU)
		pushToken(0, cur, p.Symbol, o.Maker, wantTake)
		o.GiveAmt -= payU
		o.WantAmt -= wantTake
		paid, received = wantTake, payU
	} else {
		// Ask: taker pays ugnot, receives token.
		takeU := giveAmt
		if takeU > o.WantAmt {
			takeU = o.WantAmt
		}
		if o.AllOrNone {
			require(takeU == o.WantAmt, "zdex: all-or-none")
		}
		takeUgnot(cur, takeU)
		payT := MulDiv(o.GiveAmt, takeU, o.WantAmt)
		if payT <= 0 {
			payT = 1
		}
		if payT > o.GiveAmt {
			payT = o.GiveAmt
		}
		sendUgnot(0, cur, o.Maker, takeU)
		pushToken(0, cur, p.Symbol, taker, payT)
		o.GiveAmt -= payT
		o.WantAmt -= takeU
		paid, received = takeU, payT
	}

	if o.GiveAmt == 0 || o.WantAmt == 0 {
		orders.Remove(itoa(int64(o.ID)))
	}
	chain.Emit("FillOrder", "id", itoa(int64(o.ID)), "taker", taker.String(), "paid", itoa(paid), "received", itoa(received))
	return paid, received
}

func CancelOrder(cur realm, orderID uint64) {
	o := getOrder(orderID)
	require(o.Maker == cur.Previous().Address(), "zdex: not maker")
	p := getPool(o.PoolID)
	if o.GiveUgnot {
		sendUgnot(0, cur, o.Maker, o.GiveAmt)
	} else {
		pushToken(0, cur, p.Symbol, o.Maker, o.GiveAmt)
	}
	orders.Remove(itoa(int64(o.ID)))
	chain.Emit("CancelOrder", "id", itoa(int64(o.ID)))
}

func getOrder(id uint64) *Order {
	v := orders.Get(itoa(int64(id)))
	require(v != nil, "zdex: order not found")
	return v.(*Order)
}

func OrderCount() int {
	return orders.Size()
}
