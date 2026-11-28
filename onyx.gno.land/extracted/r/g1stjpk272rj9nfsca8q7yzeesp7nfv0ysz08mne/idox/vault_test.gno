package idox

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

func TestFullWorkflowAndGuardrails(cur realm, t *testing.T) {
	vaultAddr := cur.Address()
	admin := adminAddr
	sponsor := testutils.TestAddress("sponsor")
	contractor := testutils.TestAddress("contractor")
	aiAgent := testutils.TestAddress("ai_agent")

	// 1. Admin configures the AI Agent address and strict guardrails
	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetGuardrailPolicy(cross(cur), aiAgent, 50_000_000, 150_000_000, 10, true, false)

	// 2. Admin issues the "gc_license" badge (withholding "electrical_master" for testing)
	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	IssueBadge(cross(cur), contractor, "EdwinBuilds", "gc_license", "Licensed General Contractor")

	// 3. Sponsor creates a 2-milestone RWA rehab vault with 70 GNOT total escrow
	testing.IssueCoins(vaultAddr, chain.Coins{chain.NewCoin("ugnot", 70_000_000)})
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 70_000_000)})

	vaultID := CreateVault(
		cross(cur),
		"Alachua Rental Rehab & Bath Addition",
		contractor,
		[]string{"Tranche 1: Framing & Dry-In", "Tranche 2: Rough Electrical"},
		[]string{"gc_license", "electrical_master"},
		[]int64{30_000_000, 40_000_000},
	)
	testing.SetOriginSend(nil)

	// 4. Contractor submits proof-of-work for both milestones
	testing.SetOriginCaller(contractor)
	testing.SetRealm(testing.NewUserRealm(contractor))
	SubmitProof(cross(cur), vaultID, 0, "ipfs://QmFramingInspectionPassedHash123")

	testing.SetOriginCaller(contractor)
	testing.SetRealm(testing.NewUserRealm(contractor))
	SubmitProof(cross(cur), vaultID, 1, "ipfs://QmElectricalPanelPhotoHash456")

	// 5. AI Agent audits and approves Tranche 1 -> Should SUCCEED
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	AIAuditAndRelease(cross(cur), vaultID, 0, "Verified framing inspection hash & active gc_license")

	if got := GetVaultReleased(vaultID); got != 30_000_000 {
		t.Fatalf("expected 30_000_000 released, got %d", got)
	}

	// 6. Guardrail: AI attempts Tranche 2 immediately (violates CooldownBlocks)
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	if rec := revive(func() {
		AIAuditAndRelease(cross(cur), vaultID, 1, "Attempting early payout")
	}); rec == nil {
		t.Fatalf("expected guardrail panic on cooldown violation")
	}

	// 7. Advance chain height past cooldown, then test Missing Badge Guardrail
	testing.SkipHeights(15)
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	if rec := revive(func() {
		AIAuditAndRelease(cross(cur), vaultID, 1, "Attempting payout without electrical_master badge")
	}); rec == nil {
		t.Fatalf("expected guardrail panic on missing credential badge")
	}

	// 8. Verify Render() outputs clean Markdown
	rendered := Render("")
	if !strings.Contains(rendered, "Alachua Rental Rehab & Bath Addition") {
		t.Fatalf("expected project title in Render() output")
	}
	if !strings.Contains(rendered, "EdwinBuilds") {
		t.Fatalf("expected builder handle in Render() output")
	}
}

func TestGuardrailMaxSinglePayout(cur realm, t *testing.T) {
	vaultAddr := cur.Address()
	admin := adminAddr
	sponsor := testutils.TestAddress("cap_sponsor")
	contractor := testutils.TestAddress("cap_contractor")
	aiAgent := testutils.TestAddress("cap_agent")

	testing.SkipHeights(200_000)

	// Cap single payout at 25 GNOT while daily cap is 200 GNOT
	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetGuardrailPolicy(cross(cur), aiAgent, 25_000_000, 200_000_000, 5, true, false)

	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	IssueBadge(cross(cur), contractor, "CapBuilder", "gc_license", "Licensed General Contractor")

	testing.IssueCoins(vaultAddr, chain.Coins{chain.NewCoin("ugnot", 30_000_000)})
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 30_000_000)})

	vaultID := CreateVault(
		cross(cur),
		"Single Payout Cap Vault",
		contractor,
		[]string{"Oversized Tranche"},
		[]string{"gc_license"},
		[]int64{30_000_000},
	)
	testing.SetOriginSend(nil)

	testing.SetOriginCaller(contractor)
	testing.SetRealm(testing.NewUserRealm(contractor))
	SubmitProof(cross(cur), vaultID, 0, "ipfs://QmSingleCapProof1")

	// 30 GNOT > 25 GNOT MaxSinglePayout -> must panic
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	if rec := revive(func() {
		AIAuditAndRelease(cross(cur), vaultID, 0, "Exceeds single payout cap")
	}); rec == nil {
		t.Fatalf("expected guardrail panic on MaxSinglePayout violation")
	}
	if got := GetVaultReleased(vaultID); got != 0 {
		t.Fatalf("expected 0 released after cap rejection, got %d", got)
	}

	// Raise single cap to 35 GNOT -> exact same release must now succeed
	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetGuardrailPolicy(cross(cur), aiAgent, 35_000_000, 200_000_000, 5, true, false)

	testing.SkipHeights(10)
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	AIAuditAndRelease(cross(cur), vaultID, 0, "Approved after cap raised")

	if got := GetVaultReleased(vaultID); got != 30_000_000 {
		t.Fatalf("expected 30_000_000 released, got %d", got)
	}
}

