package galcredentials

import "time"

// Mint creates a credential for one agent address. The caller becomes the
// owner. Caller identity comes from the crossing frame, never from a
// parameter.
func Mint(cur realm, agent address, perTxLimit int64, dailyLimit int64, runtime string) {
	if !cur.IsCurrent() {
		panic("not a live realm call")
	}
	if _, exists := credentials[agent]; exists {
		panic("credential already exists")
	}
	owner := cur.Previous().Address()
	credentials[agent] = &Credential{
		Agent:      agent,
		Owner:      owner,
		PerTxLimit: perTxLimit,
		DailyLimit: dailyLimit,
		SpentToday: 0,
		LastSpendDay: currentDay(),
		Status:     StatusActive,
		Runtime:    runtime,
		CreatedAt:  time.Now().Unix(),
	}
}

// SetLimits changes the spending limits of a credential. Only the
// credential owner may call it.
func SetLimits(cur realm, agent address, perTxLimit int64, dailyLimit int64) {
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
	cred.PerTxLimit = perTxLimit
	cred.DailyLimit = dailyLimit
}

// Get returns a copy of the credential for an agent address, or false if
// there is none. A copy is returned so callers cannot mutate realm state.
func Get(agent address) (Credential, bool) {
	cred, ok := credentials[agent]
	if !ok {
		return Credential{}, false
	}
	return *cred, true
}
