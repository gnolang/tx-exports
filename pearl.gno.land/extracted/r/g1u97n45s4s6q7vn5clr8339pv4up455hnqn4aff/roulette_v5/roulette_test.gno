package roulette_v5

import (
	"chain"
	"chain/banker"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var rouletteAddr = chain.PackageAddress("gno.land/r/g1u97n45s4s6q7vn5clr8339pv4up455hnqn4aff/roulette_v5")

const (
	fundAdmin  = int64(1_000_000_000)
	fundPlayer = int64(1_000_000_000)
	fundRealm  = int64(5_000_000_000)
)

func resetState() {
	admin = ""
	bankroll = 0
	reservedLiability = 0
	status = statusIdle
	serverSeedHash = ""
	bets = nil
	roundID = 0
	nonceCounter = 0
	lastResult = -1
	history = nil
	bettingClosesAt = 0
	balances = map[address]int64{}
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

func closesAtFar() int64 {
	return time.Now().Unix() + 3600
}

func fundLedger(cur realm, adminAddr, playerAddr address) {
	realmAddr := cur.Address()
	testing.IssueCoins(adminAddr, ugnot(fundAdmin))
	if playerAddr != "" {
		testing.IssueCoins(playerAddr, ugnot(fundPlayer))
	}
	testing.IssueCoins(realmAddr, ugnot(fundRealm))
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
	uassert.Equal(t, "00", DisplayLabel(37))
	uassert.False(t, betWins(BetRed, 0, 0))
	uassert.True(t, betWins(BetNumber, 0, 0))
}

func TestResolveRoundNoPlayers(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-empty")
	serverSeed := "empty-round-seed"
	fundLedger(cur, adminAddr, "")

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	StartRound(cross(cur), seedHash(serverSeed), closesAtFar())
	ResolveRound(cross(cur), serverSeed)

	uassert.Equal(t, statusIdle, GetStatus())
	expected := VerifyFairnessRound(serverSeed, 1)
	uassert.Equal(t, expected, GetLastResult())
	uassert.Equal(t, int64(0), GetHistory()[0].BetAmount)
}

func TestCheatDetectionNoBet(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-cheat-empty")
	fundLedger(cur, adminAddr, "")

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	StartRound(cross(cur), seedHash("real-seed"), closesAtFar())
	uassert.AbortsContains(t, cur, "does not match commit", func() {
		ResolveRound(cross(cur), "fake-seed")
	})
}

func TestMultiBetAndVault(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-multi")
	playerAddr := testutils.TestAddress("player-multi")
	const depositAmt = int64(500_000_000)
	serverSeed := "vault-seed"

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash(serverSeed), closesAtFar())

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetRed, 0, "c1")
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetBlack, 0, "c2")

	uassert.Equal(t, 2, GetBetCount())
	uassert.True(t, HasCurrentBet())

	result := VerifyFairnessRound(serverSeed, 1)
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	uassert.Equal(t, 0, GetBetCount())
	uassert.Equal(t, result, GetLastResult())

	vault := GetVaultBalance(playerAddr.String())
	if betWins(BetRed, 0, result) {
		uassert.Equal(t, chip1*2, vault)
	} else if betWins(BetBlack, 0, result) {
		uassert.Equal(t, chip1*2, vault)
	} else {
		uassert.Equal(t, int64(0), vault)
	}
}

func TestWithdrawWinnings(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-wd")
	playerAddr := testutils.TestAddress("player-wd")
	const depositAmt = int64(200_000_000)
	serverSeed := "withdraw-seed"

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash(serverSeed), closesAtFar())

	// Force a known RED win: hunt until VerifyFairnessRound hits red
	// Or place NUMBER after finding result — place after we know result is hard.
	// Credit vault manually via winning outside bet loop.
	result := VerifyFairnessRound(serverSeed, 1)
	bt := BetRed
	if !betWins(BetRed, 0, result) {
		if betWins(BetBlack, 0, result) {
			bt = BetBlack
		} else {
			// 0/00 — place NUMBER on result
			bt = BetNumber
		}
	}

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	if bt == BetNumber {
		PlaceBet(cross(cur), BetNumber, result, "wd-cs")
	} else {
		PlaceBet(cross(cur), bt, 0, "wd-cs")
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	expected := chip1 * payoutFor(bt)
	uassert.Equal(t, expected, GetVaultBalance(playerAddr.String()))

	before := balanceOf(playerAddr)
	testing.SetRealm(testing.NewUserRealm(playerAddr))
	WithdrawWinnings(cross(cur))
	uassert.Equal(t, int64(0), GetVaultBalance(playerAddr.String()))
	if balanceOf(playerAddr)-before != expected {
		t.Fatalf("wallet credit mismatch")
	}
}

