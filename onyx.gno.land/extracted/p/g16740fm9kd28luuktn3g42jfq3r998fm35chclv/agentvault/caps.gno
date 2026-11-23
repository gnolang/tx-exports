// Package agentvault is the reusable spend-cap library behind the
// AgentVault realm: the first wallet an AI agent cannot drain.
//
// It is pure: no realm state, no chain calls, no imports from any
// realm. Every function takes explicit inputs (including the current
// unix time for day rollovers) so the logic is unit-testable without
// a chain. The vault realm in
// gno.land/r/g16740fm9kd28luuktn3g42jfq3r998fm35chclv/agentvault
// stores AgentBudget values and calls these functions; any other
// realm can import this package and get the same caps.
package agentvault

// DaySeconds is the length of one daily budget window, in seconds.
// Days are wall-clock UTC days counted from the Unix epoch.
const DaySeconds = int64(86400)

// AgentBudget is one agent's spend limit. It is a plain value type:
// the owning realm stores it and passes it back in. SpentToday and
// DayIndex are bookkeeping the realm must not forge; RefreshDay is
// the only function that moves them, and only forward in time.
type AgentBudget struct {
	PerTxCap   int64 // max ugnot in a single spend
	DailyCap   int64 // max ugnot per day
	SpentToday int64 // ugnot already spent in DayIndex
	DayIndex   int64 // unix day (nowUnix / DaySeconds) SpentToday belongs to
}

// Attempt is one entry in a vault's append-only spend log. Allowed
// false means the guard stopped the spend; Reason names why, so the
// blocked attempt is evidence, not just a failed transaction.
type Attempt struct {
	ID      int64
	Kind    string // "spend", "escrow", "release", "refund", "fund"
	Agent   address
	Name    string // resolved agent name, if the attempt named one
	Amount  int64
	Purpose string
	Allowed bool
	Reason  string
	Day     int64 // unix day of the attempt
}

// EscrowStatus is the lifecycle state of a name payment held in escrow.
type EscrowStatus int

const (
	EscrowHeld EscrowStatus = iota
	EscrowReleased
	EscrowRefunded
)

// Escrow is one name payment held by the vault until the named
// recipient confirms delivery (release) or the owner refunds it
// after the deadline block (refund). The coins never leave the vault
// while held; release sends them, refund only flips the status.
type Escrow struct {
	ID             int64
	Payer          address
	RecipientName  string
	Recipient      address
	Amount         int64
	DeadlineHeight int64
	Status         EscrowStatus
}

// DayIndex returns the unix day for a unix timestamp.
func DayIndex(nowUnix int64) int64 {
	return nowUnix / DaySeconds
}

// ValidateCaps reports "" when a cap pair is usable, otherwise the
// reason it is not. Both caps must be positive and the
// per-transaction cap must not exceed the daily cap (a per-tx cap
// above the daily cap could never be spent in full).
func ValidateCaps(perTxCap, dailyCap int64) string {
	if perTxCap <= 0 {
		return "per-transaction cap must be positive"
	}
	if dailyCap <= 0 {
		return "daily cap must be positive"
	}
	if perTxCap > dailyCap {
		return "per-transaction cap must not exceed daily cap"
	}
	return ""
}

// NewBudget builds a budget. Callers must validate first with
// ValidateCaps; an invalid pair panics rather than silently
// installing a budget that can never be spent.
func NewBudget(perTxCap, dailyCap int64) AgentBudget {
	if reason := ValidateCaps(perTxCap, dailyCap); reason != "" {
		panic(reason)
	}
	return AgentBudget{PerTxCap: perTxCap, DailyCap: dailyCap}
}

// RefreshDay resets SpentToday when the day has rolled over. Call it
// before CheckSpend so a stale day never blocks a new day's spend.
// It only ever moves the day forward and clears the spent amount;
// it never restores spent funds.
func RefreshDay(b *AgentBudget, nowUnix int64) {
	day := DayIndex(nowUnix)
	if b.DayIndex != day {
		b.SpentToday = 0
		b.DayIndex = day
	}
}

// CheckSpend reports whether amount may be spent under this budget.
// It does not mutate the budget; call RefreshDay first, then
// ApplySpend after a successful check. The order of the checks is
// deliberate: the cheapest, most specific rejection comes first so
// the logged reason tells the agent exactly which limit it hit.
func CheckSpend(b AgentBudget, amount int64) (bool, string) {
	if amount <= 0 {
		return false, "amount must be positive"
	}
	if amount > b.PerTxCap {
		return false, "exceeds per-transaction cap"
	}
	if b.SpentToday+amount > b.DailyCap {
		return false, "exceeds daily cap"
	}
	return true, "ok"
}

// ApplySpend records a spend that already passed CheckSpend.
func ApplySpend(b *AgentBudget, amount int64) {
	b.SpentToday += amount
}

// RemainingToday returns how much of the daily cap is left.
func RemainingToday(b AgentBudget, nowUnix int64) int64 {
	if DayIndex(nowUnix) != b.DayIndex {
		return b.DailyCap
	}
	rem := b.DailyCap - b.SpentToday
	if rem < 0 {
		return 0
	}
	return rem
}

// EscrowRefundable reports whether a held escrow may be refunded:
// the deadline block has passed and it is still held. A released or
// already-refunded escrow is never refundable again.
func EscrowRefundable(e Escrow, height int64) bool {
	return e.Status == EscrowHeld && height > e.DeadlineHeight
}

// EscrowStatusString renders an escrow status for the log and the
// Render page.
func EscrowStatusString(s EscrowStatus) string {
	switch s {
	case EscrowHeld:
		return "HELD"
	case EscrowReleased:
		return "RELEASED"
	case EscrowRefunded:
		return "REFUNDED"
	default:
		return "UNKNOWN"
	}
}
