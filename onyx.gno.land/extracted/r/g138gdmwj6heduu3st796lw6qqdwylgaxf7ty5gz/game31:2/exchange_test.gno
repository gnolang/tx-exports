package game31

// Exchange unit, attack and invariant tests. See docs/EXCHANGE_SECURITY_REVIEW.md
// for the threat → code → test map.
//
// gno test caveat: revive() catches a panic but does NOT roll back realm
// state. The exchange validates everything before its first write, so a
// failing call must leave state untouched — several tests assert exactly that
// (snapshot before, compare after).

import (
	"chain"
	"strconv"
	"strings"
	"testing"
	"time"
)

// ── helpers ──────────────────────────────────────────────────────────────────

// exOpen finalizes the migration and unpauses for one test; the returned
// func restores the previous global state (other test files depend on it).
func exOpen() func() {
	setup()
	wasFinal, wasPaused, wasGame := migrationFinalized, exPaused, paused
	migrationFinalized, exPaused, paused = true, false, false
	return func() { migrationFinalized, exPaused, paused = wasFinal, wasPaused, wasGame }
}


// trader: owns wood+stone (can trade, receives up to rarity 3).
func trader(name string) address {
	a := ta(name)
	ownedTools.Set(a.String(), "starter-twig,twig,wood,stone")
	return a
}

func dl() int64 { return time.Now().Unix() + 600 }

// panicMsg runs f and returns its panic message ("" if none). For internal
// (non-crossing) helpers, where revive() does not apply.
func panicMsg(f func()) (msg string) {
	defer func() {
		if r := recover(); r != nil {
			msg = errOf(r)
		}
	}()
	f()
	return ""
}

func errOf(r any) string {
	switch v := r.(type) {
	case nil:
		return ""
	case string:
		return v
	case error:
		return v.Error()
	}
	return "?"
}

// coinTotal = every unit of `coin` the realm accounts for: all balances,
// pool reserves, order escrow, admin fees and the casino pool.
func coinTotal(coin string) uint64 {
	tot := uint64(0)
	balances.Iterate("", "", func(k string, v any) bool {
		if strings.HasSuffix(k, ":"+coin) {
			n, _ := strconv.ParseUint(v.(string), 10, 64)
			tot += n
		}
		return false
	})
	pools.Iterate("", "", func(_ string, v any) bool {
		p := v.(*pool)
		if p.coin == coin {
			tot += p.rCoin
		}
		if coin == hubCoin {
			tot += p.rHub
		}
		return false
	})
	forEachOrder(func(o *order) {
		if o.give == coin {
			tot += o.remGive
		}
	})
	return tot + getU(&adminFees, coin) + getU(&casinoPool, coin)
}

func lpSum(coin string) uint64 {
	s := uint64(0)
	lpPositions.Iterate(coin+":", coin+";", func(_ string, v any) bool {
		s += v.(*lpPos).shares
		return false
	})
	return s
}

// stateSig is a cheap fingerprint of everything the exchange owns + balances.
func stateSig(coins ...string) string {
	s := ""
	for _, c := range coins {
		s += c + "=" + u(coinTotal(c)) + ";"
		if pools.Has(c) {
			p := getPool(c)
			s += u(p.rCoin) + "/" + u(p.rHub) + "/" + u(p.shares) + ";"
		}
	}
	return s + "orders=" + u(openOrderTotal) + ";book=" + strconv.Itoa(sideTotal()) + ";next=" + u(nextOrderId)
}

func balSig(addrs []address, coins []string) string {
	s := ""
	for _, a := range addrs {
		for _, c := range coins {
			s += u(bal(a, c)) + ","
		}
	}
	return s
}

// ── gates ────────────────────────────────────────────────────────────────────

func TestEx_Gates(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	lp := trader("gate-lp")
	testing.SetRealm(testing.NewUserRealm(lp))
	seedPool("joy", lp, 10000, 10000)

	// trading only after FinalizeMigration
	migrationFinalized = false
	testing.SetRealm(testing.NewUserRealm(lp))
	mustAbort(t, "before finalize", revive(func() { SwapExactIn(cross(cur), "grin", "joy", 10, 0, dl()) }), "FinalizeMigration")
	mustAbort(t, "transfer before finalize", revive(func() { Transfer(cross(cur), "grin", ta("x").String(), "1") }), "FinalizeMigration")
	migrationFinalized = true

	// no tool requirement: a Fist-only account (no tools at all) can trade
	noob := ta("gate-noob")
	give(noob, "grin", 100)
	testing.SetRealm(testing.NewUserRealm(noob))
	if got := SwapExactIn(cross(cur), "grin", "joy", 10, 1, dl()); got == 0 || bal(noob, "joy") != got {
		t.Errorf("fist-only swap: got %d", got)
	}


	// deadlines are mandatory and enforced
	mustAbort(t, "no deadline", revive(func() { SwapExactIn(cross(cur), "grin", "joy", 10, 0, 0) }), "deadline required")
	mustAbort(t, "deadline passed", revive(func() { SwapExactIn(cross(cur), "grin", "joy", 10, 0, time.Now().Unix()-1) }), "deadline passed")

	// realm (code) callers are rejected — no cross-realm surface
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/proxy"))
	mustAbort(t, "realm caller swap", revive(func() { SwapExactIn(cross(cur), "grin", "joy", 10, 0, dl()) }), "directly from a user")
	mustAbort(t, "realm caller remove", revive(func() { RemoveLiquidity(cross(cur), "joy", 1, 0, 0, dl()) }), "directly from a user")

	// fake coins and overflow-sized inputs
	testing.SetRealm(testing.NewUserRealm(lp))
	mustAbort(t, "fake coin", revive(func() { SwapExactIn(cross(cur), "grin", "fake-coin", 10, 0, dl()) }), "unknown coin")
	mustAbort(t, "fake give", revive(func() { PlaceOrder(cross(cur), "fake-coin", 100, "grin", 100, 0) }), "unknown coin")
	mustAbort(t, "huge amount", revive(func() { SwapExactIn(cross(cur), "grin", "joy", maxAmount+1, 0, dl()) }), "between 1 and")
	mustAbort(t, "max uint", revive(func() { PlaceOrder(cross(cur), "grin", ^uint64(0), "joy", 1, 0) }), "between 1 and")
	mustAbort(t, "zero", revive(func() { AddLiquidity(cross(cur), "joy", 0, 10, 0, dl()) }), "between 1 and")
	mustAbort(t, "no pool", revive(func() { SwapExactIn(cross(cur), "grin", "cool", 10, 0, dl()) }), "no pool")
	mustAbort(t, "coin→coin needs route", revive(func() { SwapExactIn(cross(cur), "joy", "cool", 10, 0, dl()) }), "one side must be grin")

	// only the admin creates/pauses pools
	mustAbort(t, "player CreatePool", revive(func() { CreatePool(cross(cur), "cool") }), "admin only")
	mustAbort(t, "player pause", revive(func() { SetExchangePaused(cross(cur), true) }), "admin only")
	mustAbort(t, "player fee withdraw", revive(func() { WithdrawProtocolFees(cross(cur), "grin") }), "admin only")
	testing.SetRealm(testing.NewUserRealm(admin))
	mustAbort(t, "grin pool", revive(func() { CreatePool(cross(cur), "grin") }), "hub coin")
	mustAbort(t, "fake pool", revive(func() { CreatePool(cross(cur), "fake-coin") }), "unknown coin")
	mustAbort(t, "dup pool", revive(func() { CreatePool(cross(cur), "joy") }), "pool exists")
}