func TestEmergencyResetVaultRefund(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-er")
	playerAddr := testutils.TestAddress("player-er")
	const depositAmt = int64(100_000_000)

	fundLedger(cur, adminAddr, playerAddr)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash("er-seed"), closesAtFar())

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetRed, 0, "er-cs")

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	msg := EmergencyReset(cross(cur))
	uassert.Equal(t, "Round emergency reset successful", msg)
	uassert.Equal(t, statusIdle, GetStatus())
	uassert.Equal(t, 0, GetBetCount())
	uassert.Equal(t, chip1, GetVaultBalance(playerAddr.String()))
}

func TestTenPlayersSameRound(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-10")
	const depositAmt = int64(2_000_000_000)
	serverSeed := "ten-player-seed"

	fundLedger(cur, adminAddr, "")
	players := make([]address, 10)
	for i := 0; i < 10; i++ {
		players[i] = testutils.TestAddress("p10-" + strconv.Itoa(i))
		testing.IssueCoins(players[i], ugnot(fundPlayer))
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash(serverSeed), closesAtFar())

	types := []string{BetRed, BetBlack, BetEven, BetOdd, BetLow, BetHigh, BetRed, BetBlack, BetEven, BetOdd}
	for i := 0; i < 10; i++ {
		testing.SetRealm(testing.NewUserRealm(players[i]))
		testing.SetOriginSend(ugnot(chip1))
		PlaceBet(cross(cur), types[i], 0, "cs-"+strconv.Itoa(i))
	}
	uassert.Equal(t, 10, GetBetCount())

	result := VerifyFairnessRound(serverSeed, 1)
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	uassert.Equal(t, 0, GetBetCount())
	uassert.Equal(t, result, GetLastResult())

	winners := 0
	for i := 0; i < 10; i++ {
		if betWins(types[i], 0, result) {
			winners++
			uassert.Equal(t, chip1*2, GetVaultBalance(players[i].String()))
		} else {
			uassert.Equal(t, int64(0), GetVaultBalance(players[i].String()))
		}
	}
	if winners == 0 && result != 0 && result != 37 {
		t.Fatalf("expected some outside winners on result=%d", result)
	}
}

func TestNumberZeroWinVault(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin0")
	playerAddr := testutils.TestAddress("player0")
	const depositAmt = int64(500_000_000)

	fundLedger(cur, adminAddr, playerAddr)

	// Find server seed whose round-1 result is 0
	serverSeed := ""
	found := false
	for i := 0; i < 50000; i++ {
		s := "z-" + strconv.Itoa(i)
		if VerifyFairnessRound(s, 1) == 0 {
			serverSeed = s
			found = true
			break
		}
	}
	if !found {
		t.Fatal("could not find seed for 0")
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash(serverSeed), closesAtFar())

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetNumber, 0, "zero-cs")

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	uassert.Equal(t, 0, GetLastResult())
	uassert.Equal(t, chip1*payoutNumber, GetVaultBalance(playerAddr.String()))
}

func TestRedLosesOnZero(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-red")
	playerAddr := testutils.TestAddress("player-red")
	const depositAmt = int64(100_000_000)

	fundLedger(cur, adminAddr, playerAddr)

	serverSeed := ""
	for i := 0; i < 50000; i++ {
		s := "rz-" + strconv.Itoa(i)
		if VerifyFairnessRound(s, 1) == 0 {
			serverSeed = s
			break
		}
	}
	if serverSeed == "" {
		t.Fatal("no seed for 0")
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash(serverSeed), closesAtFar())

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetRed, 0, "red-cs")

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	uassert.Equal(t, 0, GetLastResult())
	uassert.Equal(t, int64(0), GetVaultBalance(playerAddr.String()))
	uassert.False(t, GetHistory()[0].Won)
}

func TestLPDepositWithdraw(cur realm, t *testing.T) {
	defer resetState()
	lp := testutils.TestAddress("lp1")
	fundLedger(cur, lp, "")

	testing.SetRealm(testing.NewUserRealm(lp))
	testing.SetOriginSend(ugnot(chip10))
	DepositLiquidity(cross(cur))
	uassert.Equal(t, chip10, GetTotalDeposits())
	uassert.Equal(t, 1, GetLPCount())

	before := balanceOf(lp)
	WithdrawLiquidity(cross(cur))
	uassert.Equal(t, 0, GetLPCount())
	if balanceOf(lp)-before != chip10 {
		t.Fatalf("LP withdraw mismatch")
	}
}
