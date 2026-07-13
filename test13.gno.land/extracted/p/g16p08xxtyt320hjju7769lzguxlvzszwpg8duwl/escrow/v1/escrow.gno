// Package escrow defines a milestone escrow state machine for Gno kits.
//
// # Architecture note (toolchain / Beta)
// Pure packages (/p/) cannot hold a `realm` capability, so they cannot call
// chain/banker.NewBanker. Coin movement is therefore performed by the calling
// *realm* (e.g. bountyboard) using:
//   - chain/runtime/unsafe.OriginSend() on fund
//   - banker.NewBanker(banker.BankerTypeRealmSend, cur) on release/refund
// This package validates amounts/parties/timeouts and updates Deal state only.
// See MarkFunded(sentAmount) and TimeoutRefund.
//
// # State machine
//
//	States: Open | Funded | Released | Refunded | Disputed | Cancelled
//
//	Valid transitions:
//	  Open     --[Fund by client, sentAmount >= AmountUgnot]--> Funded
//	  Open     --[Cancel by client OR worker]-----------------> Cancelled
//	  Funded   --[Release by client]--------------------------> Released
//	  Funded   --[Refund by client]---------------------------> Refunded
//	  Funded   --[Dispute by client OR worker]----------------> Disputed
//	  Funded   --[TimeoutRefund by ANYONE after Deadline]-----> Refunded
//	            (timeout path is permissionless so funds cannot stick forever)
//
//	Invalid (must panic):
//	  Fund when not Open; Fund by non-client; Fund with sentAmount < AmountUgnot
//	  Release/Refund when not Funded; Release/Refund by non-client
//	  Dispute when not Funded; Dispute by third party
//	  Cancel when not Open; Cancel by third party
//	  TimeoutRefund when not Funded / no timeout / before Deadline
//	  Any action after terminal states (Released|Refunded|Disputed|Cancelled)
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

// Deal is one escrow agreement between client (payer) and worker (payee).
type Deal struct {
	ID          string
	Client      string // payer address (bech32)
	Worker      string // payee address (bech32)
	AmountUgnot int64  // required fund amount in ugnot
	// FundedAmount records what was actually accepted at fund time (>= AmountUgnot).
	FundedAmount int64
	Title        string
	State        State
	CreatedAt    int64
	UpdatedAt    int64
	FundedAt     int64
	// TimeoutSecs is duration after FundedAt before TimeoutRefund is allowed.
	// 0 means no automatic timeout path.
	TimeoutSecs int64
	// Deadline = FundedAt + TimeoutSecs when funded with TimeoutSecs > 0.
	Deadline int64
	Note     string
}

// NewDeal creates an open deal. timeoutSecs may be 0 (disabled).
func NewDeal(id, client, worker string, amount int64, title string, now, timeoutSecs int64) Deal {
	if amount <= 0 {
		panic("escrow: amount must be positive")
	}
	if client == "" || worker == "" {
		panic("escrow: client and worker required")
	}
	if timeoutSecs < 0 {
		panic("escrow: timeoutSecs cannot be negative")
	}
	return Deal{
		ID:          id,
		Client:      client,
		Worker:      worker,
		AmountUgnot: amount,
		Title:       title,
		State:       StateOpen,
		CreatedAt:   now,
		UpdatedAt:   now,
		TimeoutSecs: timeoutSecs,
	}
}

// MarkFunded transitions Open → Funded.
// sentAmount is the ugnot received with the fund tx (from OriginSend in the realm).
// Underfunding (sentAmount < AmountUgnot) panics — realm must not keep partial funds
// without an explicit overpay policy (overpay is allowed; excess stays in realm
// balance until refund/release of FundedAmount or realm policy returns leftover).
func MarkFunded(d *Deal, caller string, sentAmount, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateOpen {
		panic("escrow: deal not open")
	}
	if caller != d.Client {
		panic("escrow: only client can fund")
	}
	if sentAmount < d.AmountUgnot {
		panic("escrow: underfunded")
	}
	d.FundedAmount = sentAmount
	d.FundedAt = now
	if d.TimeoutSecs > 0 {
		d.Deadline = now + d.TimeoutSecs
	} else {
		d.Deadline = 0
	}
	d.State = StateFunded
	d.UpdatedAt = now
}

// Release transitions Funded → Released. Only client (payer) may release to worker.
func Release(d *Deal, caller string, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateFunded {
		panic("escrow: deal not funded")
	}
	if caller != d.Client {
		panic("escrow: only client can release")
	}
	d.State = StateReleased
	d.UpdatedAt = now
}

// Refund transitions Funded → Refunded. Only client may refund in v0 (same as release authority).
func Refund(d *Deal, caller string, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateFunded {
		panic("escrow: deal not funded")
	}
	if caller != d.Client {
		panic("escrow: only client can refund")
	}
	d.State = StateRefunded
	d.UpdatedAt = now
	d.Note = "client-refund"
}

// Cancel open deal (client or worker). No funds locked yet.
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

// Dispute marks funded deal as disputed (client or worker).
// Coin disbursement after dispute is out of scope for v0 (manual/arbiter realm).
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

// TimeoutRefund transitions Funded → Refunded after Deadline.
// Permissionless: any caller may trigger once the timeout elapses so funds
// cannot remain stuck if both parties disappear. Realm must send FundedAmount
// back to Client after this returns.
func TimeoutRefund(d *Deal, now int64) {
	if d == nil {
		panic("escrow: nil deal")
	}
	if d.State != StateFunded {
		panic("escrow: deal not funded")
	}
	if d.TimeoutSecs <= 0 || d.Deadline <= 0 {
		panic("escrow: no timeout configured")
	}
	if now < d.Deadline {
		panic("escrow: timeout not reached")
	}
	d.State = StateRefunded
	d.UpdatedAt = now
	d.Note = "timeout-refund"
}

// CanTimeoutRefund is a read-only check for UI / realm guards.
func CanTimeoutRefund(d *Deal, now int64) bool {
	if d == nil || d.State != StateFunded {
		return false
	}
	if d.TimeoutSecs <= 0 || d.Deadline <= 0 {
		return false
	}
	return now >= d.Deadline
}

// PayoutAmount returns ugnot the realm should disburse on release/refund.
func PayoutAmount(d *Deal) int64 {
	if d == nil {
		return 0
	}
	if d.FundedAmount > 0 {
		return d.FundedAmount
	}
	return d.AmountUgnot
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
