// Package spendpolicy decides whether a payment an agent asks for may go out now, must wait for the owner, or is refused.
//
// It is pure: no state, no banker, no time source. The caller passes the policy, the tab's current state and the request
// (with the block time), and gets a Decision back. Any realm can import it to put spending limits on a key it does not
// fully trust: an AI agent, a session key, a bot.
//
// Checks run in a fixed order and the first hit wins. Hard limits (Deny) come before soft limits (Hold), so an owner
// approval can lift a Hold but never a Deny:
//
//	Deny: frozen, policy expired, session expired, amount <= 0, payee not on the list, more than the balance, overflow
//	Hold: payee address still in its hold period, more than the per-payment cap, more than what is left of the daily cap
//	Allow: everything else
package spendpolicy

import (
	"math/overflow"
	"strconv"
)

// Kind is the outcome of a check.
type Kind int

const (
	Allow Kind = iota
	Hold
	Deny
)

func (k Kind) String() string {
	switch k {
	case Allow:
		return "allow"
	case Hold:
		return "hold"
	case Deny:
		return "deny"
	}
	return "unknown"
}

// Day is the length of the daily-cap window, in seconds. Days start at 00:00 UTC (block time).
const Day = int64(86400)

// MaxPayees bounds the allowlist so a check stays cheap.
const MaxPayees = 32

// Payee is one allowed destination. UsableAt is the unix time from which payments to Addr go out without a hold;
// a new payee, or a payee whose address changed, gets UsableAt = now + PayeeHoldSecs.
type Payee struct {
	Name     string
	Addr     address
	UsableAt int64
}

// Policy is what the owner sets. Amounts are in the smallest unit of one denom (ugnot).
type Policy struct {
	PerPayment    int64 // largest single payment that goes out without approval
	DailyCap      int64 // total per UTC day that goes out without approval
	PayeeHoldSecs int64 // wait before a new or changed payee address is usable
	ExpiresAt     int64 // unix time after which every order is refused; 0 = never
	Payees        []Payee
}

// State is what the tab holds now.
type State struct {
	Balance    int64
	SpentToday int64 // spent on day SpentDay
	SpentDay   int64 // DayOf(time) of the last payment
	Frozen     bool
}

// Request is one order. Now is the block time. SessionExpiresAt is the expiry of the session key that signed the order
// (0 = not a session, or a session without expiry). OwnerApproved lifts Hold outcomes, never Deny outcomes.
type Request struct {
	To               address
	Amount           int64
	Now              int64
	SessionExpiresAt int64
	OwnerApproved    bool
}

// Decision is the outcome plus a short machine-readable reason ("" for Allow).
type Decision struct {
	Kind   Kind
	Reason string
}

func (d Decision) String() string {
	if d.Reason == "" {
		return d.Kind.String()
	}
	return d.Kind.String() + ":" + d.Reason
}

// Reasons.
const (
	ReasonFrozen         = "frozen"
	ReasonExpired        = "policy-expired"
	ReasonSessionExpired = "session-expired"
	ReasonBadAmount      = "bad-amount"
	ReasonUnknownPayee   = "unknown-payee"
	ReasonNoFunds        = "insufficient-balance"
	ReasonOverflow       = "overflow"
	ReasonPayeeHold      = "payee-hold"
	ReasonOverPayment    = "over-per-payment"
	ReasonOverDaily      = "over-daily-cap"
)

// DayOf returns the UTC day number of a unix time.
func DayOf(t int64) int64 {
	if t < 0 {
		return (t - Day + 1) / Day
	}
	return t / Day
}

// SpentOn returns what the state has spent on the day of time now (0 once the day rolled over).
func SpentOn(s State, now int64) int64 {
	if s.SpentDay == DayOf(now) {
		return s.SpentToday
	}
	return 0
}

// FindPayee returns the allowlist entry for addr.
func FindPayee(p Policy, addr address) (Payee, bool) {
	for _, py := range p.Payees {
		if py.Addr == addr {
			return py, true
		}
	}
	return Payee{}, false
}

// Check decides one order. It never panics on bad input; bad input is a Deny.
func Check(p Policy, s State, r Request) Decision {
	if s.Frozen {
		return Decision{Deny, ReasonFrozen}
	}
	if p.ExpiresAt > 0 && r.Now >= p.ExpiresAt {
		return Decision{Deny, ReasonExpired}
	}
	if r.SessionExpiresAt > 0 && r.Now >= r.SessionExpiresAt {
		return Decision{Deny, ReasonSessionExpired}
	}
	if r.Amount <= 0 {
		return Decision{Deny, ReasonBadAmount}
	}
	payee, ok := FindPayee(p, r.To)
	if !ok {
		return Decision{Deny, ReasonUnknownPayee}
	}
	if r.Amount > s.Balance {
		return Decision{Deny, ReasonNoFunds}
	}
	spent := SpentOn(s, r.Now)
	after, ok := overflow.Add64(spent, r.Amount)
	if !ok || spent < 0 {
		return Decision{Deny, ReasonOverflow}
	}
	if r.OwnerApproved {
		return Decision{Allow, ""}
	}
	if r.Now < payee.UsableAt {
		return Decision{Hold, ReasonPayeeHold}
	}
	if r.Amount > p.PerPayment {
		return Decision{Hold, ReasonOverPayment}
	}
	if after > p.DailyCap {
		return Decision{Hold, ReasonOverDaily}
	}
	return Decision{Allow, ""}
}

// Record returns the state after a payment of amount at time now went out. Call it only after an Allow (or an
// approved Hold) actually paid. It panics on misuse, because a wrong ledger is worse than a failed tx.
func Record(s State, amount int64, now int64) State {
	if amount <= 0 || amount > s.Balance {
		panic("spendpolicy: bad record amount")
	}
	spent := SpentOn(s, now)
	s.SpentToday = overflow.Add64p(spent, amount)
	s.SpentDay = DayOf(now)
	s.Balance -= amount
	return s
}

// Validate reports the first problem with a policy, or "" if it is usable.
func Validate(p Policy) string {
	if p.PerPayment < 0 || p.DailyCap < 0 || p.PayeeHoldSecs < 0 || p.ExpiresAt < 0 {
		return "negative value"
	}
	if p.PerPayment > p.DailyCap {
		return "per-payment cap above daily cap"
	}
	if len(p.Payees) > MaxPayees {
		return "more than " + strconv.Itoa(MaxPayees) + " payees"
	}
	for i, a := range p.Payees {
		if err := ValidName(a.Name); err != "" {
			return err
		}
		if !a.Addr.IsValid() {
			return "invalid address for payee " + a.Name
		}
		for _, b := range p.Payees[i+1:] {
			if a.Name == b.Name {
				return "duplicate payee name " + a.Name
			}
			if a.Addr == b.Addr {
				return "duplicate payee address " + a.Addr.String()
			}
		}
	}
	return ""
}

// ValidName accepts 1-32 characters of a-z, 0-9, '-' and '_' (names show in gnoweb and in txlink URLs).
func ValidName(name string) string {
	if len(name) == 0 || len(name) > 32 {
		return "payee name must be 1-32 characters"
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return "payee name may use a-z, 0-9, - and _ only"
		}
	}
	return ""
}
