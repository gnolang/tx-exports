package factory_v6

import (
	"chain"
	"strings"
	"testing"
)

// Regression tests for the audit and V6 production-hardening fixes:
//   P1  LOCKED-PROTOCOL-LP-1   protocol seed remains permanently locked
//   P2  ADMIN-ROTATE-1         ProposeAdmin / AcceptAdmin
//   P3  AMM-OVERFLOW-1         safeMul
//   P3  AMM-REMOVELIQ-ROUND-1  RemoveLiquidity tolerates one side rounding to 0
//   P3  FEE-ON-CHANGE-1        capped buy is not charged fee on refunded change
//   P3  DUST-SELL-1            sells with zero net proceeds are rejected
//
// Crossing calls are inlined in each test body (threading `cur` through a helper
// makes the crossing caller the factory realm itself). revive() catches
// cross-realm aborts; recover() catches same-realm panics (safeMul).

// Checksum-valid addresses (the all-q address used elsewhere only works as a
// caller; Mint/SendCoins/IssueCoins validate bech32, so coin/token targets here
// must be real addresses).
const eoaA = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
const eoaB = address("g125em6arxsnj49vx35f0n0z34putv5ty3376fg5")

// --- P3 AMM-OVERFLOW-1 -------------------------------------------------------

func TestSafeMul(t *testing.T) {
	if safeMul(0, 5) != 0 {
		t.Fatal("safeMul(0,5) should be 0")
	}
	if safeMul(3, 4) != 12 {
		t.Fatal("safeMul(3,4) should be 12")
	}
	if safeMul(1000000, 1000000) != 1000000000000 {
		t.Fatal("safeMul(1e6,1e6) wrong")
	}
}

func TestSafeMulOverflowPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("AMM-OVERFLOW-1: safeMul must panic on overflow")
		}
	}()
	_ = safeMul(int64(9223372036854775807), 2)
	t.Fatal("AMM-OVERFLOW-1: safeMul did not panic on overflow")
}

// --- P3 FEE-ON-CHANGE-1 ------------------------------------------------------

func TestFeeOnChange_CappedBuyNotOvercharged(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))
	LaunchToken(cross(cur), "CAP", "Cap Token", "", "", "", "", "", "", "")

	entry := getTokenEntry("CAP")
	// Push supply to within 5 of the cap so a 100 GNOT buy clamps at MAX_SUPPLY
	// and refunds most of the payment as change.
	if err := entry.ledger.Mint(eoaA, MAX_SUPPLY-5); err != nil {
		t.Fatal(err)
	}

	tokensOut, fee, change := QuoteBuy("CAP", MAX_BUY_UGNOT)
	if tokensOut <= 0 || tokensOut > 5 {
		t.Fatalf("expected a tiny capped fill, got %d tokens", tokensOut)
	}
	naiveFee := (MAX_BUY_UGNOT * FEE_BPS) / 10000 // fee on the full payment
	if fee >= naiveFee {
		t.Fatalf("FEE-ON-CHANGE-1: fee %d should be far below naive %d", fee, naiveFee)
	}
	if change < MAX_BUY_UGNOT/2 {
		t.Fatalf("FEE-ON-CHANGE-1: expected large refund, got change %d", change)
	}
}

// --- P3 DUST-SELL-1 ----------------------------------------------------------

func TestDustSellRejected(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))
	LaunchToken(cross(cur), "DST", "Dust Token", "", "", "", "", "", "", "")

	entry := getTokenEntry("DST")
	// supply == 1, reserves == 1: selling the single token nets 0 ugnot after fee.
	if err := entry.ledger.Mint(eoaA, 1); err != nil {
		t.Fatal(err)
	}
	entry.meta.Reserves = 1

	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.Coins{})
	r := revive(func() { Sell(cross(cur), "DST", 1, 1) })
	if r == nil {
		t.Fatal("DUST-SELL-1: a zero-proceeds sell must be rejected")
	}
	msg, _ := r.(string)
	if !strings.Contains(msg, "too small") {
		t.Fatalf("DUST-SELL-1: expected dust-sell abort, got %v", r)
	}
}

// --- P2 ADMIN-ROTATE-1 -------------------------------------------------------

