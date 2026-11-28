package verdict

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func resetState(_ int, rlm realm, adminAddr address) {
	// Drain any residual mocked bank balance from prior tests so each test
	// starts with exact 0 ugnot in the realm vault.
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	if bal := bnk.GetCoin(rlm.Address(), Denom); bal > 0 {
		sink := testutils.TestAddress("test_sink")
		bnk.SendCoins(rlm.Address(), sink, chain.Coins{{Denom: Denom, Amount: bal}})
	}

	admin = adminAddr
	realmAddr = rlm.Address()
	realmPkgPath = rlm.PkgPath()
	defaultBond = DefaultBondAmount
	arbiterQuorum = 1
	arbiters = avl.Tree{}
	arbiters.Set(adminAddr.String(), true)
	nextMarketID = 0
	markets = avl.Tree{}
	claimableBonds = avl.Tree{}
	totalCollateral = 0
	totalFeePool = 0
	totalActiveBonds = 0
	totalClaimableBonds = 0
	protocolDustPool = 0
	totalVolume = 0
	totalTrades = 0
	resolvedMarketCount = 0
	router = buildRouter()
	testing.SetOriginSend(nil)
}

func advanceTime(seconds int64) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(time.Duration(seconds) * time.Second)
	ctx.Height += seconds / 5
	testing.SetContext(ctx)
}

func ugnot(amt int64) chain.Coins {
	return chain.Coins{{Denom: Denom, Amount: amt}}
}

func assertGlobalSolvency(t *testing.T) {
	t.Helper()

	var (
		sumColl      int64
		sumFees      int64
		sumBonds     int64
		sumClaimable int64
	)

	markets.Iterate("", "", func(_ string, val any) bool {
		m, ok := val.(*market)
		if !ok {
			t.Fatalf("corrupt market in tree")
		}
		sumColl += m.collateral
		sumFees += m.feePool
		sumBonds += m.proposerBond + m.disputerBond

		tree := getPositionTree(m)
		var (
			sumYes        int64
			sumNo         int64
			sumLP         int64
			sumUnclaimWin int64
			sumSharePay   int64
			sumFeePay     int64
		)

		tree.Iterate("", "", func(_ string, pVal any) bool {
			pos, pOk := pVal.(*position)
			if !pOk {
				t.Fatalf("corrupt position in market %d", m.id)
			}
			if pos.claimed {
				if pos.yesShares != 0 || pos.noShares != 0 || pos.lpShares != 0 || pos.pendingFees != 0 {
					t.Fatalf("market %d: claimed position still has nonzero balances", m.id)
				}
				return false
			}
			sumYes += pos.yesShares
			sumNo += pos.noShares
			sumLP += pos.lpShares

			if m.status == StatusResolved {
				switch m.finalOutcome {
				case OutcomeYes:
					sumUnclaimWin += pos.yesShares
				case OutcomeNo:
					sumUnclaimWin += pos.noShares
				case OutcomeInvalid:
					sumUnclaimWin += pos.yesShares + pos.noShares
				}
				sp, fp := computePositionClaim(m, pos)
				sumSharePay += sp
				sumFeePay += fp
			}
			return false
		})

		if m.status != StatusResolved {
			if m.pool.ReserveYes+m.totalYesOut != m.collateral {
				t.Fatalf("market %d: YES conservation failed: %d + %d != %d", m.id, m.pool.ReserveYes, m.totalYesOut, m.collateral)
			}
			if m.pool.ReserveNo+m.totalNoOut != m.collateral {
				t.Fatalf("market %d: NO conservation failed: %d + %d != %d", m.id, m.pool.ReserveNo, m.totalNoOut, m.collateral)
			}
			if sumYes != m.totalYesOut {
				t.Fatalf("market %d: user YES sum %d != totalYesOut %d", m.id, sumYes, m.totalYesOut)
			}
			if sumNo != m.totalNoOut {
				t.Fatalf("market %d: user NO sum %d != totalNoOut %d", m.id, sumNo, m.totalNoOut)
			}
			if sumLP != m.pool.TotalLP {
				t.Fatalf("market %d: user LP sum %d != TotalLP %d", m.id, sumLP, m.pool.TotalLP)
			}
		} else {
			if sumLP != m.remainingLP {
				t.Fatalf("market %d: unclaimed LP %d != remainingLP %d", m.id, sumLP, m.remainingLP)
			}
			if sumUnclaimWin != m.remainingWinShares {
				t.Fatalf("market %d: unclaimed win shares %d != remainingWinShares %d", m.id, sumUnclaimWin, m.remainingWinShares)
			}
			if sumSharePay > m.collateral {
				t.Fatalf("market %d: claimable share payout %d > collateral %d", m.id, sumSharePay, m.collateral)
			}
			if sumFeePay > m.feePool {
				t.Fatalf("market %d: claimable fee payout %d > feePool %d", m.id, sumFeePay, m.feePool)
			}
		}
		return false
	})

	claimableBonds.Iterate("", "", func(_ string, val any) bool {
		v, ok := val.(int64)
		if !ok {
			t.Fatalf("corrupt claimable bond entry")
		}
		sumClaimable += v
		return false
	})

	if sumColl != totalCollateral {
		t.Fatalf("sumColl %d != totalCollateral %d", sumColl, totalCollateral)
	}
	if sumFees != totalFeePool {
		t.Fatalf("sumFees %d != totalFeePool %d", sumFees, totalFeePool)
	}
	if sumBonds != totalActiveBonds {
		t.Fatalf("sumBonds %d != totalActiveBonds %d", sumBonds, totalActiveBonds)
	}
	if sumClaimable != totalClaimableBonds {
		t.Fatalf("sumClaimable %d != totalClaimableBonds %d", sumClaimable, totalClaimableBonds)
	}

	vault := banker.NewReadonlyBanker().GetCoin(realmAddr, Denom)
	expected := totalCollateral + totalFeePool + totalActiveBonds + totalClaimableBonds + protocolDustPool
	if vault != expected {
		t.Fatalf("banker conservation mismatch: vault=%d expected=%d (coll=%d fees=%d activeBonds=%d claimBonds=%d dust=%d)",
			vault, expected, totalCollateral, totalFeePool, totalActiveBonds, totalClaimableBonds, protocolDustPool)
	}
}

