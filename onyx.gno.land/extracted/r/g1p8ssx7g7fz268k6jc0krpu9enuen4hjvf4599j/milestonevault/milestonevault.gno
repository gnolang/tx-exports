// Package milestonevault implements a trustless on-chain milestone escrow,
// bounty assignment, deadman-timeout release, and arbiter-quorum dispute protocol.
//
// Security architecture (Gno v1.8.0):
//   - Sub-realm escrow isolation: every vault mints a dedicated cur.Sub("v<id>")
//     escrow address so Vault A's funds are structurally isolated from Vault B
//     at the bank-keeper level.
//   - Ephemeral bankers only: no banker.Banker value is ever persisted in state.
//   - Checks-Effects-Interactions: all state transitions commit before SendCoins.
package milestonevault

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1p8ssx7g7fz268k6jc0krpu9enuen4hjvf4599j/escrowmath"
)

var (
	realmPkgPath        string
	vaults              []*Vault
	builderOrder        []address
	builderStatsByAddr  = make(map[address]*BuilderStats)
	totalDepositedUgnot int64
	totalReleasedUgnot  int64
	totalRefundedUgnot  int64
)

func getOrCreateBuilderStats(addr address) *BuilderStats {
	st, ok := builderStatsByAddr[addr]
	if !ok {
		st = &BuilderStats{Address: addr}
		builderStatsByAddr[addr] = st
		builderOrder = append(builderOrder, addr)
	}
	return st
}

func parseArbiters(csv string, sponsor address) []address {
	parts := escrowmath.SplitCSV(csv)
	if len(parts) == 0 || len(parts) > escrowmath.MaxArbiters {
		panic("arbiters count must be between 1 and 5")
	}
	seen := make(map[address]bool, len(parts))
	out := make([]address, 0, len(parts))
	for _, p := range parts {
		addr := address(p)
		if !addr.IsValid() {
			panic("invalid arbiter address: " + p)
		}
		if seen[addr] {
			panic("duplicate arbiter address: " + p)
		}
		seen[addr] = true
		out = append(out, addr)
	}
	_ = sponsor
	return out
}

func parsePositiveInt64(s string, field string) int64 {
	v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil || v <= 0 {
		panic("invalid positive integer for " + field)
	}
	return v
}

func parsePositiveInt(s string, field string) int {
	v, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || v <= 0 {
		panic("invalid positive integer for " + field)
	}
	return v
}

// CreateVault creates a new milestone escrow vault and atomically moves the exact
// ugnot sent in the transaction into an isolated sub-realm escrow address cur.Sub("v<id>").
//
// Parameters:
//   - title: short project title
//   - description: scope summary
//   - milestoneTitlesPipe: pipe-separated milestone names (e.g. "Spec|Build|Audit")
//   - milestoneAmountsCSV: comma-separated ugnot amounts summing to sent ugnot
//   - arbitersCSV: comma-separated 1..5 arbiter addresses
//   - timeoutBlocksStr: positive block count after submission when builder may claim timeout release
func CreateVault(
	cur realm,
	title string,
	description string,
	milestoneTitlesPipe string,
	milestoneAmountsCSV string,
	arbitersCSV string,
	timeoutBlocksStr string,
) int {
	if !cur.Previous().IsUserCall() {
		panic("CreateVault requires a direct user call (maketx call)")
	}
	realmPkgPath = cur.PkgPath()

	title = strings.TrimSpace(title)
	description = strings.TrimSpace(description)
	if title == "" {
		panic("vault title cannot be empty")
	}

	titles := escrowmath.SplitPipe(milestoneTitlesPipe)
	amounts, err := escrowmath.ParseAmountsCSV(milestoneAmountsCSV)
	if err != nil {
		panic(err.Error())
	}
	if len(titles) != len(amounts) {
		panic("milestone titles count must match milestone amounts count")
	}

	sent := unsafe.OriginSend()
	deposit := sent.AmountOf(DenomUGNOT)
	bps, err := escrowmath.ValidateMilestones(amounts, deposit)
	if err != nil {
		panic(err.Error())
	}

	sponsor := cur.Previous().Address()
	arbiters := parseArbiters(arbitersCSV, sponsor)
	timeoutBlocks := parsePositiveInt64(timeoutBlocksStr, "timeoutBlocks")

	id := len(vaults) + 1
	subPath := vaultSubPath(id)
	sub := cur.Sub(subPath)
	escrowAddr := sub.Address()

	ms := make([]*Milestone, len(amounts))
	for i := range amounts {
		ms[i] = &Milestone{
			ID:          i + 1,
			Title:       titles[i],
			AmountUgnot: amounts[i],
			Bps:         bps[i],
			Status:      MilestonePending,
		}
	}

	v := &Vault{
		ID:                id,
		Title:             title,
		Description:       description,
		Sponsor:           sponsor,
		SubPath:           subPath,
		EscrowAddr:        escrowAddr,
		Status:            VaultStatusOpen,
		TotalDepositUgnot: deposit,
		TimeoutBlocks:     timeoutBlocks,
		CreatedAtHeight:   runtime.ChainHeight(),
		Arbiters:          arbiters,
		Milestones:        ms,
		Dispute:           &Dispute{QuorumRequired: escrowmath.QuorumThreshold(len(arbiters))},
	}

	// Effects before external bank transfer.
	vaults = append(vaults, v)
	totalDepositedUgnot += deposit

	// Isolate the vault's ugnot inside its dedicated sub-realm account.
	hostBanker := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	hostBanker.SendCoins(cur.Address(), escrowAddr, chain.NewCoins(chain.NewCoin(DenomUGNOT, deposit)))

	chain.Emit(
		"VaultCreated",
		"vault_id", strconv.Itoa(id),
		"sponsor", string(sponsor),
		"escrow_addr", string(escrowAddr),
		"deposit_ugnot", strconv.FormatInt(deposit, 10),
		"milestones", strconv.Itoa(len(ms)),
	)
	return id
}

