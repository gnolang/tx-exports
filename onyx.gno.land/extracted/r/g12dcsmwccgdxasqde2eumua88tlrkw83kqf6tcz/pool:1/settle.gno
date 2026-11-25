package pool

func validOutcome(outcome int) {
	if outcome < SideA || outcome > Unresolvable {
		panic("BadSide")
	}
}

func validHash(h string) {
	if h == "" {
		return
	}
	if len(h) != 64 {
		panic("BadEvidenceHash")
	}
	for _, c := range h {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			panic("BadEvidenceHash")
		}
	}
}

// refundAt is when RefundExpired opens: grace from the latest deadline, proposal or dispute.
func refundAt(m *Market) int64 {
	start := m.Deadline
	if m.ProposedAt > start {
		start = m.ProposedAt
	}
	if m.DisputedAt > start {
		start = m.DisputedAt
	}
	return start + ResolutionGraceSeconds
}

func setCutoff(m *Market, cutoff int64) {
	if cutoff > now() || cutoff < 0 {
		panic("BadCutoff")
	}
	m.SettlementCutoff = cutoff
	emit("SettlementCutoffSet", "id", itoa(m.ID), "cutoff", itoa(cutoff))
}

// Resolve is the oracle's verdict: final at once with no dispute window, else a proposal.
func Resolve(cur realm, id int64, outcome int, summary, evidenceHash string) {
	resolve(cur, id, outcome, summary, evidenceHash, 0)
}

// ResolveWithCutoff also sets the settlement cutoff: only deposits strictly
// before it compete; later ones get their net principal back.
func ResolveWithCutoff(cur realm, id int64, outcome int, summary, evidenceHash string, cutoff int64) {
	resolve(cur, id, outcome, summary, evidenceHash, cutoff)
}

func resolve(cur realm, id int64, outcome int, summary, evidenceHash string, cutoff int64) {
	assertNotPaused()
	roles.AssertOracle(caller(cur))
	m := getMarket(id)
	if m.State != StOpen {
		panic("NotOpen")
	}
	if now() < m.Deadline {
		panic("NotExpired")
	}
	if now() >= refundAt(m) {
		panic("GraceOver")
	}
	validOutcome(outcome)
	validHash(evidenceHash)
	setCutoff(m, cutoff)
	if disputeWindow == 0 {
		settle(m, outcome, summary, evidenceHash)
		return
	}
	m.State = StProposed
	m.Proposed = outcome
	m.ProposedAt = now()
	m.EvidenceHash = evidenceHash
	m.Summary = summary
	emit("ResolutionProposed", "id", itoa(id), "outcome", itoa(int64(outcome)),
		"evidenceHash", evidenceHash, "disputableUntil", itoa(now()+disputeWindow))
}

// Dispute escalates the proposal to the arbiter, pulling DisputeBond mUSD.
// Open to the market's participants, the audit agent and the arbiter.
func Dispute(cur realm, id int64) {
	m := getMarket(id)
	if m.State != StProposed {
		panic("NotProposed")
	}
	if now() >= m.ProposedAt+disputeWindow {
		panic("WindowClosed")
	}
	c := caller(cur)
	p := m.position(c)
	staked := p != nil && (p.A != 0 || p.B != 0)
	if !staked && (roles.AuditAgent == "" || c != roles.AuditAgent) && c != roles.Arbiter {
		panic("NotParticipant")
	}
	pull(cur, c, DisputeBond)
	m.State = StDisputed
	m.Disputer = c
	m.DisputedAt = now()
	m.Bond = DisputeBond
	emit("ResolutionDisputed", "id", itoa(id), "disputer", c.String(), "bond", itoa(DisputeBond))
}

// VetoProposal lets the owner send a proposal it believes wrong to the
// arbiter, inside the window. No bond; if the arbiter never rules,
// RefundExpired refunds every stake rather than honouring the vetoed proposal.
func VetoProposal(cur realm, id int64) {
	assertOwner(cur)
	m := getMarket(id)
	if m.State != StProposed {
		panic("NotProposed")
	}
	if now() >= m.ProposedAt+disputeWindow {
		panic("WindowClosed")
	}
	m.State = StDisputed
	m.DisputedAt = now()
	emit("ResolutionDisputed", "id", itoa(id), "disputer", "", "bond", "0")
}

