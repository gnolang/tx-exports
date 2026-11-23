package vs

import (
	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
)

// Role administration. The rules live in mimir.Roles; see its doc.

func TransferOwnership(cur realm, next address) { roles.TransferOwnership(caller(cur), next, now()) }
func CancelOwnershipTransfer(cur realm)         { roles.CancelOwnershipTransfer(caller(cur)) }
func AcceptOwnership(cur realm)                 { roles.AcceptOwnership(caller(cur), now()) }
func QueueOracle(cur realm, next address)       { roles.QueueOracle(caller(cur), next, now()) }
func RevokeOracle(cur realm)                    { roles.RevokeOracle(caller(cur)) }
func CancelOracle(cur realm)                    { roles.CancelOracle(caller(cur)) }
func ExecuteOracle(cur realm)                   { roles.ExecuteOracle(now()) }
func SetArbiter(cur realm, next address)        { roles.SetArbiter(caller(cur), next) }
func QueueFeeRecipient(cur realm, next address) { roles.QueueFeeRecipient(caller(cur), next, now()) }
func CancelFeeRecipient(cur realm)              { roles.CancelFeeRecipient(caller(cur)) }
func ExecuteFeeRecipient(cur realm)             { roles.ExecuteFeeRecipient(now()) }
func SetPaused(cur realm, p bool)               { roles.SetPaused(caller(cur), p) }
func SetCaps(cur realm, market, account int64)  { roles.SetCaps(caller(cur), market, account) }

// SetAuditAgent appoints the reviewer that may dispute with a bond; "" disables it.
func SetAuditAgent(cur realm, next string) {
	roles.SetAuditAgent(caller(cur), mimir.ParseOptional(next))
}

// ClaimFees pays the caller's accrued fees (entry fees, copy fees, forfeited bonds).
func ClaimFees(cur realm) { claimFeesTo(cur, caller(cur)) }

func ClaimFeesTo(cur realm, to address) {
	if !to.IsValid() {
		panic("ZeroRecipient")
	}
	claimFeesTo(cur, to)
}

func claimFeesTo(cur realm, to address) {
	u := caller(cur)
	amount := counter(&accruedFees, u)
	if amount <= 0 {
		panic("NoFees")
	}
	accruedFees.Set(u.String(), int64(0))
	lifetimeFeesClaimed = mimir.Add(lifetimeFeesClaimed, amount)
	emit("FeeClaimed", "recipient", u.String(), "to", to.String(), "amount", itoa(amount))
	push(cur, to, amount)
}
