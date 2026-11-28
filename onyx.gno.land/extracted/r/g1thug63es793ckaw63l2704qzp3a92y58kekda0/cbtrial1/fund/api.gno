package fund

import "chain/runtime"

// Read-only views for the nominee realm and other readers. They return
// values only, never pointers to the fund's state.

// Address is the fund's own address (the spender to Approve on tUSD).
func Address() address { return fundAddr() }

// Path is the fund's package path.
func Path() string { return selfPath }

// CurrentPeriod returns the dealing period number and whether it is open
// for orders.
func CurrentPeriod() (n int64, open bool) { return cur0.n, cur0.state == stateOpen }

// Roles returns the fund's role holders (fixed at Launch).
func Roles() (mgr, admin, rev, off address) { return manager, administrator, reviewer, officer }

// NomineeTotals returns how many nominee sub-accounts hold shares, and how
// many shares they hold together.
func NomineeTotals() (accounts, shares int64) { return nomineeAccounts, nomineeShares }

// CheckAgent panics unless the current transaction is signed by the fund's
// registered screening-agent session, belonging to master, limited to this
// fund's realms, expiring no later than the registered expiry. The nominee calls it with its
// own cur.Previous().Address(). It reveals nothing and changes nothing.
func CheckAgent(master address) {
	addr, expiresAt, allow, isSession := runtime.GetSessionInfo()
	if !isSession {
		panic("screening agent: session key required")
	}
	if !launched || addr != agentSession {
		panic("screening agent: unregistered session key")
	}
	requireNotClosed() // review 3, m5
	if master != officer {
		panic("screening agent: session must belong to the compliance officer")
	}
	if len(allow) == 0 {
		panic("screening agent: session must be limited to this realm")
	}
	for _, p := range allow {
		if p != "vm/exec:"+selfPath {
			panic("screening agent: session must be limited to this realm")
		}
	}
	if expiresAt <= 0 || expiresAt > agentExpiry {
		panic("screening agent: session must expire no later than the registered expiry")
	}
}

// Auditor returns the auditor's address.
func Auditor() address { return auditor }

// Launched reports whether the fund has launched (its roles are fixed).
func Launched() bool { return launched }

// IsRoleOrFundAccount reports whether a holds a fund role, is the deployer,
// or is one of the fund's own accounts (the nominee checks its operator).
func IsRoleOrFundAccount(a address) bool { return isRole(a) || isFundAccount(a) }

// Status returns the board-level state: dealing suspended until (unix
// seconds, 0 if not), closed to subscriptions, winding down, closed.
func Status() (suspendedUntilUnix int64, subscriptionsClosedNow, windingDownNow, closed bool) {
	// A wind-down counts from its approval (review 3, m4).
	return suspendedUntil, subscriptionsClosed, windingDown || windDownApproved, cur0.state == stateClosed
}

// HighWaterMark returns a holder's performance-fee mark (per share).
func HighWaterMark(holderAddr address) int64 {
	if h := getHolder(holderAddr); h != nil {
		return h.hwm
	}
	return 0
}
