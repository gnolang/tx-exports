package mimir

import (
	"chain"
	"strconv"
)

// TimelockSeconds delays ownership, oracle and fee-recipient changes.
const TimelockSeconds = int64(2 * 24 * 60 * 60)

// Roles holds a market realm's roles, pause flag and guarded-launch caps, and
// enforces the same rules the EVM contracts do:
//   - two-step ownership with a timelock;
//   - a timelocked oracle change the owner can revoke at once;
//   - the oracle is never also the owner, the arbiter or the fee recipient;
//   - the audit agent may only dispute, and never holds another role;
//   - a timelocked fee-recipient change;
//   - queued changes are executed by anyone once due.
//
// Every method takes the caller and the block time from the realm, which
// owns the Roles value.
type Roles struct {
	Owner               address
	Arbiter             address
	AuditAgent          address
	Oracle              address
	FeeRecipient        address
	PendingOwner        address
	PendingOwnerEta     int64
	PendingOracle       address
	PendingOracleEta    int64
	PendingFeeRecipient address
	PendingFeeEta       int64
	Paused              bool
	MaxAccountStake     int64
	MaxMarketStake      int64
}

// NewRoles validates the initial roles as the EVM constructors did.
func NewRoles(owner, arbiter, oracle, feeRecipient address) *Roles {
	if !owner.IsValid() || !arbiter.IsValid() || !oracle.IsValid() || !feeRecipient.IsValid() {
		panic("ZeroAddress")
	}
	if oracle == owner || oracle == arbiter || oracle == feeRecipient {
		panic("RoleCollision")
	}
	chain.Emit("OwnershipTransferred", "previous", "", "next", owner.String())
	chain.Emit("ArbiterChanged", "previous", "", "next", arbiter.String())
	chain.Emit("OracleChanged", "previous", "", "next", oracle.String())
	chain.Emit("FeeRecipientChanged", "previous", "", "next", feeRecipient.String())
	return &Roles{Owner: owner, Arbiter: arbiter, Oracle: oracle, FeeRecipient: feeRecipient}
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }

func (r *Roles) AssertOwner(caller address) {
	if caller != r.Owner {
		panic("NotOwner")
	}
}

func (r *Roles) AssertOracle(caller address) {
	if r.Oracle == "" || caller != r.Oracle {
		panic("NotOracle")
	}
}

func (r *Roles) AssertArbiter(caller address) {
	if caller != r.Arbiter {
		panic("NotArbiter")
	}
}

func (r *Roles) AssertNotPaused() {
	if r.Paused {
		panic("IsPaused")
	}
}

func (r *Roles) checkAuditCollision(next address) {
	if next != "" && next == r.AuditAgent {
		panic("RoleCollision")
	}
}

func (r *Roles) TransferOwnership(caller, next address, now int64) {
	r.AssertOwner(caller)
	if !next.IsValid() {
		panic("ZeroAddress")
	}
	r.PendingOwner = next
	r.PendingOwnerEta = now + TimelockSeconds
	chain.Emit("OwnershipTransferStarted", "previous", r.Owner.String(), "next", next.String(), "eta", i64(r.PendingOwnerEta))
}

func (r *Roles) CancelOwnershipTransfer(caller address) {
	r.AssertOwner(caller)
	if r.PendingOwnerEta == 0 {
		panic("NothingQueued")
	}
	chain.Emit("OwnershipTransferCancelled", "pending", r.PendingOwner.String())
	r.PendingOwner = ""
	r.PendingOwnerEta = 0
}

func (r *Roles) AcceptOwnership(caller address, now int64) {
	if r.PendingOwner == "" || caller != r.PendingOwner {
		panic("NotPendingOwner")
	}
	if now < r.PendingOwnerEta {
		panic("Timelocked")
	}
	r.checkAuditCollision(caller)
	chain.Emit("OwnershipTransferred", "previous", r.Owner.String(), "next", caller.String())
	r.Owner = caller
	r.PendingOwner = ""
	r.PendingOwnerEta = 0
}

func (r *Roles) QueueOracle(caller, next address, now int64) {
	r.AssertOwner(caller)
	if !next.IsValid() {
		panic("ZeroAddress")
	}
	if next == r.Owner || next == r.Arbiter || next == r.FeeRecipient {
		panic("RoleCollision")
	}
	r.PendingOracle = next
	r.PendingOracleEta = now + TimelockSeconds
	chain.Emit("OracleChangeQueued", "next", next.String(), "eta", i64(r.PendingOracleEta))
}

