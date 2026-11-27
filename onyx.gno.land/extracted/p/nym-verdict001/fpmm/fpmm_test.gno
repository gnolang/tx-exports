package fpmm

import "testing"

func invariantProduct(p Pool) u128 {
	return u128Mul64(uint64(p.ReserveYes), uint64(p.ReserveNo))
}

func TestU128Arithmetic(t *testing.T) {
	max64 := ^uint64(0)
	max128 := u128{hi: max64, lo: max64}

	// Add carry and overflow.
	s, ok := u128Add(u128{hi: 0, lo: max64}, u128{hi: 0, lo: 1})
	if !ok || s.hi != 1 || s.lo != 0 {
		t.Fatalf("expected carry to hi=1 lo=0, got %+v ok=%v", s, ok)
	}
	if _, ok := u128Add(max128, u128{hi: 0, lo: 1}); ok {
		t.Fatalf("expected 128-bit overflow")
	}

	// Sub borrow and underflow.
	d, ok := u128Sub(u128{hi: 1, lo: 0}, u128{hi: 0, lo: 1})
	if !ok || d.hi != 0 || d.lo != max64 {
		t.Fatalf("expected borrow diff lo=max64, got %+v ok=%v", d, ok)
	}
	if _, ok := u128Sub(u128{hi: 0, lo: 5}, u128{hi: 0, lo: 6}); ok {
		t.Fatalf("expected underflow")
	}

	// Mul64 and Div64 when hi >= d.
	p := u128Mul64(max64, max64)
	if p.hi != max64-1 || p.lo != 1 {
		t.Fatalf("unexpected max64^2: %+v", p)
	}
	q, rem := u128Div64(u128{hi: 100, lo: 17}, 3)
	// Verify q*3 + rem == {100, 17}.
	p1 := u128Mul64(q.lo, 3)
	p2 := u128{hi: q.hi * 3, lo: 0}
	recon, ok := u128Add(p1, p2)
	if !ok {
		t.Fatalf("reconstruct overflow")
	}
	recon, ok = u128Add(recon, u128From64(rem))
	if !ok || recon.hi != 100 || recon.lo != 17 || rem >= 3 {
		t.Fatalf("div reconstruction mismatch: recon=%+v rem=%d", recon, rem)
	}

	// mulDivFloor / mulDivCeil exactness.
	qf, ok := mulDivFloor(10, 10, 3)
	if !ok || qf != 33 {
		t.Fatalf("mulDivFloor(10,10,3) = %d, want 33", qf)
	}
	qc, ok := mulDivCeil(10, 10, 3)
	if !ok || qc != 34 {
		t.Fatalf("mulDivCeil(10,10,3) = %d, want 34", qc)
	}
	qcExact, ok := mulDivCeil(10, 9, 3)
	if !ok || qcExact != 30 {
		t.Fatalf("mulDivCeil(10,9,3) = %d, want 30", qcExact)
	}
}

func TestU128SqrtExact(t *testing.T) {
	cases := []u128{
		{0, 0},
		{0, 1},
		{0, 2},
		{0, 3},
		{0, 4},
		{0, 15},
		{0, 16},
		{0, 17},
		{0, ^uint64(0)},
		{1, 0},
		{1, 1},
		u128Mul64(1_000_000_000_000, 1_000_000_000_000),
		{^uint64(0) - 1, 1}, // max64^2
		{^uint64(0), ^uint64(0)},
	}
	// Add k^2-1 and k^2+1 around large values.
	sq := u128Mul64(1_234_567_890_123, 1_234_567_890_123)
	sqMinus, _ := u128Sub(sq, u128From64(1))
	sqPlus, _ := u128Add(sq, u128From64(1))
	cases = append(cases, sq, sqMinus, sqPlus)

	for i, n := range cases {
		fl := u128SqrtFloor(n)
		flSq := u128Mul64(fl, fl)
		if u128Cmp(flSq, n) > 0 {
			t.Fatalf("case %d: floor^2 > n (%+v > %+v)", i, flSq, n)
		}
		if fl < ^uint64(0) {
			nextSq := u128Mul64(fl+1, fl+1)
			if u128Cmp(nextSq, n) <= 0 {
				t.Fatalf("case %d: (floor+1)^2 <= n (%+v <= %+v)", i, nextSq, n)
			}
		}

		cl, ok := u128SqrtCeil(n)
		if n.hi == ^uint64(0) && n.lo == ^uint64(0) {
			// sqrt(2^128 - 1) is between 2^64 - 1 and 2^64, so ceil overflows uint64.
			if ok {
				t.Fatalf("expected ceil overflow for max uint128")
			}
			continue
		}
		if !ok {
			t.Fatalf("case %d: unexpected sqrtCeil failure", i)
		}
		clSq := u128Mul64(cl, cl)
		if u128Cmp(clSq, n) < 0 {
			t.Fatalf("case %d: ceil^2 < n", i)
		}
		if cl > 0 {
			prevSq := u128Mul64(cl-1, cl-1)
			if u128Cmp(prevSq, n) >= 0 {
				t.Fatalf("case %d: (ceil-1)^2 >= n", i)
			}
		}
	}
}

