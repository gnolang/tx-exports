package galcredentials

import "chain/runtime"

// ApprovalStatus is the lifecycle state of a spend approval.
type ApprovalStatus string

const (
	// ApprovalPending: created, awaiting the owner's decision.
	ApprovalPending ApprovalStatus = "pending"
	// ApprovalApproved: approved once by the owner; the amount was counted.
	ApprovalApproved ApprovalStatus = "approved"
	// ApprovalRejected: rejected by the owner; nothing was counted.
	ApprovalRejected ApprovalStatus = "rejected"
)

// Approval is one over-limit spend waiting for (or decided by) the owner.
type Approval struct {
	ID int64
	Agent address
	Amount int64
	Status ApprovalStatus
	// CreatedHeight is the block height the approval was requested at.
	CreatedHeight int64
	// ExpiresHeight is the last block height at which the approval may
	// still be approved. After that height it is permanently unusable.
	// Expired approvals stay stored as "pending" but the expiry check in
	// Approve always fails for them, so they can never be used.
	ExpiresHeight int64
}

// approvalWindowBlocks is how long a pending approval stays usable:
// 1000 blocks from creation. That is long enough for an owner to see the
// request and act on it, and short enough that an approval created in the
// moment cannot be replayed much later.
const approvalWindowBlocks = 1000

var approvals = map[int64]*Approval{}
var nextApprovalID int64 = 1

// RequestApproval asks the owner to approve a spend that is over the
// per-transaction limit. It mirrors the needs-approval branch of
// AuthorizeSpend: the credential must exist and be active, the amount
// must be positive, over the per-transaction limit, and still within the
// daily limit (after the daily rollover). Anything else panics, so no
// approval record is created for a spend that would be denied outright.
// Requesting creates no spending power and counts nothing; only the
// owner can approve (Approve) or reject (Reject). Any caller may
// request, typically the agent itself or the app acting for it.
// It returns the approval ID.
func RequestApproval(cur realm, agent address, amount int64) int64 {
	cred, ok := credentials[agent]
	if !ok {
		panic("credential not found")
	}
	if cred.Status != StatusActive {
		panic("credential not active")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	rolloverDay(cred)
	if amount <= cred.PerTxLimit {
		panic("spend does not need approval")
	}
	if cred.SpentToday+amount > cred.DailyLimit {
		panic("spend exceeds daily limit")
	}
	id := nextApprovalID
	nextApprovalID++
	height := runtime.ChainHeight()
	approvals[id] = &Approval{
		ID:            id,
		Agent:         agent,
		Amount:        amount,
		Status:        ApprovalPending,
		CreatedHeight: height,
		ExpiresHeight: height + approvalWindowBlocks,
	}
	return id
}

// GetApproval returns a copy of the approval for an ID, or false if
// there is none. A copy is returned so callers cannot mutate realm state.
func GetApproval(approvalID int64) (Approval, bool) {
	ap, ok := approvals[approvalID]
	if !ok {
		return Approval{}, false
	}
	return *ap, true
}

// Approve authorizes a pending spend, exactly once. Only the credential
// owner may call it (caller from the crossing frame). The amount is
// counted into SpentToday at approve time, and only if the credential
// is still active and the amount still fits the daily limit then —
// other spends since the request may have eaten the budget, so the
// check is re-run here, after the daily rollover. Every failure panics
// (which rolls back state in Gno), so a failed approve counts nothing:
// unknown ID, non-owner, already decided, expired, suspended/revoked
// credential, or an amount that no longer fits the daily limit.
func Approve(cur realm, approvalID int64) {
	ap, ok := approvals[approvalID]
	if !ok {
		panic("approval not found")
	}
	cred, ok := credentials[ap.Agent]
	if !ok {
		panic("credential not found")
	}
	if cred.Owner != cur.Previous().Address() {
		panic("not credential owner")
	}
	if ap.Status != ApprovalPending {
		panic("approval not pending")
	}
	if runtime.ChainHeight() > ap.ExpiresHeight {
		panic("approval expired")
	}
	if cred.Status != StatusActive {
		panic("credential not active")
	}
	rolloverDay(cred)
	if cred.SpentToday+ap.Amount > cred.DailyLimit {
		panic("spend exceeds daily limit")
	}
	cred.SpentToday += ap.Amount
	ap.Status = ApprovalApproved
}

// Reject closes a pending approval without authorizing the spend:
// nothing is counted. Only the credential owner may call it (caller
// from the crossing frame). Rejecting an already-decided approval
// panics. Rejecting an expired approval is allowed: it is already dead,
// and closing it just tidies the record.
func Reject(cur realm, approvalID int64) {
	ap, ok := approvals[approvalID]
	if !ok {
		panic("approval not found")
	}
	cred, ok := credentials[ap.Agent]
	if !ok {
		panic("credential not found")
	}
	if cred.Owner != cur.Previous().Address() {
		panic("not credential owner")
	}
	if ap.Status != ApprovalPending {
		panic("approval not pending")
	}
	ap.Status = ApprovalRejected
}