func assertDrainedToZero(t *testing.T) {
	t.Helper()
	assertGlobalSolvency(t)
	vault := banker.NewReadonlyBanker().GetCoin(realmAddr, Denom)
	if vault != 0 || totalCollateral != 0 || totalFeePool != 0 || totalActiveBonds != 0 || totalClaimableBonds != 0 || protocolDustPool != 0 {
		t.Fatalf("expected full drain to 0, got vault=%d coll=%d fees=%d active=%d claim=%d dust=%d",
			vault, totalCollateral, totalFeePool, totalActiveBonds, totalClaimableBonds, protocolDustPool)
	}
}

func TestCreateMarket_SuccessAndValidation(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	resetState(0, cur, alice)

	now := time.Now().Unix()
	closeT := now + 3600

	// Below MinInitialLiquidity must abort.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(MinInitialLiquidity - 1))
	uassert.AbortsWithMessage(t, cur, "insufficient ugnot sent", func() {
		CreateMarket(cross(cur), "Valid Q?", "Desc", "Crypto", closeT, 100, 0)
	})

	// Empty question must abort.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(MinInitialLiquidity))
	uassert.AbortsWithMessage(t, cur, "invalid question length", func() {
		CreateMarket(cross(cur), "   ", "Desc", "Crypto", closeT, 100, 0)
	})

	// Close time too soon must abort.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(MinInitialLiquidity))
	uassert.AbortsWithMessage(t, cur, "close time out of bounds", func() {
		CreateMarket(cross(cur), "Valid Q?", "Desc", "Crypto", now+10, 100, 0)
	})

	// Multi-denom send must abort.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "uatom", Amount: 1_000_000}, {Denom: Denom, Amount: 1_000_000}})
	uassert.AbortsWithMessage(t, cur, "expected single ugnot coin", func() {
		CreateMarket(cross(cur), "Valid Q?", "Desc", "Crypto", closeT, 100, 0)
	})

	// Valid market creation.
	seed := int64(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(seed))
	testing.SetOriginSend(ugnot(seed))
	id := CreateMarket(cross(cur), "Will Gno ship v1.9?", "Official tag on GitHub.", "Ecosystem", closeT, 100, 120)
	testing.SetOriginSend(nil)

	uassert.Equal(t, uint64(1), id)
	mv, ok := GetMarket(id)
	uassert.True(t, ok)
	uassert.Equal(t, int64(5_000), mv.YesProbBps)
	uassert.Equal(t, seed, mv.Collateral)
	uassert.Equal(t, int64(120), mv.DisputeWindow)

	pos := GetPosition(id, alice)
	uassert.Equal(t, seed, pos.LPShares)
	assertGlobalSolvency(t)
}

func TestPaymentGuard_RejectsCodeRealmCallers(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	resetState(0, cur, alice)

	now := time.Now().Unix()
	closeT := now + 120

	// Seed a real market as EOA alice.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(1_000_000))
	testing.SetOriginSend(ugnot(1_000_000))
	id := CreateMarket(cross(cur), "Guard Test?", "", "Security", closeT, 100, 60)
	testing.SetOriginSend(nil)

	// Attacker 1: intermediate code realm (/r/attacker/evil).
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/evil"))
	testing.SetOriginSend(ugnot(1_000_000))
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		CreateMarket(cross(cur), "Evil?", "", "Sec", closeT, 100, 60)
	})
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		Buy(cross(cur), id, true, 1)
	})
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		AddLiquidity(cross(cur), id, 1)
	})

	// Attacker 2: MsgRun ephemeral realm (/e/<addr>/run) which passes IsUser()
	// but MUST FAIL IsUserCall()!
	msgRunRealm := runtime.NewRealm(bob, "gno.land/e/"+bob.String()+"/run")
	testing.SetRealm(msgRunRealm)
	testing.SetOriginSend(ugnot(1_000_000))
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		CreateMarket(cross(cur), "RunEvil?", "", "Sec", closeT, 100, 60)
	})
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		Buy(cross(cur), id, true, 1)
	})
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		AddLiquidity(cross(cur), id, 1)
	})

	// Advance past closeTime to test ProposeOutcome and DisputeOutcome guards.
	advanceTime(200)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/evil"))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		ProposeOutcome(cross(cur), id, uint8(OutcomeYes))
	})

	testing.SetRealm(msgRunRealm)
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		ProposeOutcome(cross(cur), id, uint8(OutcomeYes))
	})

	// EOA alice proposes validly, then test DisputeOutcome code/MsgRun rejection.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), id, uint8(OutcomeYes))
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/evil"))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		DisputeOutcome(cross(cur), id)
	})

	testing.SetRealm(msgRunRealm)
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	uassert.AbortsWithMessage(t, cur, "direct EOA MsgCall required", func() {
		DisputeOutcome(cross(cur), id)
	})

	testing.SetOriginSend(nil)
	assertGlobalSolvency(t)
}

