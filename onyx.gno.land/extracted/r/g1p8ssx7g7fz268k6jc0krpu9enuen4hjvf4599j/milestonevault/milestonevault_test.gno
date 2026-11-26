package milestonevault

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
)

const (
	addrSponsor  = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	addrBuilder  = address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	addrArbiter1 = address("g1w4ek2u33ta047h6lta047h6lta047h6ldvdwpn")
	addrArbiter2 = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	addrArbiter3 = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	addrStranger = address("g1vh7krmhyjva5x2j5l9s2k8q7x2k9m4n5p6q7r8")
)

func resetState() {
	vaults = nil
	builderOrder = nil
	builderStatsByAddr = make(map[address]*BuilderStats)
	totalDepositedUgnot = 0
	totalReleasedUgnot = 0
	totalRefundedUgnot = 0
}

func fundAndCreateVault(
	cur realm,
	sponsor address,
	title string,
	desc string,
	mTitles string,
	mAmounts string,
	arbiters string,
	timeout string,
	deposit int64,
) int {
	realmAddr := chain.PackageAddress("gno.land/r/g1p8ssx7g7fz268k6jc0krpu9enuen4hjvf4599j/milestonevault")
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin(DenomUGNOT, deposit)))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(DenomUGNOT, deposit)))
	testing.SetRealm(testing.NewUserRealm(sponsor))
	return CreateVault(cross(cur), title, desc, mTitles, mAmounts, arbiters, timeout)
}

func TestSubRealmEscrowIsolationAndHappyPath(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()
	arbiters := string(addrArbiter1) + "," + string(addrArbiter2) + "," + string(addrArbiter3)

	// 1. Create Vault #1 (3,000,000 ugnot across 2 milestones) and Vault #2 (2,000,000 ugnot).
	v1ID := fundAndCreateVault(
		cur, addrSponsor,
		"Onyx Sub-Realm Indexer",
		"Stream isolated escrow events from Onyx testnet",
		"Spec & Schema|Indexer Implementation",
		"1000000,2000000",
		arbiters, "50", 3000000,
	)
	v2ID := fundAndCreateVault(
		cur, addrSponsor,
		"Smart Contract Audit",
		"Formal review of Gno realm invariants",
		"Audit Report",
		"2000000",
		arbiters, "100", 2000000,
	)

	if v1ID != 1 || v2ID != 2 {
		t.Fatalf("expected vault IDs 1 and 2, got %d and %d", v1ID, v2ID)
	}

	escrow1 := GetVaultEscrowAddress(1)
	escrow2 := GetVaultEscrowAddress(2)
	if escrow1 == escrow2 {
		t.Fatalf("sub-realm escrow addresses must be distinct: %s", escrow1)
	}
	if got := ro.GetCoin(escrow1, DenomUGNOT); got != 3000000 {
		t.Fatalf("expected vault #1 sub-balance 3000000, got %d", got)
	}
	if got := ro.GetCoin(escrow2, DenomUGNOT); got != 2000000 {
		t.Fatalf("expected vault #2 sub-balance 2000000, got %d", got)
	}

	// 2. Builder applies and Sponsor assigns Builder to Vault #1.
	testing.SetRealm(testing.NewUserRealm(addrBuilder))
	ApplyForVault(cross(cur), "1", "Ready to deliver with full gno test coverage")

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	AssignBuilder(cross(cur), "1", string(addrBuilder))

	// 3. Builder submits M1 and Sponsor approves -> atomic payout from escrow1 ONLY.
	beforeBuilder := ro.GetCoin(addrBuilder, DenomUGNOT)
	testing.SetRealm(testing.NewUserRealm(addrBuilder))
	SubmitMilestone(cross(cur), "1", "1", "https://github.com/milestonevault/spec/commit/abc123")

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	ApproveMilestone(cross(cur), "1", "1")

	if got := ro.GetCoin(addrBuilder, DenomUGNOT) - beforeBuilder; got != 1000000 {
		t.Fatalf("expected builder payout 1000000 ugnot, got %d", got)
	}
	if got := ro.GetCoin(escrow1, DenomUGNOT); got != 2000000 {
		t.Fatalf("expected escrow1 remaining 2000000, got %d", got)
	}
	// Vault #2's isolated sub-account must remain 100% untouched.
	if got := ro.GetCoin(escrow2, DenomUGNOT); got != 2000000 {
		t.Fatalf("vault #2 isolated balance unexpectedly changed: %d", got)
	}

	// 4. Builder submits M2 and Sponsor approves -> Vault #1 transitions to COMPLETED.
	testing.SetRealm(testing.NewUserRealm(addrBuilder))
	SubmitMilestone(cross(cur), "1", "2", "https://github.com/milestonevault/indexer/commit/def456")

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	ApproveMilestone(cross(cur), "1", "2")

	v1 := mustGetVault(1)
	if v1.Status != VaultStatusCompleted {
		t.Fatalf("expected Vault #1 COMPLETED, got %s", v1.Status)
	}
	if got := ro.GetCoin(escrow1, DenomUGNOT); got != 0 {
		t.Fatalf("expected escrow1 drained to 0, got %d", got)
	}
	st := builderStatsByAddr[addrBuilder]
	if st == nil || st.MilestonesCompleted != 2 || st.VaultsCompleted != 1 || st.TotalEarnedUgnot != 3000000 {
		t.Fatalf("unexpected builder stats: %+v", st)
	}
}