// ApplyForVault lets any builder submit an on-chain proposal for an OPEN vault.
func ApplyForVault(cur realm, vaultIDStr string, pitch string) {
	realmPkgPath = cur.PkgPath()
	v := mustGetVault(parsePositiveInt(vaultIDStr, "vaultID"))
	if v.Status != VaultStatusOpen {
		panic("vault is not open for applications")
	}
	caller := cur.Previous().Address()
	if caller == v.Sponsor {
		panic("sponsor cannot apply to own vault")
	}
	pitch = strings.TrimSpace(pitch)
	if pitch == "" {
		panic("application pitch cannot be empty")
	}
	for _, app := range v.Applications {
		if app.Builder == caller {
			panic("builder already applied to this vault")
		}
	}
	v.Applications = append(v.Applications, &Application{
		Builder:         caller,
		Pitch:           pitch,
		AppliedAtHeight: runtime.ChainHeight(),
	})
	chain.Emit(
		"VaultApplied",
		"vault_id", strconv.Itoa(v.ID),
		"builder", string(caller),
	)
}

// AssignBuilder allows the sponsor to assign a builder to an OPEN vault, transitioning it to ACTIVE.
func AssignBuilder(cur realm, vaultIDStr string, builderAddrStr string) {
	realmPkgPath = cur.PkgPath()
	v := mustGetVault(parsePositiveInt(vaultIDStr, "vaultID"))
	if v.Status != VaultStatusOpen {
		panic("vault must be OPEN to assign a builder")
	}
	caller := cur.Previous().Address()
	if caller != v.Sponsor {
		panic("only the vault sponsor can assign a builder")
	}
	builder := address(strings.TrimSpace(builderAddrStr))
	if !builder.IsValid() {
		panic("invalid builder address")
	}
	if builder == v.Sponsor {
		panic("sponsor cannot assign themselves as builder")
	}
	v.Builder = builder
	v.Status = VaultStatusActive
	getOrCreateBuilderStats(builder)

	chain.Emit(
		"BuilderAssigned",
		"vault_id", strconv.Itoa(v.ID),
		"builder", string(builder),
	)
}