func TestAdminRotation(cur realm, t *testing.T) {
	admin = eoaA
	pendingAdmin = ""

	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	ProposeAdmin(cross(cur), eoaB)
	if GetPendingAdmin() != eoaB {
		t.Fatal("ADMIN-ROTATE-1: pending admin not set")
	}

	// The current admin cannot accept on behalf of the pending admin.
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	rBad := revive(func() { AcceptAdmin(cross(cur)) })
	if rBad == nil {
		t.Fatal("ADMIN-ROTATE-1: only the pending admin may accept")
	}

	// The pending admin accepts and takes over.
	testing.SetRealm(testing.NewUserRealm(eoaB))
	testing.SetOriginCaller(eoaB)
	AcceptAdmin(cross(cur))
	if GetAdmin() != eoaB {
		t.Fatal("ADMIN-ROTATE-1: admin should be the new key")
	}
	if GetPendingAdmin() != "" {
		t.Fatal("ADMIN-ROTATE-1: pending admin should clear after accept")
	}
	admin = eoaA // restore for any later tests
}

// --- P1 LOCKED-PROTOCOL-LP-1 -------------------------------------------------

func TestProtocolLiquidityRemainsLocked(cur realm, t *testing.T) {
	admin = eoaA
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))
	LaunchToken(cross(cur), "LPT", "LP Token", "", "", "", "", "", "", "")

	entry := getTokenEntry("LPT")
	tokenRes := int64(1000000)
	gnotRes := int64(2000000)
	if err := entry.ledger.Mint(realmAddr, tokenRes); err != nil { // back the pool token side
		t.Fatal(err)
	}
	ammPools["LPT"] = &AMMPool{
		TokenReserve: tokenRes,
		GNOTReserve:  gnotRes,
		KLast:        safeK(tokenRes, gnotRes),
		TotalLP:      gnotRes,
		Active:       true,
	}
	lpBalances["LPT"] = make(map[address]int64)
	lpBalances["LPT"][realmAddr] = gnotRes // permanently locked protocol LP
	lpBalances["LPT"][eoaA] = 100
	ammPools["LPT"].TotalLP += 100
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", gnotRes)))

	if GetProtocolLockedLP("LPT") != gnotRes {
		t.Fatal("LOCKED-PROTOCOL-LP-1: locked position should be publicly queryable")
	}
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.Coins{})
	_, _ = RemoveLiquidity(cross(cur), "LPT", 100, 1, 1)
	if GetProtocolLockedLP("LPT") != gnotRes {
		t.Fatal("LOCKED-PROTOCOL-LP-1: user exit changed locked protocol LP")
	}
	if ammPools["LPT"].TotalLP != gnotRes {
		t.Fatal("LOCKED-PROTOCOL-LP-1: user exit must leave the locked LP supply")
	}
	admin = eoaA
}

// --- P3 AMM-REMOVELIQ-ROUND-1 ------------------------------------------------

func TestRemoveLiquidityDoesNotBrickOnRounding(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))
	LaunchToken(cross(cur), "RND", "Round Token", "", "", "", "", "", "", "")

	entry := getTokenEntry("RND")
	// Imbalanced pool: large token reserve, tiny GNOT reserve. Burning 1 LP gives
	// tokensOut > 0 but gnotOut rounds to 0 -> old code panicked ("||").
	tokenRes := int64(1000000000)
	gnotRes := int64(10)
	totalLP := int64(1000000)
	if err := entry.ledger.Mint(realmAddr, tokenRes); err != nil {
		t.Fatal(err)
	}
	ammPools["RND"] = &AMMPool{
		TokenReserve: tokenRes,
		GNOTReserve:  gnotRes,
		KLast:        safeK(tokenRes, gnotRes),
		TotalLP:      totalLP,
		Active:       true,
	}
	lpBalances["RND"] = make(map[address]int64)
	lpBalances["RND"][eoaA] = 1
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", gnotRes)))

	testing.SetRealm(testing.NewUserRealm(eoaA))
	testing.SetOriginCaller(eoaA)
	testing.SetOriginSend(chain.Coins{})
	r := revive(func() { RemoveLiquidity(cross(cur), "RND", 1, 1, 0) })
	if r != nil {
		t.Fatalf("AMM-REMOVELIQ-ROUND-1: should not brick when one side rounds to 0, got %v", r)
	}
	if lpBalances["RND"][eoaA] != 0 {
		t.Fatal("AMM-REMOVELIQ-ROUND-1: LP should be burned")
	}
}
