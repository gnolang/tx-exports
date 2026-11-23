package vs

import (
	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
)

func validVerdict(side int) {
	if side < SideCreator || side > SideUnresolvable {
		panic("InvalidVerdict")
	}
}

func validHash(h string) {
	if h == "" {
		return
	}
	if len(h) != 64 {
		panic("BadEvidenceHash")
	}
	for _, ch := range h {
		if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') {
			panic("BadEvidenceHash")
		}
	}
}

func setCutoff(c *Claim, cutoff int64) {
	if cutoff > now() || cutoff < 0 {
		panic("BadCutoff")
	}
	c.SettlementCutoff = cutoff
	emit("SettlementCutoffSet", "id", itoa(c.ID), "cutoff", itoa(cutoff))
}

// refundAt is when RefundExpired opens: grace counted from the deadline, or
// from the proposal or dispute if later. From then on new verdicts are refused.
func refundAt(c *Claim) int64 {
	start := c.Deadline
	if c.Proposal.ProposedAt > start {
		start = c.Proposal.ProposedAt
	}
	if c.Proposal.DisputedAt > start {
		start = c.Proposal.DisputedAt
	}
	return start + ResolutionGraceSeconds
}

// ResolveClaimWithCutoff is the oracle's verdict on an active claim. With a
// dispute window it is a proposal; only stakes made strictly before `cutoff`
// (0 = all) compete, later ones are refunded.
func ResolveClaimWithCutoff(cur realm, claimID int64, winnerSide int, summary string,
	confidence int, evidenceHash string, cutoff int64) {
	roles.AssertOracle(caller(cur))
	roles.AssertNotPaused()
	c := getClaim(claimID)
	if c.State != StActive {
		panic("NotActive")
	}
	if now() < c.Deadline {
		panic("NotYetExpired")
	}
	if now() >= refundAt(c) {
		panic("GraceOver")
	}
	validVerdict(winnerSide)
	validHash(evidenceHash)
	if confidence < 0 || confidence > 100 {
		panic("BadConfidence")
	}
	setCutoff(c, cutoff)
	if disputeWindow == 0 {
		settle(cur, c, winnerSide, summary, confidence, evidenceHash)
		return
	}
	c.State = StProposed
	c.Proposal = Proposal{WinnerSide: winnerSide, Confidence: confidence, ProposedAt: now(),
		EvidenceHash: evidenceHash, Summary: summary}
	emit("ResolutionProposed", "id", itoa(claimID), "winnerSide", itoa(int64(winnerSide)),
		"confidence", itoa(int64(confidence)), "evidenceHash", evidenceHash,
		"disputableUntil", itoa(now()+disputeWindow))
}

// DisputeResolution escalates a proposed verdict to the arbiter by posting
// DisputeBond. The bond comes back if the arbiter changes the verdict and is
// forfeited otherwise. Open to the creator, challengers, the audit agent and
// the arbiter.
func DisputeResolution(cur realm, claimID int64) {
	c := getClaim(claimID)
	if c.State != StProposed {
		panic("NothingToDispute")
	}
	if now() >= c.Proposal.ProposedAt+disputeWindow {
		panic("DisputeWindowClosed")
	}
	u := caller(cur)
	if !(u == c.Creator || c.hasJoined(u) || (roles.AuditAgent != "" && u == roles.AuditAgent) || u == roles.Arbiter) {
		panic("NotAParticipant")
	}
	// The bond is not a position: no entry fee.
	pull(cur, u, DisputeBond)
	c.State = StDisputed
	c.Proposal.Disputer = u
	c.Proposal.DisputedAt = now()
	c.Proposal.Bond = DisputeBond
	emit("ResolutionDisputed", "id", itoa(claimID), "disputer", u.String(), "bond", itoa(DisputeBond))
}

// VetoProposal sends a proposal the owner believes wrong to the arbiter, inside
// the window. No bond; if the arbiter never rules, RefundExpired refunds.
func VetoProposal(cur realm, claimID int64) {
	roles.AssertOwner(caller(cur))
	c := getClaim(claimID)
	if c.State != StProposed {
		panic("NotProposed")
	}
	if now() >= c.Proposal.ProposedAt+disputeWindow {
		panic("WindowClosed")
	}
	c.State = StDisputed
	c.Proposal.DisputedAt = now()
	emit("ResolutionDisputed", "id", itoa(claimID), "disputer", "", "bond", "0")
}

// FinalizeResolution settles an undisputed proposal once its window has closed. Anyone may call it.
func FinalizeResolution(cur realm, claimID int64) {
	roles.AssertNotPaused()
	c := getClaim(claimID)
	if c.State != StProposed {
		panic("NotProposed")
	}
	if now() < c.Proposal.ProposedAt+disputeWindow {
		panic("DisputeWindowOpen")
	}
	p := c.Proposal
	settle(cur, c, p.WinnerSide, p.Summary, p.Confidence, p.EvidenceHash)
}

// ResolveDisputeWithCutoff is the arbiter's final word on a disputed claim.
func ResolveDisputeWithCutoff(cur realm, claimID int64, winnerSide int, summary string,
	confidence int, evidenceHash string, cutoff int64) {
	roles.AssertNotPaused()
	roles.AssertArbiter(caller(cur))
	c := getClaim(claimID)
	if c.State != StDisputed {
		panic("NotDisputed")
	}
	if now() >= refundAt(c) {
		panic("GraceOver")
	}
	validVerdict(winnerSide)
	validHash(evidenceHash)
	disputerRight := winnerSide != c.Proposal.WinnerSide || cutoff != c.SettlementCutoff
	setCutoff(c, cutoff)
	emit("DisputeResolved", "id", itoa(claimID), "winnerSide", itoa(int64(winnerSide)), "disputerRight", boolStr(disputerRight))
	// Settle first: the claim is resolved before any value leaves, bond included.
	settle(cur, c, winnerSide, summary, confidence, evidenceHash)
	settleBond(cur, c, disputerRight)
}

