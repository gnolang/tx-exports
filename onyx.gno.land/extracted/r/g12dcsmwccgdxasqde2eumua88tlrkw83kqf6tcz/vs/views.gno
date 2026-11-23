package vs

import (
	"strings"

	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
)

func ClaimCount() int64                      { return claimCount }
func Owner() address                         { return roles.Owner }
func Arbiter() address                       { return roles.Arbiter }
func Oracle() address                        { return roles.Oracle }
func AuditAgent() address                    { return roles.AuditAgent }
func FeeRecipient() address                  { return roles.FeeRecipient }
func Paused() bool                           { return roles.Paused }
func DisputeWindow() int64                   { return disputeWindow }
func AccruedFees(a address) int64            { return counter(&accruedFees, a) }
func UserStats(a address) (int64, int64)     { return counter(&wins, a), counter(&losses, a) }
func HasChallenged(id int64, a address) bool { return getClaim(id).hasJoined(a) }
func Invited(id int64, a address) bool       { return getClaim(id).isInvited(a) }

// PlatformStats: claims opened, claims resolved.
func PlatformStats() (int64, int64) { return claimCount, totalResolved }

// FeeStats: accrued, claimed and outstanding fees. Outstanding is always covered by the realm's balance.
func FeeStats() (int64, int64, int64) {
	return lifetimeFeesAccrued, lifetimeFeesClaimed, lifetimeFeesAccrued - lifetimeFeesClaimed
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
		kv("lockSeconds", itoa(ChallengeLockSeconds)),
		kv("graceSeconds", itoa(ResolutionGraceSeconds)),
		kv("maxPoolMultiple", itoa(MaxPoolMultiple)),
		kv("maxMarketStake", itoa(roles.MaxMarketStake)),
		kv("maxAccountStake", itoa(roles.MaxAccountStake)),
		kv("claimCount", itoa(claimCount)),
		kv("totalResolved", itoa(totalResolved)),
		kv("lifetimeFeesAccrued", itoa(lifetimeFeesAccrued)),
		kv("lifetimeFeesClaimed", itoa(lifetimeFeesClaimed)),
		kv("now", itoa(now())),
	}, ",") + "}"
}

func ClaimJSON(id int64) string { return claimJSON(getClaim(id)) }

// ClaimsJSON lists claims newest first: `offset` skips that many from the newest.
func ClaimsJSON(offset, limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	var out []string
	claims.ReverseIterateByOffset(offset, limit, func(_ string, v any) bool {
		out = append(out, claimJSON(v.(*Claim)))
		return false
	})
	return "[" + strings.Join(out, ",") + "]"
}

// ChallengersJSON lists a claim's challengers in the order they joined.
func ChallengersJSON(id int64) string {
	c := getClaim(id)
	out := make([]string, 0, len(c.challengers))
	for _, ch := range c.challengers {
		out = append(out, "{"+strings.Join([]string{
			kv("address", mimir.Quote(ch.Addr.String())),
			kv("stake", itoa(ch.Stake)),
			kv("at", itoa(ch.At)),
			kv("referrer", mimir.Quote(ch.Referrer.String())),
		}, ",")+"}")
	}
	return "[" + strings.Join(out, ",") + "]"
}

func claimJSON(c *Claim) string {
	ea, eb := eligibleTotals(c)
	p := c.Proposal
	return "{" + strings.Join([]string{
		kv("id", itoa(c.ID)),
		kv("creator", mimir.Quote(c.Creator.String())),
		kv("question", mimir.Quote(c.Question)),
		kv("creatorPosition", mimir.Quote(c.CreatorPosition)),
		kv("counterPosition", mimir.Quote(c.CounterPosition)),
		kv("resolutionUrl", mimir.Quote(c.ResolutionURL)),
		kv("creatorStake", itoa(c.CreatorStake)),
		kv("totalChallengerStake", itoa(c.TotalChallengerStake)),
		kv("reservedCreatorLiability", itoa(c.ReservedCreatorLiability)),
		kv("eligibleCreator", itoa(ea)),
		kv("eligibleChallengers", itoa(eb)),
		kv("deadline", itoa(c.Deadline)),
		kv("state", itoa(int64(c.State))),
		kv("winnerSide", itoa(int64(c.WinnerSide))),
		kv("resolutionSummary", mimir.Quote(c.ResolutionSummary)),
		kv("confidence", itoa(int64(c.Confidence))),
		kv("category", mimir.Quote(c.Category)),
		kv("parentId", itoa(c.ParentID)),
		kv("challengerCount", itoa(int64(len(c.challengers)))),
		kv("createdAt", itoa(c.CreatedAt)),
		kv("marketType", mimir.Quote(c.MarketType)),
		kv("oddsMode", mimir.Quote(c.OddsMode)),
		kv("challengerPayoutBps", itoa(c.ChallengerPayoutBps)),
		kv("handicapLine", mimir.Quote(c.HandicapLine)),
		kv("settlementRule", mimir.Quote(c.SettlementRule)),
		kv("maxChallengers", itoa(int64(c.MaxChallengers))),
		kv("isPrivate", boolStr(c.IsPrivate)),
		kv("evidenceHash", mimir.Quote(c.EvidenceHash)),
		kv("referrer", mimir.Quote(c.Referrer.String())),
		kv("entryFees", itoa(c.EntryFees)),
		kv("settlementCutoff", itoa(c.SettlementCutoff)),
		kv("lockAt", itoa(c.LockAt)),
		kv("proposal", "{"+strings.Join([]string{
			kv("winnerSide", itoa(int64(p.WinnerSide))),
			kv("confidence", itoa(int64(p.Confidence))),
			kv("proposedAt", itoa(p.ProposedAt)),
			kv("disputedAt", itoa(p.DisputedAt)),
			kv("disputer", mimir.Quote(p.Disputer.String())),
			kv("bond", itoa(p.Bond)),
			kv("evidenceHash", mimir.Quote(p.EvidenceHash)),
			kv("summary", mimir.Quote(p.Summary)),
		}, ",")+"}"),
	}, ",") + "}"
}

func kv(k, v string) string { return mimir.Quote(k) + ":" + v }
