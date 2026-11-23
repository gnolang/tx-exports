package pool

import (
	"strings"

	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
)

func MarketCount() int64          { return marketCount }
func Owner() address              { return roles.Owner }
func Arbiter() address            { return roles.Arbiter }
func Oracle() address             { return roles.Oracle }
func AuditAgent() address         { return roles.AuditAgent }
func FeeRecipient() address       { return roles.FeeRecipient }
func Paused() bool                { return roles.Paused }
func DisputeWindow() int64        { return disputeWindow }
func AccruedFees(a address) int64 { return feesOf(a) }

// SideTotals are the pool sizes: the implied probability of A is totalA / (totalA + totalB).
func SideTotals(id int64) (int64, int64) {
	m := getMarket(id)
	return m.TotalA, m.TotalB
}

func StakeOf(id int64, user address) (int64, int64) {
	p := getMarket(id).position(user)
	if p == nil {
		return 0, 0
	}
	return p.A, p.B
}

// EligibleTotals are the side totals that compete under the settlement cutoff.
func EligibleTotals(id int64) (int64, int64) {
	m := getMarket(id)
	t := m.history.Before(m.SettlementCutoff)
	return t.A, t.B
}

// Claimable is what ClaimFor would pay `user` now (net) and the copy fees it
// would take. 0 if unresolved, already claimed or nothing owed.
func Claimable(id int64, user address) (payout, fee int64) {
	m := getMarket(id)
	p := m.position(user)
	if m.State != StResolved || p == nil || p.Claimed {
		return 0, 0
	}
	gross, feeBase := owed(m, p)
	toRef, toPlatform := copyFees(user, p, feeBase)
	fee = toRef + toPlatform
	return gross - fee, fee
}

func ConfigJSON() string {
	return "{" + strings.Join([]string{
		kv("owner", mimir.Quote(roles.Owner.String())),
		kv("arbiter", mimir.Quote(roles.Arbiter.String())),
		kv("oracle", mimir.Quote(roles.Oracle.String())),
		kv("auditAgent", mimir.Quote(roles.AuditAgent.String())),
		kv("feeRecipient", mimir.Quote(roles.FeeRecipient.String())),
		kv("paused", boolStr(roles.Paused)),
		kv("disputeWindow", itoa(disputeWindow)),
		kv("minStake", itoa(MinStake)),
		kv("disputeBond", itoa(DisputeBond)),
		kv("lockSeconds", itoa(LockSeconds)),
		kv("graceSeconds", itoa(ResolutionGraceSeconds)),
		kv("maxMarketStake", itoa(roles.MaxMarketStake)),
		kv("maxAccountStake", itoa(roles.MaxAccountStake)),
		kv("marketCount", itoa(marketCount)),
		kv("lifetimeFeesAccrued", itoa(lifetimeFeesAccrued)),
		kv("lifetimeFeesClaimed", itoa(lifetimeFeesClaimed)),
		kv("now", itoa(now())),
	}, ",") + "}"
}

func MarketJSON(id int64) string { return marketJSON(getMarket(id)) }

// MarketsJSON lists markets newest first: `offset` skips that many from the newest.
func MarketsJSON(offset, limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	var out []string
	markets.ReverseIterateByOffset(offset, limit, func(_ string, v any) bool {
		out = append(out, marketJSON(v.(*Market)))
		return false
	})
	return "[" + strings.Join(out, ",") + "]"
}

// PositionJSON is one user's stake, claim state and claimable amount in a market.
func PositionJSON(id int64, user address) string {
	m := getMarket(id)
	p := m.position(user)
	if p == nil {
		p = &Position{}
	}
	payout, fee := Claimable(id, user)
	return "{" + strings.Join([]string{
		kv("a", itoa(p.A)), kv("b", itoa(p.B)),
		kv("copyA", itoa(p.CopyA)), kv("copyB", itoa(p.CopyB)),
		kv("referrer", mimir.Quote(p.Referrer.String())),
		kv("claimed", boolStr(p.Claimed)),
		kv("claimable", itoa(payout)), kv("claimFee", itoa(fee)),
	}, ",") + "}"
}

func marketJSON(m *Market) string {
	ea, eb := EligibleTotals(m.ID)
	return "{" + strings.Join([]string{
		kv("id", itoa(m.ID)),
		kv("creator", mimir.Quote(m.Creator.String())),
		kv("deadline", itoa(m.Deadline)),
		kv("createdAt", itoa(m.CreatedAt)),
		kv("state", itoa(int64(m.State))),
		kv("outcome", itoa(int64(m.Outcome))),
		kv("proposed", itoa(int64(m.Proposed))),
		kv("proposedAt", itoa(m.ProposedAt)),
		kv("disputedAt", itoa(m.DisputedAt)),
		kv("disputer", mimir.Quote(m.Disputer.String())),
		kv("bond", itoa(m.Bond)),
		kv("totalA", itoa(m.TotalA)),
		kv("totalB", itoa(m.TotalB)),
		kv("eligibleA", itoa(ea)),
		kv("eligibleB", itoa(eb)),
		kv("entryFees", itoa(m.EntryFees)),
		kv("settlementCutoff", itoa(m.SettlementCutoff)),
		kv("lockAt", itoa(m.LockAt)),
		kv("participants", itoa(int64(m.positions.Size()))),
		kv("evidenceHash", mimir.Quote(m.EvidenceHash)),
		kv("question", mimir.Quote(m.Question)),
		kv("labelA", mimir.Quote(m.LabelA)),
		kv("labelB", mimir.Quote(m.LabelB)),
		kv("resolutionUrl", mimir.Quote(m.ResolutionURL)),
		kv("category", mimir.Quote(m.Category)),
		kv("summary", mimir.Quote(m.Summary)),
	}, ",") + "}"
}

func kv(k, v string) string { return mimir.Quote(k) + ":" + v }