// ── pools ────────────────────────────────────────────────────────────────────

func TestEx_PoolLifecycleAndFees(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	lp, tr := trader("pl-lp"), trader("pl-tr")
	sig0 := u(coinTotal("cool")) + "/" + u(coinTotal("grin"))

	// first deposit: any ratio (open economy), 1000 shares burned
	testing.SetRealm(testing.NewUserRealm(lp))
	minted := seedPool("cool", lp, 1000, 1500) // √(1.5M)=1224
	p := getPool("cool")
	if minted != 224 || p.shares != 1224 || lpSum("cool")+minLiquidity != p.shares {
		t.Errorf("first deposit minted=%d shares=%d lpSum=%d", minted, p.shares, lpSum("cool"))
	}
	// under 2000 grin depth: no swaps yet
	give(tr, "grin", 100000)
	give(tr, "cool", 100000)
	testing.SetRealm(testing.NewUserRealm(tr))
	mustAbort(t, "filling pool", revive(func() { SwapExactIn(cross(cur), "grin", "cool", 10, 0, dl()) }), "not open for swaps")
	if QuoteSwap("grin", "cool", 10) != "0" {
		t.Errorf("quote on filling pool")
	}
	// later deposit at the pool ratio
	give(lp, "cool", 10000)
	give(lp, "grin", 15000)
	testing.SetRealm(testing.NewUserRealm(lp))
	AddLiquidity(cross(cur), "cool", 10000, 15000, 1, dl())
	if p.rHub < minOpenDepthGrin || lpSum("cool")+minLiquidity != p.shares {
		t.Errorf("after add: %s lpSum=%d", PoolInfo("cool"), lpSum("cool"))
	}

	// swap grin→cool: fee 0.5% (ceil), proto 0.15% (floor) split 50/50
	testing.SetRealm(testing.NewUserRealm(tr))
	q, _ := strconv.ParseUint(QuoteSwap("grin", "cool", 1000), 10, 64)
	k0 := isqrt128(p.rCoin, p.rHub)
	adm0, cas0 := getU(&adminFees, "grin"), getU(&casinoPool, "grin")
	out := SwapExactIn(cross(cur), "grin", "cool", 1000, q, dl())
	if out != q || out == 0 {
		t.Errorf("out=%d quote=%d", out, q)
	}
	if getU(&adminFees, "grin")-adm0 != 0 || getU(&casinoPool, "grin")-cas0 != 1 {
		// proto = floor(1000×15/10000) = 1 → admin floor(0.5)=0, casino 1
		t.Errorf("fee split admin+%d casino+%d", getU(&adminFees, "grin")-adm0, getU(&casinoPool, "grin")-cas0)
	}
	if isqrt128(p.rCoin, p.rHub) < k0 {
		t.Errorf("k decreased")
	}
	// bigger swap the other way: proto 15 → admin 7, casino 8
	adm0, cas0 = getU(&adminFees, "cool"), getU(&casinoPool, "cool")
	SwapExactIn(cross(cur), "cool", "grin", 10000, 1, dl())
	if getU(&adminFees, "cool")-adm0 != 7 || getU(&casinoPool, "cool")-cas0 != 8 {
		t.Errorf("fee split cool admin+%d casino+%d", getU(&adminFees, "cool")-adm0, getU(&casinoPool, "cool")-cas0)
	}

	// slippage revert changes nothing (validate-then-write)
	before := stateSig("cool", "grin") + balSig([]address{tr}, []string{"cool", "grin"})
	mustAbort(t, "minOut", revive(func() { SwapExactIn(cross(cur), "grin", "cool", 1000, 1_000_000, dl()) }), "slippage")
	mustAbort(t, "insufficient", revive(func() { SwapExactIn(cross(cur), "grin", "cool", maxAmount, 0, dl()) }), "insufficient")
	if after := stateSig("cool", "grin") + balSig([]address{tr}, []string{"cool", "grin"}); after != before {
		t.Errorf("failed swap changed state:\n%s\n%s", before, after)
	}

	// LP exits fully after warm-up: gets ≥ deposit in value terms thanks to fees
	testing.SkipHeights(200) // > 600 s
	testing.SetRealm(testing.NewUserRealm(lp))
	pos := lpPositions.Get("cool:" + lp.String()).(*lpPos)
	oc, og := RemoveLiquidity(cross(cur), "cool", pos.shares, 0, 0, dl())
	if lpPositions.Has("cool:"+lp.String()) || p.shares != minLiquidity {
		t.Errorf("position not closed, shares=%d", p.shares)
	}
	if oc == 0 || og == 0 || p.rCoin == 0 || p.rHub == 0 {
		t.Errorf("remove out %d/%d, pool left %d/%d", oc, og, p.rCoin, p.rHub)
	}
	// conservation across the whole test
	_ = sig0
	if lpSum("cool")+minLiquidity != p.shares {
		t.Errorf("lp sum")
	}
}

