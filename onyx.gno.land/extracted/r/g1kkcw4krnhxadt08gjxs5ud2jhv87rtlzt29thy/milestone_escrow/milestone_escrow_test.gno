package milestone_escrow

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
)

var (
	clientAddr     = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	contractorAddr = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	arbiterAddr    = address("g1w3jhxap3ta047h6lta047h6lta047h6l4mfnm7")
	strangerAddr   = address("g15vj5q08amlvyd0nx6zjgcvwq2d0gt9fcchrvum")
)

func resetState() {
	nextContractID = 1
	contracts = nil
	contractsByID = make(map[uint64]*EscrowContract)
	totalDeposited = 0
	totalReleased = 0
	totalRefunded = 0
	totalDisputesCount = 0
}

func fundAndCallCreate(
	cur realm,
	title string,
	contractor string,
	arbiter string,
	titles string,
	amounts string,
	sendUgnot int64,
) uint64 {
	pkgAddr := cur.Address()
	coins := chain.NewCoins(chain.NewCoin(DenomUgnot, sendUgnot))
	testing.IssueCoins(clientAddr, coins)
	testing.SetOriginCaller(clientAddr)
	testing.SetOriginSend(coins)
	testing.SetRealm(testing.NewUserRealm(clientAddr))
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(clientAddr, pkgAddr, coins)
	return CreateContract(cross(cur), title, contractor, arbiter, titles, amounts)
}

func assertPanics(t *testing.T, label string, fn func()) {
	t.Helper()
	if r := revive(fn); r == nil {
		t.Fatalf("expected panic for case %q, but succeeded", label)
	}
}

func TestHappyPathMultiMilestoneEscrow(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()
	beforeContractor := ro.GetCoin(contractorAddr, DenomUgnot)

	id := fundAndCallCreate(
		cur,
		"Smart Contract Audit",
		contractorAddr.String(),
		arbiterAddr.String(),
		"Spec Review,Final Report",
		"400000,600000",
		1000000,
	)
	if id != 1 {
		t.Fatalf("expected contract ID 1, got %d", id)
	}
	if LockedBalanceUgnot() != 1000000 {
		t.Fatalf("expected locked 1000000, got %d", LockedBalanceUgnot())
	}

	// Contractor submits milestone 0
	testing.SetOriginCaller(contractorAddr)
	testing.SetRealm(testing.NewUserRealm(contractorAddr))
	SubmitMilestone(cross(cur), id, 0, "https://github.com/devbox-zero-ops/audit/commit/111")

	// Client approves milestone 0 -> 400000 ugnot paid
	testing.SetOriginCaller(clientAddr)
	testing.SetRealm(testing.NewUserRealm(clientAddr))
	ApproveMilestone(cross(cur), id, 0)

	if ro.GetCoin(contractorAddr, DenomUgnot)-beforeContractor != 400000 {
		t.Fatalf("expected contractor +400000 after m0")
	}
	if contractsByID[id].Status != ContractActive {
		t.Fatalf("contract should still be ACTIVE after m0")
	}

	// Approve milestone 1 -> remaining 600000 ugnot paid & contract completed
	ApproveMilestone(cross(cur), id, 1)
	if ro.GetCoin(contractorAddr, DenomUgnot)-beforeContractor != 1000000 {
		t.Fatalf("expected contractor +1000000 after m1")
	}
	if contractsByID[id].Status != ContractCompleted {
		t.Fatalf("expected COMPLETED status, got %s", contractsByID[id].Status)
	}
	if LockedBalanceUgnot() != 0 {
		t.Fatalf("expected locked 0, got %d", LockedBalanceUgnot())
	}
}

func TestDisputeAndArbiterBasisPointSplit(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()
	beforeContractor := ro.GetCoin(contractorAddr, DenomUgnot)
	beforeClient := ro.GetCoin(clientAddr, DenomUgnot)

	id := fundAndCallCreate(
		cur,
		"Indexer Build",
		contractorAddr.String(),
		arbiterAddr.String(),
		"Core Sync",
		"1000000",
		1000000,
	)

	// Contractor submits and client opens dispute
	testing.SetOriginCaller(contractorAddr)
	testing.SetRealm(testing.NewUserRealm(contractorAddr))
	SubmitMilestone(cross(cur), id, 0, "https://github.com/devbox-zero-ops/indexer/pull/7")

	testing.SetOriginCaller(clientAddr)
	testing.SetRealm(testing.NewUserRealm(clientAddr))
	OpenDispute(cross(cur), id, 0, "Pagination edge case incomplete")

	// Stranger cannot resolve dispute
	testing.SetOriginCaller(strangerAddr)
	testing.SetRealm(testing.NewUserRealm(strangerAddr))
	assertPanics(t, "stranger resolve", func() {
		ResolveDispute(cross(cur), id, 0, 5000)
	})

	// Arbiter splits 65% contractor / 35% client
	testing.SetOriginCaller(arbiterAddr)
	testing.SetRealm(testing.NewUserRealm(arbiterAddr))
	ResolveDispute(cross(cur), id, 0, 6500)

	if ro.GetCoin(contractorAddr, DenomUgnot)-beforeContractor != 650000 {
		t.Fatalf("expected contractor +650000")
	}
	if ro.GetCoin(clientAddr, DenomUgnot)-beforeClient != 350000 {
		t.Fatalf("expected client refund +350000")
	}
	if contractsByID[id].Status != ContractCompleted {
		t.Fatalf("expected contract COMPLETED after dispute resolution")
	}
	if LockedBalanceUgnot() != 0 {
		t.Fatalf("expected 0 locked after split resolution")
	}
}

