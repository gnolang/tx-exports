package roulette_v2

import (
	"chain"
	"chain/banker"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// Must match gnomod.toml module path (PackageAddress derives the realm bech32).
var rouletteAddr = chain.PackageAddress("gno.land/r/g1u97n45s4s6q7vn5clr8339pv4up455hnqn4aff/roulette_v2")

const (
	fundAdmin  = int64(1_000_000_000) // 1000 GNOT
	fundPlayer = int64(1_000_000_000) // 1000 GNOT
	fundRealm  = int64(5_000_000_000) // 5000 GNOT — covers ×36 payouts
)

func resetState() {
	admin = ""
	bankroll = 0
	status = statusIdle
	serverSeedHash = ""
	currentBet = nil
	roundID = 0
	nonceCounter = 0
	lastResult = -1
	history = nil
	lps = nil
	totalShares = 0
	totalDeposits = 0
	accumulatedProfit = 0
}

func seedHash(serverSeed string) string {
	sum := sha256.Sum256([]byte(serverSeed))
	return hex.EncodeToString(sum[:])
}

func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoins(addr).AmountOf(denom)
}

func ugnot(amount int64) chain.Coins {
	return chain.Coins{{Denom: denom, Amount: amount}}
}

// fundLedger pre-funds admin, player (optional), and the realm under test.
// Modern equivalent of legacy std.TestLedger.SetBalance — uses testing.IssueCoins.
// Always prefer cur.Address() over a hard-coded PackageAddress so sends hit the live realm.
func fundLedger(cur realm, adminAddr, playerAddr address) {
	realmAddr := cur.Address()
	testing.IssueCoins(adminAddr, ugnot(fundAdmin))
	if playerAddr != "" {
		testing.IssueCoins(playerAddr, ugnot(fundPlayer))
	}
	testing.IssueCoins(realmAddr, ugnot(fundRealm))
	// Keep package-path address funded too (should equal cur.Address() for this module).
	if realmAddr != rouletteAddr {
		testing.IssueCoins(rouletteAddr, ugnot(fundRealm))
	}
}

func TestVerifyFairness_Modulo38(t *testing.T) {
	a := VerifyFairness("server-secret", "client-seed", 1)
	b := VerifyFairness("server-secret", "client-seed", 1)
	if a != b {
		t.Fatalf("non-deterministic: %d != %d", a, b)
	}
	if a < 0 || a > 37 {
		t.Fatalf("out of range [0,37]: %d", a)
	}
	for i := 0; i < 80; i++ {
		r := VerifyFairness("s", "c", i)
		if r < 0 || r >= wheelSize {
			t.Fatalf("out of range nonce=%d: %d", i, r)
		}
	}
	uassert.Equal(t, "00", DisplayLabel(37))
	uassert.Equal(t, "0", DisplayLabel(0))
	uassert.False(t, betWins(BetRed, 0, 0))
	uassert.False(t, betWins(BetRed, 0, 37))
	uassert.True(t, betWins(BetNumber, 0, 0))
	uassert.True(t, betWins(BetNumber, 37, 37))
	uassert.True(t, betWins(BetLow, 0, 18))
	uassert.True(t, betWins(BetHigh, 0, 19))
	uassert.False(t, validAmounts[3_000_000])
	uassert.True(t, validAmounts[chip1])
}

func TestNumberZeroWin(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin0")
	playerAddr := testutils.TestAddress("player0")
	const depositAmt = int64(500_000_000)
	serverSeed := "hit-zero"

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))

	cs := ""
	found := false
	for i := 0; i < 20000; i++ {
		cs = "z-" + strconv.Itoa(i)
		if VerifyFairness(serverSeed, cs, nonceCounter+1) == 0 {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("could not find seed for 0")
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	StartRound(cross(cur), seedHash(serverSeed))

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetNumber, 0, cs)

	before := balanceOf(playerAddr)
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	uassert.Equal(t, 0, GetLastResult())
	uassert.True(t, GetHistory()[0].Won)
	uassert.Equal(t, chip1*payoutNumber, GetHistory()[0].Payout)
	if balanceOf(playerAddr)-before != chip1*payoutNumber {
		t.Fatalf("payout delta mismatch")
	}
}

func TestNumberDoubleZeroWin(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin00")
	playerAddr := testutils.TestAddress("player00")
	const depositAmt = int64(500_000_000)
	serverSeed := "hit-double-zero"

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))

	cs := ""
	found := false
	for i := 0; i < 20000; i++ {
		cs = "dz-" + strconv.Itoa(i)
		if VerifyFairness(serverSeed, cs, nonceCounter+1) == 37 {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("could not find seed for 00")
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	StartRound(cross(cur), seedHash(serverSeed))

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetNumber, 37, cs)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	uassert.Equal(t, 37, GetLastResult())
	uassert.True(t, GetHistory()[0].Won)
	uassert.Equal(t, chip1*payoutNumber, GetHistory()[0].Payout)
}

