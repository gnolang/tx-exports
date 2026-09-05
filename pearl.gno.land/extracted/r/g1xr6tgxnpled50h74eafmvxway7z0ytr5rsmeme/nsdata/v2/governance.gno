package nsdata

import (
	"strconv"
	"time"

	"chain"

	"gno.land/p/nt/avl/v0"
)

// Governance and emergency response for a realm that can never be
// redeployed. Everything here is callable ONLY by a direct wallet
// transaction — never through a logic realm — so a compromised or buggy
// logic realm can never touch it.
//
// Three powers, deliberately not held by the same key:
//
//   admin     — day-to-day authority: grants/revokes logic realms, tunes
//               config. The warm key.
//   recovery  — cannot operate the registry at all. Can only rotate
//               admin, cancel a pending change, revoke a logic realm,
//               and pause. MUST be a multisig in production; see the
//               trust note below for why that is not optional.
//   guardian  — can ONLY pause. Nothing else. Safe to keep hot (a
//               monitoring bot), because its compromise costs an
//               outage, never the registry.
//
// GRANTING POWER IS SLOW, REVOKING IT IS INSTANT. Handing authority to a
// new admin or a new logic realm goes through a timelock. Revocation and
// pause are immediate. An attacker holding one key cannot act instantly:
// they must announce and wait, and every step emits an event.
//
// EACH ROLE CAN ROTATE THE OTHER, AND NEITHER CAN VETO ITS OWN
// REPLACEMENT. A recovery-initiated admin rotation can be cancelled only
// by recovery; an admin-initiated recovery rotation only by admin. That
// symmetry is what stops a compromised key from blocking its own
// eviction. Proposals live in PER-KIND slots so an admin rotation and a
// recovery rotation can never contend for the same slot — an earlier
// single-slot design let one in-flight proposal freeze the entire
// governance surface, which meant the honest key could not even propose
// a response.
//
// THE TRUST ASYMMETRY THAT REMAINS, stated honestly rather than papered
// over. Both roles rotate the other on the same timelock, so if both
// propose at once the one that proposed FIRST matures first and wins.
// An attacker who steals a key acts before the operator notices, so they
// generally propose first. That makes a stolen key a genuine loss of the
// registry, for EITHER role, and no arrangement of timelocks inside this
// realm fixes it: every asymmetry that would let one role out-race the
// other hands the mirror-image power to whoever steals that role instead.
//
// The mitigation is therefore operational, not contractual:
//   - recovery MUST be a multisig, so no single stolen key can use it;
//   - timelockDelay must be long enough that you will actually notice an
//     event within it;
//   - watch for GovernanceProposed and treat one you did not initiate as
//     an active incident: Pause immediately, then race a counter-rotation
//     while you still have a key the attacker does not.
// Pause does NOT stop ExecutePending — it stops registry mutations, which
// limits damage but does not stop a rotation. Do not rely on it for that.
type pendingOp struct {
	kind string // "admin" | "recovery" | "grantLogic" | "delay"
	addr address
	dur  time.Duration
	at   time.Time // when it becomes executable

	// protectorRole names the role that has EXCLUSIVE control of this
	// proposal — "" means either admin or recovery may cancel it. Set to
	// "recovery" on a recovery-initiated admin rotation, and to "admin"
	// on an admin-initiated recovery rotation, so the role being replaced
	// cannot veto its own replacement.
	protectorRole string
}

var (
	recovery address
	guardian address
	paused   bool

	// Delay applied to every power-granting change. Starts at zero so
	// local development and initial wiring are not painful; raise it
	// before the registry holds anything worth stealing. Changing it is
	// itself timelocked, or an attacker would simply set it to zero.
	timelockDelay time.Duration

	// Upper bound on timelockDelay. Without it, one execution of an
	// absurd delay would stamp every FUTURE proposal with an unreachable
	// maturity and permanently brick governance in a realm that cannot be
	// redeployed. Settable, but itself bounded by absoluteMaxTimelock.
	maxTimelockDelay = 30 * 24 * time.Hour

	// One genuine hard ceiling: a bound that could itself be raised
	// without limit would not be a bound.
	absoluteMaxTimelock = 365 * 24 * time.Hour

	// Per-kind proposal slots, keyed by kind. Per-kind rather than a
	// single slot so that one in-flight proposal cannot freeze the whole
	// governance surface.
	pendingOps avl.Tree

	// If this registry is ever abandoned in favour of a successor
	// deployment, this is how readers discover where it went.
	successor string
)