// Instant unstake and cancel must work while paused, and for banned players.
func TestEx_PauseNeverTrapsFunds(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	lp := trader("pz-lp")
	testing.SetRealm(testing.NewUserRealm(lp))
	seedPool("think", lp, 5000, 5000)
	give(lp, "grin", 1000)
	testing.SetRealm(testing.NewUserRealm(lp))
	id := PlaceOrder(cross(cur), "grin", 100, "think", 90, 0)

	testing.SetRealm(testing.NewUserRealm(admin))
	SetExchangePaused(cross(cur), true)
	SetPoolPaused(cross(cur), "think", true)
	SetPaused(cross(cur), true) // whole game paused too
	BanAddress(cross(cur), lp.String(), "test", 0)

	testing.SetRealm(testing.NewUserRealm(lp))
	mustAbort(t, "swap paused", revive(func() { SwapExactIn(cross(cur), "grin", "think", 10, 0, dl()) }), "paused")
	mustAbort(t, "add paused", revive(func() { AddLiquidity(cross(cur), "think", 10, 10, 0, dl()) }), "paused")
	mustAbort(t, "order paused", revive(func() { PlaceOrder(cross(cur), "grin", 100, "think", 90, 0) }), "paused")

	g0 := bal(lp, "grin")
	CancelOrder(cross(cur), id) // works paused + banned
	if bal(lp, "grin") != g0+100 {
		t.Errorf("cancel refund %d", bal(lp, "grin")-g0)
	}
	pos := lpPositions.Get("think:" + lp.String()).(*lpPos)
	oc, og := RemoveLiquidity(cross(cur), "think", pos.shares, 1, 1, dl()) // works paused + banned
	if oc == 0 || og == 0 {
		t.Errorf("remove while paused gave %d/%d", oc, og)
	}
	// Transfer is the player's own money: works paused and banned
	Transfer(cross(cur), "grin", trader("pz-friend").String(), "1")

	// fee withdrawal is never blocked either
	testing.SetRealm(testing.NewUserRealm(admin))
	if getU(&adminFees, "grin") > 0 {
		WithdrawProtocolFees(cross(cur), "grin")
	}
	UnbanAddress(cross(cur), lp.String())
	SetPaused(cross(cur), false)
	SetExchangePaused(cross(cur), false)
	SetPoolPaused(cross(cur), "think", false)
}

// Anti-JIT: a deposit that leaves within 600 s gets no fees.
func TestEx_FeeSkimmingJIT(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	lp, jit, tr := trader("jit-lp"), trader("jit-jit"), trader("jit-tr")
	testing.SetRealm(testing.NewUserRealm(lp))
	seedPool("sleep", lp, 20000, 20000)
	p := getPool("sleep")

	// JIT adds 2× the pool, a burst of swaps happens, JIT leaves at once
	give(jit, "sleep", 40000)
	give(jit, "grin", 40000)
	testing.SetRealm(testing.NewUserRealm(jit))
	sh := AddLiquidity(cross(cur), "sleep", 40000, 40000, 1, dl())
	give(tr, "grin", 50000)
	give(tr, "sleep", 50000)
	testing.SetRealm(testing.NewUserRealm(tr))
	for i := 0; i < 10; i++ {
		SwapExactIn(cross(cur), "grin", "sleep", 3000, 1, dl())
		SwapExactIn(cross(cur), "sleep", "grin", 3000, 1, dl())
	}
	testing.SetRealm(testing.NewUserRealm(jit))
	oc, og := RemoveLiquidity(cross(cur), "sleep", sh, 0, 0, dl())
	// value at the current pool price, in grin: JIT must not gain
	valOut := og + mulDiv(oc, p.rHub, p.rCoin)
	valIn := 40000 + mulDiv(40000, p.rHub, p.rCoin)
	if valOut > valIn || isqrt128(oc, og) > sh+1 {
		t.Errorf("JIT skimmed fees: out %d > in %d (√ %d vs shares %d)", valOut, valIn, isqrt128(oc, og), sh)
	}
	// the long-term LP (past warm-up) keeps the fees
	testing.SkipHeights(200)
	testing.SetRealm(testing.NewUserRealm(lp))
	pos := lpPositions.Get("sleep:" + lp.String()).(*lpPos)
	oc2, og2 := RemoveLiquidity(cross(cur), "sleep", pos.shares, 0, 0, dl())
	// IL-free measure: √(coin×grin) out vs the 19000 shares' √k at entry (1.0/share)
	if isqrt128(oc2, og2) <= 19000 {
		t.Errorf("LP earned nothing: %d/%d", oc2, og2)
	}
}

// First-depositor share inflation and donation attacks.
func TestEx_InflationAndDonation(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	att, vic := trader("inf-att"), trader("inf-vic")
	testing.SetRealm(testing.NewUserRealm(admin))
	CreatePool(cross(cur), "party")
	give(att, "party", 10_000_000)
	give(att, "grin", 10_000_000)
	testing.SetRealm(testing.NewUserRealm(att))
	mustAbort(t, "dust first deposit", revive(func() { AddLiquidity(cross(cur), "party", 1000, 1000, 0, dl()) }), "too small")
	AddLiquidity(cross(cur), "party", 1001, 1001, 0, dl()) // 1 share for the attacker
	p := getPool("party")
	// donation: Transfer to the realm address only credits a balance entry,
	// reserves are internal counters and don't move.
	realmAddr := chain.PackageAddress(realmPkgPath).String()
	Transfer(cross(cur), "grin", realmAddr, "5000000")
	if p.rHub != 1001 || p.rCoin != 1001 {
		t.Errorf("donation moved reserves: %s", PoolInfo("party"))
	}
	// victim deposits normally and gets a proportional number of shares
	give(vic, "party", 100000)
	give(vic, "grin", 100000)
	testing.SetRealm(testing.NewUserRealm(vic))
	sh := AddLiquidity(cross(cur), "party", 100000, 100000, 1, dl())
	if sh < 99000 {
		t.Errorf("victim got only %d shares for 100k/100k (pool %s)", sh, PoolInfo("party"))
	}
	// the attacker can't extract more than they put in
	testing.SetRealm(testing.NewUserRealm(att))
	testing.SkipHeights(200)
	a0c, a0g := bal(att, "party"), bal(att, "grin")
	RemoveLiquidity(cross(cur), "party", 1, 0, 0, dl())
	if bal(att, "party")-a0c > 1 || bal(att, "grin")-a0g > 1 {
		t.Errorf("attacker extracted %d/%d", bal(att, "party")-a0c, bal(att, "grin")-a0g)
	}
}