func settleBond(cur realm, c *Claim, returnIt bool) {
	bond := c.Proposal.Bond
	if bond == 0 {
		return
	}
	c.Proposal.Bond = 0
	if returnIt {
		push(cur, c.Proposal.Disputer, bond)
	} else {
		accrue(c.ID, roles.FeeRecipient, bond)
	}
}

// RefundExpired is the escape hatch, open to anyone once the grace has passed:
//   - an active claim the oracle never resolved refunds every stake;
//   - a disputed claim the arbiter never ruled on settles to the proposal and
//     the bond is forfeited, unless the owner vetoed it or the realm is
//     paused: then every stake is refunded and the bond goes back;
//   - a paused, undisputed proposal refunds after the grace from its proposal.
func RefundExpired(cur realm, claimID int64) {
	c := getClaim(claimID)
	disputed := c.State == StDisputed
	if !(disputed || c.State == StActive || (roles.Paused && c.State == StProposed)) {
		panic("NotActive")
	}
	if now() < refundAt(c) {
		panic("OracleGraceNotOver")
	}
	p := c.Proposal
	switch {
	case disputed && !roles.Paused && p.Disputer != "":
		emit("DisputeResolved", "id", itoa(claimID), "winnerSide", itoa(int64(p.WinnerSide)), "disputerRight", "false")
		settle(cur, c, p.WinnerSide, p.Summary, p.Confidence, p.EvidenceHash)
		settleBond(cur, c, false)
	case disputed:
		emit("DisputeResolved", "id", itoa(claimID), "winnerSide", itoa(SideUnresolvable), "disputerRight", "true")
		settle(cur, c, SideUnresolvable, "Refunded: vetoed or paused", 0, "")
		settleBond(cur, c, true)
	default:
		emit("ClaimExpiredRefund", "id", itoa(claimID), "caller", caller(cur).String())
		settle(cur, c, SideUnresolvable, "Refunded: not resolved within the grace period", 0, "")
	}
}

// EligibleTotals are the creator's and the challengers' stakes that compete
// under the settlement cutoff.
func EligibleTotals(claimID int64) (int64, int64) { return eligibleTotals(getClaim(claimID)) }

func eligibleTotals(c *Claim) (int64, int64) {
	if c.SettlementCutoff == 0 {
		return c.CreatorStake, c.TotalChallengerStake
	}
	if c.CreatedAt >= c.SettlementCutoff {
		return 0, 0
	}
	b := int64(0)
	for _, ch := range c.challengers {
		if ch.At < c.SettlementCutoff {
			b += ch.Stake
		}
	}
	return c.CreatorStake, b
}

func settle(cur realm, c *Claim, winnerSide int, summary string, confidence int, evidenceHash string) {
	c.State = StResolved
	c.WinnerSide = winnerSide
	c.ResolutionSummary = summary
	c.Confidence = confidence
	c.EvidenceHash = evidenceHash
	totalResolved++
	paid, taken := distribute(cur, c, winnerSide)
	emit("ClaimResolved", "id", itoa(c.ID), "winnerSide", itoa(int64(winnerSide)), "summary", summary,
		"confidence", itoa(int64(confidence)), "evidenceHash", evidenceHash)
	emit("MarketSettled", "id", itoa(c.ID), "totalPaid", itoa(paid), "totalFees", itoa(taken))
}

// distribute pays only eligible risk; late principal is refunded as on a draw.
func distribute(cur realm, c *Claim, outcome int) (totalPaid, totalFees int64) {
	_, eligible := eligibleTotals(c)
	// A late creator also gives zero eligible challenger liquidity.
	if eligible == 0 {
		outcome = SideUnresolvable
	}
	remainder := c.CreatorStake
	atRisk := eligible * MaxPoolMultiple
	if atRisk > remainder {
		atRisk = remainder
	}
	if outcome == SideCreator {
		totalPaid, totalFees = payWinner(cur, c.ID, c.Creator, remainder+eligible, remainder, c.Referrer)
		remainder = 0
		bump(&wins, c.Creator)
	} else if outcome == SideChallengers {
		bump(&losses, c.Creator)
	}
	for _, ch := range c.challengers {
		early := c.SettlementCutoff == 0 || ch.At < c.SettlementCutoff
		switch {
		case early && outcome == SideCreator:
			bump(&losses, ch.Addr)
		case early && outcome == SideChallengers:
			var payout int64
			if c.OddsMode == "fixed" {
				payout = grossPayout(ch.Stake, c.ChallengerPayoutBps)
				if payout > ch.Stake {
					// Admission reserved every fixed profit; excluding late positions only reduces it.
					remainder -= payout - ch.Stake
				}
			} else {
				share := mimir.MulDiv(ch.Stake, atRisk, eligible)
				remainder -= share
				payout = ch.Stake + share
			}
			paid, taken := payWinner(cur, c.ID, ch.Addr, payout, ch.Stake, ch.Referrer)
			totalPaid += paid
			totalFees += taken
			bump(&wins, ch.Addr)
		default:
			push(cur, ch.Addr, ch.Stake)
			totalPaid += ch.Stake
		}
	}
	push(cur, c.Creator, remainder)
	totalPaid += remainder
	return totalPaid, totalFees
}