func TestGuardrailDailySpendLimitAndRollingWindow(cur realm, t *testing.T) {
	vaultAddr := cur.Address()
	admin := adminAddr
	sponsor := testutils.TestAddress("daily_sponsor")
	contractor := testutils.TestAddress("daily_contractor")
	aiAgent := testutils.TestAddress("daily_agent")

	// Start in a fresh rolling 24h window
	testing.SkipHeights(400_000)

	// Single cap = 50 GNOT, rolling 24h daily cap = 60 GNOT, cooldown = 5 blocks
	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetGuardrailPolicy(cross(cur), aiAgent, 50_000_000, 60_000_000, 5, true, false)

	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	IssueBadge(cross(cur), contractor, "DailyBuilder", "gc_license", "Licensed General Contractor")

	testing.IssueCoins(vaultAddr, chain.Coins{chain.NewCoin("ugnot", 70_000_000)})
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 70_000_000)})

	vaultID := CreateVault(
		cross(cur),
		"Daily Spend Limit Vault",
		contractor,
		[]string{"Draw 1: Foundation", "Draw 2: Roof Dry-In"},
		[]string{"gc_license", "gc_license"},
		[]int64{40_000_000, 30_000_000},
	)
	testing.SetOriginSend(nil)

	testing.SetOriginCaller(contractor)
	testing.SetRealm(testing.NewUserRealm(contractor))
	SubmitProof(cross(cur), vaultID, 0, "ipfs://QmDailyProof0")

	testing.SetOriginCaller(contractor)
	testing.SetRealm(testing.NewUserRealm(contractor))
	SubmitProof(cross(cur), vaultID, 1, "ipfs://QmDailyProof1")

	// Draw 1 (40 GNOT <= 60 GNOT daily cap) -> succeeds
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	AIAuditAndRelease(cross(cur), vaultID, 0, "Within daily spend cap")

	if got := GetVaultReleased(vaultID); got != 40_000_000 {
		t.Fatalf("expected 40_000_000 released, got %d", got)
	}

	// Clear cooldown (10 > 5), stay inside 24h window: 40 + 30 = 70 > 60 -> must panic
	testing.SkipHeights(10)
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	if rec := revive(func() {
		AIAuditAndRelease(cross(cur), vaultID, 1, "Breaches rolling daily limit")
	}); rec == nil {
		t.Fatalf("expected guardrail panic on DailySpendLimit violation")
	}
	if got := GetVaultReleased(vaultID); got != 40_000_000 {
		t.Fatalf("expected released to remain 40_000_000, got %d", got)
	}

	// Advance past the 24h rolling window -> daily counter resets and Draw 2 succeeds
	testing.SkipHeights(200_000)
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	AIAuditAndRelease(cross(cur), vaultID, 1, "Approved in new 24h rolling window")

	if got := GetVaultReleased(vaultID); got != 70_000_000 {
		t.Fatalf("expected 70_000_000 total released after window rollover, got %d", got)
	}
}

func TestGuardrailEmergencyPauseKillSwitch(cur realm, t *testing.T) {
	vaultAddr := cur.Address()
	admin := adminAddr
	sponsor := testutils.TestAddress("pause_sponsor")
	contractor := testutils.TestAddress("pause_contractor")
	aiAgent := testutils.TestAddress("pause_agent")

	testing.SkipHeights(800_000)

	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetGuardrailPolicy(cross(cur), aiAgent, 50_000_000, 150_000_000, 5, true, false)

	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	IssueBadge(cross(cur), contractor, "PauseBuilder", "gc_license", "Licensed General Contractor")

	testing.IssueCoins(vaultAddr, chain.Coins{chain.NewCoin("ugnot", 20_000_000)})
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 20_000_000)})

	vaultID := CreateVault(
		cross(cur),
		"Emergency Pause Test Vault",
		contractor,
		[]string{"Tranche 1: Site Prep"},
		[]string{"gc_license"},
		[]int64{20_000_000},
	)
	testing.SetOriginSend(nil)

	testing.SetOriginCaller(contractor)
	testing.SetRealm(testing.NewUserRealm(contractor))
	SubmitProof(cross(cur), vaultID, 0, "ipfs://QmPauseProof0")

	// Engage emergency kill-switch (paused = true)
	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetGuardrailPolicy(cross(cur), aiAgent, 50_000_000, 150_000_000, 5, true, true)

	testing.SkipHeights(10)
	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	if rec := revive(func() {
		AIAuditAndRelease(cross(cur), vaultID, 0, "Attempt payout while paused")
	}); rec == nil {
		t.Fatalf("expected guardrail panic while circuit breaker is paused")
	}
	if got := GetVaultReleased(vaultID); got != 0 {
		t.Fatalf("expected 0 released while paused, got %d", got)
	}

	// Disengage kill-switch (paused = false) -> payout succeeds
	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetGuardrailPolicy(cross(cur), aiAgent, 50_000_000, 150_000_000, 5, true, false)

	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	AIAuditAndRelease(cross(cur), vaultID, 0, "Approved after resume")

	if got := GetVaultReleased(vaultID); got != 20_000_000 {
		t.Fatalf("expected 20_000_000 released after unpause, got %d", got)
	}
}

