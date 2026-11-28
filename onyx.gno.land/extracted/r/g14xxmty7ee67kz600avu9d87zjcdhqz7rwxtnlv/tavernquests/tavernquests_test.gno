package tavernquests

import (
	"chain"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/ufmt/v0"
)

const pkgPath = "gno.land/r/g14xxmty7ee67kz600avu9d87zjcdhqz7rwxtnlv/tavernquests"

func TestCreate_Submit_Approve(cur realm, t *testing.T) {
	defer resetTestState()

	// Setup
	pkgAddr := chain.PackageAddress(pkgPath)
	creator := testutils.TestAddress("creator1")
	worker := testutils.TestAddress("worker1")
	reward := chain.Coins{{Denom: "ugnot", Amount: 1000000}}
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100000000}})

	// Create a bounty with a 7-day deadline
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(reward)
	id := CreateBounty(cross(cur), "Fix the tavern sign", "Repaint the wooden sign by the door", 7)
	uassert.Equal(t, 1, id)
	uassert.Equal(t, 1, BountyCount())

	expected := ufmt.Sprintf(`- status: open
- creator: %s
- title: Fix the tavern sign
- description: Repaint the wooden sign by the door
- reward: 1000000ugnot
- worker: none
- proof: 
- deadline: 2009-02-20T23:31:30Z
- remaining: 168h0m0s`, creator)
	uassert.Equal(t, expected, GetBounty(id))
	uassert.Equal(t, expected, Render("1"))

	// Worker submits proof
	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitProof(cross(cur), id, "https://example.com/proof")

	expected = ufmt.Sprintf(`- status: submitted
- creator: %s
- title: Fix the tavern sign
- description: Repaint the wooden sign by the door
- reward: 1000000ugnot
- worker: %s
- proof: https://example.com/proof
- deadline: 2009-02-20T23:31:30Z
- remaining: 168h0m0s`, creator, worker)
	uassert.Equal(t, expected, GetBounty(id))

	// A second submission must fail
	uassert.AbortsWithMessage(t, cur, "proof already submitted", func() {
		SubmitProof(cross(cur), id, "https://example.com/other-proof")
	})

	// Creator approves -> escrow released to the worker
	testing.SetRealm(testing.NewUserRealm(creator))
	Approve(cross(cur), id)

	expected = ufmt.Sprintf(`- status: approved
- creator: %s
- title: Fix the tavern sign
- description: Repaint the wooden sign by the door
- reward: 1000000ugnot
- worker: %s
- proof: https://example.com/proof
- deadline: 2009-02-20T23:31:30Z
- remaining: 168h0m0s`, creator, worker)
	uassert.Equal(t, expected, GetBounty(id))

	// After approval neither refund nor approve may run again
	uassert.AbortsWithMessage(t, cur, "bounty already approved", func() {
		Refund(cross(cur), id)
	})
	uassert.AbortsWithMessage(t, cur, "bounty already approved", func() {
		Approve(cross(cur), id)
	})
}

func TestRefund_BeforeSubmit(cur realm, t *testing.T) {
	defer resetTestState()

	pkgAddr := chain.PackageAddress(pkgPath)
	creator := testutils.TestAddress("creator2")
	reward := chain.Coins{{Denom: "ugnot", Amount: 500000}}
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100000000}})

	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(reward)
	id := CreateBounty(cross(cur), "Wash the mugs", "Wash all tavern mugs", 3)
	uassert.Equal(t, 1, id)

	// Creator cancels before any submission -> full refund
	Refund(cross(cur), id)
	uassert.Equal(t, "refunded", mustGet(id).Status())

	// After refund nothing else may happen
	uassert.AbortsWithMessage(t, cur, "bounty already refunded", func() {
		Approve(cross(cur), id)
	})
	worker := testutils.TestAddress("worker2")
	testing.SetRealm(testing.NewUserRealm(worker))
	uassert.AbortsWithMessage(t, cur, "bounty already refunded", func() {
		SubmitProof(cross(cur), id, "https://example.com/proof")
	})
}

func TestSubmitProof_ByCreator_Aborts(cur realm, t *testing.T) {
	defer resetTestState()

	pkgAddr := chain.PackageAddress(pkgPath)
	creator := testutils.TestAddress("creator3")
	reward := chain.Coins{{Denom: "ugnot", Amount: 100000}}
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100000000}})

	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(reward)
	id := CreateBounty(cross(cur), "Sweep the floor", "Sweep the tavern floor", 7)

	uassert.AbortsWithMessage(t, cur, "creator cannot work on own bounty", func() {
		SubmitProof(cross(cur), id, "https://example.com/proof")
	})
}

func TestApprove_ByNonCreator_Aborts(cur realm, t *testing.T) {
	defer resetTestState()

	pkgAddr := chain.PackageAddress(pkgPath)
	creator := testutils.TestAddress("creator4")
	worker := testutils.TestAddress("worker4")
	reward := chain.Coins{{Denom: "ugnot", Amount: 100000}}
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100000000}})

	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(reward)
	id := CreateBounty(cross(cur), "Tune the lute", "Tune the bard's lute", 7)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitProof(cross(cur), id, "https://example.com/proof")

	// The worker cannot approve their own work
	uassert.AbortsWithMessage(t, cur, "only the bounty creator can approve", func() {
		Approve(cross(cur), id)
	})
	// ... and cannot approve without a submission either (covered above:
	// approve before submit aborts with "no proof submitted yet")
}

func TestApprove_WithoutSubmission_Aborts(cur realm, t *testing.T) {
	defer resetTestState()

	pkgAddr := chain.PackageAddress(pkgPath)
	creator := testutils.TestAddress("creator5")
	reward := chain.Coins{{Denom: "ugnot", Amount: 100000}}
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100000000}})

	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(reward)
	id := CreateBounty(cross(cur), "Polish the bar", "Polish the oak bar", 7)

	uassert.AbortsWithMessage(t, cur, "no proof submitted yet", func() {
		Approve(cross(cur), id)
	})
}

func TestRefund_SubmittedBeforeDeadline_Aborts(cur realm, t *testing.T) {
	defer resetTestState()

	pkgAddr := chain.PackageAddress(pkgPath)
	creator := testutils.TestAddress("creator6")
	worker := testutils.TestAddress("worker6")
	reward := chain.Coins{{Denom: "ugnot", Amount: 100000}}
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100000000}})

	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(reward)
	id := CreateBounty(cross(cur), "Brew a stout", "Brew one keg of stout", 7)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitProof(cross(cur), id, "https://example.com/proof")

	// Submitted but not yet expired: creator must approve, not refund
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "cannot refund submitted bounty before deadline", func() {
		Refund(cross(cur), id)
	})
}

func TestCreate_WithoutSend_Aborts(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator7")
	testing.SetRealm(testing.NewUserRealm(creator))
	// No SetOriginSend: no escrow attached
	uassert.AbortsWithMessage(t, cur, "at least one coin needs to be sent", func() {
		CreateBounty(cross(cur), "Empty bounty", "No reward attached", 7)
	})
}

func TestGetBounty_Unknown(cur realm, t *testing.T) {
	defer resetTestState()

	uassert.Equal(t, "404", GetBounty(99))
	uassert.Equal(t, "404", Render("99"))
	uassert.Equal(t, "", Render(""))
	uassert.Equal(t, 0, BountyCount())
}

func resetTestState() {
	bounties = avl.Tree{}
	counter = 0
}