func TestNewPoolAndValidation(t *testing.T) {
	if _, err := NewPool(MinReserve-1, 100); err != ErrInvalidReserve {
		t.Fatalf("expected ErrInvalidReserve, got %v", err)
	}
	if _, err := NewPool(MaxReserve+1, 100); err != ErrInvalidReserve {
		t.Fatalf("expected ErrInvalidReserve above max, got %v", err)
	}
	if _, err := NewPool(10_000, -1); err != ErrInvalidFeeBps {
		t.Fatalf("expected ErrInvalidFeeBps <0, got %v", err)
	}
	if _, err := NewPool(10_000, MaxFeeBps+1); err != ErrInvalidFeeBps {
		t.Fatalf("expected ErrInvalidFeeBps >max, got %v", err)
	}

	p, err := NewPool(1_000_000, 100)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if p.YesProbBps() != 5_000 || p.NoProbBps() != 5_000 {
		t.Fatalf("expected 5000/5000 bps, got %d/%d", p.YesProbBps(), p.NoProbBps())
	}
	if _, err := p.QuoteBuy(Side(99), 1_000); err != ErrInvalidSide {
		t.Fatalf("expected ErrInvalidSide, got %v", err)
	}
	if _, err := p.QuoteBuy(SideYes, 0); err != ErrInvalidAmount {
		t.Fatalf("expected ErrInvalidAmount, got %v", err)
	}
	if _, err := p.QuoteBuy(SideYes, 1); err != ErrZeroOutput {
		t.Fatalf("expected ErrZeroOutput when 1 ugnot is consumed by ceil fee, got %v", err)
	}
	if _, _, err := p.ApplyBuy(SideYes, 1_000, 1_000_000); err != ErrSlippage {
		t.Fatalf("expected ErrSlippage on buy, got %v", err)
	}
	if _, _, err := p.ApplySell(SideYes, 1_000, 1_000_000); err != ErrSlippage {
		t.Fatalf("expected ErrSlippage on sell, got %v", err)
	}
	if _, _, err := p.ApplyAddLiquidity(10_000, 100_000); err != ErrSlippage {
		t.Fatalf("expected ErrSlippage on add liquidity, got %v", err)
	}
	if _, _, err := p.ApplyRemoveLiquidity(p.TotalLP); err != ErrInsufficientLiquidity {
		t.Fatalf("expected ErrInsufficientLiquidity removing all LP, got %v", err)
	}
	if _, _, err := p.ApplyBuy(SideYes, MaxReserve+1, 0); err != ErrInvalidAmount {
		t.Fatalf("expected ErrInvalidAmount above MaxReserve, got %v", err)
	}
	pLarge, err := NewPool(MaxReserve/2, 100)
	if err != nil {
		t.Fatalf("unexpected error creating large pool: %v", err)
	}
	if _, _, err := pLarge.ApplyBuy(SideYes, MaxReserve, 0); err != ErrOverflow {
		t.Fatalf("expected ErrOverflow, got %v", err)
	}
}