func TestRedLosesOnZero(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin-red")
	playerAddr := testutils.TestAddress("player-red")
	const depositAmt = int64(100_000_000)
	serverSeed := "red-lose-zero"

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))

	cs := ""
	found := false
	for i := 0; i < 20000; i++ {
		cs = "rz-" + strconv.Itoa(i)
		if VerifyFairness(serverSeed, cs, nonceCounter+1) == 0 {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("could not find seed landing on 0")
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	StartRound(cross(cur), seedHash(serverSeed))

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip2))
	PlaceBet(cross(cur), BetRed, 0, cs)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	uassert.Equal(t, 0, GetLastResult())
	uassert.False(t, GetHistory()[0].Won)
	uassert.Equal(t, chip2, GetAccumulatedProfit())
}

func TestInvalidBetAmount(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin-amt")
	playerAddr := testutils.TestAddress("player-amt")
	const depositAmt = int64(100_000_000)
	const badAmt = int64(3_000_000)

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash("amt-seed"))

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(badAmt))
	uassert.AbortsContains(t, cur, "invalid bet amount", func() {
		PlaceBet(cross(cur), BetRed, 0, "client")
	})
}

func TestLiquidityPool(cur realm, t *testing.T) {
	defer resetState()

	lp1 := testutils.TestAddress("lp1")
	lp2 := testutils.TestAddress("lp2")

	fundLedger(cur, lp1, lp2)

	testing.SetRealm(testing.NewUserRealm(lp1))
	testing.SetOriginSend(ugnot(10_000_000))
	DepositLiquidity(cross(cur))
	uassert.Equal(t, int64(10_000_000), GetTotalShares())
	uassert.Equal(t, int64(10_000_000), GetTotalDeposits())
	uassert.Equal(t, 1, GetLPCount())

	testing.SetRealm(testing.NewUserRealm(lp2))
	testing.SetOriginSend(ugnot(10_000_000))
	DepositLiquidity(cross(cur))
	uassert.Equal(t, int64(20_000_000), GetTotalShares())
	uassert.Equal(t, 2, GetLPCount())

	accumulatedProfit = 4_000_000
	if GetLPInfo(lp1.String()) == "no LP position" {
		t.Fatal("LP1 missing")
	}
	if GetPoolStats() == "" {
		t.Fatal("empty pool stats")
	}

	bankBefore := GetBankroll()
	testing.SetRealm(testing.NewUserRealm(lp1))
	WithdrawLiquidity(cross(cur))
	uassert.Equal(t, bankBefore-12_000_000, GetBankroll())
	uassert.Equal(t, int64(2_000_000), GetAccumulatedProfit())
	uassert.Equal(t, 1, GetLPCount())
}

func TestLiquidityMinDeposit(cur realm, t *testing.T) {
	defer resetState()
	lp := testutils.TestAddress("lpmin")
	fundLedger(cur, lp, "")

	testing.SetRealm(testing.NewUserRealm(lp))
	testing.SetOriginSend(ugnot(500_000))
	uassert.AbortsContains(t, cur, "minimum LP deposit", func() {
		DepositLiquidity(cross(cur))
	})
}

func TestFullRoundRedWin(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin-win")
	playerAddr := testutils.TestAddress("player-win")
	const depositAmt = int64(100_000_000)
	serverSeed := "red-win-seed"

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))

	cs := ""
	found := false
	for i := 0; i < 20000; i++ {
		cs = "rw-" + strconv.Itoa(i)
		if VerifyFairness(serverSeed, cs, nonceCounter+1) == 1 {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("could not find red result")
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	StartRound(cross(cur), seedHash(serverSeed))

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip5))
	PlaceBet(cross(cur), BetRed, 0, cs)

	before := balanceOf(playerAddr)
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	uassert.True(t, GetHistory()[0].Won)
	uassert.Equal(t, chip5*2, GetHistory()[0].Payout)
	if balanceOf(playerAddr)-before != chip5*2 {
		t.Fatalf("red payout mismatch")
	}
}

func TestCheatDetection(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin-cheat")
	playerAddr := testutils.TestAddress("player-cheat")
	const depositAmt = int64(50_000_000)

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash("real-seed"))

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetBlack, 0, "c")

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	uassert.AbortsContains(t, cur, "does not match commit", func() {
		ResolveRound(cross(cur), "fake-seed")
	})
}
