// Package escrow defines a minimal milestone escrow state machine for Gno kits.
// Actual coin transfers are handled by the calling realm (std.Banker / send).
// This package stays pure: types + transition rules only.
package escrow

// State of an escrow deal.
type State int

const (
	StateOpen State = iota
	StateFunded
	StateReleased
	StateRefunded
	StateDisputed
	StateCancelled
)

// Deal is one escrow agreement between client and worker.
type Deal struct {
	ID          string
	Client      string
	Worker      string
	// AmountUgnot is informational metadata for UI; realm enforces real transfers.
	AmountUgnot int64
	Title       string
	State       State
	CreatedAt   int64
	UpdatedAt   int64
	Note        string
}

// NewDeal creates an open deal.
func NewDeal(id, client, worker string, amount int64, title string, now int64) Deal {
	return Deal{
		ID:          id,
		Client:      client,
		Worker:      worker,
		AmountUgnot: amount,
		Title:       title,
		State:       StateOpen,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
}

// MarkFunded transitions Open → Funded.
func MarkFunded(d *Deal, caller string, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateOpen {
		panic("escrow: deal not open")
	}
	if caller != d.Client {
		panic("escrow: only client can fund")
	}
	d.State = StateFunded
	d.UpdatedAt = now
}

// Release transitions Funded → Released (client or arbiter policy in realm).
func Release(d *Deal, caller string, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateFunded {
		panic("escrow: deal not funded")
	}
	if caller != d.Client {
		panic("escrow: only client can release in v0")
	}
	d.State = StateReleased
	d.UpdatedAt = now
}

// Refund transitions Funded → Refunded.
func Refund(d *Deal, caller string, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateFunded {
		panic("escrow: deal not funded")
	}
	if caller != d.Client {
		panic("escrow: only client can refund in v0")
	}
	d.State = StateRefunded
	d.UpdatedAt = now
}

// Cancel open deal (client or worker).
func Cancel(d *Deal, caller string, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateOpen {
		panic("escrow: only open deals can cancel")
	}
	if caller != d.Client && caller != d.Worker {
		panic("escrow: unauthorized cancel")
	}
	d.State = StateCancelled
	d.UpdatedAt = now
}

// Dispute marks funded deal as disputed.
func Dispute(d *Deal, caller string, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateFunded {
		panic("escrow: only funded deals can dispute")
	}
	if caller != d.Client && caller != d.Worker {
		panic("escrow: unauthorized dispute")
	}
	d.State = StateDisputed
	d.UpdatedAt = now
}

// StateString for Render.
func StateString(s State) string {
	switch s {
	case StateOpen:
		return "open"
	case StateFunded:
		return "funded"
	case StateReleased:
		return "released"
	case StateRefunded:
		return "refunded"
	case StateDisputed:
		return "disputed"
	case StateCancelled:
		return "cancelled"
	default:
		return "unknown"
	}
}
