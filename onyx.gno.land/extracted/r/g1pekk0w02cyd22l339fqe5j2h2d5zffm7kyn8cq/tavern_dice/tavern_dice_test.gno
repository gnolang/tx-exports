package tavern_dice

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func bankerNewReadonly() banker.Banker {
	return banker.NewReadonlyBanker()
}

func resetTestState() {
	owner = address("")
	rollSeq = 0
	prevRollHash = [32]byte{}
	totalBets = 0
	totalWagered = 0
	totalPaidOut = 0
	totalWins = 0
	rolls = nil
	players = map[address]*playerStats{}
	funders = map[address]int64{}
}

func pkgAddr() address {
	return chain.PackageAddress(pkgPath)
}

// betAs places one number bet as player with the given send amount.
// The caller must have issued coins to the realm (bankroll) first.
func betAs(cur realm, t *testing.T, player address, amount int64, number int) int {
	testing.SetRealm(testing.NewUserRealm(player))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: amount}})
	return BetNumber(cross(cur), number)
}

func TestBetNumberWin(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	player := testutils.TestAddress("player1")

	// The roll is deterministic in tests (fixed block height/time), so we
	// can pre-compute it and bet on it.
	expectedRoll, _ := deriveRoll(player)
	roll := betAs(cur, t, player, 10000, expectedRoll)
	uassert.Equal(t, expectedRoll, roll)
	uassert.Equal(t, int64(1), totalBets)
	uassert.Equal(t, int64(10000), totalWagered)
	uassert.Equal(t, int64(50000), totalPaidOut)
	uassert.Equal(t, int64(1), totalWins)
	uassert.Equal(t, int64(50000), players[player].biggestWin)
	// Payout landed on the player; the bankroll paid it out.
	banker_ := bankerNewReadonly()
	uassert.Equal(t, int64(50000), banker_.GetCoin(player, denom))
	uassert.Equal(t, int64(10000000-50000), banker_.GetCoin(pkgAddr(), denom))
}

func TestBetNumberLoss(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	player := testutils.TestAddress("player2")

	expectedRoll, _ := deriveRoll(player)
	losing := expectedRoll%6 + 1 // a number the roll cannot be
	roll := betAs(cur, t, player, 10000, losing)
	uassert.Equal(t, expectedRoll, roll)
	uassert.Equal(t, int64(1), totalBets)
	uassert.Equal(t, int64(10000), totalWagered)
	uassert.Equal(t, int64(0), totalPaidOut)
	uassert.Equal(t, int64(0), totalWins)
	uassert.Equal(t, int64(0), players[player].biggestWin)
	uassert.Equal(t, 1, len(rolls))
	uassert.Equal(t, int64(0), rolls[0].payout)
}

func TestBetParityWinAndLoss(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	player := testutils.TestAddress("player3")

	expectedRoll, _ := deriveRoll(player)
	even := expectedRoll%2 == 0
	testing.SetRealm(testing.NewUserRealm(player))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 10000}})
	roll := BetParity(cross(cur), even)
	uassert.Equal(t, expectedRoll, roll)
	uassert.Equal(t, int64(19000), totalPaidOut) // 1.9x

	// Second bet, wrong parity: no payout.
	testing.SetRealm(testing.NewUserRealm(player))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 10000}})
	BetParity(cross(cur), !even)
	uassert.Equal(t, int64(2), totalBets)
	uassert.Equal(t, int64(19000), totalPaidOut)
	uassert.Equal(t, int64(1), totalWins)
}

func TestBetBelowMin(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	player := testutils.TestAddress("player4")
	testing.SetRealm(testing.NewUserRealm(player))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 500}})
	uassert.AbortsWithMessage(t, cur, "bet below minimum", func() {
		BetNumber(cross(cur), 3)
	})
}

func TestBetNoSend(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	player := testutils.TestAddress("player5")
	testing.SetRealm(testing.NewUserRealm(player))
	// No SetOriginSend: the envelope is empty.
	uassert.AbortsWithMessage(t, cur, "bet must be sent in ugnot only", func() {
		BetNumber(cross(cur), 3)
	})
}

func TestBetWrongDenom(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	player := testutils.TestAddress("player6")
	testing.SetRealm(testing.NewUserRealm(player))
	testing.SetOriginSend(chain.Coins{{Denom: "atom", Amount: 10000}})
	uassert.AbortsWithMessage(t, cur, "bet must be sent in ugnot only", func() {
		BetNumber(cross(cur), 3)
	})
}

