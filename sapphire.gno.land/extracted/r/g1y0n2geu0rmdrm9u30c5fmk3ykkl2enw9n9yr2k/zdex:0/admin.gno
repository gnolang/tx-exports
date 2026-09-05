package zdex

import "chain"

func SetPaused(cur realm, v bool) {
	mustOwner(cur)
	paused = v
	chain.Emit("Pause", "paused", itoa(btoi(v)))
}

func TransferAdmin(cur realm, next address) {
	mustOwner(cur)
	require(next.IsValid(), "zdex: invalid admin")
	admin = next
	chain.Emit("TransferAdmin", "to", next.String())
}

func Admin() address {
	return admin
}

func Paused() bool {
	return paused
}

func CollectFees(cur realm, poolID string) (ugnotOut, tokenOut int64) {
	assertNotPaused()
	p := getPool(poolID)
	caller := cur.Previous().Address()

	totalBps := p.CreatorBps + p.ProtocolBps
	require(totalBps > 0, "zdex: no collectable fee")
	require(p.AccruedU > 0 || p.AccruedT > 0, "zdex: nothing accrued")

	var shareBps int64
	if caller == p.Creator {
		shareBps = p.CreatorBps
	} else {
		mustOwner(cur)
		shareBps = p.ProtocolBps
	}
	require(shareBps > 0, "zdex: no share")

	if p.AccruedU > 0 {
		ugnotOut = MulDiv(p.AccruedU, shareBps, totalBps)
		if ugnotOut > 0 {
			p.AccruedU = sub64(p.AccruedU, ugnotOut)
			sendUgnot(0, cur, caller, ugnotOut)
		}
	}
	if p.AccruedT > 0 {
		tokenOut = MulDiv(p.AccruedT, shareBps, totalBps)
		if tokenOut > 0 {
			p.AccruedT = sub64(p.AccruedT, tokenOut)
			pushToken(0, cur, p.Symbol, caller, tokenOut)
		}
	}
	chain.Emit("CollectFees", "pool", poolID, "to", caller.String(), "ugnot", itoa(ugnotOut), "token", itoa(tokenOut))
	return ugnotOut, tokenOut
}

func btoi(v bool) int64 {
	if v {
		return 1
	}
	return 0
}
