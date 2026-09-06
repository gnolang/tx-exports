package zdex

import "chain"

func SetPaused(cur realm, v bool) {
	mustOwner(cur)
	paused = v
	chain.Emit("Pause", "paused", itoa(btoi(v)))
}

func ProposeAdmin(cur realm, next address) {
	mustOwner(cur)
	require(next.IsValid(), "zdex: invalid admin")
	pendingAdmin = next
	chain.Emit("ProposeAdmin", "to", next.String())
}

func AcceptAdmin(cur realm) {
	require(pendingAdmin.IsValid(), "zdex: no pending admin")
	require(cur.Previous().Address() == pendingAdmin, "zdex: not pending admin")
	admin = pendingAdmin
	var z address
	pendingAdmin = z
	chain.Emit("AcceptAdmin", "to", admin.String())
}

func TransferAdmin(cur realm, next address) {
	ProposeAdmin(cur, next)
}

func Admin() address {
	return admin
}

func RealmAddr() address {
	return thisAddr()
}

func PendingAdmin() address {
	return pendingAdmin
}

func Paused() bool {
	return paused
}

func CollectFees(cur realm, poolID string) (ugnotOut, tokenOut int64) {
	p := getPool(poolID)
	caller := cur.Previous().Address()
	got := false
	if caller == p.Creator {
		ugnotOut = add64(ugnotOut, p.AccruedCreatorU)
		tokenOut = add64(tokenOut, p.AccruedCreatorT)
		p.AccruedCreatorU = 0
		p.AccruedCreatorT = 0
		got = true
	}
	if caller == admin {
		ugnotOut = add64(ugnotOut, p.AccruedProtocolU)
		tokenOut = add64(tokenOut, p.AccruedProtocolT)
		p.AccruedProtocolU = 0
		p.AccruedProtocolT = 0
		got = true
	}
	require(got, "zdex: not fee recipient")
	require(ugnotOut > 0 || tokenOut > 0, "zdex: nothing accrued")
	if ugnotOut > 0 {
		sendUgnot(0, cur, caller, ugnotOut)
	}
	if tokenOut > 0 {
		pushToken(0, cur, poolTokRef(p), caller, tokenOut)
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