func TestBuySellBasicsAndSlippage(t *testing.T) {
	p, err := NewPool(1_000_000, 100) // 1% fee
	if err != nil {
		t.Fatal(err)
	}
	p2, bq, err := p.ApplyBuy(SideYes, 100_000, 1)
	if err != nil {
		t.Fatalf("buy failed: %v", err)
	}
	if bq.Fee != 1_000 || bq.NetCollateral != 99_000 {
		t.Fatalf("unexpected fee/net: %+v", bq)
	}
	if bq.SharesOut <= 99_000 {
		t.Fatalf("expected >99000 YES shares from balanced pool, got %d", bq.SharesOut)
	}
	if p2.YesProbBps() <= 5_000 {
		t.Fatalf("buying YES should raise YES prob > 5000, got %d", p2.YesProbBps())
	}

	p3, sq, err := p2.ApplySell(SideYes, bq.SharesOut, 1)
	if err != nil {
		t.Fatalf("sell failed: %v", err)
	}
	if sq.CollateralOut >= 100_000 {
		t.Fatalf("round-trip extracted value: %d >= 100000", sq.CollateralOut)
	}
	if p3.YesProbBps() >= p2.YesProbBps() {
		t.Fatalf("selling YES should reduce YES prob: before=%d after=%d", p2.YesProbBps(), p3.YesProbBps())
	}
}

func TestRoundTripArbitrageImpossible(t *testing.T) {
	fees := []int64{0, 50, 200, 500}
	poolSizes := []int64{1_000, 100_000, 10_000_000, 10_000_000_000_000}
	tradeSizes := []int64{10, 500, 25_000, 5_000_000, 5_000_000_000_000}

	for _, fee := range fees {
		for _, poolSz := range poolSizes {
			p, err := NewPool(poolSz, fee)
			if err != nil {
				t.Fatalf("NewPool(%d, %d): %v", poolSz, fee, err)
			}
			for _, tradeSz := range tradeSizes {
				if tradeSz > poolSz*10 {
					continue
				}
				k0 := invariantProduct(p)
				pBuy, bq, err := p.ApplyBuy(SideYes, tradeSz, 0)
				if err != nil {
					continue
				}
				k1 := invariantProduct(pBuy)
				if u128Cmp(k1, k0) < 0 {
					t.Fatalf("buy shrank k: pool=%d fee=%d trade=%d", poolSz, fee, tradeSz)
				}
				pSell, sq, err := pBuy.ApplySell(SideYes, bq.SharesOut, 0)
				if err != nil {
					continue
				}
				k2 := invariantProduct(pSell)
				if u128Cmp(k2, k1) < 0 {
					t.Fatalf("sell shrank k: pool=%d fee=%d trade=%d", poolSz, fee, tradeSz)
				}
				if sq.CollateralOut > tradeSz {
					t.Fatalf("round-trip profit! pool=%d fee=%d in=%d out=%d", poolSz, fee, tradeSz, sq.CollateralOut)
				}
			}
		}
	}
}