// SubmitMilestone lets the assigned builder attach verifiable proof (commit/PR/URL) for a PENDING milestone.
func SubmitMilestone(cur realm, vaultIDStr string, milestoneIDStr string, evidenceURL string) {
	realmPkgPath = cur.PkgPath()
	v := mustGetVault(parsePositiveInt(vaultIDStr, "vaultID"))
	if v.Status != VaultStatusActive {
		panic("vault must be ACTIVE to submit a milestone")
	}
	caller := cur.Previous().Address()
	if caller != v.Builder {
		panic("only the assigned builder can submit milestone deliverables")
	}
	m := v.GetMilestone(parsePositiveInt(milestoneIDStr, "milestoneID"))
	if m == nil {
		panic("milestone not found")
	}
	if m.Status != MilestonePending {
		panic("milestone must be PENDING to submit")
	}
	evidenceURL = strings.TrimSpace(evidenceURL)
	if evidenceURL == "" {
		panic("evidence URL or proof hash cannot be empty")
	}

	m.Status = MilestoneSubmitted
	m.EvidenceURL = evidenceURL
	m.SubmittedAtHeight = runtime.ChainHeight()

	chain.Emit(
		"MilestoneSubmitted",
		"vault_id", strconv.Itoa(v.ID),
		"milestone_id", strconv.Itoa(m.ID),
		"builder", string(caller),
		"evidence", evidenceURL,
	)
}

// ApproveMilestone lets the sponsor approve a SUBMITTED milestone and atomically release ugnot
// from the vault's isolated sub-realm escrow directly to the builder.
func ApproveMilestone(cur realm, vaultIDStr string, milestoneIDStr string) {
	realmPkgPath = cur.PkgPath()
	v := mustGetVault(parsePositiveInt(vaultIDStr, "vaultID"))
	if v.Status != VaultStatusActive {
		panic("vault must be ACTIVE to approve milestones")
	}
	caller := cur.Previous().Address()
	if caller != v.Sponsor {
		panic("only the vault sponsor can approve a milestone")
	}
	m := v.GetMilestone(parsePositiveInt(milestoneIDStr, "milestoneID"))
	if m == nil {
		panic("milestone not found")
	}
	if m.Status != MilestoneSubmitted {
		panic("milestone must be SUBMITTED before approval")
	}

	releaseMilestoneToBuilder(cur, v, m)
}

// ClaimTimeoutRelease protects builders against unresponsive sponsors:
// once timeoutBlocks have elapsed since submission without approval or dispute,
// the builder can claim the milestone payout permissionlessly.
func ClaimTimeoutRelease(cur realm, vaultIDStr string, milestoneIDStr string) {
	realmPkgPath = cur.PkgPath()
	v := mustGetVault(parsePositiveInt(vaultIDStr, "vaultID"))
	if v.Status != VaultStatusActive {
		panic("vault must be ACTIVE to claim timeout release")
	}
	caller := cur.Previous().Address()
	if caller != v.Builder {
		panic("only the assigned builder can claim timeout release")
	}
	m := v.GetMilestone(parsePositiveInt(milestoneIDStr, "milestoneID"))
	if m == nil {
		panic("milestone not found")
	}
	if m.Status != MilestoneSubmitted {
		panic("milestone must be SUBMITTED to claim timeout release")
	}
	unlockHeight := m.SubmittedAtHeight + v.TimeoutBlocks
	if runtime.ChainHeight() < unlockHeight {
		panic("timeout not reached yet; unlocks at block " + strconv.FormatInt(unlockHeight, 10))
	}

	releaseMilestoneToBuilder(cur, v, m)
}

func releaseMilestoneToBuilder(cur realm, v *Vault, m *Milestone) {
	// Checks-Effects-Interactions: commit state updates before SendCoins.
	m.Status = MilestoneApproved
	m.ApprovedAtHeight = runtime.ChainHeight()
	v.ReleasedUgnot += m.AmountUgnot
	totalReleasedUgnot += m.AmountUgnot

	st := getOrCreateBuilderStats(v.Builder)
	st.MilestonesCompleted++
	st.TotalEarnedUgnot += m.AmountUgnot

	if v.AllMilestonesSettled() {
		v.Status = VaultStatusCompleted
		st.VaultsCompleted++
	}

	sub := cur.Sub(v.SubPath)
	subBanker := banker.NewBanker(banker.BankerTypeRealmSend, sub)
	subBanker.SendCoins(sub.Address(), v.Builder, chain.NewCoins(chain.NewCoin(DenomUGNOT, m.AmountUgnot)))

	chain.Emit(
		"MilestoneReleased",
		"vault_id", strconv.Itoa(v.ID),
		"milestone_id", strconv.Itoa(m.ID),
		"builder", string(v.Builder),
		"amount_ugnot", strconv.FormatInt(m.AmountUgnot, 10),
	)
}