// -- role checks --

func assertIsAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("nsdata: restricted to admin")
	}
}

func assertIsAdminOrRecovery(cur realm) {
	a := cur.Previous().Address()
	if a != admin && a != recovery {
		panic("nsdata: restricted to admin or recovery")
	}
}

func assertCanPause(cur realm) {
	a := cur.Previous().Address()
	if a != admin && a != recovery && a != guardian {
		panic("nsdata: restricted to admin, recovery or guardian")
	}
}

// -- emergency stop --

// Pause halts every registry mutation. Reads are unaffected, so names
// stay resolvable while writes are frozen.
//
// It deliberately does NOT gate ExecutePending: governance must keep
// working during an incident, and gating it would achieve nothing anyway
// because Unpause is available to both privileged roles, so whoever
// holds a stolen key would simply unpause.
func Pause(cur realm) {
	assertCanPause(cur)
	paused = true
	chain.Emit("Paused", "by", cur.Previous().Address().String())
}

// Unpause excludes the guardian: a hot key that can stop the system must
// not also be able to restart it.
func Unpause(cur realm) {
	assertIsAdminOrRecovery(cur)
	paused = false
	chain.Emit("Unpaused", "by", cur.Previous().Address().String())
}

func IsPaused() bool { return paused }

// -- trusted logic realms (a set, not a single slot) --

func IsTrustedLogic(addr address) bool {
	return trustedLogicSet.Get(addr.String()) != nil
}

func ListTrustedLogic() string {
	out := ""
	trustedLogicSet.Iterate("", "", func(key string, v any) bool {
		if out != "" {
			out += ","
		}
		out += key
		return false
	})
	return out
}

// RevokeTrustedLogic is INSTANT and available to the guardian, because
// cutting off a misbehaving logic realm is the emergency action that must
// never wait on a timelock.
func RevokeTrustedLogic(cur realm, logicAddr address) {
	assertCanPause(cur)
	trustedLogicSet.Remove(logicAddr.String())
	chain.Emit("TrustedLogicRevoked", "addr", logicAddr.String(), "by", cur.Previous().Address().String())
}

// -- timelocked proposals --

// ProposeAdminTransfer starts an admin rotation. When recovery initiates
// it, only recovery may cancel it — the admin being replaced gets no veto
// over their own replacement.
func ProposeAdminTransfer(cur realm, newAdmin address) {
	assertIsAdminOrRecovery(cur)
	if !newAdmin.IsValid() {
		panic("nsdata: invalid address")
	}
	role := ""
	if cur.Previous().Address() == recovery && recovery != admin {
		role = "recovery"
	}
	setPending(cur, &pendingOp{kind: "admin", addr: newAdmin, protectorRole: role})
}

// ProposeRecoveryTransfer is the mirror image: when admin initiates it,
// only admin may cancel it, so a compromised recovery key cannot block
// its own replacement either.
func ProposeRecoveryTransfer(cur realm, newRecovery address) {
	assertIsAdminOrRecovery(cur)
	if !newRecovery.IsValid() {
		panic("nsdata: invalid address")
	}
	role := ""
	if cur.Previous().Address() == admin && recovery != admin {
		role = "admin"
	}
	setPending(cur, &pendingOp{kind: "recovery", addr: newRecovery, protectorRole: role})
}

func ProposeTrustedLogicGrant(cur realm, logicAddr address) {
	assertIsAdmin(cur)
	if !logicAddr.IsValid() {
		panic("nsdata: invalid address")
	}
	setPending(cur, &pendingOp{kind: "grantLogic", addr: logicAddr})
}