func TestDeterministicFuzzInvariants(t *testing.T) {
	p, err := NewPool(10_000_000, 100)
	if err != nil {
		t.Fatal(err)
	}
	collateral := int64(10_000_000)
	userYes := int64(0)
	userNo := int64(0)

	seed := uint64(0x9e3779b97f4a7c15)
	nextRand := func() uint64 {
		seed ^= seed << 13
		seed ^= seed >> 7
		seed ^= seed << 17
		return seed
	}

	assertState := func(step int, prevK u128, checkK bool) {
		if p.ReserveYes < 1 || p.ReserveNo < 1 {
			t.Fatalf("step %d: collapsed reserve (%d, %d)", step, p.ReserveYes, p.ReserveNo)
		}
		if p.ReserveYes+userYes != collateral {
			t.Fatalf("step %d: YES conservation broken: %d + %d != %d", step, p.ReserveYes, userYes, collateral)
		}
		if p.ReserveNo+userNo != collateral {
			t.Fatalf("step %d: NO conservation broken: %d + %d != %d", step, p.ReserveNo, userNo, collateral)
		}
		if p.YesProbBps()+p.NoProbBps() != BpsScale {
			t.Fatalf("step %d: probs do not sum to 10000", step)
		}
		if checkK {
			curK := invariantProduct(p)
			if u128Cmp(curK, prevK) < 0 {
				t.Fatalf("step %d: invariant k decreased", step)
			}
		}
	}

	for step := 0; step < 250; step++ {
		r := nextRand()
		op := r % 6
		kBefore := invariantProduct(p)

		switch op {
		case 0, 1: // Buy YES / NO
			side := SideYes
			if op == 1 {
				side = SideNo
			}
			amt := int64(1_000 + (nextRand() % 500_000))
			nextP, bq, err := p.ApplyBuy(side, amt, 0)
			if err != nil {
				continue
			}
			p = nextP
			collateral += bq.NetCollateral
			if side == SideYes {
				userYes += bq.SharesOut
			} else {
				userNo += bq.SharesOut
			}
			assertState(step, kBefore, true)

		case 2, 3: // Sell YES / NO
			side := SideYes
			held := userYes
			if op == 3 {
				side = SideNo
				held = userNo
			}
			if held < 100 {
				continue
			}
			amt := int64(uint64(1 + nextRand()%uint64(held)))
			nextP, sq, err := p.ApplySell(side, amt, 0)
			if err != nil {
				continue
			}
			p = nextP
			collateral -= sq.GrossCollateral
			if side == SideYes {
				userYes -= amt
			} else {
				userNo -= amt
			}
			assertState(step, kBefore, true)

		case 4: // Add liquidity
			amt := int64(10_000 + (nextRand() % 1_000_000))
			nextP, aq, err := p.ApplyAddLiquidity(amt, 0)
			if err != nil {
				continue
			}
			p = nextP
			collateral += amt
			if aq.RefundShares > 0 {
				if aq.RefundSide == SideYes {
					userYes += aq.RefundShares
				} else if aq.RefundSide == SideNo {
					userNo += aq.RefundShares
				}
			}
			assertState(step, kBefore, false)

		case 5: // Remove liquidity
			if p.TotalLP <= MinReserve*2 {
				continue
			}
			burn := int64(1_000 + (nextRand() % uint64(p.TotalLP/4)))
			nextP, rq, err := p.ApplyRemoveLiquidity(burn)
			if err != nil {
				continue
			}
			p = nextP
			collateral -= rq.CollateralOut
			userYes += rq.YesOut
			userNo += rq.NoOut
			assertState(step, kBefore, false)
		}
	}
}

func TestExtremeSkewAndMaxReserves(t *testing.T) {
	// Near MaxReserve pool and heavy skew.
	p, err := NewPool(100_000_000_000_000, 100) // 10^14 ugnot
	if err != nil {
		t.Fatal(err)
	}
	k0 := invariantProduct(p)
	pSkew, bq, err := p.ApplyBuy(SideYes, 50_000_000_000_000, 0)
	if err != nil {
		t.Fatalf("large buy failed: %v", err)
	}
	if u128Cmp(invariantProduct(pSkew), k0) < 0 {
		t.Fatalf("large buy violated k")
	}
	if pSkew.YesProbBps() <= 6000 {
		t.Fatalf("expected strong skew >60%%, got %d", pSkew.YesProbBps())
	}

	pBack, sq, err := pSkew.ApplySell(SideYes, bq.SharesOut, 0)
	if err != nil {
		t.Fatalf("large sell failed: %v", err)
	}
	if sq.CollateralOut >= 50_000_000_000_000 {
		t.Fatalf("large round trip profitable")
	}
	if u128Cmp(invariantProduct(pBack), invariantProduct(pSkew)) < 0 {
		t.Fatalf("large sell violated k")
	}
}

func TestLiquiditySkewAddRemoveConservation(t *testing.T) {
	p, err := NewPool(1_000_000, 0)
	if err != nil {
		t.Fatal(err)
	}
	// Skew pool by buying YES.
	p, bq, err := p.ApplyBuy(SideYes, 500_000, 0)
	if err != nil {
		t.Fatal(err)
	}
	collateral := int64(1_000_000 + 500_000)
	userYes := bq.SharesOut
	userNo := int64(0)

	// Add liquidity to skewed pool: ReserveNo > ReserveYes, so excess is YES shares.
	p, aq, err := p.ApplyAddLiquidity(500_000, 1)
	if err != nil {
		t.Fatalf("skew add failed: %v", err)
	}
	if aq.RefundSide != SideYes || aq.RefundShares <= 0 {
		t.Fatalf("expected YES refund on skewed add, got %+v", aq)
	}
	collateral += 500_000
	userYes += aq.RefundShares

	if p.ReserveYes+userYes != collateral || p.ReserveNo+userNo != collateral {
		t.Fatalf("conservation mismatch after skew add")
	}

	// Remove half LP shares.
	burn := p.TotalLP / 2
	p, rq, err := p.ApplyRemoveLiquidity(burn)
	if err != nil {
		t.Fatalf("skew remove failed: %v", err)
	}
	collateral -= rq.CollateralOut
	userYes += rq.YesOut
	userNo += rq.NoOut
	if p.ReserveYes+userYes != collateral || p.ReserveNo+userNo != collateral {
		t.Fatalf("conservation mismatch after skew remove")
	}
}

