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

// SetFarm allowlists a vault realm so it can prepaid-ugnot LP/swap.
// Only that farm's own code should NotifyFarmPay after RealmSend.
func SetFarm(cur realm, addr address, on bool) {
	mustOwner(cur)
	require(addr.IsValid(), "zdex: farm addr")
	k := addr.String()
	if on {
		farms.Set(k, true)
	} else {
		farms.Remove(k)
		farmPay.Remove(k)
	}
	chain.Emit("SetFarm", "farm", k, "on", itoa(btoi(on)))
}

func IsFarm(addr address) bool {
	return farms.Has(addr.String())
}

// NotifyFarmPay records ugnot the farm already RealmSent to this DEX
// in the same call stack. Unknown realms cannot mint LP from the float.
func NotifyFarmPay(cur realm, amount int64) {
	require(amount > 0, "zdex: amount")
	prev := cur.Previous()
	require(!prev.IsUserCall(), "zdex: farm only")
	k := prev.Address().String()
	require(farms.Has(k), "zdex: unknown farm")
	curAmt := int64(0)
	if v := farmPay.Get(k); v != nil {
		n, ok := v.(int64)
		if ok {
			curAmt = n
		}
	}
	farmPay.Set(k, add64(curAmt, amount))
}

func CollectFees(cur realm, poolID string) (ugnotOut, tokenOut int64) {
	rejectStrayUgnot()
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
		if p.QuoteSym != "" {
			pushToken(0, cur, p.QuoteTok, caller, ugnotOut)
		} else {
			sendUgnot(0, cur, caller, ugnotOut)
		}
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