func TestBuySell_PriceMovementAndExactBankerAccounting(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 3600
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(2_000_000))
	testing.SetOriginSend(ugnot(2_000_000))
	id := CreateMarket(cross(cur), "Price test?", "", "DeFi", closeT, 100, 60)
	testing.SetOriginSend(nil)

	// Bob previews then buys YES.
	qBuy, err := PreviewBuy(id, true, 500_000)
	uassert.NoError(t, err)

	bobBefore := banker.NewReadonlyBanker().GetCoin(bob, Denom)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(500_000))
	testing.SetOriginSend(ugnot(500_000))
	sharesOut := Buy(cross(cur), id, true, qBuy.SharesOut)
	testing.SetOriginSend(nil)
	uassert.Equal(t, qBuy.SharesOut, sharesOut)

	mv, _ := GetMarket(id)
	uassert.True(t, mv.YesProbBps > 5_000)
	uassert.Equal(t, int64(5_000), mv.FeePool) // 1% of 500_000
	assertGlobalSolvency(t)

	// Bob sells half of his YES shares.
	sellShares := sharesOut / 2
	qSell, err := PreviewSell(id, true, sellShares)
	uassert.NoError(t, err)

	testing.SetRealm(testing.NewUserRealm(bob))
	gotOut := Sell(cross(cur), id, true, sellShares, qSell.CollateralOut)
	uassert.Equal(t, qSell.CollateralOut, gotOut)

	bobAfter := banker.NewReadonlyBanker().GetCoin(bob, Denom)
	uassert.Equal(t, bobBefore+gotOut, bobAfter)
	assertGlobalSolvency(t)
}

func TestAddRemoveLiquidity_SkewedPoolAndFeeIsolation(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 3600
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(1_000_000))
	testing.SetOriginSend(ugnot(1_000_000))
	id := CreateMarket(cross(cur), "LP isolation?", "", "DeFi", closeT, 200, 60) // 2% fee
	testing.SetOriginSend(nil)

	// Bob trades before Carol provides LP -> Alice owns 100% of those 20,000 ugnot fees.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(1_000_000))
	testing.SetOriginSend(ugnot(1_000_000))
	Buy(cross(cur), id, true, 1)
	testing.SetOriginSend(nil)

	posAliceBefore := GetPosition(id, alice)
	uassert.Equal(t, int64(20_000), posAliceBefore.PendingFees)

	// Carol adds 500,000 ugnot to skewed pool.
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.IssueCoins(realmAddr, ugnot(500_000))
	testing.SetOriginSend(ugnot(500_000))
	carolLP := AddLiquidity(cross(cur), id, 1)
	testing.SetOriginSend(nil)

	posCarol := GetPosition(id, carol)
	uassert.Equal(t, carolLP, posCarol.LPShares)
	uassert.Equal(t, int64(0), posCarol.PendingFees) // Zero retroactive fees!
	uassert.True(t, posCarol.YesShares > 0)          // Received excess skew YES shares!

	// Bob trades again -> fees split proportionally between Alice and Carol.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(500_000))
	testing.SetOriginSend(ugnot(500_000))
	Buy(cross(cur), id, false, 1)
	testing.SetOriginSend(nil)

	// Carol removes half her LP shares and receives merged collateral + partial fees + skew shares.
	carolBefore := banker.NewReadonlyBanker().GetCoin(carol, Denom)
	testing.SetRealm(testing.NewUserRealm(carol))
	cOut, fOut, yOut, nOut := RemoveLiquidity(cross(cur), id, carolLP/2)
	uassert.True(t, cOut > 0)
	uassert.True(t, fOut > 0 && fOut < 10_000)
	uassert.True(t, yOut == 0 || nOut == 0)
	uassert.Equal(t, carolBefore+cOut+fOut, banker.NewReadonlyBanker().GetCoin(carol, Denom))
	assertGlobalSolvency(t)
}