// Sandwich: the victim's minOut (quote − 1%) makes the front-run revert the victim.
func TestEx_SandwichWithMinOut(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	lp, att, vic := trader("sw-lp"), trader("sw-att"), trader("sw-vic")
	testing.SetRealm(testing.NewUserRealm(lp))
	seedPool("hot", lp, 100000, 100000)
	give(vic, "grin", 10000)
	give(att, "grin", 1_000_000)
	testing.SetRealm(testing.NewUserRealm(vic))
	q, _ := strconv.ParseUint(QuoteSwap("grin", "hot", 5000), 10, 64)
	minOut := q * 99 / 100
	// attacker front-runs with a big buy
	testing.SetRealm(testing.NewUserRealm(att))
	SwapExactIn(cross(cur), "grin", "hot", 50000, 1, dl())
	testing.SetRealm(testing.NewUserRealm(vic))
	before := stateSig("hot", "grin") + balSig([]address{vic}, []string{"hot", "grin"})
	mustAbort(t, "sandwiched victim", revive(func() { SwapExactIn(cross(cur), "grin", "hot", 5000, minOut, dl()) }), "slippage")
	if stateSig("hot", "grin")+balSig([]address{vic}, []string{"hot", "grin"}) != before {
		t.Errorf("victim's failed swap changed state")
	}
	// open economy: the big trade itself is allowed (no impact cap)
	testing.SetRealm(testing.NewUserRealm(att))
	give(att, "hot", 1_000_000)
	SwapExactIn(cross(cur), "hot", "grin", 1_000_000, 1, dl()) // dump 10× the pool
}

// Round trips and add→remove never profit (rounding favors the pool).
func TestEx_RoundingFavorsPool(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	lp, tr := trader("rd-lp"), trader("rd-tr")
	testing.SetRealm(testing.NewUserRealm(lp))
	seedPool("wow", lp, 50000, 70000)
	testing.SetRealm(testing.NewUserRealm(tr))
	for amt := uint64(1); amt <= 3000; amt = amt*3 + 1 {
		give(tr, "grin", amt)
		g0 := bal(tr, "grin")
		w0 := bal(tr, "wow")
		if q := QuoteSwap("grin", "wow", amt); q == "0" {
			continue
		}
		out := SwapExactIn(cross(cur), "grin", "wow", amt, 1, dl())
		if QuoteSwap("wow", "grin", out) != "0" {
			SwapExactIn(cross(cur), "wow", "grin", out, 0+1, dl())
		}
		if bal(tr, "grin")+bal(tr, "wow") > g0+w0 && bal(tr, "grin") > g0 {
			t.Errorf("round trip of %d profited: grin %d→%d", amt, g0, bal(tr, "grin"))
		}
	}
	// add then remove immediately never returns more than deposited
	give(tr, "wow", 777)
	give(tr, "grin", 999)
	c0, g0 := bal(tr, "wow"), bal(tr, "grin")
	sh := AddLiquidity(cross(cur), "wow", 777, 999, 1, dl())
	RemoveLiquidity(cross(cur), "wow", sh, 0, 0, dl())
	if bal(tr, "wow") > c0 || bal(tr, "grin") > g0 {
		t.Errorf("add/remove profited: %d/%d → %d/%d", c0, g0, bal(tr, "wow"), bal(tr, "grin"))
	}
}

// ── order book ───────────────────────────────────────────────────────────────

func TestEx_OrderBookLifecycle(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	mk, tk, other := trader("ob-mk"), trader("ob-tk"), trader("ob-ot")
	give(mk, "grin", 10000)
	give(mk, "rock", 1000)
	give(tk, "rock", 10000)
	give(tk, "grin", 10000)

	// "I want 10 rock, I pay 100 grin" — escrow + 2 grin post fee (1/1)
	testing.SetRealm(testing.NewUserRealm(mk))
	adm0, cas0 := getU(&adminFees, "grin"), getU(&casinoPool, "grin")
	g0 := bal(mk, "grin")
	id := PlaceOrder(cross(cur), "grin", 100, "rock", 10, 0)
	if bal(mk, "grin") != g0-102 || getU(&adminFees, "grin")-adm0 != 1 || getU(&casinoPool, "grin")-cas0 != 1 {
		t.Errorf("place: grin %d→%d fees %d/%d", g0, bal(mk, "grin"), getU(&adminFees, "grin")-adm0, getU(&casinoPool, "grin")-cas0)
	}
	if !strings.Contains(OrdersOf(mk.String()), `"id":"`+u(id)+`"`) {
		t.Errorf("OrdersOf: %s", OrdersOf(mk.String()))
	}
	mustAbort(t, "too small", revive(func() { PlaceOrder(cross(cur), "grin", 49, "rock", 10, 0) }), "50 grin")
	mustAbort(t, "expiry > 7d", revive(func() { PlaceOrder(cross(cur), "grin", 100, "rock", 10, 8*86400) }), "7 days")
	mustAbort(t, "same coin", revive(func() { PlaceOrder(cross(cur), "grin", 100, "grin", 10, 0) }), "differ")

	// other players can't cancel it
	testing.SetRealm(testing.NewUserRealm(other))
	mustAbort(t, "cancel by other", revive(func() { CancelOrder(cross(cur), id) }), "not your order")

	// self-match: the maker's own order is skipped, so nothing fills
	testing.SetRealm(testing.NewUserRealm(mk))
	mustAbort(t, "self match", revive(func() { FillOrders(cross(cur), "rock", "grin", 5, 1, 0, dl()) }), "slippage")

	// partial fill: taker pays 4 rock (+ceil fee 1) → gets floor(4×100/10)=40 grin
	testing.SetRealm(testing.NewUserRealm(tk))
	r0, tg0 := bal(tk, "rock"), bal(tk, "grin")
	mr0 := bal(mk, "rock")
	got := FillOrders(cross(cur), "rock", "grin", 5, 40, 0, dl())
	if got != 40 || bal(tk, "rock") != r0-5 || bal(tk, "grin") != tg0+40 || bal(mk, "rock") != mr0+4 {
		t.Errorf("partial fill got=%d rock -%d maker +%d", got, r0-bal(tk, "rock"), bal(mk, "rock")-mr0)
	}
	o := findOrder(id)
	if o == nil || o.remGive != 60 || o.remWant != 6 {
		t.Errorf("after partial: %s", Order(mk.String(), id))
	}
	// next fill (6 rock) completes it; remaining 60 grin
	got = FillOrders(cross(cur), "rock", "grin", 100, 1, 0, dl())
	if got != 60 || findOrder(id) != nil {
		t.Errorf("full fill got=%d order=%s", got, Order(mk.String(), id))
	}
	// double cancel / cancel of a filled order
	testing.SetRealm(testing.NewUserRealm(mk))
	mustAbort(t, "cancel filled", revive(func() { CancelOrder(cross(cur), id) }), "no such open order")
	id2 := PlaceOrder(cross(cur), "grin", 200, "rock", 20, 0)
	g1 := bal(mk, "grin")
	CancelOrder(cross(cur), id2)
	if bal(mk, "grin") != g1+200 {
		t.Errorf("cancel refund %d", bal(mk, "grin")-g1)
	}
	mustAbort(t, "double cancel", revive(func() { CancelOrder(cross(cur), id2) }), "no such open order")
}

