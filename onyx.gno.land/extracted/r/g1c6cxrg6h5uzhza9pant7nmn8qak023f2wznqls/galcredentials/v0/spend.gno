package galcredentials

import "time"

// SpendDecision is the answer AuthorizeSpend gives to a caller (another
// realm or an off-chain client). It is a plain string so it reads clearly
// in `gnokey` output and in gnoweb, and so another realm can compare it
// directly: `AuthorizeSpend(...) == SpendAllowed`.
type SpendDecision string

const (
	// SpendAllowed: the spend fits the limits and has been counted.
	SpendAllowed SpendDecision = "allowed"
	// SpendDenied: the spend is refused (unknown/suspended/revoked agent,
	// non-positive amount, or over the daily limit). Nothing is counted.
	SpendDenied SpendDecision = "denied"
	// SpendNeedsApproval: the spend is over the per-transaction limit but
	// within the daily limit. Nothing is counted yet; the owner must
	// approve it first (ticket 04).
	SpendNeedsApproval SpendDecision = "needs_approval"
)

const secondsPerDay = 86400

// currentDay is the current block day: block timestamp (time.Now() is the
// block timestamp in Gno) divided into whole days since the Unix epoch.
func currentDay() int64 {
	return time.Now().Unix() / secondsPerDay
}

// rolloverDay resets a credential's daily total when the block day has
// changed since its last spend. This is day-boundary bookkeeping, not
// part of any spend, so it runs before every limit check.
func rolloverDay(cred *Credential) {
	today := currentDay()
	if cred.LastSpendDay != today {
		cred.SpentToday = 0
		cred.LastSpendDay = today
	}
}

// IsActive reports whether an agent has a credential that is currently
// usable. Unknown agents and suspended/revoked credentials are inactive.
// This is the read-only half of the public seam for other realms; it
// never changes state.
func IsActive(agent address) bool {
	cred, ok := credentials[agent]
	if !ok {
		return false
	}
	return cred.Status == StatusActive
}

// AuthorizeSpend is the spending-guard half of the public seam: any other
// realm (or an off-chain caller via `gnokey maketx call`) asks it before
// letting an agent spend, and branches on the answer.
//
//   - SpendAllowed: the spend fits the limits. It is counted in
//     SpentToday immediately, so a second call sees the updated total.
//     (Ticket 03 semantics: the spend is recorded when allowed. The
//     confirm-after-transfer pattern, where a failed transfer must not
//     eat the budget, is a later concern, not this ticket.)
//   - SpendNeedsApproval: over the per-transaction limit but within the
//     daily limit. Nothing is counted; the owner must approve it first
//     (ticket 04 creates the approval record).
//   - SpendDenied: unknown, suspended or revoked agent, a non-positive
//     amount, or a spend that would pass the daily limit. Denied spends
//     never count and never change state (except the day rollover below).
//
// The daily total resets automatically when the block day changes: if the
// stored LastSpendDay differs from today, SpentToday is zeroed first.
// A denied spend on a new day still performs that reset, because the
// reset is day-boundary bookkeeping, not part of the spend itself.
func AuthorizeSpend(cur realm, agent address, amount int64) SpendDecision {
	cred, ok := credentials[agent]
	if !ok {
		return SpendDenied
	}
	if cred.Status != StatusActive {
		return SpendDenied
	}
	if amount <= 0 {
		return SpendDenied
	}
	rolloverDay(cred)
	if amount > cred.PerTxLimit {
		if cred.SpentToday+amount > cred.DailyLimit {
			return SpendDenied
		}
		return SpendNeedsApproval
	}
	if cred.SpentToday+amount > cred.DailyLimit {
		return SpendDenied
	}
	cred.SpentToday += amount
	return SpendAllowed
}