func TestOptimisticResolution_UnchallengedYes_DrainsToZero(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 300
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(1_000_000))
	testing.SetOriginSend(ugnot(1_000_000))
	id := CreateMarket(cross(cur), "Optimistic YES?", "", "Tech", closeT, 100, 120)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(400_000))
	testing.SetOriginSend(ugnot(400_000))
	Buy(cross(cur), id, true, 1)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.IssueCoins(realmAddr, ugnot(250_000))
	testing.SetOriginSend(ugnot(250_000))
	Buy(cross(cur), id, false, 1)
	testing.SetOriginSend(nil)

	// Cannot propose before closeTime.
	advanceTime(100)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	uassert.AbortsWithMessage(t, cur, "market has not closed yet", func() {
		ProposeOutcome(cross(cur), id, uint8(OutcomeYes))
	})

	// Advance past closeTime; Bob proposes YES.
	advanceTime(250)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), id, uint8(OutcomeYes))
	testing.SetOriginSend(nil)

	// Cannot finalize before disputeDeadline.
	advanceTime(60)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "dispute window still active", func() {
		FinalizeResolution(cross(cur), id)
	})

	// Advance past disputeDeadline; Carol permissionlessly finalizes.
	advanceTime(120)
	testing.SetRealm(testing.NewUserRealm(carol))
	FinalizeResolution(cross(cur), id)
	assertGlobalSolvency(t)

	// Bob pulls his refunded bond.
	bobBal0 := banker.NewReadonlyBanker().GetCoin(bob, Denom)
	testing.SetRealm(testing.NewUserRealm(bob))
	bondOut := ClaimBonds(cross(cur))
	uassert.Equal(t, DefaultBondAmount, bondOut)
	uassert.Equal(t, bobBal0+DefaultBondAmount, banker.NewReadonlyBanker().GetCoin(bob, Denom))

	// Alice (LP) and Bob (YES winner) claim; Carol (NO loser) must fail with nothing to claim.
	testing.SetRealm(testing.NewUserRealm(alice))
	pAlice := Claim(cross(cur), id)
	uassert.True(t, pAlice > 0)

	testing.SetRealm(testing.NewUserRealm(bob))
	pBob := Claim(cross(cur), id)
	uassert.True(t, pBob > 0)

	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "nothing to claim", func() {
		Claim(cross(cur), id)
	})

	if protocolDustPool > 0 {
		testing.SetRealm(testing.NewUserRealm(alice))
		WithdrawDust(cross(cur), alice)
	}
	assertDrainedToZero(t)
}

func TestOptimisticResolution_UnchallengedNo_DrainsToZero(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 300
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(1_500_000))
	testing.SetOriginSend(ugnot(1_500_000))
	id := CreateMarket(cross(cur), "Optimistic NO?", "", "Tech", closeT, 100, 60)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(300_000))
	testing.SetOriginSend(ugnot(300_000))
	Buy(cross(cur), id, true, 1)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.IssueCoins(realmAddr, ugnot(600_000))
	testing.SetOriginSend(ugnot(600_000))
	Buy(cross(cur), id, false, 1)
	testing.SetOriginSend(nil)

	advanceTime(350)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), id, uint8(OutcomeNo))
	testing.SetOriginSend(nil)

	advanceTime(70)
	testing.SetRealm(testing.NewUserRealm(alice))
	FinalizeResolution(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(carol))
	ClaimBonds(cross(cur))
	Claim(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(alice))
	Claim(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "nothing to claim", func() {
		Claim(cross(cur), id)
	})

	if protocolDustPool > 0 {
		testing.SetRealm(testing.NewUserRealm(alice))
		WithdrawDust(cross(cur), alice)
	}
	assertDrainedToZero(t)
}

func TestDispute_ArbiterQuorum_ProposerWinsSlashesDisputer(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	arb2 := testutils.TestAddress("arb2")
	arb3 := testutils.TestAddress("arb3")
	proposer := testutils.TestAddress("proposer")
	disputer := testutils.TestAddress("disputer")
	resetState(0, cur, alice)

	// Set 2-of-3 arbiter quorum.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddArbiter(cross(cur), arb2)
	AddArbiter(cross(cur), arb3)
	SetArbiterQuorum(cross(cur), 2)

	closeT := time.Now().Unix() + 120
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(500_000))
	testing.SetOriginSend(ugnot(500_000))
	id := CreateMarket(cross(cur), "Dispute Proposer Wins?", "", "Gov", closeT, 100, 120)
	testing.SetOriginSend(nil)

	advanceTime(150)
	testing.SetRealm(testing.NewUserRealm(proposer))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), id, uint8(OutcomeYes))
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(disputer))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	DisputeOutcome(cross(cur), id)
	testing.SetOriginSend(nil)

	// Non-arbiter vote must abort.
	testing.SetRealm(testing.NewUserRealm(disputer))
	uassert.AbortsWithMessage(t, cur, "caller is not an arbiter", func() {
		CastArbiterVote(cross(cur), id, uint8(OutcomeNo))
	})

	// Arbiter 1 (alice) votes YES; duplicate vote aborts; market still DISPUTED (quorum 2).
	testing.SetRealm(testing.NewUserRealm(alice))
	CastArbiterVote(cross(cur), id, uint8(OutcomeYes))
	uassert.AbortsWithMessage(t, cur, "arbiter already voted", func() {
		CastArbiterVote(cross(cur), id, uint8(OutcomeYes))
	})
	mv, _ := GetMarket(id)
	uassert.Equal(t, uint8(StatusDisputed), uint8(mv.Status))

	// Arbiter 2 (arb2) votes NO -> still disputed (1 YES vs 1 NO).
	testing.SetRealm(testing.NewUserRealm(arb2))
	CastArbiterVote(cross(cur), id, uint8(OutcomeNo))
	mv, _ = GetMarket(id)
	uassert.Equal(t, uint8(StatusDisputed), uint8(mv.Status))

	// Arbiter 3 (arb3) votes YES -> 2-of-3 quorum reached! Proposer wins BOTH bonds.
	testing.SetRealm(testing.NewUserRealm(arb3))
	CastArbiterVote(cross(cur), id, uint8(OutcomeYes))

	mv, _ = GetMarket(id)
	uassert.Equal(t, uint8(StatusResolved), uint8(mv.Status))
	uassert.Equal(t, uint8(OutcomeYes), uint8(mv.FinalOutcome))
	uassert.Equal(t, 2*DefaultBondAmount, GetClaimableBonds(proposer))
	uassert.Equal(t, int64(0), GetClaimableBonds(disputer))

	testing.SetRealm(testing.NewUserRealm(proposer))
	won := ClaimBonds(cross(cur))
	uassert.Equal(t, 2*DefaultBondAmount, won)
	testing.SetRealm(testing.NewUserRealm(disputer))
	uassert.AbortsWithMessage(t, cur, "no claimable bonds", func() {
		ClaimBonds(cross(cur))
	})
	assertGlobalSolvency(t)
}