func TestDeadmanTimeoutRelease(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()
	id := fundAndCreateVault(
		cur, addrSponsor,
		"CLI Tooling",
		"Automated deployment CLI",
		"CLI Release",
		"1500000",
		string(addrArbiter1), "25", 1500000,
	)
	_ = id

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	AssignBuilder(cross(cur), "1", string(addrBuilder))

	testing.SetRealm(testing.NewUserRealm(addrBuilder))
	SubmitMilestone(cross(cur), "1", "1", "https://github.com/milestonevault/cli/releases/v1")

	// Before timeout, ClaimTimeoutRelease must abort.
	if r := revive(func() { ClaimTimeoutRelease(cross(cur), "1", "1") }); r == nil {
		t.Fatalf("expected ClaimTimeoutRelease to abort before timeout")
	}

	// Advance chain height past timeoutBlocks (25) and claim permissionlessly.
	beforeBuilder := ro.GetCoin(addrBuilder, DenomUGNOT)
	testing.SkipHeights(30)
	testing.SetRealm(testing.NewUserRealm(addrBuilder))
	ClaimTimeoutRelease(cross(cur), "1", "1")

	if got := ro.GetCoin(addrBuilder, DenomUGNOT) - beforeBuilder; got != 1500000 {
		t.Fatalf("expected timeout payout 1500000, got %d", got)
	}
	if mustGetVault(1).Status != VaultStatusCompleted {
		t.Fatalf("expected COMPLETED after timeout claim")
	}
}

func TestDisputeQuorumReleaseAndDeadlockSplit(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()
	arbiters := string(addrArbiter1) + "," + string(addrArbiter2) + "," + string(addrArbiter3)

	fundAndCreateVault(
		cur, addrSponsor,
		"Disputed Protocol Build",
		"Two-milestone build testing both majority release and deadlock split",
		"M1 Core|M2 Frontend",
		"1000000,1000001",
		arbiters, "100", 2000001,
	)

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	AssignBuilder(cross(cur), "1", string(addrBuilder))

	// Milestone 1: Sponsor disputes -> 2 of 3 arbiters vote RELEASE -> builder paid.
	testing.SetRealm(testing.NewUserRealm(addrBuilder))
	SubmitMilestone(cross(cur), "1", "1", "https://github.com/org/repo/pull/1")

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	OpenDispute(cross(cur), "1", "1", "Missing benchmark section")

	beforeBuilder := ro.GetCoin(addrBuilder, DenomUGNOT)
	testing.SetRealm(testing.NewUserRealm(addrArbiter1))
	VoteDispute(cross(cur), "1", "RELEASE")
	if mustGetVault(1).Status != VaultStatusDisputed {
		t.Fatalf("should still be DISPUTED after 1 of 3 votes")
	}

	testing.SetRealm(testing.NewUserRealm(addrArbiter2))
	VoteDispute(cross(cur), "1", "RELEASE")
	if mustGetVault(1).Status != VaultStatusActive {
		t.Fatalf("expected vault back to ACTIVE after M1 dispute resolved")
	}
	if got := ro.GetCoin(addrBuilder, DenomUGNOT) - beforeBuilder; got != 1000000 {
		t.Fatalf("expected 1000000 released to builder, got %d", got)
	}

	// Milestone 2 (odd 1000001 ugnot): 3-way deadlock (1 RELEASE, 1 REFUND, 1 SPLIT) -> deterministic SPLIT!
	testing.SetRealm(testing.NewUserRealm(addrBuilder))
	SubmitMilestone(cross(cur), "1", "2", "https://github.com/org/repo/pull/2")

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	OpenDispute(cross(cur), "1", "2", "Partial UI completion")

	bBefore := ro.GetCoin(addrBuilder, DenomUGNOT)
	sBefore := ro.GetCoin(addrSponsor, DenomUGNOT)

	testing.SetRealm(testing.NewUserRealm(addrArbiter1))
	VoteDispute(cross(cur), "1", "RELEASE")
	testing.SetRealm(testing.NewUserRealm(addrArbiter2))
	VoteDispute(cross(cur), "1", "REFUND")
	testing.SetRealm(testing.NewUserRealm(addrArbiter3))
	VoteDispute(cross(cur), "1", "SPLIT")

	bDelta := ro.GetCoin(addrBuilder, DenomUGNOT) - bBefore
	sDelta := ro.GetCoin(addrSponsor, DenomUGNOT) - sBefore
	if bDelta != 500001 || sDelta != 500000 {
		t.Fatalf("expected 500001/500000 conserved split, got %d/%d", bDelta, sDelta)
	}
	if mustGetVault(1).Status != VaultStatusCompleted {
		t.Fatalf("expected COMPLETED after M2 split settlement")
	}
	if got := ro.GetCoin(GetVaultEscrowAddress(1), DenomUGNOT); got != 0 {
		t.Fatalf("expected zero dust left in sub-realm escrow, got %d", got)
	}
}

