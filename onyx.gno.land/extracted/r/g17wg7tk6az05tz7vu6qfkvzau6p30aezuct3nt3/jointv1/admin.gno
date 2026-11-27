package jointv1

import (
	"chain/runtime/unsafe"
	"time"
)

// Admin returns the admin address (the deployer).
func Admin() address {
	return admin.Owner()
}

// SetSecondsPerGameHour sets the real seconds per game hour (10 to 3600).
// Admin only. Game hours stay continuous: the clock is re-anchored at the
// current hour (old speed) before the new speed applies. Same value: no-op.
func SetSecondsPerGameHour(cur realm, s int64) {
	assertAdmin(cur)
	assertNoSend()
	if s < MinSecondsPerGameHour || s > MaxSecondsPerGameHour {
		panic("town: seconds per game hour must be 10 to 3600")
	}
	if s == params.SecondsPerGameHour {
		return
	}
	hourBase = CurrentGameHour() // at the old speed
	anchorUnix = time.Now().Unix()
	params.SecondsPerGameHour = s
}

// SetPotBps sets the share of GNOT shop sales that goes to the season pot,
// in basis points (0 to 10000). Admin only.
func SetPotBps(cur realm, bps int64) {
	assertAdmin(cur)
	assertNoSend()
	if bps < MinPotBps || bps > MaxPotBps {
		panic("town: pot bps must be 0 to 10000")
	}
	params.PotBps = bps
}

// SetPoolK sets the pool exponent step count (1 to 3: N^0.5, N^0.75,
// N^0.875). Admin only. It applies to every hour settled after the change,
// including missed hours not yet settled.
func SetPoolK(cur realm, k int) {
	assertAdmin(cur)
	assertNoSend()
	if k < MinPoolK || k > MaxPoolK {
		panic("town: pool k must be 1 to 3")
	}
	poolK = k
}

// SetPoolScaleBps sets the customer pool scale in basis points (5000 to
// 30000). Admin only. Like SetPoolK it applies to hours settled after it.
func SetPoolScaleBps(cur realm, bps int64) {
	assertAdmin(cur)
	assertNoSend()
	if bps < MinPoolScaleBps || bps > MaxPoolScaleBps {
		panic("town: pool scale must be 5000 to 30000")
	}
	poolScaleBps = bps
}

// SetTreasury sets the only address that may withdraw the GNOT treasury.
// Admin only. An empty address is refused.
func SetTreasury(cur realm, addr address) {
	assertAdmin(cur)
	assertNoSend()
	if addr == "" {
		panic("town: treasury address is empty")
	}
	treasuryAddr = addr
}

// SetPubPotBps sets the pubs' share of a frozen season pot, in basis points
// (4000 to 8000). Farms receive the rest. Admin only. It applies the next
// time a season is frozen.
func SetPubPotBps(cur realm, bps int64) {
	assertAdmin(cur)
	assertNoSend()
	if bps < MinPubPotBps || bps > MaxPubPotBps {
		panic("town: pub pot bps must be 4000 to 8000")
	}
	pubPotBps = bps
}

// SetPaused pauses or resumes all game actions. Reads keep working. Admin only.
func SetPaused(cur realm, p bool) {
	assertAdmin(cur)
	assertNoSend()
	params.Paused = p
}

func assertAdmin(cur realm) {
	if !admin.OwnedBy(cur.Previous().Address()) {
		panic("town: admin only")
	}
}

// assertNotPaused guards every game action.
func assertNotPaused() {
	if params.Paused {
		panic("town: game is paused")
	}
}

// assertNoSend rejects attached coins on functions that do not take payment;
// without it coins sent by mistake would be stuck in the realm.
func assertNoSend() {
	if len(unsafe.OriginSend()) != 0 {
		panic("town: this function takes no coins")
	}
}