// OpenDispute pauses a vault and escalates a SUBMITTED milestone to the arbiter council.
// Either the sponsor or the assigned builder may open a dispute.
func OpenDispute(cur realm, vaultIDStr string, milestoneIDStr string, reason string) {
	realmPkgPath = cur.PkgPath()
	v := mustGetVault(parsePositiveInt(vaultIDStr, "vaultID"))
	if v.Status != VaultStatusActive {
		panic("only ACTIVE vaults can enter dispute")
	}
	caller := cur.Previous().Address()
	if caller != v.Sponsor && caller != v.Builder {
		panic("only sponsor or assigned builder can open a dispute")
	}
	m := v.GetMilestone(parsePositiveInt(milestoneIDStr, "milestoneID"))
	if m == nil {
		panic("milestone not found")
	}
	if m.Status != MilestoneSubmitted {
		panic("only a SUBMITTED milestone can be disputed")
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		panic("dispute reason cannot be empty")
	}

	v.Status = VaultStatusDisputed
	v.Dispute = &Dispute{
		Active:         true,
		MilestoneID:    m.ID,
		OpenedBy:       caller,
		Reason:         reason,
		OpenedAtHeight: runtime.ChainHeight(),
		QuorumRequired: escrowmath.QuorumThreshold(len(v.Arbiters)),
		Voted:          make(map[address]string),
	}

	chain.Emit(
		"DisputeOpened",
		"vault_id", strconv.Itoa(v.ID),
		"milestone_id", strconv.Itoa(m.ID),
		"opened_by", string(caller),
		"reason", reason,
	)
}

// VoteDispute lets an appointed arbiter cast one immutable vote: "RELEASE", "REFUND", or "SPLIT".
// Once strict majority quorum is reached (or all arbiters vote with deadlock fallback to SPLIT),
// the disputed milestone settles atomically from the isolated sub-realm escrow.
func VoteDispute(cur realm, vaultIDStr string, verdict string) {
	realmPkgPath = cur.PkgPath()
	v := mustGetVault(parsePositiveInt(vaultIDStr, "vaultID"))
	if v.Status != VaultStatusDisputed || v.Dispute == nil || !v.Dispute.Active {
		panic("vault does not have an active dispute")
	}
	caller := cur.Previous().Address()
	if !v.IsArbiter(caller) {
		panic("caller is not an appointed arbiter for this vault")
	}
	if _, already := v.Dispute.Voted[caller]; already {
		panic("arbiter already voted on this dispute")
	}

	verdict = strings.ToUpper(strings.TrimSpace(verdict))
	switch verdict {
	case VoteRelease:
		v.Dispute.VotesRelease++
	case VoteRefund:
		v.Dispute.VotesRefund++
	case VoteSplit:
		v.Dispute.VotesSplit++
	default:
		panic("verdict must be RELEASE, REFUND, or SPLIT")
	}
	v.Dispute.Voted[caller] = verdict

	chain.Emit(
		"DisputeVoted",
		"vault_id", strconv.Itoa(v.ID),
		"arbiter", string(caller),
		"verdict", verdict,
	)

	outcome, reached := escrowmath.EvaluateDisputeTally(
		v.Dispute.VotesRelease,
		v.Dispute.VotesRefund,
		v.Dispute.VotesSplit,
		len(v.Arbiters),
	)
	if !reached {
		return
	}

	// Settle dispute atomically.
	m := v.GetMilestone(v.Dispute.MilestoneID)
	v.Dispute.Active = false
	v.Dispute.ResolvedOutcome = outcome

	st := getOrCreateBuilderStats(v.Builder)
	sub := cur.Sub(v.SubPath)
	subBanker := banker.NewBanker(banker.BankerTypeRealmSend, sub)

	switch outcome {
	case VoteRelease:
		m.Status = MilestoneApproved
		m.ApprovedAtHeight = runtime.ChainHeight()
		v.ReleasedUgnot += m.AmountUgnot
		totalReleasedUgnot += m.AmountUgnot
		st.MilestonesCompleted++
		st.TotalEarnedUgnot += m.AmountUgnot
		st.DisputesWon++
		if v.AllMilestonesSettled() {
			v.Status = VaultStatusCompleted
			st.VaultsCompleted++
		} else {
			v.Status = VaultStatusActive
		}
		subBanker.SendCoins(sub.Address(), v.Builder, chain.NewCoins(chain.NewCoin(DenomUGNOT, m.AmountUgnot)))

	case VoteRefund:
		m.Status = MilestoneRefunded
		v.RefundedUgnot += m.AmountUgnot
		totalRefundedUgnot += m.AmountUgnot
		st.DisputesLost++
		if v.AllMilestonesSettled() {
			v.Status = VaultStatusCompleted
		} else {
			v.Status = VaultStatusActive
		}
		subBanker.SendCoins(sub.Address(), v.Sponsor, chain.NewCoins(chain.NewCoin(DenomUGNOT, m.AmountUgnot)))

	case VoteSplit:
		builderAmt, sponsorAmt := escrowmath.ComputeSplit(m.AmountUgnot)
		m.Status = MilestoneSplit
		m.ApprovedAtHeight = runtime.ChainHeight()
		v.ReleasedUgnot += builderAmt
		v.RefundedUgnot += sponsorAmt
		totalReleasedUgnot += builderAmt
		totalRefundedUgnot += sponsorAmt
		st.TotalEarnedUgnot += builderAmt
		if v.AllMilestonesSettled() {
			v.Status = VaultStatusCompleted
		} else {
			v.Status = VaultStatusActive
		}
		if builderAmt > 0 {
			subBanker.SendCoins(sub.Address(), v.Builder, chain.NewCoins(chain.NewCoin(DenomUGNOT, builderAmt)))
		}
		if sponsorAmt > 0 {
			subBanker.SendCoins(sub.Address(), v.Sponsor, chain.NewCoins(chain.NewCoin(DenomUGNOT, sponsorAmt)))
		}
	}

	chain.Emit(
		"DisputeResolved",
		"vault_id", strconv.Itoa(v.ID),
		"milestone_id", strconv.Itoa(m.ID),
		"outcome", outcome,
	)
}

