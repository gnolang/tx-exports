package roulette_v6

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

var rouletteAddr = chain.PackageAddress("gno.land/r/g1u97n45s4s6q7vn5clr8339pv4up455hnqn4aff/roulette_v6")

const (
	fundAdmin  = int64(1_000_000_000)
	fundPlayer = int64(1_000_000_000)
	fundRealm  = int64(5_000_000_000)
)

func resetState() {
	admin = ""
	bankroll = 0
	reservedLiability = 0
	status = statusReady
	currentCommitHash = ""
	hasPending = false
	pending = Bet{}
	betID = 0
	lastResult = -1
	lastNonce = 0
	history = nil
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

func armAndFund(cur realm, adminAddr address, serverSeed string, depositAmt int64) {
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(ugnot(depositAmt))
	DepositBankroll(cross(cur))
	ArmTable(cross(cur), seedHash(serverSeed))
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

func TestInstantSpinVault(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-instant")
	playerAddr := testutils.TestAddress("player-instant")
	const depositAmt = int64(500_000_000)
	serverSeed := "instant-seed-1"
	nextSeed := "instant-seed-2"

	fundLedger(cur, adminAddr, playerAddr)
	armAndFund(cur, adminAddr, serverSeed, depositAmt)

	uassert.Equal(t, statusReady, GetStatus())
	uassert.Equal(t, seedHash(serverSeed), GetCurrentCommitHash())

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetRed, 0, "client-a")

	uassert.Equal(t, statusPending, GetStatus())
	uassert.True(t, HasPendingBet())
	uassert.Equal(t, 1, GetPendingNonce())

	expected := VerifyFairness(serverSeed, "client-a", 1)
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveBet(cross(cur), serverSeed, seedHash(nextSeed))

	uassert.Equal(t, statusReady, GetStatus())
	uassert.False(t, HasPendingBet())
	uassert.Equal(t, expected, GetLastResult())
	uassert.Equal(t, 1, GetLastNonce())
	uassert.Equal(t, seedHash(nextSeed), GetCurrentCommitHash())

	vault := GetVaultBalance(playerAddr.String())
	if betWins(BetRed, 0, expected) {
		uassert.Equal(t, chip1*2, vault)
	} else {
		uassert.Equal(t, int64(0), vault)
	}
}

func TestCheatDetection(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-cheat")
	playerAddr := testutils.TestAddress("player-cheat")
	fundLedger(cur, adminAddr, playerAddr)
	armAndFund(cur, adminAddr, "real-seed", 100_000_000)

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetBlack, 0, "cs")

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	uassert.AbortsContains(t, cur, "does not match commit", func() {
		ResolveBet(cross(cur), "fake-seed", seedHash("next"))
	})
}

func TestTableBusyOnePending(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-busy")
	p1 := testutils.TestAddress("player-busy-1")
	p2 := testutils.TestAddress("player-busy-2")
	fundLedger(cur, adminAddr, p1)
	testing.IssueCoins(p2, ugnot(fundPlayer))
	armAndFund(cur, adminAddr, "busy-seed", 200_000_000)

	testing.SetRealm(testing.NewUserRealm(p1))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetEven, 0, "c1")

	testing.SetRealm(testing.NewUserRealm(p2))
	testing.SetOriginSend(ugnot(chip1))
	uassert.AbortsContains(t, cur, "table busy", func() {
		PlaceBet(cross(cur), BetOdd, 0, "c2")
	})
}

func TestWithdrawWinnings(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-wd")
	playerAddr := testutils.TestAddress("player-wd")
	const depositAmt = int64(500_000_000)

	fundLedger(cur, adminAddr, playerAddr)

	serverSeed := ""
	clientSeed := "wd-cs"
	for i := 0; i < 50000; i++ {
		s := "wd-" + strconv.Itoa(i)
		// nonce will be 1 after first PlaceBet
		if VerifyFairness(s, clientSeed, 1) == 0 {
			serverSeed = s
			break
		}
	}
	if serverSeed == "" {
		t.Fatal("could not find seed for NUMBER 0")
	}

	armAndFund(cur, adminAddr, serverSeed, depositAmt)

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetNumber, 0, clientSeed)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveBet(cross(cur), serverSeed, seedHash("next-wd"))

	expected := chip1 * payoutNumber
	uassert.Equal(t, 0, GetLastResult())
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
	serverSeed := "er-seed"

	fundLedger(cur, adminAddr, playerAddr)
	armAndFund(cur, adminAddr, serverSeed, depositAmt)

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetRed, 0, "er-cs")

	commitBefore := GetCurrentCommitHash()
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	msg := EmergencyReset(cross(cur))
	uassert.Equal(t, "Bet emergency reset successful", msg)
	uassert.Equal(t, statusReady, GetStatus())
	uassert.False(t, HasPendingBet())
	uassert.Equal(t, chip1, GetVaultBalance(playerAddr.String()))
	uassert.Equal(t, commitBefore, GetCurrentCommitHash()) // unrevealed seed kept
}

func TestRedLosesOnZero(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-red")
	playerAddr := testutils.TestAddress("player-red")
	const depositAmt = int64(100_000_000)
	clientSeed := "red-cs"

	fundLedger(cur, adminAddr, playerAddr)

	serverSeed := ""
	for i := 0; i < 50000; i++ {
		s := "rz-" + strconv.Itoa(i)
		if VerifyFairness(s, clientSeed, 1) == 0 {
			serverSeed = s
			break
		}
	}
	if serverSeed == "" {
		t.Fatal("no seed for 0")
	}

	armAndFund(cur, adminAddr, serverSeed, depositAmt)

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetRed, 0, clientSeed)

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveBet(cross(cur), serverSeed, seedHash("next-rz"))

	uassert.Equal(t, 0, GetLastResult())
	uassert.Equal(t, int64(0), GetVaultBalance(playerAddr.String()))
	uassert.False(t, GetHistory()[0].Won)
}

func TestSequentialSpinsRearm(cur realm, t *testing.T) {
	defer resetState()
	adminAddr := testutils.TestAddress("admin-seq")
	playerAddr := testutils.TestAddress("player-seq")
	fundLedger(cur, adminAddr, playerAddr)

	seed1 := "seq-1"
	seed2 := "seq-2"
	seed3 := "seq-3"
	armAndFund(cur, adminAddr, seed1, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetLow, 0, "c1")
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveBet(cross(cur), seed1, seedHash(seed2))

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(ugnot(chip1))
	PlaceBet(cross(cur), BetHigh, 0, "c2")
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveBet(cross(cur), seed2, seedHash(seed3))

	uassert.Equal(t, 2, GetRoundID())
	uassert.Equal(t, seedHash(seed3), GetCurrentCommitHash())
	uassert.Equal(t, statusReady, GetStatus())
	uassert.Equal(t, 2, len(GetHistory()))
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