func TestDispute_ArbiterQuorum_DisputerWinsSlashesProposer(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	arb2 := testutils.TestAddress("arb2")
	proposer := testutils.TestAddress("proposer")
	disputer := testutils.TestAddress("disputer")
	resetState(0, cur, alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	AddArbiter(cross(cur), arb2)
	SetArbiterQuorum(cross(cur), 2)

	closeT := time.Now().Unix() + 120
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(500_000))
	testing.SetOriginSend(ugnot(500_000))
	id := CreateMarket(cross(cur), "Dispute Disputer Wins?", "", "Gov", closeT, 100, 120)
	testing.SetOriginSend(nil)

	advanceTime(150)
	testing.SetRealm(testing.NewUserRealm(proposer))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), id, uint8(OutcomeYes)) // Wrong proposal
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(disputer))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	DisputeOutcome(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(alice))
	CastArbiterVote(cross(cur), id, uint8(OutcomeNo))
	testing.SetRealm(testing.NewUserRealm(arb2))
	CastArbiterVote(cross(cur), id, uint8(OutcomeNo))

	mv, _ := GetMarket(id)
	uassert.Equal(t, uint8(StatusResolved), uint8(mv.Status))
	uassert.Equal(t, uint8(OutcomeNo), uint8(mv.FinalOutcome))
	uassert.Equal(t, 2*DefaultBondAmount, GetClaimableBonds(disputer))
	uassert.Equal(t, int64(0), GetClaimableBonds(proposer))

	testing.SetRealm(testing.NewUserRealm(disputer))
	uassert.Equal(t, 2*DefaultBondAmount, ClaimBonds(cross(cur)))
	testing.SetRealm(testing.NewUserRealm(alice))
	Claim(cross(cur), id)
	if protocolDustPool > 0 {
		WithdrawDust(cross(cur), alice)
	}
	assertDrainedToZero(t)
}

func TestDispute_SelfDisputeRejected(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 120
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(200_000))
	testing.SetOriginSend(ugnot(200_000))
	id := CreateMarket(cross(cur), "Self dispute?", "", "Sec", closeT, 100, 120)
	testing.SetOriginSend(nil)

	advanceTime(150)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), id, uint8(OutcomeYes))

	testing.SetOriginSend(ugnot(DefaultBondAmount))
	uassert.AbortsWithMessage(t, cur, "proposer cannot self-dispute", func() {
		DisputeOutcome(cross(cur), id)
	})
	testing.SetOriginSend(nil)
	assertGlobalSolvency(t)
}

func TestResolution_InvalidOutcome_ProportionalPayoutAndDrainsToZero(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 200
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(1_000_000))
	testing.SetOriginSend(ugnot(1_000_000))
	id := CreateMarket(cross(cur), "Invalid outcome?", "", "Misc", closeT, 100, 60)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(400_000))
	testing.SetOriginSend(ugnot(400_000))
	Buy(cross(cur), id, true, 1)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.IssueCoins(realmAddr, ugnot(300_000))
	testing.SetOriginSend(ugnot(300_000))
	Buy(cross(cur), id, false, 1)
	testing.SetOriginSend(nil)

	advanceTime(250)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), id, uint8(OutcomeInvalid))
	testing.SetOriginSend(nil)

	advanceTime(80)
	testing.SetRealm(testing.NewUserRealm(bob))
	FinalizeResolution(cross(cur), id)
	assertGlobalSolvency(t)

	// Everyone (LP + YES holder + NO holder) claims 50% per share.
	testing.SetRealm(testing.NewUserRealm(alice))
	ClaimBonds(cross(cur))
	pA := Claim(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(bob))
	pB := Claim(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(carol))
	pC := Claim(cross(cur), id)
	uassert.True(t, pA > 0 && pB > 0 && pC > 0)

	if protocolDustPool > 0 {
		testing.SetRealm(testing.NewUserRealm(alice))
		WithdrawDust(cross(cur), alice)
	}
	assertDrainedToZero(t)
}