// CancelVault allows the sponsor to cancel an OPEN (unassigned) vault and reclaim 100%
// of the escrowed ugnot from the isolated sub-realm account.
func CancelVault(cur realm, vaultIDStr string) {
	realmPkgPath = cur.PkgPath()
	v := mustGetVault(parsePositiveInt(vaultIDStr, "vaultID"))
	if v.Status != VaultStatusOpen {
		panic("only OPEN (unassigned) vaults can be cancelled")
	}
	caller := cur.Previous().Address()
	if caller != v.Sponsor {
		panic("only the vault sponsor can cancel an open vault")
	}

	refundAmt := v.LockedAmount()
	v.Status = VaultStatusCancelled
	for _, m := range v.Milestones {
		m.Status = MilestoneRefunded
	}
	v.RefundedUgnot += refundAmt
	totalRefundedUgnot += refundAmt

	if refundAmt > 0 {
		sub := cur.Sub(v.SubPath)
		subBanker := banker.NewBanker(banker.BankerTypeRealmSend, sub)
		subBanker.SendCoins(sub.Address(), v.Sponsor, chain.NewCoins(chain.NewCoin(DenomUGNOT, refundAmt)))
	}

	chain.Emit(
		"VaultCancelled",
		"vault_id", strconv.Itoa(v.ID),
		"sponsor", string(v.Sponsor),
		"refund_ugnot", strconv.FormatInt(refundAmt, 10),
	)
}

// VaultCount returns total number of created vaults (read-only helper for composability).
func VaultCount() int {
	return len(vaults)
}

// GetVaultEscrowAddress returns the isolated cur.Sub escrow address for vaultID.
func GetVaultEscrowAddress(vaultID int) address {
	return mustGetVault(vaultID).EscrowAddr
}

func mustGetVault(id int) *Vault {
	if id < 1 || id > len(vaults) {
		panic("vault not found: " + strconv.Itoa(id))
	}
	return vaults[id-1]
}
