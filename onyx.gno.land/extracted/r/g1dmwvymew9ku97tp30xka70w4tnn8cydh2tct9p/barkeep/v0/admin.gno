package barkeep

import (
	"chain"
	"chain/runtime"
	"time"

	"gno.land/p/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/renown/v0"
)

// Admin returns the current admin address.
func Admin() address { return admin }

// PendingAdmin returns the address that may accept the admin role.
func PendingAdmin() address { return pendingAdmin }

func assertAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("barkeep: caller is not the admin")
	}
}

func mustSource(path string) *source {
	s := sourceByPath(path)
	if s == nil {
		panic("barkeep: unknown source " + path)
	}
	return s
}

func logAction(action string, attrs ...string) {
	chain.Emit(action, attrs...)
	text := action
	for i := 0; i+1 < len(attrs); i += 2 {
		text += " " + attrs[i] + "=" + attrs[i+1]
	}
	e := logEntry{ts: time.Now().Unix(), height: runtime.ChainHeight(), action: text}
	if len(adminLog) < MaxAdminLog {
		adminLog = append(adminLog, e)
		return
	}
	for i := 1; i < len(adminLog); i++ {
		adminLog[i-1] = adminLog[i]
	}
	adminLog[len(adminLog)-1] = e
}

// SetSourceTier moves a source between unverified, verified and revoked.
// Verifying a source that has no weight gives it the default weight. A
// revoked or unverified source stops counting toward every score at once,
// because points are kept per source.
func SetSourceTier(cur realm, path, tier string) {
	assertAdmin(cur)
	s := mustSource(path)
	switch tier {
	case TierUnverified, TierVerified, TierRevoked:
	default:
		panic("barkeep: invalid tier " + tier)
	}
	if s.tier != TierVerified && tier == TierVerified {
		verifiedCount++
	} else if s.tier == TierVerified && tier != TierVerified {
		verifiedCount--
	}
	s.tier = tier
	if tier == TierVerified && s.weight == 0 {
		s.weight = params.DefaultWeight
	}
	logAction("SourceTierChanged", "source", path, "tier", tier)
}

// SetWeight sets a source's weight (permille, 0..MaxWeight) and bucket cap
// in whole points.
func SetWeight(cur realm, path string, weight, capPoints int64) {
	assertAdmin(cur)
	s := mustSource(path)
	if weight < 0 || weight > params.MaxWeight {
		panic("barkeep: weight out of range")
	}
	if capPoints <= 0 || capPoints > 1_000_000 {
		panic("barkeep: cap out of range")
	}
	s.weight = weight
	s.capacity = capPoints * renown.Milli
	logAction("SourceWeightChanged", "source", path, "weight", itoa(weight), "cap", itoa(capPoints))
}

// Pause stops or resumes attestations from one source. Existing points of
// a paused source keep counting and decaying.
func Pause(cur realm, path string, paused bool) {
	assertAdmin(cur)
	s := mustSource(path)
	s.paused = paused
	logAction("SourcePaused", "source", path, "paused", boolStr(paused))
}

// PauseAll stops or resumes every attestation.
func PauseAll(cur realm, paused bool) {
	assertAdmin(cur)
	pausedAll = paused
	logAction("BarkeepPaused", "paused", boolStr(paused))
}

// TransferAdmin proposes a new admin. The role moves only after the new
// address calls AcceptAdmin. Proposing the zero address cancels.
func TransferAdmin(cur realm, newAdmin address) {
	assertAdmin(cur)
	if newAdmin != "" && !newAdmin.IsValid() {
		panic("barkeep: invalid admin address")
	}
	pendingAdmin = newAdmin
	logAction("AdminProposed", "pending", newAdmin.String())
}

// AcceptAdmin completes a TransferAdmin.
func AcceptAdmin(cur realm) {
	caller := cur.Previous().Address()
	if pendingAdmin == "" || caller != pendingAdmin {
		panic("barkeep: caller is not the pending admin")
	}
	admin = caller
	pendingAdmin = ""
	logAction("AdminChanged", "admin", caller.String())
}