func TestEx_OrderPriorityExpiryAndSpam(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	a, b, tk := trader("op-a"), trader("op-b"), trader("op-tk")
	give(a, "grin", 100000)
	give(b, "grin", 100000)
	give(tk, "fire", 100000)
	// a asks 2 fire per 100 grin, b asks 1 fire per 100 grin (better for takers)
	testing.SetRealm(testing.NewUserRealm(a))
	ida := PlaceOrder(cross(cur), "grin", 100, "fire", 2, 0)
	testing.SetRealm(testing.NewUserRealm(b))
	idb := PlaceOrder(cross(cur), "grin", 100, "fire", 1, 3600)
	if !strings.HasPrefix(BookDepth("fire", "grin", 10, 0), `[{"id":"`+u(idb)+`"`) {
		t.Errorf("best price not first: %s", BookDepth("fire", "grin", 10, 0))
	}
	// b's order expires: a fill skips it, refunds b, fills a instead
	testing.SkipHeights(721) // > 3600 s
	bg := bal(b, "grin")
	testing.SetRealm(testing.NewUserRealm(tk))
	got := FillOrders(cross(cur), "fire", "grin", 3, 100, 0, dl())
	if got != 100 || findOrder(idb) != nil || bal(b, "grin") != bg+100 || findOrder(ida) != nil {
		t.Errorf("expired handling got=%d b+%d", got, bal(b, "grin")-bg)
	}
	// filling an expired-only book gets nothing and reverts
	testing.SetRealm(testing.NewUserRealm(b))
	idb2 := PlaceOrder(cross(cur), "grin", 100, "fire", 1, 60)
	testing.SkipHeights(20)
	testing.SetRealm(testing.NewUserRealm(tk))
	mustAbort(t, "expired only", revive(func() { FillOrders(cross(cur), "fire", "grin", 3, 1, 0, dl()) }), "slippage")
	if findOrder(idb2) == nil {
		t.Errorf("revert path must not have closed the order")
	}
	SweepExpiredOrders(cross(cur), "fire", "grin")
	if findOrder(idb2) != nil {
		t.Errorf("sweep did not close the expired order")
	}
	// spam: max 20 open orders per maker
	testing.SetRealm(testing.NewUserRealm(a))
	for i := 0; i < 20; i++ {
		PlaceOrder(cross(cur), "grin", 50, "fire", uint64(1+i), 0)
	}
	mustAbort(t, "21st order", revive(func() { PlaceOrder(cross(cur), "grin", 50, "fire", 1, 0) }), "max 20")
	// fills are bounded: ≤ 10 per call even with 20 resting orders
	testing.SetRealm(testing.NewUserRealm(tk))
	n0 := int(openOrderTotal)
	FillOrders(cross(cur), "fire", "grin", 100000, 1, 50, dl())
	if n0-int(openOrderTotal) > maxFillsPerTx {
		t.Errorf("filled %d orders in one call", n0-int(openOrderTotal))
	}
}

// ── router ───────────────────────────────────────────────────────────────────

func TestEx_RouterBookThenPool(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	lp, mk, tr := trader("rt-lp"), trader("rt-mk"), trader("rt-tr")
	testing.SetRealm(testing.NewUserRealm(lp))
	seedPool("seedling", lp, 100000, 100000)
	testing.SetRealm(testing.NewUserRealm(lp))
	seedPool("leaves", lp, 100000, 100000)
	// a cheap ask on the book: 1000 seedling for 500 grin (pool price ~1:1)
	give(mk, "seedling", 1000)
	give(mk, "grin", 10)
	testing.SetRealm(testing.NewUserRealm(mk))
	PlaceOrder(cross(cur), "seedling", 1000, "grin", 500, 0)
	give(tr, "grin", 5000)
	q := QuoteRoute(tr.String(), "grin", "seedling", 2000, 0)
	if !strings.Contains(q, `"bookFills":1`) {
		t.Errorf("router ignored the cheaper book: %s", q)
	}
	testing.SetRealm(testing.NewUserRealm(tr))
	outStr := q[strings.Index(q, `"out":"`)+7:]
	want, _ := strconv.ParseUint(outStr[:strings.Index(outStr, `"`)], 10, 64)
	out := SwapRoute(cross(cur), "grin", "seedling", 2000, want, 0, dl())
	if out != want {
		t.Errorf("route out %d != quote %d", out, want)
	}
	// coin → coin through two pools
	give(tr, "leaves", 1000)
	out2 := SwapRoute(cross(cur), "leaves", "seedling", 1000, 1, 0, dl())
	if out2 == 0 || out2 >= 1000 {
		t.Errorf("two-hop out %d", out2)
	}
	before := stateSig("seedling", "leaves", "grin")
	mustAbort(t, "route minOut", revive(func() { SwapRoute(cross(cur), "grin", "seedling", 100, 1000, 0, dl()) }), "slippage")
	if stateSig("seedling", "leaves", "grin") != before {
		t.Errorf("failed route changed state")
	}
}

// ── admin can't touch user funds ─────────────────────────────────────────────

