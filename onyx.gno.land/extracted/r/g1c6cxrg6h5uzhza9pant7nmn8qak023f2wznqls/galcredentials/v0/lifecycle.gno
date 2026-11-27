package galcredentials

// Suspend pauses a credential: while suspended, IsActive reports false
// and AuthorizeSpend denies every spend, and pending approvals cannot be
// approved (Approve checks the status). Only the credential owner may
// call it (caller from the crossing frame). The credential must exist
// and be active; suspending an already-suspended or revoked credential
// panics, so a failed suspend changes nothing.
func Suspend(cur realm, agent address) {
	if !cur.IsCurrent() {
		panic("not a live realm call")
	}
	cred, ok := credentials[agent]
	if !ok {
		panic("credential not found")
	}
	if cred.Owner != cur.Previous().Address() {
		panic("not credential owner")
	}
	if cred.Status != StatusActive {
		panic("credential not active")
	}
	cred.Status = StatusSuspended
}

// Reactivate brings a suspended credential back to active, so the agent
// may spend again under its limits (spending already counted before the
// suspension is kept). Only the credential owner may call it. The
// credential must exist and be suspended; reactivating an active or
// revoked credential panics.
func Reactivate(cur realm, agent address) {
	if !cur.IsCurrent() {
		panic("not a live realm call")
	}
	cred, ok := credentials[agent]
	if !ok {
		panic("credential not found")
	}
	if cred.Owner != cur.Previous().Address() {
		panic("not credential owner")
	}
	if cred.Status != StatusSuspended {
		panic("credential not suspended")
	}
	cred.Status = StatusActive
}

// Revoke is the kill switch: it permanently disables a credential. A
// revoked credential can never spend again, can never be reactivated,
// and can never be suspended. Only the credential owner may call it.
// The credential must exist and not already be revoked; revoking an
// already-revoked credential panics. A suspended credential may be
// revoked directly, without reactivating it first.
func Revoke(cur realm, agent address) {
	if !cur.IsCurrent() {
		panic("not a live realm call")
	}
	cred, ok := credentials[agent]
	if !ok {
		panic("credential not found")
	}
	if cred.Owner != cur.Previous().Address() {
		panic("not credential owner")
	}
	if cred.Status == StatusRevoked {
		panic("credential already revoked")
	}
	cred.Status = StatusRevoked
}
