package tavernescrow

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func resetState() {
	bounties = avl.NewTree()
	hunters = avl.NewTree()
	nextID = 1
	totalPaid = 0
	paidCount = 0
}

func TestBountyLifecycleAndEscrowPayout(cur realm, t *testing.T) {
	defer resetState()

	pkgAddr := chain.PackageAddress("gno.land/r/tavernescrow/v1")
	sponsor := testutils.TestAddress("sponsor1")
	hunter := testutils.TestAddress("hunter1")
	reward := chain.Coins{{Denom: "ugnot", Amount: 1_000_000}}

	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: 5_000_000}})
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(reward)

	id := CreateBounty(cross(cur), "Build Gno Indexer", "Index realm events and expose JSON endpoint.")
	uassert.Equal(t, uint64(1), id)

	board := Render("")
	uassert.True(t, strings.Contains(board, "Build Gno Indexer"), "board should list bounty title")
	uassert.True(t, strings.Contains(board, "OPEN"), "board should show OPEN status")

	// Sponsor cannot claim own bounty
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "sponsor cannot claim own bounty", func() {
		SubmitWork(cross(cur), id, "https://github.com/lexuantamle8-tech/self-claim")
	})

	// Hunter submits invalid URL -> rejected
	testing.SetRealm(testing.NewUserRealm(hunter))
	uassert.AbortsWithMessage(t, cur, "proofURL must start with https://", func() {
		SubmitWork(cross(cur), id, "http://insecure.example.com")
	})

	// Hunter submits valid proof URL
	SubmitWork(cross(cur), id, "https://github.com/lexuantamle8-tech/indexer-proof")
	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "SUBMITTED"), "detail should show SUBMITTED")
	uassert.True(t, strings.Contains(detail, "indexer-proof"), "detail should include proof URL")

	// Non-sponsor cannot approve
	uassert.AbortsWithMessage(t, cur, "only sponsor can approve payout", func() {
		ApproveAndPay(cross(cur), id)
	})

	// Sponsor approves -> releases escrow & updates reputation
	ro := banker.NewReadonlyBanker()
	beforeBal := ro.GetCoin(hunter, "ugnot")

	testing.SetRealm(testing.NewUserRealm(sponsor))
	ApproveAndPay(cross(cur), id)

	afterBal := ro.GetCoin(hunter, "ugnot")
	uassert.Equal(t, beforeBal+1_000_000, afterBal, "hunter should receive exact escrowed ugnot")

	totalB, settled, paid := GetStats()
	uassert.Equal(t, 1, totalB)
	uassert.Equal(t, uint64(1), settled)
	uassert.Equal(t, int64(1_000_000), paid)

	finalBoard := Render("")
	uassert.True(t, strings.Contains(finalBoard, "Verified Hunter Reputation"), "board should show hunter reputation")
	uassert.True(t, strings.Contains(finalBoard, hunter.String()), "board should list paid hunter")
}

func TestRejectReopensAndCancelRefundsSponsor(cur realm, t *testing.T) {
	defer resetState()

	pkgAddr := chain.PackageAddress("gno.land/r/tavernescrow/v1")
	sponsor := testutils.TestAddress("sponsor2")
	hunter := testutils.TestAddress("hunter2")
	reward := chain.Coins{{Denom: "ugnot", Amount: 500_000}}

	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: 2_000_000}})
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(reward)

	id := CreateBounty(cross(cur), "Audit Realm", "Review escrow invariants.")
	testing.SetOriginSend(nil)

	// Hunter submits, sponsor rejects -> bounty returns to OPEN
	testing.SetRealm(testing.NewUserRealm(hunter))
	SubmitWork(cross(cur), id, "https://github.com/lexuantamle8-tech/draft-audit")

	testing.SetRealm(testing.NewUserRealm(sponsor))
	RejectSubmission(cross(cur), id)
	uassert.True(t, strings.Contains(Render("bounty/1"), "`OPEN`"), "rejected bounty should return to OPEN")

	// Sponsor cancels -> exact ugnot refunded
	ro := banker.NewReadonlyBanker()
	beforeBal := ro.GetCoin(sponsor, "ugnot")
	CancelBounty(cross(cur), id)
	afterBal := ro.GetCoin(sponsor, "ugnot")
	uassert.Equal(t, beforeBal+500_000, afterBal, "sponsor should receive exact refund")
	uassert.True(t, strings.Contains(Render("bounty/1"), "`CANCELLED`"), "cancelled bounty should show CANCELLED")
}

func TestCreateBountyGuards(cur realm, t *testing.T) {
	defer resetState()

	sponsor := testutils.TestAddress("sponsor3")
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(nil)

	uassert.AbortsWithMessage(t, cur, "title cannot be empty", func() {
		CreateBounty(cross(cur), "   ", "desc")
	})
	uassert.AbortsWithMessage(t, cur, "must attach positive ugnot reward to lock in escrow", func() {
		CreateBounty(cross(cur), "Zero Reward", "should fail")
	})
}