func TestDispute_ArbiterTimeoutLivenessEscape(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	proposer := testutils.TestAddress("proposer")
	disputer := testutils.TestAddress("disputer")
	bystander := testutils.TestAddress("bystander")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 120
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(500_000))
	testing.SetOriginSend(ugnot(500_000))
	id := CreateMarket(cross(cur), "Stalled arbiters?", "", "Sec", closeT, 100, 120)
	testing.SetOriginSend(nil)

	advanceTime(150)
	testing.SetRealm(testing.NewUserRealm(proposer))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), id, uint8(OutcomeYes))
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(disputer))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	DisputeOutcome(cross(cur), id)
	testing.SetOriginSend(nil)

	// Cannot expire early.
	advanceTime(3600)
	testing.SetRealm(testing.NewUserRealm(bystander))
	uassert.AbortsWithMessage(t, cur, "arbiter timeout not reached", func() {
		ExpireDispute(cross(cur), id)
	})

	// Advance past ArbiterTimeout -> permissionless ExpireDispute resolves INVALID and refunds both bonds.
	advanceTime(ArbiterTimeout)
	testing.SetRealm(testing.NewUserRealm(bystander))
	ExpireDispute(cross(cur), id)

	mv, _ := GetMarket(id)
	uassert.Equal(t, uint8(StatusResolved), uint8(mv.Status))
	uassert.Equal(t, uint8(OutcomeInvalid), uint8(mv.FinalOutcome))
	uassert.Equal(t, DefaultBondAmount, GetClaimableBonds(proposer))
	uassert.Equal(t, DefaultBondAmount, GetClaimableBonds(disputer))

	testing.SetRealm(testing.NewUserRealm(proposer))
	ClaimBonds(cross(cur))
	testing.SetRealm(testing.NewUserRealm(disputer))
	ClaimBonds(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	Claim(cross(cur), id)
	if protocolDustPool > 0 {
		WithdrawDust(cross(cur), alice)
	}
	assertDrainedToZero(t)
}

func TestSecurityGuards_DoubleClaimAndAdminGovernance(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	resetState(0, cur, alice)

	// Non-admin governance rejections.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		AddArbiter(cross(cur), bob)
	})
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		SetDefaultBond(cross(cur), 500_000)
	})
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		TransferAdmin(cross(cur), bob)
	})

	// Admin bounds & quorum floor.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "bond amount out of bounds", func() {
		SetDefaultBond(cross(cur), MinAllowedBond-1)
	})
	uassert.AbortsWithMessage(t, cur, "quorum out of range", func() {
		SetArbiterQuorum(cross(cur), 2) // Only 1 arbiter right now
	})
	AddArbiter(cross(cur), bob)
	SetArbiterQuorum(cross(cur), 2)
	uassert.AbortsWithMessage(t, cur, "cannot drop arbiters below quorum", func() {
		RemoveArbiter(cross(cur), bob)
	})
	SetDefaultBond(cross(cur), 2_000_000)
	TransferAdmin(cross(cur), carol)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		SetDefaultBond(cross(cur), 1_000_000)
	})

	// Double claim & double bond claim rejections.
	closeT := time.Now().Unix() + 100
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(200_000))
	testing.SetOriginSend(ugnot(200_000))
	id := CreateMarket(cross(cur), "Double claim?", "", "Sec", closeT, 0, 60)
	testing.SetOriginSend(nil)

	advanceTime(120)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(2_000_000))
	testing.SetOriginSend(ugnot(2_000_000))
	ProposeOutcome(cross(cur), id, uint8(OutcomeYes))
	testing.SetOriginSend(nil)

	advanceTime(70)
	testing.SetRealm(testing.NewUserRealm(bob))
	FinalizeResolution(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(alice))
	ClaimBonds(cross(cur))
	uassert.AbortsWithMessage(t, cur, "no claimable bonds", func() {
		ClaimBonds(cross(cur))
	})

	Claim(cross(cur), id)
	uassert.AbortsWithMessage(t, cur, "already claimed", func() {
		Claim(cross(cur), id)
	})
	assertGlobalSolvency(t)
}

func TestStructuredViews_ValueIsolationAndPagination(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 3600
	for i := 0; i < 3; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		testing.IssueCoins(realmAddr, ugnot(200_000))
		testing.SetOriginSend(ugnot(200_000))
		CreateMarket(cross(cur), "Market", "Desc", "Cat", closeT, 100, 60)
		testing.SetOriginSend(nil)
	}

	// Verify reverse-chronological pagination.
	page1 := ListMarkets(0, 2)
	uassert.Equal(t, 2, len(page1))
	uassert.Equal(t, uint64(3), page1[0].ID)
	uassert.Equal(t, uint64(2), page1[1].ID)

	page2 := ListMarkets(2, 2)
	uassert.Equal(t, 1, len(page2))
	uassert.Equal(t, uint64(1), page2[0].ID)

	// Mutating returned slices must not mutate realm state.
	hist := GetPriceHistory(1)
	uassert.Equal(t, 1, len(hist))
	hist[0].YesProbBps = 9999
	uassert.Equal(t, int64(5000), GetPriceHistory(1)[0].YesProbBps)

	testing.SetRealm(testing.NewUserRealm(alice))
	AddArbiter(cross(cur), bob)
	arbs := GetArbiters()
	uassert.Equal(t, 2, len(arbs))
	arbs[0] = testutils.TestAddress("fake")
	arbsFresh := GetArbiters()
	uassert.True(t, arbsFresh[0] != testutils.TestAddress("fake"))

	stats := GetStats()
	uassert.Equal(t, 3, stats.MarketCount)
	uassert.Equal(t, stats.TotalCollateral, stats.VaultBalance)
	assertGlobalSolvency(t)
}