// ProposeTimelockDelay is bounded on BOTH sides. An unbounded delay would
// let a single execution stamp every future proposal with an unreachable
// maturity, permanently disabling governance in an unredeployable realm.
func ProposeTimelockDelay(cur realm, seconds int64) {
	assertIsAdmin(cur)
	if seconds < 0 {
		panic("nsdata: delay cannot be negative")
	}
	d := time.Duration(seconds) * time.Second
	// Guard the multiplication itself, not just the input: seconds is
	// attacker-chosen and time.Duration is int64 nanoseconds, so a large
	// value would overflow to a negative (instantly-mature) delay.
	if seconds > int64(absoluteMaxTimelock/time.Second) || d < 0 || d > maxTimelockDelay {
		panic("nsdata: delay out of range")
	}
	setPending(cur, &pendingOp{kind: "delay", dur: d})
}

// SetMaxTimelockDelay raises or lowers the ceiling on timelockDelay.
// Bounded by absoluteMaxTimelock, and it cannot be set below the delay
// currently in force.
func SetMaxTimelockDelay(cur realm, seconds int64) {
	assertIsAdminOrRecovery(cur)
	d := time.Duration(seconds) * time.Second
	if seconds < 0 || d < 0 || d > absoluteMaxTimelock || d < timelockDelay {
		panic("nsdata: max delay out of range")
	}
	maxTimelockDelay = d
	chain.Emit("MaxTimelockDelaySet", "seconds", strconv.FormatInt(int64(d/time.Second), 10))
}

func canControl(op *pendingOp, caller address) bool {
	switch op.protectorRole {
	case "recovery":
		return caller == recovery
	case "admin":
		return caller == admin
	default:
		return caller == admin || caller == recovery
	}
}

func getPendingOp(kind string) *pendingOp {
	if v := pendingOps.Get(kind); v != nil {
		return v.(*pendingOp)
	}
	return nil
}

func setPending(cur realm, op *pendingOp) {
	caller := cur.Previous().Address()
	if existing := getPendingOp(op.kind); existing != nil {
		// You may replace only what you could cancel. Slots are per-kind,
		// so this contends only with another proposal of the SAME kind.
		if !canControl(existing, caller) {
			panic("nsdata: a change of this kind is pending and you may not replace it")
		}
		chain.Emit("GovernanceDisplaced", "kind", existing.kind)
	}
	op.at = time.Now().Add(timelockDelay)
	pendingOps.Set(op.kind, op)
	chain.Emit("GovernanceProposed",
		"kind", op.kind,
		"addr", op.addr.String(),
		"executableAt", op.at.Format(time.RFC3339),
		"by", caller.String())
}

// CancelPending cancels the pending change of one kind. A proposal with a
// protectorRole can be cancelled only by that role, so a compromised key
// cannot veto its own replacement.
func CancelPending(cur realm, kind string) {
	assertIsAdminOrRecovery(cur)
	op := getPendingOp(kind)
	if op == nil {
		panic("nsdata: nothing pending of that kind")
	}
	if !canControl(op, cur.Previous().Address()) {
		panic("nsdata: only the " + op.protectorRole + " key may cancel this change")
	}
	pendingOps.Remove(kind)
	chain.Emit("GovernanceCancelled", "kind", kind, "by", cur.Previous().Address().String())
}

// ExecutePending applies a matured change. Callable by anyone on purpose:
// execution must not depend on a particular key still being available,
// since key unavailability is one of the things being recovered from. It
// only applies what was already proposed and survived its window.
func ExecutePending(cur realm, kind string) {
	op := getPendingOp(kind)
	if op == nil {
		panic("nsdata: nothing pending of that kind")
	}
	if time.Now().Before(op.at) {
		panic("nsdata: still in the timelock window")
	}
	pendingOps.Remove(kind)
	switch op.kind {
	case "admin":
		admin = op.addr
		// The admin that was just replaced cannot leave behind a live
		// proposal to replace recovery.
		dropPendingProtectedBy("recovery", "admin")
	case "recovery":
		recovery = op.addr
		// Likewise: a superseded recovery key's pending admin rotation
		// dies with it, so a stolen key cannot keep acting after the
		// operator has rotated it out.
		dropPendingProtectedBy("admin", "recovery")
	case "grantLogic":
		trustedLogicSet.Set(op.addr.String(), true)
	case "delay":
		timelockDelay = op.dur
	default:
		panic("nsdata: unknown pending kind")
	}
	chain.Emit("GovernanceExecuted", "kind", op.kind, "addr", op.addr.String())
}

