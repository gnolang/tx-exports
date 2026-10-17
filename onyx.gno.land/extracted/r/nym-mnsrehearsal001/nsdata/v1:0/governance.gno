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
//	admin     — day-to-day authority: grants/revokes logic realms, tunes
//	            config. The warm key.
//	recovery  — cannot operate the registry at all. Can only rotate
//	            admin, cancel a pending change, revoke a logic realm,
//	            and pause. MUST be a multisig in production; see the
//	            trust note below for why that is not optional.
//	guardian  — can ONLY pause. Nothing else. Safe to keep hot (a
//	            monitoring bot), because its compromise costs an
//	            outage, never the registry.
//
// GRANTING POWER IS SLOW, REVOKING IT IS INSTANT. Handing authority to a
// new admin or a new logic realm goes through a timelock, and so — since
// actions.gno — does every admin action in the logic realm that destroys
// or moves names or money (deletion, lifecycle and treasury changes,
// unfreezing, reassigning, pricing rules, large price moves). Revocation,
// cancellation and pause are immediate; undoing a pause takes recovery or
// the timelock. An attacker holding one key cannot act instantly: they
// must announce and wait, and every step emits an event.
//
// EACH ROLE CAN ROTATE THE OTHER, AND THE ADMIN CANNOT VETO ITS OWN
// REPLACEMENT. A rotation recovery proposes — of the admin, or of itself —
// can be cancelled or displaced only by recovery. An admin-initiated
// rotation of recovery is the admin's to withdraw and, since the re-audit
// of 2026-10-16, recovery's to veto too: recovery is the root (see the
// trust note below), and a veto it could not send in its incident sitting
// reverted the whole sitting, eviction included. A LOST recovery cancels
// nothing, so the admin can still replace it. Proposals live in PER-KIND
// slots so an admin rotation and a recovery rotation can never contend for
// the same slot — an earlier single-slot design let one in-flight proposal
// freeze the entire governance surface, which meant the honest key could
// not even propose a response.
//
// THE TRUST ASYMMETRY, chosen rather than papered over. Both roles rotate
// the other on the same timelock, and it used to be that whichever proposed
// FIRST matured first and won — so a thief holding the admin key, acting
// before anybody noticed, could take recovery too. Since the re-audit of
// 2026-10-16 (M-1) RECOVERY WINS: once recovery's eviction is pending,
// nothing the admin proposed executes before it, a rotation of recovery the
// admin queued earlier included, and the eviction drops all of it. Every
// asymmetry hands the mirror-image power to whoever steals the favoured
// role, and this one is deliberate, the same as the ledger's (nsnft
// governance.gno): a stolen RECOVERY key now beats an honest admin, which
// is why recovery must be the cold multisig and the admin the key that is
// used.
//
// The mitigation is therefore operational as well as contractual:
//   - recovery MUST be a multisig, so no single stolen key can use it;
//   - timelockDelay must be long enough that you will actually notice an
//     event within it;
//   - watch for GovernanceProposed and ActionProposed and treat one you
//     did not initiate as an active incident.
//
// THE INCIDENT RUNBOOK, in this order (MAINNET.md §1b has it in full).
// First RevokeTrustedLogic on every entry of ListTrustedLogic(): guardian,
// admin or recovery may, it is instant, and re-granting needs the
// timelock, so no stolen key can switch the logic back on. Then Pause, and
// Disarm (incident.gno). Then, from recovery: the counter-rotation FIRST and
// alone — proposing it drops everything the admin had pending — then
// VoidGrantsSince and SetQuarantine (incident.gno), and CancelAllActions /
// CancelPending on anything left, which cannot revert; execute the eviction
// at maturity, before anything else.
//
// Pause does NOT stop ExecutePending — it stops registry mutations, which
// limits damage but does not stop a rotation. Do not rely on it for that.
//
// RECOVERY'S EVICTION LANDS FIRST, by rule (re-audit 2026-10-16, M-1). An
// eviction used to drop the admin's plans only when it executed, and anyone
// chose the order matured proposals ran in: the thief could re-propose a
// cancelled grant the block after recovery's sitting, or execute recovery's
// own move to a new cold key first, which dropped recovery's eviction. Now:
//
//	recovery proposing the eviction DROPS everything the admin had pending
//	— grants, delay, unpause, a rotation of recovery, every timelocked
//	action — so nothing of the admin's is held to spring back if the
//	eviction is cancelled; while it is pending (EvictionPending) the admin
//	proposes nothing, nothing it proposed may execute, and logic can spend
//	none of its actions;
//
//	a veto holds: what recovery cancels of the admin's, the admin may not
//	propose again for one timelock (any action, after an action veto), so
//	the sitting cannot be re-proposed around; recovery's eviction landing
//	clears the vetoes, and nothing else does;
//
//	recovery moving ITSELF keeps its eviction: the eviction is protected by
//	the recovery role, which the new key holds, and recovery's rotation of
//	itself is recovery's alone to cancel or displace. Only an
//	admin-initiated replacement of recovery drops the replaced key's
//	eviction.
//
//	recovery's cancellations are idempotent: cancelling what is no longer
//	pending does nothing, so a thief withdrawing its own proposal first
//	cannot make recovery's batched sitting revert.
type pendingOp struct {
	kind string // "admin" | "recovery" | "grantLogic" | "delay" | "unpause"
	addr address
	dur  time.Duration
	at   time.Time // when it becomes executable

	// protectorRole names the role that has EXCLUSIVE control of this
	// proposal — "" means either admin or recovery may cancel it. Set to
	// "recovery" on a recovery-initiated admin rotation, and to "admin"
	// on an admin-initiated recovery rotation, so the role being replaced
	// cannot veto its own replacement.
	protectorRole string

	// by is who proposed it. Recorded so that nobody has to reconstruct
	// it from events, and so the rotation rule below is checkable.
	by address
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

	// kind -> unix second until which the admin may not propose that kind
	// again, because recovery vetoed it; "action" for timelocked actions.
	// See the note above pendingOp. Cleared when the admin rotates.
	vetoUntil avl.Tree
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

// Pause halts every registry mutation, timelocked actions included.
// Reads are unaffected, so names stay resolvable while writes are frozen.
//
// It deliberately does NOT gate ExecutePending: governance must keep
// working during an incident — recovery's counter-rotation above all.
//
// A pause also drops a pending admin-proposed unpause, so the guardian
// bot can hold the registry paused against a stolen admin key simply by
// pausing again whenever it sees UnpauseProposed.
func Pause(cur realm) {
	assertCanPause(cur)
	paused = true
	if getPendingOp("unpause") != nil {
		pendingOps.Remove("unpause")
		chain.Emit("GovernanceInvalidated", "kind", "unpause", "reason", "paused again")
	}
	chain.Emit("Paused", "by", cur.Previous().Address().String())
}

/*
Unpause restarts the registry at once, and only RECOVERY may do that.

It used to be open to the admin too, which made a pause useless against
the key most likely to be stolen: the admin could unpause in the same
multi-message transaction as whatever it did next, so a pause stopped only
writers that did not hold admin. An audit showed it. The admin can still
unpause — ProposeUnpause, then the timelock — so a false alarm costs a
delay rather than the cold key; recovery can cancel that proposal, and any
new pause drops it. The guardian is excluded as before: a hot key that can
stop the system must not also be able to restart it.
*/
func Unpause(cur realm) {
	if cur.Previous().Address() != recovery {
		panic("nsdata: an instant unpause takes the recovery key; the admin may ProposeUnpause and wait out the timelock")
	}
	paused = false
	if getPendingOp("unpause") != nil {
		pendingOps.Remove("unpause")
	}
	chain.Emit("Unpaused", "by", cur.Previous().Address().String())
}

// ProposeUnpause is the admin's way back from a pause: a proposal like
// any grant of power, executable by anyone once it matures.
func ProposeUnpause(cur realm) {
	assertIsAdmin(cur)
	if !paused {
		panic("nsdata: the registry is not paused")
	}
	setPending(cur, &pendingOp{kind: "unpause"})
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
	if role == "recovery" {
		// AN EVICTION DROPS THE ADMIN'S PLANS WHEN IT IS PROPOSED, not only
		// when it lands: held instead, they all sprang back the moment the
		// eviction was cancelled — to fix a typo in its target, say — and a
		// rotation of recovery the admin queued outlived it (re-audit
		// follow-up, 2026-10-16).
		dropPendingProtectedBy("recovery", "admin")
		dropAdminProposals("recovery is replacing the admin")
	}
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
	// Recovery's rotation of itself is recovery's alone: unprotected, the
	// admin could cancel it, or displace it with a rotation of its own that
	// recovery could then neither cancel nor replace.
	if cur.Previous().Address() == recovery && recovery != admin {
		role = "recovery"
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
	// Bound the input before multiplying: a huge value used to wrap to a
	// sub-second ceiling and be accepted (audit L-3a).
	if seconds < 0 || seconds > int64(absoluteMaxTimelock/time.Second) {
		panic("nsdata: max delay out of range")
	}
	d := time.Duration(seconds) * time.Second
	if d < 0 || d > absoluteMaxTimelock || d < timelockDelay {
		panic("nsdata: max delay out of range")
	}
	maxTimelockDelay = d
	chain.Emit("MaxTimelockDelaySet", "seconds", strconv.FormatInt(int64(d/time.Second), 10),
		"by", cur.Previous().Address().String())
}

func canControl(op *pendingOp, caller address) bool {
	switch op.protectorRole {
	case "recovery":
		return caller == recovery
	case "admin":
		// The admin's rotation of recovery: the admin's to withdraw, and
		// recovery's to veto (see the note at the top).
		return caller == admin || caller == recovery
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

// EvictionPending reports a pending rotation of the admin that recovery
// proposed while the two roles are separate keys: recovery replacing an
// admin it no longer trusts. See the note above pendingOp.
func EvictionPending() bool {
	op := getPendingOp("admin")
	return op != nil && op.protectorRole == "recovery"
}

// adminAlone: the address is the admin and not also recovery — the case
// every eviction rule is about. While one key holds both, nothing is.
func adminAlone(a address) bool { return a == admin && a != recovery }

// assertAdminMayPropose refuses the admin while recovery is replacing it,
// and for one timelock after recovery vetoed a proposal of this kind.
func assertAdminMayPropose(caller address, kind string) {
	if !adminAlone(caller) {
		return
	}
	if EvictionPending() {
		panic("nsdata: recovery is replacing the admin; the admin proposes nothing until that lands")
	}
	if v := vetoUntil.Get(kind); v != nil && time.Now().Unix() < v.(int64) {
		panic("nsdata: recovery vetoed the admin's " + kind + "; the admin may propose one again from unix " +
			strconv.FormatInt(v.(int64), 10))
	}
}

// veto starts the cooldown on a kind, when recovery has just cancelled
// something the admin proposed.
func veto(caller address, kind string, proposer address) {
	if caller != recovery || caller == admin || !adminAlone(proposer) || timelockDelay <= 0 {
		return
	}
	until := time.Now().Unix() + int64(timelockDelay/time.Second)
	vetoUntil.Set(kind, until)
	chain.Emit("GovernanceVetoed", "kind", kind, "until", strconv.FormatInt(until, 10), "by", caller.String())
}

func setPending(cur realm, op *pendingOp) {
	caller := cur.Previous().Address()
	if existing := getPendingOp(op.kind); existing != nil {
		// You may replace only what you could cancel. Slots are per-kind,
		// so this contends only with another proposal of the SAME kind.
		if !canControl(existing, caller) {
			panic("nsdata: a change of this kind is pending and you may not replace it")
		}
		chain.Emit("GovernanceDisplaced", "kind", existing.kind, "by", caller.String())
	}
	assertAdminMayPropose(caller, op.kind)
	op.at = time.Now().Add(timelockDelay)
	op.by = caller
	pendingOps.Set(op.kind, op)
	// `seconds` carries a delay proposal's value, which this event used to
	// leave out, so "set the delay to zero" and "raise it" looked the same
	// to a monitor (audit L-3c).
	chain.Emit("GovernanceProposed",
		"kind", op.kind,
		"addr", op.addr.String(),
		"seconds", strconv.FormatInt(int64(op.dur/time.Second), 10),
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
		return // idempotent, so a batched incident sitting cannot be made to revert
	}
	if !canControl(op, cur.Previous().Address()) {
		panic("nsdata: only the " + op.protectorRole + " key may cancel this change")
	}
	pendingOps.Remove(kind)
	veto(cur.Previous().Address(), kind, op.by)
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
	// The ceiling may have been lowered since this was proposed; the
	// ceiling in force wins (audit L-3b). Checked before anything moves.
	if op.kind == "delay" && op.dur > maxTimelockDelay {
		panic("nsdata: that delay is above the ceiling now in force")
	}
	// The eviction lands first, whoever picks the order: nothing the admin
	// proposed runs while recovery is replacing it (see above pendingOp).
	if op.kind != "admin" && adminAlone(op.by) && EvictionPending() {
		panic("nsdata: recovery is replacing the admin; the admin's pending changes wait for that, and die with it")
	}
	pendingOps.Remove(kind)
	switch op.kind {
	case "admin":
		admin = op.addr
		// Recovery's eviction landing clears the vetoes it was fighting with;
		// an admin moving to a key of its own choosing does not.
		if op.protectorRole == "recovery" {
			vetoUntil = avl.Tree{}
		}
		// The admin that was just replaced cannot leave behind a live
		// proposal to replace recovery...
		dropPendingProtectedBy("recovery", "admin")
		// ...nor anything else only an admin could have proposed. This
		// used to drop the recovery rotation alone, so an evicted thief's
		// grantLogic survived the eviction — re-proposed just before it,
		// it matured a delay later and the thief, holding no role at all,
		// executed it (anyone may): a realm of their choosing trusted with
		// every vault write. An audit proved it. The new admin re-proposes
		// whatever it actually wants.
		dropAdminProposals("admin rotated")
	case "recovery":
		recovery = op.addr
		// Likewise: a superseded recovery key's pending admin rotation
		// dies with it, so a stolen key cannot keep acting after the
		// operator has rotated it out — when the ADMIN replaced it. Recovery
		// moving itself keeps its eviction, which the recovery role (now the
		// new key) still protects: executing that rotation first used to be
		// the thief's way to void the eviction (re-audit M-1 b).
		if op.protectorRole == "admin" {
			dropPendingProtectedBy("admin", "recovery")
		}
	case "grantLogic":
		trustedLogicSet.Set(op.addr.String(), true)
	case "delay":
		timelockDelay = op.dur
	case "unpause":
		paused = false
	default:
		panic("nsdata: unknown pending kind")
	}
	chain.Emit("GovernanceExecuted", "kind", op.kind, "addr", op.addr.String(),
		"seconds", strconv.FormatInt(int64(op.dur/time.Second), 10),
		"proposedBy", op.by.String(), "by", cur.Previous().Address().String())
}

// dropPendingProtectedBy removes the pending change of `kind` when it is
// protected by `role` — used when that role's key has just been replaced.
func dropPendingProtectedBy(kind, role string) {
	if op := getPendingOp(kind); op != nil && op.protectorRole == role {
		pendingOps.Remove(kind)
		chain.Emit("GovernanceInvalidated", "kind", kind, "reason", role+" rotated")
	}
}

// adminOnlyKinds are the proposals only the admin can make. Every one of
// them dies when the admin rotates: whoever proposed it no longer holds
// the key that could, and an eviction that leaves the evicted key's plans
// running has not evicted anybody.
var adminOnlyKinds = []string{"grantLogic", "delay", "unpause"}

func dropAdminProposals(reason string) {
	for _, k := range adminOnlyKinds {
		if getPendingOp(k) != nil {
			pendingOps.Remove(k)
			chain.Emit("GovernanceInvalidated", "kind", k, "reason", reason)
		}
	}
	// Timelocked admin actions too (actions.gno): every one was proposed
	// by the key that just lost the role, or is about to.
	dropAllActions(reason)
}

func GetPending(kind string) (addr address, executableAt time.Time, protectorRole string) {
	op := getPendingOp(kind)
	if op == nil {
		return "", time.Time{}, ""
	}
	return op.addr, op.at, op.protectorRole
}

// GetPendingDetail is GetPending with the rest of the proposal: the delay
// a "delay" proposal would install, in seconds — which GetPending could
// not show, so "set the delay to zero" and "raise it" looked identical —
// and who proposed it.
func GetPendingDetail(kind string) (addr address, seconds int64, executableAt time.Time, protectorRole string, by address) {
	op := getPendingOp(kind)
	if op == nil {
		return "", 0, time.Time{}, "", ""
	}
	return op.addr, int64(op.dur / time.Second), op.at, op.protectorRole, op.by
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

// SetGuardian takes the RECOVERY key, to seat a guardian as much as to
// replace one.
//
// Replacing took recovery from the start: otherwise the first move of
// anyone who steals the admin key is to point the guardian at themselves,
// disarming the emergency stop before you can use it. Seating an EMPTY
// seat used to be the admin's too, and that was the same hole: a stolen
// admin key seated its own bot, and after its eviction that bot could
// still pause and revoke, removable only by recovery (re-audit 2026-10-16,
// L-4). The deploy seats the guardian while its key still holds recovery.
func SetGuardian(cur realm, addr address) {
	if cur.Previous().Address() != recovery {
		if guardian == "" {
			panic("nsdata: seating a guardian takes the recovery key")
		}
		panic("nsdata: replacing an existing guardian requires the recovery key")
	}
	guardian = addr
	chain.Emit("GuardianSet", "addr", addr.String(), "by", cur.Previous().Address().String())
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
	chain.Emit("GuardianSet", "addr", "", "by", cur.Previous().Address().String())
}

// SetSuccessor records where this registry moved, if it ever has to be
// abandoned. Pair it with Pause() so the retired registry cannot drift
// away from the snapshot its successor was built from.
func SetSuccessor(cur realm, s string) {
	assertIsAdminOrRecovery(cur)
	successor = s
	chain.Emit("SuccessorSet", "successor", s, "by", cur.Previous().Address().String())
}

func GetAdmin() address                  { return admin }
func GetRecovery() address               { return recovery }
func GetGuardian() address               { return guardian }
func GetSuccessor() string               { return successor }
func GetTimelockDelay() time.Duration    { return timelockDelay }
func GetMaxTimelockDelay() time.Duration { return maxTimelockDelay }