func TestGuardrailUnauthorizedCallers(cur realm, t *testing.T) {
	vaultAddr := cur.Address()
	admin := adminAddr
	sponsor := testutils.TestAddress("auth_sponsor")
	contractor := testutils.TestAddress("auth_contractor")
	aiAgent := testutils.TestAddress("auth_agent")
	attacker := testutils.TestAddress("auth_attacker")

	testing.SkipHeights(1_000_000)

	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetGuardrailPolicy(cross(cur), aiAgent, 50_000_000, 150_000_000, 5, true, false)

	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	IssueBadge(cross(cur), contractor, "AuthBuilder", "gc_license", "Licensed General Contractor")

	testing.IssueCoins(vaultAddr, chain.Coins{chain.NewCoin("ugnot", 15_000_000)})
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 15_000_000)})

	vaultID := CreateVault(
		cross(cur),
		"Authorization Test Vault",
		contractor,
		[]string{"Tranche 1: Trim"},
		[]string{"gc_license"},
		[]int64{15_000_000},
	)
	testing.SetOriginSend(nil)

	// 1. Non-admin (attacker & AI agent) cannot modify guardrail policy
	testing.SetOriginCaller(attacker)
	testing.SetRealm(testing.NewUserRealm(attacker))
	if rec := revive(func() {
		SetGuardrailPolicy(cross(cur), attacker, 999_000_000, 999_000_000, 0, false, false)
	}); rec == nil {
		t.Fatalf("expected panic: attacker called SetGuardrailPolicy")
	}

	testing.SetOriginCaller(aiAgent)
	testing.SetRealm(testing.NewUserRealm(aiAgent))
	if rec := revive(func() {
		SetGuardrailPolicy(cross(cur), aiAgent, 999_000_000, 999_000_000, 0, false, false)
	}); rec == nil {
		t.Fatalf("expected panic: AI agent attempted to self-raise guardrails")
	}

	// 2. Non-admin cannot issue badges
	testing.SetOriginCaller(attacker)
	testing.SetRealm(testing.NewUserRealm(attacker))
	if rec := revive(func() {
		IssueBadge(cross(cur), attacker, "FakeGC", "gc_license", "Forged License")
	}); rec == nil {
		t.Fatalf("expected panic: attacker called IssueBadge")
	}

	// 3. Non-contractor (attacker & sponsor) cannot submit milestone proofs
	testing.SetOriginCaller(attacker)
	testing.SetRealm(testing.NewUserRealm(attacker))
	if rec := revive(func() {
		SubmitProof(cross(cur), vaultID, 0, "ipfs://QmSpoofedProof")
	}); rec == nil {
		t.Fatalf("expected panic: attacker called SubmitProof")
	}

	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	if rec := revive(func() {
		SubmitProof(cross(cur), vaultID, 0, "ipfs://QmSponsorProof")
	}); rec == nil {
		t.Fatalf("expected panic: sponsor called SubmitProof")
	}

	// Legitimate contractor submits proof so payout checks test caller auth only
	testing.SetOriginCaller(contractor)
	testing.SetRealm(testing.NewUserRealm(contractor))
	SubmitProof(cross(cur), vaultID, 0, "ipfs://QmValidContractorProof")

	// 4. Unauthorized callers (attacker, contractor, and admin when admin != aiAgent) cannot release payouts
	testing.SetOriginCaller(attacker)
	testing.SetRealm(testing.NewUserRealm(attacker))
	if rec := revive(func() {
		AIAuditAndRelease(cross(cur), vaultID, 0, "Attacker drain attempt")
	}); rec == nil {
		t.Fatalf("expected panic: attacker called AIAuditAndRelease")
	}

	testing.SetOriginCaller(contractor)
	testing.SetRealm(testing.NewUserRealm(contractor))
	if rec := revive(func() {
		AIAuditAndRelease(cross(cur), vaultID, 0, "Contractor self-approval attempt")
	}); rec == nil {
		t.Fatalf("expected panic: contractor called AIAuditAndRelease")
	}

	testing.SetOriginCaller(admin)
	testing.SetRealm(testing.NewUserRealm(admin))
	if rec := revive(func() {
		AIAuditAndRelease(cross(cur), vaultID, 0, "Admin bypass attempt")
	}); rec == nil {
		t.Fatalf("expected panic: admin bypassed AI agent role on AIAuditAndRelease")
	}

	if got := GetVaultReleased(vaultID); got != 0 {
		t.Fatalf("expected 0 released after all unauthorized attempts, got %d", got)
	}
}