// Finalize settles an undisputed proposal once the window has closed. Anyone may call it.
func Finalize(cur realm, id int64) {
	assertNotPaused()
	m := getMarket(id)
	if m.State != StProposed {
		panic("NotProposed")
	}
	if now() < m.ProposedAt+disputeWindow {
		panic("WindowOpen")
	}
	settle(m, m.Proposed, m.Summary, m.EvidenceHash)
}

// ResolveDispute is the arbiter's final word on a disputed market.
func ResolveDispute(cur realm, id int64, outcome int, summary, evidenceHash string) {
	m := getMarket(id)
	resolveDispute(cur, m, outcome, summary, evidenceHash, m.SettlementCutoff)
}

func ResolveDisputeWithCutoff(cur realm, id int64, outcome int, summary, evidenceHash string, cutoff int64) {
	resolveDispute(cur, getMarket(id), outcome, summary, evidenceHash, cutoff)
}

func resolveDispute(cur realm, m *Market, outcome int, summary, evidenceHash string, cutoff int64) {
	assertNotPaused()
	roles.AssertArbiter(caller(cur))
	if m.State != StDisputed {
		panic("NotDisputed")
	}
	if now() >= refundAt(m) {
		panic("GraceOver")
	}
	validOutcome(outcome)
	validHash(evidenceHash)
	disputerRight := outcome != m.Proposed || cutoff != m.SettlementCutoff
	setCutoff(m, cutoff)
	emit("DisputeResolved", "id", itoa(m.ID), "outcome", itoa(int64(outcome)), "disputerRight", boolStr(disputerRight))
	// Settled before the bond moves.
	settle(m, outcome, summary, evidenceHash)
	settleBond(cur, m, disputerRight)
}

// RefundExpired is the escape hatch, open to anyone once the grace has passed.
// A market the oracle never resolved is refunded in full; a dispute the
// arbiter never ruled on settles to the oracle's proposal and the bond is
// forfeited, so a cheap dispute cannot turn a loss into a free refund. A
// vetoed proposal, or any proposal while paused, refunds instead.
func RefundExpired(cur realm, id int64) {
	m := getMarket(id)
	disputed := m.State == StDisputed
	if !disputed && m.State != StOpen && !(roles.Paused && m.State == StProposed) {
		panic("NotOpen")
	}
	if now() < refundAt(m) {
		panic("GraceNotOver")
	}
	switch {
	case disputed && !roles.Paused && m.Disputer != "":
		emit("DisputeResolved", "id", itoa(id), "outcome", itoa(int64(m.Proposed)), "disputerRight", "false")
		settle(m, m.Proposed, m.Summary, m.EvidenceHash)
		settleBond(cur, m, false)
	case disputed:
		emit("DisputeResolved", "id", itoa(id), "outcome", itoa(Unresolvable), "disputerRight", "true")
		settle(m, Unresolvable, "Refunded: vetoed or paused", "")
		settleBond(cur, m, true)
	default:
		emit("MarketExpiredRefund", "id", itoa(id), "caller", caller(cur).String())
		settle(m, Unresolvable, "Refunded: not resolved within the grace period", "")
	}
}

func settle(m *Market, outcome int, summary, evidenceHash string) {
	m.State = StResolved
	m.Outcome = outcome
	m.Summary = summary
	m.EvidenceHash = evidenceHash
	emit("MarketResolved", "id", itoa(m.ID), "outcome", itoa(int64(outcome)), "summary", summary, "evidenceHash", evidenceHash)
}

func settleBond(cur realm, m *Market, returnIt bool) {
	bond := m.Bond
	if bond == 0 {
		return
	}
	m.Bond = 0
	if returnIt {
		push(cur, m.Disputer, bond)
	} else {
		accrue(m.ID, roles.FeeRecipient, bond)
	}
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
