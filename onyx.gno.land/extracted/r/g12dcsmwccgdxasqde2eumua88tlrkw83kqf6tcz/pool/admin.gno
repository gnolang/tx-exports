package pool

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

// SetAuditAgent appoints the reviewer that may dispute with a bond; "" disables it.
func SetAuditAgent(cur realm, next string) {
	roles.SetAuditAgent(caller(cur), mimir.ParseOptional(next))
}

// SetCaps sets guarded launch caps in net mUSD units (0 = none). They only gate new stakes.
func SetCaps(cur realm, market, account int64) { roles.SetCaps(caller(cur), market, account) }

// SetLockAt closes a market to new stakes early (kickoff), by its creator or
// the owner. Only ever earlier.
func SetLockAt(cur realm, id int64, at int64) {
	m := getMarket(id)
	c := caller(cur)
	if c != m.Creator && c != roles.Owner {
		panic("BadLock")
	}
	if m.State != StOpen || at < now() || at+LockSeconds > m.Deadline {
		panic("BadLock")
	}
	if m.LockAt != 0 && at > m.LockAt {
		panic("BadLock")
	}
	m.LockAt = at
	emit("LockSet", "id", itoa(id), "lockAt", itoa(at))
}