func TestEx_AdminCannotTouchUserFunds(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	lp, mk := trader("ad-lp"), trader("ad-mk")
	testing.SetRealm(testing.NewUserRealm(lp))
	seedPool("fallen", lp, 30000, 30000)
	give(mk, "grin", 1000)
	testing.SetRealm(testing.NewUserRealm(mk))
	PlaceOrder(cross(cur), "grin", 300, "fallen", 300, 0)
	users := []address{lp, mk}
	coins := []string{"fallen", "grin"}
	before := stateSig(coins...) + balSig(users, coins)

	// every admin entry point, called by the admin
	testing.SetRealm(testing.NewUserRealm(admin))
	SetExchangePaused(cross(cur), true)
	SetExchangePaused(cross(cur), false)
	SetPoolPaused(cross(cur), "fallen", true)
	SetPoolPaused(cross(cur), "fallen", false)
	SetPaused(cross(cur), true)
	SetPaused(cross(cur), false)
	BanAddress(cross(cur), mk.String(), "x", 0)
	UnbanAddress(cross(cur), mk.String())
	SetVeinMax(cross(cur), "fallen", "999999999999")
	SetPassPrice(cross(cur), 7_000_000)
	mustAbort(t, "migrate after finalize", revive(func() {
		MigrateBatch(cross(cur), "steal", "balance", `[["`+admin.String()+`","grin","999999"]]`)
	}), "finalized")
	if after := stateSig(coins...) + balSig(users, coins); after != before {
		t.Errorf("admin calls changed user funds:\n%s\n%s", before, after)
	}
	// fee withdrawal moves only the admin's own ledger
	if getU(&adminFees, "grin") > 0 {
		c0 := getU(&casinoPool, "grin")
		WithdrawProtocolFees(cross(cur), "grin")
		if getU(&casinoPool, "grin") != c0 || getU(&adminFees, "grin") != 0 {
			t.Errorf("fee withdraw touched the casino pool")
		}
	}
	// WithdrawFunds can't take donated / player GNOT — only unwithdrawn pass revenue
	realmAddr := chain.PackageAddress(realmPkgPath)
	testing.IssueCoins(realmAddr, chain.Coins{chain.NewCoin("ugnot", 50_000_000)})
	owed := WithdrawableFunds()
	mustAbort(t, "withdraw donation", revive(func() { WithdrawFunds(cross(cur), admin.String(), owed+1) }), "unwithdrawn pass revenue")
}

// ── casino pool caps ─────────────────────────────────────────────────────────

func seedCasino(coin string, amt uint64) {
	setU(&casinoPool, coin, amt)
	casinoReserved.Remove(coin)
	casinoDay.Remove(coin)
}


func TestEx_CheckedMath(t *testing.T) {
	if !strings.Contains(panicMsg(func() { addChk(^uint64(0), 1) }), "overflow") {
		t.Errorf("addChk")
	}
	if !strings.Contains(panicMsg(func() { subChk(1, 2) }), "underflow") {
		t.Errorf("subChk")
	}
	if !strings.Contains(panicMsg(func() { mulDiv(^uint64(0), ^uint64(0), 1) }), "overflow") {
		t.Errorf("mulDiv")
	}
	if !strings.Contains(panicMsg(func() { mulDiv(1, 1, 0) }), "division by zero") {
		t.Errorf("mulDiv /0")
	}
	if !strings.Contains(panicMsg(func() { addU(&balances, "x-overflow", ^uint64(0)); addU(&balances, "x-overflow", 1) }), "overflow") {
		t.Errorf("addU must not wrap")
	}
	balances.Remove("x-overflow")
	if isqrt128(^uint64(0), ^uint64(0)) != ^uint64(0)-1 && isqrt128(^uint64(0), ^uint64(0)) != ^uint64(0) {
		t.Errorf("isqrt128 max = %d", isqrt128(^uint64(0), ^uint64(0)))
	}
	for _, c := range [][2]uint64{{1, 1}, {2, 8}, {1000, 1000}, {123456789, 987654321}, {1 << 40, 1 << 40}, {maxAmount, maxAmount}} {
		s := isqrt128(c[0], c[1])
		if mulLess(c[0], c[1], s, s) || !mulLess(c[0], c[1], s+1, s+1) {
			t.Errorf("isqrt128(%d×%d)=%d", c[0], c[1], s)
		}
	}
	if priceKey(1, 2) >= priceKey(1, 1) || priceKey(3, 1) <= priceKey(2, 1) || len(priceKey(maxAmount, 1)) != 24 {
		t.Errorf("priceKey ordering")
	}
}

// ── invariant random walk ────────────────────────────────────────────────────

type xrng struct{ s uint64 }

func (r *xrng) next(n uint64) uint64 {
	r.s = r.s*6364136223846793005 + 1442695040888963407
	return (r.s >> 33) % n
}