func TestRender_RoutesAndSVGChart(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	resetState(0, cur, alice)

	closeT := time.Now().Unix() + 3600
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(1_000_000))
	testing.SetOriginSend(ugnot(1_000_000))
	id := CreateMarket(cross(cur), "Will Verdict ship SVG charts?", "Chart test.", "DeFi", closeT, 100, 60)
	testing.SetOriginSend(nil)

	advanceTime(30)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(250_000))
	testing.SetOriginSend(ugnot(250_000))
	Buy(cross(cur), id, true, 1)
	testing.SetOriginSend(nil)

	home := Render("")
	uassert.True(t, strings.Contains(home, "<gno-columns>"))
	uassert.True(t, strings.Contains(home, "<gno-frame>"))
	uassert.True(t, strings.Contains(home, "<gno-button"))
	uassert.True(t, strings.Contains(home, "data:image/svg+xml;base64,"))
	uassert.True(t, strings.Contains(home, "Will Verdict ship SVG charts?"))

	detail := Render("/market/1/")
	uassert.True(t, strings.Contains(detail, "![YES Probability Chart](data:image/svg+xml;base64,"))
	uassert.True(t, strings.Contains(detail, "$help&func=Buy"))
	uassert.True(t, strings.Contains(detail, `<gno-form exec="Sell">`))
	uassert.True(t, strings.Contains(detail, `readonly="true"`))
	uassert.False(t, strings.Contains(detail, `type="hidden"`))

	createPage := Render("create")
	uassert.True(t, strings.Contains(createPage, "$help&func=CreateMarket"))

	portPage := Render("portfolio/" + bob.String())
	uassert.True(t, strings.Contains(portPage, bob.String()))
	uassert.True(t, strings.Contains(portPage, "Will Verdict ship SVG charts?"))

	notFound := Render("does/not/exist")
	uassert.True(t, strings.Contains(notFound, "Route Not Found"))
}

func TestRender_SanitizesMarkdownAndMathInjection(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	resetState(0, cur, alice)

	hostileQ := `Win $GNOT/$ATOM? [phish](https://evil.com) <gno-button href="/r/evil" label="pwn" />`
	hostileDesc := "# Fake H1\n<script>alert(1)</script>\n$100/$200"
	hostileCat := "DeFi|Hack"

	closeT := time.Now().Unix() + 3600
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(200_000))
	testing.SetOriginSend(ugnot(200_000))
	CreateMarket(cross(cur), hostileQ, hostileDesc, hostileCat, closeT, 100, 60)
	testing.SetOriginSend(nil)

	home := Render("")
	// Unescaped raw <gno-button from hostileQ must NOT appear; escaped \$ must appear.
	uassert.False(t, strings.Contains(home, `<gno-button href="/r/evil"`))
	uassert.False(t, strings.Contains(home, `](https://evil.com)`))
	uassert.True(t, strings.Contains(home, `\$GNOT/\$ATOM`))
	uassert.True(t, strings.Contains(home, `DeFi\|Hack`))

	detail := Render("market/1")
	uassert.False(t, strings.Contains(detail, "\n# Fake H1"))
	uassert.False(t, strings.Contains(detail, "\n<script>alert(1)</script>"))
	uassert.True(t, strings.Contains(detail, `\$100/\$200`))

	badPath := Render("bad/[click](https://evil.com)/$X$")
	uassert.False(t, strings.Contains(badPath, `[click](https://evil.com)`))
	uassert.True(t, strings.Contains(badPath, `\$X\$`))
}

