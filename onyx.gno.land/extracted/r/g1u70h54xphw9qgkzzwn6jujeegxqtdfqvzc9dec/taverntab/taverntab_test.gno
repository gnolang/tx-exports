package taverntab

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var realmAddr = chain.PackageAddress("gno.land/r/g1u70h54xphw9qgkzzwn6jujeegxqtdfqvzc9dec/taverntab")

func balanceOf(addr address) int64 {
	b := banker.NewReadonlyBanker()
	return b.GetCoin(addr, "ugnot")
}

func resetTestState() {
	tabs = map[uint64]*tab{}
	nextID = 1
	heldTotal = 0
}

// openTabAs drives OpenTab the way a real user call would: the given
// user becomes the previous realm, and amount ugnot rides the call.
// The test VM tracks the origin-send envelope but does not move coins
// into the realm account, so the realm is issued the deposit to fund
// the later payout (same pattern as the atomicswap example tests).
func openTabAs(cur realm, payer, payee address, amount int64, memo string) uint64 {
	testing.SetRealm(testing.NewUserRealm(payer))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: amount}})
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: amount}})
	return OpenTab(cross(cur), payee, memo)
}

func TestOpenAndSettlePaysPayee(cur realm, t *testing.T) {
	defer resetTestState()
	payer := testutils.TestAddress("payer")
	payee := testutils.TestAddress("payee")

	id := openTabAs(cur, payer, payee, 5000, "two ales and a stew")
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, int64(5000), HeldTotal())
	uassert.Equal(t, int64(0), balanceOf(payee))

	_, tabPayee, amount, _, status, found := GetTab(id)
	uassert.True(t, found)
	uassert.Equal(t, payee, tabPayee)
	uassert.Equal(t, int64(5000), amount)
	uassert.Equal(t, "open", status)

	testing.SetRealm(testing.NewUserRealm(payer))
	SettleTab(cross(cur), id)

	uassert.Equal(t, int64(5000), balanceOf(payee), "payee must receive the held amount")
	uassert.Equal(t, int64(0), HeldTotal())
	_, _, _, _, status, _ = GetTab(id)
	uassert.Equal(t, "settled", status)
}

func TestOpenAndCancelRefundsPayer(cur realm, t *testing.T) {
	defer resetTestState()
	payer := testutils.TestAddress("payer")
	payee := testutils.TestAddress("payee")

	id := openTabAs(cur, payer, payee, 7000, "a round for the table")
	uassert.Equal(t, int64(0), balanceOf(payer))

	testing.SetRealm(testing.NewUserRealm(payer))
	CancelTab(cross(cur), id)

	uassert.Equal(t, int64(7000), balanceOf(payer), "payer must be refunded in full")
	uassert.Equal(t, int64(0), balanceOf(payee))
	uassert.Equal(t, int64(0), HeldTotal())
	_, _, _, _, status, _ := GetTab(id)
	uassert.Equal(t, "cancelled", status)
}

func TestNonPayerCannotSettleOrCancel(cur realm, t *testing.T) {
	defer resetTestState()
	payer := testutils.TestAddress("payer")
	payee := testutils.TestAddress("payee")
	stranger := testutils.TestAddress("stranger")

	id := openTabAs(cur, payer, payee, 3000, "stranger keep out")

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsWithMessage(t, cur, "SettleTab: only the payer can settle this tab",
		func() { SettleTab(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, "CancelTab: only the payer can cancel this tab",
		func() { CancelTab(cross(cur), id) })

	// The payee is not the payer either: settling is not theirs to trigger.
	testing.SetRealm(testing.NewUserRealm(payee))
	uassert.AbortsWithMessage(t, cur, "SettleTab: only the payer can settle this tab",
		func() { SettleTab(cross(cur), id) })

	// Tab untouched: still open, tavern still holding the coins.
	_, _, _, _, status, _ := GetTab(id)
	uassert.Equal(t, "open", status)
	uassert.Equal(t, int64(3000), HeldTotal())
}

func TestDoubleSettleRejected(cur realm, t *testing.T) {
	defer resetTestState()
	payer := testutils.TestAddress("payer")
	payee := testutils.TestAddress("payee")

	id := openTabAs(cur, payer, payee, 4000, "settle me once")

	testing.SetRealm(testing.NewUserRealm(payer))
	SettleTab(cross(cur), id)
	uassert.Equal(t, int64(4000), balanceOf(payee))

	uassert.AbortsWithMessage(t, cur, "SettleTab: tab is not open",
		func() { SettleTab(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, "CancelTab: tab is not open",
		func() { CancelTab(cross(cur), id) })
	uassert.Equal(t, int64(4000), balanceOf(payee), "payee must not be paid twice")
}

func TestSettleAfterCancelRejected(cur realm, t *testing.T) {
	defer resetTestState()
	payer := testutils.TestAddress("payer")
	payee := testutils.TestAddress("payee")

	id := openTabAs(cur, payer, payee, 4000, "cancel me once")

	testing.SetRealm(testing.NewUserRealm(payer))
	CancelTab(cross(cur), id)
	uassert.AbortsWithMessage(t, cur, "SettleTab: tab is not open",
		func() { SettleTab(cross(cur), id) })
	uassert.Equal(t, int64(0), balanceOf(payee))
}

func TestRenderBoard(cur realm, t *testing.T) {
	defer resetTestState()
	payer := testutils.TestAddress("payer")
	payee := testutils.TestAddress("payee")

	id := openTabAs(cur, payer, payee, 2500, "board special")
	board := Render("")
	uassert.True(t, contains(board, "TavernTab"), "board must carry the title")
	uassert.True(t, contains(board, "2500ugnot"), "board must show the held amount")

	one := Render("1")
	uassert.True(t, contains(one, "open"), "single-tab view must show the status")
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, "404: unknown tab", Render("999"))
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