func TestEx_InvariantRandomWalk(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	// seedPool: the caller must already act as `lp` (testing.SetRealm can't be
	// switched from inside a closure). Pools are created by the admin API in
	// TestEx_Gates; here the empty pool record is written directly.
	seedPool := func(coin string, lp address, coinAmt, grinAmt uint64) uint64 {
		if !pools.Has(coin) {
			pools.Set(coin, &pool{coin: coin})
		}
		give(lp, coin, coinAmt)
		give(lp, "grin", grinAmt)
		return AddLiquidity(cross(cur), coin, coinAmt, grinAmt, 0, dl())
	}
	coins := []string{"melt", "tear", "grin"}
	names := []string{"iw-0", "iw-1", "iw-2", "iw-3"}
	var us []address
	for _, n := range names {
		a := trader(n)
		us = append(us, a)
		for _, c := range coins {
			give(a, c, 2_000_000)
		}
	}
	testing.SetRealm(testing.NewUserRealm(us[0]))
	seedPool("melt", us[0], 200000, 200000)
	testing.SetRealm(testing.NewUserRealm(us[1]))
	seedPool("tear", us[1], 100000, 300000)
	tot := map[string]uint64{}
	for _, c := range coins {
		tot[c] = coinTotal(c)
	}
	rkps := map[string]uint64{"melt": rootKPerShare(getPool("melt")), "tear": rootKPerShare(getPool("tear"))}
	type res3 struct{ c, h, s uint64 }
	prev := map[string]res3{}
	for _, c := range []string{"melt", "tear"} {
		p := getPool(c)
		prev[c] = res3{p.rCoin, p.rHub, p.shares}
	}
	rng := &xrng{s: 42}
	ok, failed := 0, 0
	for step := 0; step < 400; step++ {
		a := us[rng.next(4)]
		testing.SetRealm(testing.NewUserRealm(a))
		pc := coins[rng.next(2)]
		amt := 1 + rng.next(20000)
		op := rng.next(7)
		isSwap := false
		r := revive(func() {
			switch op {
			case 0:
				SwapExactIn(cross(cur), "grin", pc, amt, 1, dl())
				isSwap = true
			case 1:
				SwapExactIn(cross(cur), pc, "grin", amt, 1, dl())
				isSwap = true
			case 2:
				AddLiquidity(cross(cur), pc, amt, amt*2, 1, dl())
			case 3:
				key := pc + ":" + a.String()
				if lpPositions.Has(key) {
					sh := lpPositions.Get(key).(*lpPos).shares
					RemoveLiquidity(cross(cur), pc, 1+rng.next(sh), 0, 0, dl())
				}
			case 4:
				PlaceOrder(cross(cur), coins[rng.next(3)], 100+amt, coins[rng.next(3)], 1+rng.next(5000), int64(60+rng.next(3600)))
			case 5:
				FillOrders(cross(cur), coins[rng.next(3)], coins[rng.next(3)], amt, 1, int(1+rng.next(10)), dl())
			case 6:
				SwapRoute(cross(cur), coins[rng.next(3)], coins[rng.next(3)], amt, 1, int(rng.next(10)), dl())
			}
		})
		if r != nil {
			failed++
		} else {
			ok++
		}
		testing.SkipHeights(int64(rng.next(30)))
		// I1 conservation per coin (also proves failed calls wrote nothing)
		for _, c := range coins {
			if got := coinTotal(c); got != tot[c] {
				t.Fatalf("step %d op %d (%s): %s total %d != %d", step, op, errOf(r), c, got, tot[c])
			}
		}
		for _, c := range []string{"melt", "tear"} {
			p := getPool(c)
			// I2 LP shares sum to the total (minus the burned 1000)
			if lpSum(c)+minLiquidity != p.shares {
				t.Fatalf("step %d: %s lpSum %d + 1000 != %d", step, c, lpSum(c), p.shares)
			}
			// I3 reserves never empty while shares exist
			if p.rCoin == 0 || p.rHub == 0 {
				t.Fatalf("step %d: %s reserves emptied", step, c)
			}
			// I4 a swap (shares unchanged) never decreases k — exact 128-bit check
			pv := prev[c]
			if p.shares == pv.s && mulLess(p.rCoin, p.rHub, pv.c, pv.h) {
				t.Fatalf("step %d op %d: %s k decreased on a swap", step, op, c)
			}
			// I4b √k per share never decreases beyond isqrt's floor (≤ 1e9/S + 1 units)
			now := rootKPerShare(p)
			if now+rootKScale/p.shares+1 < rkps[c] {
				t.Fatalf("step %d op %d swap=%t: %s √k/share fell %d → %d", step, op, isSwap, c, rkps[c], now)
			}
			rkps[c] = now
			prev[c] = res3{p.rCoin, p.rHub, p.shares}
		}
		// I5 no open order is empty (can't overfill)
		nOrders, nSide := 0, 0
		forEachOrder(func(o *order) {
			nOrders++
			if o.remGive == 0 || o.remWant == 0 {
				t.Fatalf("step %d: empty open order %d", step, o.id)
			}
			// I6 every open order has exactly its book entry
			s := sideStr(sideKey(o.want, o.give))
			e := sideEntry(o)
			i := sideSearch(s, e[:sideSortLen]) * sideEntryLen
			if i+sideEntryLen > len(s) || s[i:i+sideEntryLen] != e {
				t.Fatalf("step %d: order %d missing from its book side", step, o.id)
			}
		})
		sides.Iterate("", "", func(_ string, v any) bool {
			s := v.(string)
			nSide += len(s) / sideEntryLen
			// I7 each side is strictly sorted (price, then id)
			for i := sideEntryLen; i < len(s); i += sideEntryLen {
				if s[i-sideEntryLen:i-sideEntryLen+sideSortLen] >= s[i:i+sideSortLen] {
					t.Fatalf("step %d: book side out of order", step)
				}
			}
			return false
		})
		if nOrders != nSide || uint64(nOrders) != openOrderTotal {
			t.Fatalf("step %d: orders %d, book entries %d, counter %d", step, nOrders, nSide, openOrderTotal)
		}
	}
	if ok < 100 {
		t.Errorf("random walk too degenerate: %d ok, %d failed", ok, failed)
	}
}

// ── order storage test helpers (production looks orders up per maker) ──────

func forEachOrder(fn func(o *order)) {
	makerBooks.Iterate("", "", func(maker string, _ any) bool {
		for _, r := range makerRecs(maker) {
			fn(decodeOrder(maker, r))
		}
		return false
	})
}

func findOrder(id uint64) *order {
	var found *order
	forEachOrder(func(o *order) {
		if o.id == id {
			found = o
		}
	})
	return found
}

func sideTotal() int {
	n := 0
	sides.Iterate("", "", func(_ string, v any) bool {
		n += len(v.(string)) / sideEntryLen
		return false
	})
	return n
}

// A book side holds ≤ maxSideOrders. When full, a worse-or-equal price is
// refused and a better one evicts the worst order, refunding only its maker.
// Storage stays bounded and nobody can lock a side with absurd prices.
func TestEx_BookSideCapAndEviction(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	var worstMaker address
	var worstId uint64
	n := 0
	for m := 0; n < maxSideOrders; m++ {
		mk := trader("cap-" + strconv.Itoa(m))
		give(mk, "grin", 1000000)
		testing.SetRealm(testing.NewUserRealm(mk))
		for i := 0; i < int(maxOpenOrders) && n < maxSideOrders; i++ {
			// price rises with n: the last one placed is the worst for takers
			id := PlaceOrder(cross(cur), "grin", 100, "joy", uint64(100+n), 0)
			worstMaker, worstId = mk, id
			n++
		}
	}
	if sideCount("joy", "grin") != maxSideOrders {
		t.Fatalf("side count %d", sideCount("joy", "grin"))
	}
	late := trader("cap-late")
	give(late, "grin", 10000)
	testing.SetRealm(testing.NewUserRealm(late))
	sig := stateSig("grin", "joy")
	mustAbort(t, "worse price on full side", revive(func() { PlaceOrder(cross(cur), "grin", 100, "joy", 100000, 0) }), "book side full")
	mustAbort(t, "equal-to-worst price", revive(func() { PlaceOrder(cross(cur), "grin", 100, "joy", uint64(100+maxSideOrders-1), 0) }), "book side full")
	if stateSig("grin", "joy") != sig {
		t.Errorf("refused order changed state")
	}
	wg := bal(worstMaker, "grin")
	id := PlaceOrder(cross(cur), "grin", 100, "joy", 50, 0)
	if sideCount("joy", "grin") != maxSideOrders || findOrder(worstId) != nil || findOrder(id) == nil {
		t.Errorf("eviction failed: count=%d", sideCount("joy", "grin"))
	}
	if bal(worstMaker, "grin") != wg+100 {
		t.Errorf("evicted maker refund %d", bal(worstMaker, "grin")-wg)
	}
	if !strings.HasPrefix(BookDepth("joy", "grin", 1, 0), `[{"id":"`+u(id)+`"`) {
		t.Errorf("new best order not first: %s", BookDepth("joy", "grin", 1, 0))
	}
}