func TestFeeAccumulatorConservation(t *testing.T) {
	acc := FeeAccumulator{}
	lp1 := int64(1_000_000)
	lp2 := int64(0)
	lp3 := int64(0)
	totalLP := lp1

	var debt1, debt2, debt3 int64
	var pending1, pending2, pending3 int64
	var totalFees int64

	// Trade 1: small 1 ugnot fee, then 50,000 ugnot fee (only LP1 is in pool).
	for _, f := range []int64{1, 50_000} {
		var err error
		acc, err = UpdateFeeAccumulator(acc, f, totalLP)
		if err != nil {
			t.Fatal(err)
		}
		totalFees += f
	}

	// LP2 enters with 2,000,000 LP shares.
	lp2 = 2_000_000
	totalLP += lp2
	var err error
	debt2, err = ComputeLPFeeDebt(acc, lp2)
	if err != nil {
		t.Fatal(err)
	}
	// Immediately after entry, LP2 pending MUST be 0.
	if p := ComputePendingLPFee(acc, lp2, debt2); p != 0 {
		t.Fatalf("newcomer LP2 claimed prior fees: %d", p)
	}

	// Trade 2: large fee 123,456 ugnot + tiny fee 3 ugnot.
	for _, f := range []int64{123_456, 3} {
		acc, err = UpdateFeeAccumulator(acc, f, totalLP)
		if err != nil {
			t.Fatal(err)
		}
		totalFees += f
	}

	// LP3 enters with 500,000 shares.
	lp3 = 500_000
	totalLP += lp3
	debt3, err = ComputeLPFeeDebt(acc, lp3)
	if err != nil {
		t.Fatal(err)
	}
	if p := ComputePendingLPFee(acc, lp3, debt3); p != 0 {
		t.Fatalf("newcomer LP3 claimed prior fees: %d", p)
	}

	// Trade 3: 10^10 ugnot fee.
	bigFee := int64(10_000_000_000)
	acc, err = UpdateFeeAccumulator(acc, bigFee, totalLP)
	if err != nil {
		t.Fatal(err)
	}
	totalFees += bigFee

	pending1 += ComputePendingLPFee(acc, lp1, debt1)
	pending2 += ComputePendingLPFee(acc, lp2, debt2)
	pending3 += ComputePendingLPFee(acc, lp3, debt3)

	sumPaid := pending1 + pending2 + pending3
	if sumPaid > totalFees {
		t.Fatalf("fee over-distribution: paid=%d > collected=%d", sumPaid, totalFees)
	}
	if totalFees-sumPaid > 10 {
		t.Fatalf("unexpected fee precision loss: collected=%d paid=%d", totalFees, sumPaid)
	}
}

func TestQuoteSettleLPConservation(t *testing.T) {
	settYes := int64(1_234_567)
	settNo := int64(987_655)
	settLP := int64(100_001)
	slices := []int64{33_333, 33_333, 33_335}

	var sumYes, sumNo int64
	for _, s := range slices {
		y, n, err := QuoteSettleLP(settYes, settNo, settLP, s)
		if err != nil {
			t.Fatal(err)
		}
		sumYes += y
		sumNo += n
	}
	if sumYes > settYes || sumNo > settNo {
		t.Fatalf("settlement exceeded reserves: yes=%d/%d no=%d/%d", sumYes, settYes, sumNo, settNo)
	}
	if settYes-sumYes > 3 || settNo-sumNo > 3 {
		t.Fatalf("unexpected settlement dust: yes=%d/%d no=%d/%d", sumYes, settYes, sumNo, settNo)
	}
}
