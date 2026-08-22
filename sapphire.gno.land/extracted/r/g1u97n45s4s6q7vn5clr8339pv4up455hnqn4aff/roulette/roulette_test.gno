package roulette

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

var rouletteAddr = chain.PackageAddress("gno.land/r/roulette")

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
}

func seedHash(serverSeed string) string {
	sum := sha256.Sum256([]byte(serverSeed))
	return hex.EncodeToString(sum[:])
}

func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoins(addr).AmountOf(denom)
}

// TestVerifyFairness_Modulo35 — deterministic and in [0, 34].
func TestVerifyFairness_Modulo35(t *testing.T) {
	a := VerifyFairness("server-secret", "client-seed", 1)
	b := VerifyFairness("server-secret", "client-seed", 1)
	if a != b {
		t.Fatalf("non-deterministic: %d != %d", a, b)
	}
	if a < 0 || a > 34 {
		t.Fatalf("out of range [0,34]: %d", a)
	}
	for i := 0; i < 40; i++ {
		r := VerifyFairness("s", "c", i)
		if r < 0 || r >= wheelSize {
			t.Fatalf("out of range nonce=%d: %d", i, r)
		}
	}
}

// TestNumberPayout_x35 — winning NUMBER bet pays ×35.
func TestNumberPayout_x35(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin")
	playerAddr := testutils.TestAddress("player")
	const (
		serverSeed = "number-win-seed"
		clientSeed = "player-seed"
		betAmount  = int64(100)
		depositAmt = int64(1_000_000)
	)

	testing.IssueCoins(rouletteAddr, chain.Coins{{Denom: denom, Amount: depositAmt}})
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: depositAmt}})
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash(serverSeed))

	nonce := nonceCounter + 1
	winNum := VerifyFairness(serverSeed, clientSeed, nonce)

	testing.IssueCoins(rouletteAddr, chain.Coins{{Denom: denom, Amount: betAmount}})
	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: betAmount}})
	PlaceBet(cross(cur), BetNumber, winNum, clientSeed)

	before := balanceOf(playerAddr)
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	payout := betAmount * payoutNumber
	uassert.Equal(t, winNum, GetLastResult())
	uassert.True(t, GetHistory()[0].Won)
	uassert.Equal(t, payout, GetHistory()[0].Payout)
	if balanceOf(playerAddr)-before != payout {
		t.Fatalf("payout: got %d want %d", balanceOf(playerAddr)-before, payout)
	}
	uassert.Equal(t, depositAmt+betAmount-payout, GetBankroll())
}

// TestColorPayout_x2 — winning RED bet pays ×2.
func TestColorPayout_x2(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin2")
	playerAddr := testutils.TestAddress("player2")
	const (
		serverSeed = "color-win-seed"
		betAmount  = int64(200)
		depositAmt = int64(100_000)
	)

	testing.IssueCoins(rouletteAddr, chain.Coins{{Denom: denom, Amount: depositAmt}})
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: depositAmt}})
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash(serverSeed))

	var cs string
	var res int
	found := false
	for i := 0; i < 200; i++ {
		cs = "red-try-" + strconv.Itoa(i)
		res = VerifyFairness(serverSeed, cs, nonceCounter+1)
		if res != 0 && IsRed(res) {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("could not find a red outcome for the test")
	}

	testing.IssueCoins(rouletteAddr, chain.Coins{{Denom: denom, Amount: betAmount}})
	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: betAmount}})
	PlaceBet(cross(cur), BetRed, 0, cs)

	before := balanceOf(playerAddr)
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), serverSeed)

	payout := betAmount * payoutOutside
	uassert.Equal(t, res, GetLastResult())
	uassert.True(t, GetHistory()[0].Won)
	uassert.Equal(t, payout, GetHistory()[0].Payout)
	if balanceOf(playerAddr)-before != payout {
		t.Fatalf("color payout: got %d want %d", balanceOf(playerAddr)-before, payout)
	}
}

// TestOutsideLosesOnZero — result 0 ⇒ BLACK bet loses.
func TestOutsideLosesOnZero(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin3")
	playerAddr := testutils.TestAddress("player3")
	const depositAmt = int64(50_000)
	const betAmount = int64(50)

	testing.IssueCoins(rouletteAddr, chain.Coins{{Denom: denom, Amount: depositAmt}})
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: depositAmt}})
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash("zero-seed-hunt"))

	var cs string
	found := false
	for i := 0; i < 500; i++ {
		cs = "z-" + strconv.Itoa(i)
		if VerifyFairness("zero-seed-hunt", cs, nonceCounter+1) == 0 {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("could not find a zero outcome for the test")
	}

	testing.IssueCoins(rouletteAddr, chain.Coins{{Denom: denom, Amount: betAmount}})
	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: betAmount}})
	PlaceBet(cross(cur), BetBlack, 0, cs)

	bankBefore := GetBankroll()
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	ResolveRound(cross(cur), "zero-seed-hunt")

	uassert.Equal(t, 0, GetLastResult())
	uassert.False(t, GetHistory()[0].Won)
	uassert.Equal(t, bankBefore, GetBankroll())
}

// TestCheat_BadServerSeed — bad reveal → abort.
func TestCheat_BadServerSeed(cur realm, t *testing.T) {
	defer resetState()

	adminAddr := testutils.TestAddress("admin4")
	playerAddr := testutils.TestAddress("player4")
	const depositAmt = int64(100_000)
	const betAmount = int64(10)

	testing.IssueCoins(rouletteAddr, chain.Coins{{Denom: denom, Amount: depositAmt + betAmount}})
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: depositAmt}})
	DepositBankroll(cross(cur))
	StartRound(cross(cur), seedHash("vrai-secret"))

	testing.SetRealm(testing.NewUserRealm(playerAddr))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: betAmount}})
	PlaceBet(cross(cur), BetNumber, 7, "client")

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	uassert.AbortsContains(t, cur, "serverSeed does not match commit", func() {
		ResolveRound(cross(cur), "faux-secret")
	})
	uassert.Equal(t, statusOpen, GetStatus())
}

// TestBetWinsHelpers — color / even-odd / low-high coverage.
func TestBetWinsHelpers(t *testing.T) {
	if !betWins(BetNumber, 0, 0) {
		t.Fatal("NUMBER(0) must win on 0")
	}
	if betWins(BetRed, 0, 0) || betWins(BetBlack, 0, 0) || betWins(BetEven, 0, 0) {
		t.Fatal("outside bets must lose on 0")
	}
	if !betWins(BetRed, 0, 1) || betWins(BetBlack, 0, 1) {
		t.Fatal("1 is red")
	}
	if !betWins(BetBlack, 0, 2) || betWins(BetRed, 0, 2) {
		t.Fatal("2 is black")
	}
	if !betWins(BetEven, 0, 2) || !betWins(BetOdd, 0, 3) {
		t.Fatal("EVEN/ODD")
	}
	if !betWins(BetLow, 0, 17) || betWins(BetLow, 0, 18) {
		t.Fatal("LOW 1-17")
	}
	if !betWins(BetHigh, 0, 18) || betWins(BetHigh, 0, 17) {
		t.Fatal("HIGH 18-34")
	}
}