func TestBetTooLargeForBankroll(cur realm, t *testing.T) {
	defer resetTestState()
	// Bankroll 10,000ugnot: max number-bet payout is 2,500, so a 1,000
	// bet (5,000 payout) is too large.
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000}})
	player := testutils.TestAddress("player7")
	testing.SetRealm(testing.NewUserRealm(player))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 1000}})
	uassert.AbortsWithMessage(t, cur, "bet too large for the bankroll", func() {
		BetNumber(cross(cur), 3)
	})
}

func TestBetNotUserCall(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	// No SetRealm: the caller is the test realm itself, not a user.
	uassert.AbortsWithMessage(t, cur, "bets must be placed directly by a user account", func() {
		BetNumber(cross(cur), 3)
	})
}

func TestBetNumberOutOfRange(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	player := testutils.TestAddress("player8")
	testing.SetRealm(testing.NewUserRealm(player))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 10000}})
	uassert.AbortsWithMessage(t, cur, "number must be between 1 and 6", func() {
		BetNumber(cross(cur), 7)
	})
}

func TestFund(cur realm, t *testing.T) {
	defer resetTestState()
	funder := testutils.TestAddress("funder1")
	testing.SetRealm(testing.NewUserRealm(funder))
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 5000}})
	Fund(cross(cur))
	uassert.Equal(t, int64(5000), funders[funder])
	testing.SetOriginSend(chain.Coins{{Denom: denom, Amount: 3000}})
	Fund(cross(cur))
	uassert.Equal(t, int64(8000), funders[funder])
}

func TestFundWrongDenom(cur realm, t *testing.T) {
	defer resetTestState()
	funder := testutils.TestAddress("funder2")
	testing.SetRealm(testing.NewUserRealm(funder))
	testing.SetOriginSend(chain.Coins{{Denom: "atom", Amount: 5000}})
	uassert.AbortsWithMessage(t, cur, "fund with ugnot only", func() {
		Fund(cross(cur))
	})
}

func TestWithdraw(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	ownerAddr := testutils.TestAddress("owner1")
	owner = ownerAddr // init does not run as a user call in tests
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	Withdraw(cross(cur), 3000)
	banker_ := bankerNewReadonly()
	uassert.Equal(t, int64(3000), banker_.GetCoin(ownerAddr, denom))
	uassert.Equal(t, int64(10000000-3000), banker_.GetCoin(pkgAddr(), denom))
}

func TestWithdrawNotOwner(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 10000000}})
	owner = testutils.TestAddress("owner2")
	other := testutils.TestAddress("other1")
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsWithMessage(t, cur, "only the owner can withdraw", func() {
		Withdraw(cross(cur), 1000)
	})
}

func TestWithdrawOverBankroll(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 1000}})
	ownerAddr := testutils.TestAddress("owner3")
	owner = ownerAddr
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	uassert.AbortsWithMessage(t, cur, "amount exceeds bankroll", func() {
		Withdraw(cross(cur), 2000)
	})
}

func TestHistoryTrim(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 100000000}})
	player := testutils.TestAddress("player9")
	for i := 0; i < 25; i++ {
		betAs(cur, t, player, 1000, 1)
	}
	uassert.Equal(t, 20, len(rolls))
	uassert.Equal(t, int64(5), rolls[0].seq) // seqs 5..24 kept
	uassert.Equal(t, int64(24), rolls[19].seq)
	uassert.Equal(t, int64(25), totalBets)
	uassert.Equal(t, int64(25), rollSeq)
}

func TestRender(cur realm, t *testing.T) {
	defer resetTestState()
	testing.IssueCoins(pkgAddr(), chain.Coins{{Denom: denom, Amount: 1000000}})
	player := testutils.TestAddress("player10")
	betAs(cur, t, player, 1000, 1)
	home := Render("")
	uassert.True(t, contains(home, "Tavern Dice"), "home should title the game")
	uassert.True(t, contains(home, "1000000 ugnot"), "home should show the bankroll")
	uassert.True(t, contains(home, "Recent rolls"), "home should show rolls")
	rollsPage := Render("rolls")
	uassert.True(t, contains(rollsPage, "Recent Rolls"), "rolls page should title itself")
}

func contains(s, sub string) bool {
	if len(sub) == 0 {
		return true
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