func TestCancelOpenVaultRefundsSponsor(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()
	fundAndCreateVault(
		cur, addrSponsor,
		"Cancelled Scope",
		"Test full refund from isolated sub-realm",
		"Single Deliverable",
		"900000",
		string(addrArbiter1), "50", 900000,
	)

	sBefore := ro.GetCoin(addrSponsor, DenomUGNOT)
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	CancelVault(cross(cur), "1")

	if got := ro.GetCoin(addrSponsor, DenomUGNOT) - sBefore; got != 900000 {
		t.Fatalf("expected full 900000 refund, got %d", got)
	}
	if mustGetVault(1).Status != VaultStatusCancelled {
		t.Fatalf("expected CANCELLED status")
	}
	if got := ro.GetCoin(GetVaultEscrowAddress(1), DenomUGNOT); got != 0 {
		t.Fatalf("expected sub-realm balance 0 after cancel, got %d", got)
	}
}

func TestRenderMarkdownAndJSONEndpoints(cur realm, t *testing.T) {
	resetState()
	fundAndCreateVault(
		cur, addrSponsor,
		"Render Audit Vault",
		"Verify gnoweb Markdown and ABCI JSON routes",
		"Phase 1|Phase 2",
		"400000,600000",
		string(addrArbiter1), "40", 1000000,
	)

	home := Render("")
	if !strings.Contains(home, "MilestoneVault") || !strings.Contains(home, "Render Audit Vault") {
		t.Fatalf("unexpected home render: %s", home)
	}

	detail := Render("vault/1")
	if !strings.Contains(detail, "VERIFIED (1:1 backed)") || !strings.Contains(detail, "Phase 1") {
		t.Fatalf("unexpected vault detail render: %s", detail)
	}

	statsJSON := Render("api/stats")
	if !strings.Contains(statsJSON, `"vaultCount":1`) || !strings.Contains(statsJSON, `"totalLockedUgnot":1000000`) {
		t.Fatalf("unexpected stats JSON: %s", statsJSON)
	}

	vaultsJSON := Render("api/vaults")
	if !strings.Contains(vaultsJSON, `"title":"Render Audit Vault"`) || !strings.Contains(vaultsJSON, `"liveSubBalanceUgnot":1000000`) {
		t.Fatalf("unexpected vaults JSON: %s", vaultsJSON)
	}
}

func assertPanics(t *testing.T, label string, fn func()) {
	t.Helper()
	if r := revive(fn); r == nil {
		t.Fatalf("expected abort for %s", label)
	}
}

func TestAuthorizationGuards(cur realm, t *testing.T) {
	resetState()
	fundAndCreateVault(
		cur, addrSponsor,
		"Security Guard Vault",
		"Verify strict caller authentication across all state transitions",
		"Deliverable",
		"500000",
		string(addrArbiter1), "20", 500000,
	)

	// Stranger cannot assign builder or cancel vault.
	testing.SetRealm(testing.NewUserRealm(addrStranger))
	assertPanics(t, "stranger AssignBuilder", func() { AssignBuilder(cross(cur), "1", string(addrBuilder)) })
	assertPanics(t, "stranger CancelVault", func() { CancelVault(cross(cur), "1") })

	// Sponsor assigns builder.
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	AssignBuilder(cross(cur), "1", string(addrBuilder))

	// Stranger cannot submit milestone.
	testing.SetRealm(testing.NewUserRealm(addrStranger))
	assertPanics(t, "stranger SubmitMilestone", func() { SubmitMilestone(cross(cur), "1", "1", "https://fake") })

	// Builder submits milestone.
	testing.SetRealm(testing.NewUserRealm(addrBuilder))
	SubmitMilestone(cross(cur), "1", "1", "https://github.com/milestonevault/pr/9")

	// Builder cannot self-approve milestone.
	assertPanics(t, "builder self-ApproveMilestone", func() { ApproveMilestone(cross(cur), "1", "1") })

	// Sponsor opens dispute; stranger cannot vote.
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	OpenDispute(cross(cur), "1", "1", "Check tests")

	testing.SetRealm(testing.NewUserRealm(addrStranger))
	assertPanics(t, "stranger VoteDispute", func() { VoteDispute(cross(cur), "1", "RELEASE") })
}