// dropPendingProtectedBy removes the pending change of `kind` when it is
// protected by `role` — used when that role's key has just been replaced.
func dropPendingProtectedBy(kind, role string) {
	if op := getPendingOp(kind); op != nil && op.protectorRole == role {
		pendingOps.Remove(kind)
		chain.Emit("GovernanceInvalidated", "kind", kind, "reason", role+" rotated")
	}
}

func GetPending(kind string) (addr address, executableAt time.Time, protectorRole string) {
	op := getPendingOp(kind)
	if op == nil {
		return "", time.Time{}, ""
	}
	return op.addr, op.at, op.protectorRole
}

func ListPending() string {
	out := ""
	pendingOps.Iterate("", "", func(key string, v any) bool {
		if out != "" {
			out += ","
		}
		out += key
		return false
	})
	return out
}

// -- instant, low-risk admin settings --

// SetGuardian: assigning an UNSET guardian is instant and admin-callable,
// but REPLACING a guardian already in place requires recovery.
//
// Otherwise the first move of anyone who steals the admin key is to point
// the guardian at themselves, disarming the emergency stop before you can
// use it — which would make the "revoking is instant" property worthless
// exactly when it matters.
func SetGuardian(cur realm, addr address) {
	if guardian == "" {
		assertIsAdminOrRecovery(cur)
	} else if cur.Previous().Address() != recovery {
		panic("nsdata: replacing an existing guardian requires the recovery key")
	}
	guardian = addr
	chain.Emit("GuardianSet", "addr", addr.String())
}

/*
ClearGuardian stands the pause capability down.

"Removing a power is never the dangerous direction" was the old
reasoning here, and it is wrong in one specific way: removing this power
restores the state in which SetGuardian is admin-callable. SetGuardian
demands the RECOVERY key whenever a guardian is already set, and says
why — a stolen admin key must not be able to disarm the emergency stop.
ClearGuardian then SetGuardian was a two-transaction admin-only
replacement of a live guardian, which defeats exactly that rule.

So standing down a LIVE guardian now takes the same key that replacing
one takes. Clearing when there is no guardian stays open to either role,
because then there is nothing to defeat.

The practical stakes are small — assertCanPause admits admin, recovery
and guardian, so an operator holding recovery keeps Pause and
RevokeTrustedLogic either way. It is fixed because this realm can never
be redeployed, and a documented authorization rule that a two-call
sequence walks around is not something to leave in permanent code.
*/
func ClearGuardian(cur realm) {
	assertIsAdminOrRecovery(cur)
	if guardian != "" && cur.Previous().Address() != recovery {
		panic("nsdata: standing down a live guardian takes the recovery key, the same as replacing one")
	}
	guardian = ""
	chain.Emit("GuardianSet", "addr", "")
}

// SetSuccessor records where this registry moved, if it ever has to be
// abandoned. Pair it with Pause() so the retired registry cannot drift
// away from the snapshot its successor was built from.
func SetSuccessor(cur realm, s string) {
	assertIsAdminOrRecovery(cur)
	successor = s
	chain.Emit("SuccessorSet", "successor", s)
}

func GetAdmin() address               { return admin }
func GetRecovery() address            { return recovery }
func GetGuardian() address            { return guardian }
func GetSuccessor() string            { return successor }
func GetTimelockDelay() time.Duration { return timelockDelay }
func GetMaxTimelockDelay() time.Duration { return maxTimelockDelay }