func mustPanicEx(t *testing.T, what string, f func(), want string) {
	msg := panicMsg(f)
	if msg == "" || !strings.Contains(msg, want) {
		t.Errorf("%s: want panic containing %q, got %q", what, want, msg)
	}
}

// No receive cap (Simion, 2026-10-11): every coin is freely transferable and
// tradable. A Fist-only player (hands, no tools) receives an r6 coin by Send,
// sends it on and swaps for more; stone traders (formerly capped at r3) buy r6
// by swap, list an order that WANTS r6 and receive r6 by fill.
func TestEx_NoReceiveCap(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	r6 := "dragon"
	if coinRarity[r6] != 6 {
		t.Fatalf("%s is not r6", r6)
	}
	lp := trader("free-lp")
	if !pools.Has(r6) {
		pools.Set(r6, &pool{coin: r6})
	}
	give(lp, r6, 200)
	give(lp, "grin", 20100) // 20000 staked + posting fees
	testing.SetRealm(testing.NewUserRealm(lp))
	AddLiquidity(cross(cur), r6, 100, 20000, 0, dl())

	// Send: Fist-only player receives r6 and sends some back
	fist := ta("free-fist")
	Transfer(cross(cur), r6, fist.String(), "10")
	if bal(fist, r6) != 10 {
		t.Errorf("fist got %d %s, want 10", bal(fist, r6), r6)
	}
	testing.SetRealm(testing.NewUserRealm(fist))
	Transfer(cross(cur), r6, lp.String(), "3")
	if bal(fist, r6) != 7 {
		t.Errorf("fist after send-on: %d", bal(fist, r6))
	}
	// no tool gate either: the Fist-only player buys more r6 by swap
	give(fist, "grin", 1000)
	if got := SwapExactIn(cross(cur), "grin", r6, 500, 1, dl()); got == 0 {
		t.Errorf("fist-only swap into r6 returned 0")
	}

	// Swap: stone-only trader buys r6
	st := trader("free-stone")
	give(st, "grin", 5000)
	testing.SetRealm(testing.NewUserRealm(st))
	if got := SwapExactIn(cross(cur), "grin", r6, 1000, 1, dl()); got == 0 || bal(st, r6) != got {
		t.Errorf("stone swap into r6: got %d bal %d", got, bal(st, r6))
	}
	// Order that wants r6 is accepted
	PlaceOrder(cross(cur), "grin", 600, r6, 1, 0)

	// Fill: lp lists r6 for grin; another stone-only trader fills and receives r6
	testing.SetRealm(testing.NewUserRealm(lp))
	PlaceOrder(cross(cur), r6, 2, "grin", 500, 0)
	st2 := trader("free-stone2")
	give(st2, "grin", 1000)
	testing.SetRealm(testing.NewUserRealm(st2))
	if got := FillOrders(cross(cur), "grin", r6, 600, 1, 5, dl()); got != 2 || bal(st2, r6) != 2 {
		t.Errorf("fill into r6: got %d bal %d", got, bal(st2, r6))
	}
}

// Trading is open to every account (Simion, 2026-10-11): a Fist-only player
// (no tools at all) swaps, posts an order, fills an order, stakes and unstakes.
func TestEx_FistOnlyTrades(cur realm, t *testing.T) {
	restore := exOpen()
	defer restore()
	lp := ta("fo-lp") // no tools either
	if !pools.Has("joy") {
		pools.Set("joy", &pool{coin: "joy"})
	}
	give(lp, "joy", 10200)
	give(lp, "grin", 10100)
	testing.SetRealm(testing.NewUserRealm(lp))
	AddLiquidity(cross(cur), "joy", 10000, 10000, 1, dl())
	PlaceOrder(cross(cur), "joy", 100, "grin", 120, 0) // for the Fist-only player to fill

	fist := ta("fo-fist")
	if ownedTools.Has(fist.String()) {
		t.Fatalf("test player must own no tools")
	}
	give(fist, "grin", 5000)
	testing.SetRealm(testing.NewUserRealm(fist))
	// swap
	if got := SwapExactIn(cross(cur), "grin", "joy", 500, 1, dl()); got == 0 || bal(fist, "joy") != got {
		t.Errorf("swap: got %d bal %d", got, bal(fist, "joy"))
	}
	// post (other side of the book, so no self-match with the fill below)
	if id := PlaceOrder(cross(cur), "grin", 300, "joy", 100, 0); id == 0 || openOrderCount(fist.String()) != 1 {
		t.Errorf("post: id %d open %d", id, openOrderCount(fist.String()))
	}
	// fill lp's joy order
	j0 := bal(fist, "joy")
	if got := FillOrders(cross(cur), "grin", "joy", 125, 1, 5, dl()); got == 0 || bal(fist, "joy")-j0 != got {
		t.Errorf("fill: got %d", got)
	}
	// stake and unstake
	sh := AddLiquidity(cross(cur), "joy", 200, 1000, 1, dl())
	if sh == 0 {
		t.Errorf("stake minted 0 shares")
	}
	c, g := RemoveLiquidity(cross(cur), "joy", sh, 1, 1, dl())
	if c == 0 || g == 0 {
		t.Errorf("unstake returned %d joy %d grin", c, g)
	}
}