func TestCancelUnstartedMilestonesAndGuards(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()
	beforeClient := ro.GetCoin(clientAddr, DenomUgnot)

	id := fundAndCallCreate(
		cur,
		"Frontend Redesign",
		contractorAddr.String(),
		"",
		"Wireframes,Production UI",
		"300000,700000",
		1000000,
	)

	// Approve first milestone, leave second PENDING
	testing.SetOriginCaller(clientAddr)
	testing.SetRealm(testing.NewUserRealm(clientAddr))
	ApproveMilestone(cross(cur), id, 0)

	// Cancel remaining unstarted milestone -> 700000 refunded to client
	CancelUnstarted(cross(cur), id)
	if ro.GetCoin(clientAddr, DenomUgnot)-beforeClient != 700000 {
		t.Fatalf("expected 700000 refund to client")
	}
	if contractsByID[id].Status != ContractCancelled {
		t.Fatalf("expected CANCELLED status")
	}
	if LockedBalanceUgnot() != 0 {
		t.Fatalf("expected 0 locked after cancellation")
	}
}

func TestDepositMismatchAndRoleGuards(cur realm, t *testing.T) {
	resetState()

	// Exact deposit mismatch panics
	assertPanics(t, "wrong deposit", func() {
		fundAndCallCreate(
			cur,
			"Bad Deposit",
			contractorAddr.String(),
			"",
			"Task A",
			"500000",
			499999,
		)
	})

	id := fundAndCallCreate(
		cur,
		"Guarded Contract",
		contractorAddr.String(),
		arbiterAddr.String(),
		"Deliverable",
		"500000",
		500000,
	)

	// Client cannot submit milestone
	testing.SetOriginCaller(clientAddr)
	testing.SetRealm(testing.NewUserRealm(clientAddr))
	assertPanics(t, "client submit", func() {
		SubmitMilestone(cross(cur), id, 0, "https://example.com/fake")
	})

	// Contractor cannot approve milestone
	testing.SetOriginCaller(contractorAddr)
	testing.SetRealm(testing.NewUserRealm(contractorAddr))
	assertPanics(t, "contractor approve", func() {
		ApproveMilestone(cross(cur), id, 0)
	})

	// Once submitted, client cannot unilaterally cancel
	SubmitMilestone(cross(cur), id, 0, "https://example.com/real")
	testing.SetOriginCaller(clientAddr)
	testing.SetRealm(testing.NewUserRealm(clientAddr))
	assertPanics(t, "cancel submitted", func() {
		CancelUnstarted(cross(cur), id)
	})
}

func TestRenderRoutesAndConservationInvariant(cur realm, t *testing.T) {
	resetState()
	id := fundAndCallCreate(
		cur,
		"SDK Docs",
		contractorAddr.String(),
		arbiterAddr.String(),
		"Draft,Final",
		"250000,750000",
		1000000,
	)

	home := Render("")
	if !strings.Contains(home, "MilestoneEscrow") || !strings.Contains(home, "SDK Docs") {
		t.Fatalf("home render missing expected content")
	}

	detail := Render("contract/1")
	if !strings.Contains(detail, "Contract #1") || !strings.Contains(detail, "Draft") {
		t.Fatalf("contract detail render missing expected content")
	}

	stats := Render("stats")
	if !strings.Contains(stats, "**PASS**") {
		t.Fatalf("stats render missing conservation PASS")
	}

	guide := Render("guide")
	if !strings.Contains(guide, "CreateContract") || !strings.Contains(guide, "onyx-1") {
		t.Fatalf("guide render missing CLI examples")
	}

	notFound := Render("unknown")
	if !strings.Contains(notFound, "404") {
		t.Fatalf("unknown route should return 404")
	}
	_ = id
}