// RevokeOracle is the emergency stop: the oracle loses its power at once.
func (r *Roles) RevokeOracle(caller address) {
	r.AssertOwner(caller)
	chain.Emit("OracleChanged", "previous", r.Oracle.String(), "next", "")
	r.Oracle = ""
}

func (r *Roles) CancelOracle(caller address) {
	r.AssertOwner(caller)
	if r.PendingOracleEta == 0 {
		panic("NothingQueued")
	}
	chain.Emit("OracleChangeCancelled", "next", r.PendingOracle.String())
	r.PendingOracle = ""
	r.PendingOracleEta = 0
}

func (r *Roles) ExecuteOracle(now int64) {
	if r.PendingOracleEta == 0 {
		panic("NothingQueued")
	}
	if now < r.PendingOracleEta {
		panic("Timelocked")
	}
	r.checkAuditCollision(r.PendingOracle)
	chain.Emit("OracleChanged", "previous", r.Oracle.String(), "next", r.PendingOracle.String())
	r.Oracle = r.PendingOracle
	r.PendingOracle = ""
	r.PendingOracleEta = 0
}

// SetAuditAgent appoints the reviewer that may dispute with a bond; "" disables it.
func (r *Roles) SetAuditAgent(caller, next address) {
	r.AssertOwner(caller)
	if next != "" && (next == r.Owner || next == r.Arbiter || next == r.Oracle || next == r.FeeRecipient) {
		panic("RoleCollision")
	}
	chain.Emit("AuditAgentChanged", "previous", r.AuditAgent.String(), "next", next.String())
	r.AuditAgent = next
}

func (r *Roles) SetArbiter(caller, next address) {
	r.AssertOwner(caller)
	if !next.IsValid() {
		panic("ZeroAddress")
	}
	if next == r.Oracle {
		panic("RoleCollision")
	}
	r.checkAuditCollision(next)
	chain.Emit("ArbiterChanged", "previous", r.Arbiter.String(), "next", next.String())
	r.Arbiter = next
}

// SetCaps sets guarded launch caps in mUSD units (0 = none). They only gate new positions.
func (r *Roles) SetCaps(caller address, market, account int64) {
	r.AssertOwner(caller)
	if market < 0 || account < 0 {
		panic("BadCap")
	}
	r.MaxMarketStake = market
	r.MaxAccountStake = account
	chain.Emit("CapsChanged", "maxMarketStake", i64(market), "maxAccountStake", i64(account))
}

// CheckCaps panics when an account's stake or a market's total is over its cap.
func (r *Roles) CheckCaps(mine, total int64) {
	if (r.MaxAccountStake != 0 && mine > r.MaxAccountStake) || (r.MaxMarketStake != 0 && total > r.MaxMarketStake) {
		panic("CapExceeded")
	}
}

func (r *Roles) QueueFeeRecipient(caller, next address, now int64) {
	r.AssertOwner(caller)
	if !next.IsValid() {
		panic("ZeroAddress")
	}
	r.PendingFeeRecipient = next
	r.PendingFeeEta = now + TimelockSeconds
	chain.Emit("FeeRecipientQueued", "next", next.String(), "eta", i64(r.PendingFeeEta))
}

func (r *Roles) CancelFeeRecipient(caller address) {
	r.AssertOwner(caller)
	if r.PendingFeeEta == 0 {
		panic("NothingQueued")
	}
	chain.Emit("FeeRecipientCancelled", "next", r.PendingFeeRecipient.String())
	r.PendingFeeRecipient = ""
	r.PendingFeeEta = 0
}

func (r *Roles) ExecuteFeeRecipient(now int64) {
	if r.PendingFeeEta == 0 {
		panic("NothingQueued")
	}
	if now < r.PendingFeeEta {
		panic("Timelocked")
	}
	r.checkAuditCollision(r.PendingFeeRecipient)
	chain.Emit("FeeRecipientChanged", "previous", r.FeeRecipient.String(), "next", r.PendingFeeRecipient.String())
	r.FeeRecipient = r.PendingFeeRecipient
	r.PendingFeeRecipient = ""
	r.PendingFeeEta = 0
}

func (r *Roles) SetPaused(caller address, p bool) {
	r.AssertOwner(caller)
	r.Paused = p
	if p {
		chain.Emit("Paused", "paused", "true")
	} else {
		chain.Emit("Paused", "paused", "false")
	}
}

// ParseOptional reads an optional address argument: "" means none.
func ParseOptional(s string) address {
	if s == "" {
		return ""
	}
	a := address(s)
	if !a.IsValid() {
		panic("BadAddress")
	}
	return a
}