func TestMultiMarketStatefulInvariantSimulation(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	dave := testutils.TestAddress("dave")
	eve := testutils.TestAddress("eve")
	arb2 := testutils.TestAddress("arb2")
	arb3 := testutils.TestAddress("arb3")
	resetState(0, cur, alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	AddArbiter(cross(cur), arb2)
	AddArbiter(cross(cur), arb3)
	SetArbiterQuorum(cross(cur), 2)

	baseClose := time.Now().Unix() + 3600

	// Market 1: 1% fee, optimistic YES resolution.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.IssueCoins(realmAddr, ugnot(2_000_000))
	testing.SetOriginSend(ugnot(2_000_000))
	m1 := CreateMarket(cross(cur), "Sim Market 1", "Desc 1", "Crypto", baseClose, 100, 120)
	testing.SetOriginSend(nil)

	// Market 2: 2.5% fee, disputed and resolved NO by 2-of-3 arbiters.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(1_500_000))
	testing.SetOriginSend(ugnot(1_500_000))
	m2 := CreateMarket(cross(cur), "Sim Market 2", "Desc 2", "Policy", baseClose, 250, 120)
	testing.SetOriginSend(nil)

	// Market 3: 0% fee, disputed and resolved INVALID via ExpireDispute timeout.
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.IssueCoins(realmAddr, ugnot(1_000_000))
	testing.SetOriginSend(ugnot(1_000_000))
	m3 := CreateMarket(cross(cur), "Sim Market 3", "Desc 3", "Sports", baseClose, 0, 120)
	testing.SetOriginSend(nil)

	assertGlobalSolvency(t)

	// Phase 1: Interleaved trading and LP ops across all 3 markets.
	traders := []address{alice, bob, carol, dave, eve}
	mids := []uint64{m1, m2, m3}
	seed := uint64(0x517cc1b727220a95)
	nextRand := func() uint64 {
		seed ^= seed << 13
		seed ^= seed >> 7
		seed ^= seed << 17
		return seed
	}

	for step := 0; step < 45; step++ {
		advanceTime(5)
		actor := traders[nextRand()%uint64(len(traders))]
		mid := mids[nextRand()%uint64(len(mids))]
		op := nextRand() % 4

		switch op {
		case 0, 1: // Buy YES or NO
			buyYes := op == 0
			amt := int64(20_000 + (nextRand() % 300_000))
			if _, err := PreviewBuy(mid, buyYes, amt); err != nil {
				continue
			}
			testing.SetRealm(testing.NewUserRealm(actor))
			testing.IssueCoins(realmAddr, ugnot(amt))
			testing.SetOriginSend(ugnot(amt))
			Buy(cross(cur), mid, buyYes, 1)
			testing.SetOriginSend(nil)

		case 2: // Sell held YES or NO shares
			pos := GetPosition(mid, actor)
			sellYes := true
			held := pos.YesShares
			if pos.NoShares > held {
				sellYes = false
				held = pos.NoShares
			}
			if held < 5_000 {
				continue
			}
			sellAmt := held / 2
			if _, err := PreviewSell(mid, sellYes, sellAmt); err != nil {
				continue
			}
			testing.SetRealm(testing.NewUserRealm(actor))
			Sell(cross(cur), mid, sellYes, sellAmt, 1)

		case 3: // Add or partial Remove LP
			pos := GetPosition(mid, actor)
			if pos.LPShares > 200_000 && (nextRand()%2 == 0) {
				burn := pos.LPShares / 4
				if _, err := PreviewRemoveLiquidity(mid, burn); err != nil {
					continue
				}
				testing.SetRealm(testing.NewUserRealm(actor))
				RemoveLiquidity(cross(cur), mid, burn)
			} else {
				amt := int64(50_000 + (nextRand() % 200_000))
				if _, err := PreviewAddLiquidity(mid, amt); err != nil {
					continue
				}
				testing.SetRealm(testing.NewUserRealm(actor))
				testing.IssueCoins(realmAddr, ugnot(amt))
				testing.SetOriginSend(ugnot(amt))
				AddLiquidity(cross(cur), mid, 1)
				testing.SetOriginSend(nil)
			}
		}
		assertGlobalSolvency(t)
	}

	// Phase 2: Advance past closeTime; propose all 3 markets.
	advanceTime(4000)

	testing.SetRealm(testing.NewUserRealm(dave))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), m1, uint8(OutcomeYes))
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(eve))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), m2, uint8(OutcomeYes)) // Will be overturned to NO
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	ProposeOutcome(cross(cur), m3, uint8(OutcomeNo))
	testing.SetOriginSend(nil)

	assertGlobalSolvency(t)

	// Dispute m2 and m3 inside dispute window.
	advanceTime(30)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	DisputeOutcome(cross(cur), m2)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(dave))
	testing.IssueCoins(realmAddr, ugnot(DefaultBondAmount))
	testing.SetOriginSend(ugnot(DefaultBondAmount))
	DisputeOutcome(cross(cur), m3)
	testing.SetOriginSend(nil)

	// Arbiter quorum resolves m2 as NO (carol wins 2x bond).
	testing.SetRealm(testing.NewUserRealm(alice))
	CastArbiterVote(cross(cur), m2, uint8(OutcomeNo))
	testing.SetRealm(testing.NewUserRealm(arb2))
	CastArbiterVote(cross(cur), m2, uint8(OutcomeNo))

	// Advance past disputeDeadline -> finalize m1 (YES).
	advanceTime(150)
	testing.SetRealm(testing.NewUserRealm(alice))
	FinalizeResolution(cross(cur), m1)

	// Advance past ArbiterTimeout -> expire m3 (INVALID).
	advanceTime(ArbiterTimeout)
	testing.SetRealm(testing.NewUserRealm(eve))
	ExpireDispute(cross(cur), m3)

	assertGlobalSolvency(t)

	// Phase 3: Every trader claims all claimable bonds and all winning/LP market positions.
	for _, actor := range traders {
		if GetClaimableBonds(actor) > 0 {
			testing.SetRealm(testing.NewUserRealm(actor))
			ClaimBonds(cross(cur))
		}
		for _, mid := range mids {
			pos := GetPosition(mid, actor)
			if pos.EstClaimable > 0 && !pos.Claimed {
				testing.SetRealm(testing.NewUserRealm(actor))
				Claim(cross(cur), mid)
			}
		}
		assertGlobalSolvency(t)
	}

	if protocolDustPool > 0 {
		testing.SetRealm(testing.NewUserRealm(alice))
		WithdrawDust(cross(cur), alice)
	}
	assertDrainedToZero(t)
}
