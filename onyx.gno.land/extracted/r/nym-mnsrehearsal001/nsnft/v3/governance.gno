package nsnft

import (
	"chain"
	"chain/runtime"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

/*
GOVERNANCE, AND WHY THE SMALLEST REALM NEEDED SOME.

The first version had one admin key and an instant Trust. Whoever held
that key could trust a realm of their own, burn any name and mint it to
themselves, in one block — and none of the vault's protections applied,
because its timelock, recovery role and guardian all live in nsdata and
nothing in that flow touches nsdata. In the generation where this is the
realm that can never change, it had the weakest governance of all. Two
audits (2026-10-15, H2/H3 and H-2) asked for this before it ships.

The model mirrors nsdata/governance.gno, with the two lessons its own
audit taught applied from the start:

	admin     the warm key. Proposes every power-granting change. Can
	          withdraw a registry's trust or the art instantly.
	recovery  the cold key, a multisig in production. Operates nothing.
	          Cancels ANY pending change, rotates admin, withdraws trust.
	guardian  hot (a monitoring bot), seated by recovery. Withdraws trust
	          or the art, and cancels the admin's grants (a registry, the
	          art, the timelock) but never a rotation. Nothing else, so its
	          theft costs an outage, never a name.

GRANTING IS SLOW, REVOKING IS INSTANT. Trusting a registry (the only way
anything can mint or burn), approving a view realm for the art, changing
the timelock and rotating either role all wait `timelockDelay` (an admin
replacing recovery waits twice that), are announced with an event, and
can be cancelled in the meantime. Withdrawing a registry's trust or the
art takes one transaction.

RECOVERY IS THE ROOT, AND THAT IS A DELIBERATE DEPARTURE. nsdata lets
each role rotate the other with neither able to cancel its own
replacement, which means a stolen admin key can propose a recovery
rotation recovery cannot stop. Here recovery may cancel anything and the
admin only what the admin proposed. A stolen admin key therefore gets
nothing that survives the timelock: every proposal it makes can be
cancelled and recovery can evict it. What it CAN do at once is withdraw
— untrust the registry, clear the art — which stops registrations until
an honest admin re-grants them, an outage and not a theft. The admin can
still replace a LOST recovery key — nobody cancels that proposal, so it
lands after twice the delay — which is the case the symmetry was there
for. The price is that a stolen recovery key is the one theft this realm
cannot contain, which is why it must be a cold multisig.

A ROTATION TAKES ITS PREDECESSOR'S PROPOSALS WITH IT. nsdata's audit (M-1)
found an evicted admin's pending grant surviving the eviction, executable
by anyone a delay later. Here, whenever a role changes hands, every
pending change proposed by an address that no longer holds a role is
dropped, with an event.

RECOVERY WINS THE EVICTION RACE, BY RULE AND NOT BY TIMING (re-audit
2026-10-16, M-1). An eviction used to drop the thief's proposals only at
the moment it executed, and anybody — the thief included — chose the order
in which matured proposals ran. So the thief re-proposed a cancelled trust
the block after recovery's sitting, executed it the moment it matured
(seconds after the eviction did), and minted through its registry in the
same transaction; or it executed recovery's own move to a new cold key
first, which orphaned recovery's eviction. Three rules close it:

	recovery proposing the eviction DROPS everything the admin had
	pending, and while the eviction is pending the admin proposes nothing
	and nothing it proposed may execute — so nothing of the admin's is
	held to spring back if the eviction lapses or is cancelled;

	a veto holds: when recovery or the guardian cancels what the admin
	proposed, the admin may not propose that kind again for one timelock,
	so recovery's sitting cannot be re-proposed around while it is still
	gathering signatures. Recovery's eviction landing clears the vetoes;
	replacing or standing down a guardian clears that guardian's; nothing
	else does, not an admin moving to a key of its own;

	recovery moving to a new key HANDS its eviction to that key (it was
	recovery's, and recovery still holds the role), so executing
	recovery's own rotation first no longer voids it. An admin replacing a
	lost recovery still drops the old key's plans.

Cancelling what is no longer pending does nothing, so a thief withdrawing
its own proposal first cannot make a batched sitting revert.

PROPOSALS EXPIRE. A matured change stays executable for executeWindow and
is void after it, so a forgotten proposal cannot be executed by a stranger
a year later (nsdata audit L-1).

ROLES NEVER MERGE. A rotation that would leave admin and recovery the
same key is refused, at proposal and again at execution: with one key in
both seats every protection above silently disappears (nsdata audit I-5).
They start merged on the deployer, which hands them out while the
timelock is still zero.

ExecutePending is open to anyone, as in nsdata: applying a change that
was announced and survived its window must not depend on a particular key
still being available. Every entry point below is a thin wrapper that
reads the caller and the clock and hands them to an unexported function,
so the rules themselves can be tested directly.
*/

const (
	// The ceiling on the timelock: a constant, not a setting, so a stolen
	// key cannot raise it and an absurd value cannot brick governance.
	maxTimelock int64 = 30 * 24 * 60 * 60
	// How long a matured proposal stays executable before it is void.
	executeWindow int64 = 14 * 24 * 60 * 60
	maxPathLen          = 256

	kindAdmin    = "admin"
	kindRecovery = "recovery"
	kindTrust    = "trust"
	kindDelay    = "delay"
	kindRenderer = "renderer"
)

type pendingOp struct {
	kind     string
	target   string  // what it changes to, as text: an address, a package path, or seconds
	addr     address // admin and recovery: the new holder; trust: the registry's address
	secs     int64   // delay: the new timelock
	at       int64   // unix seconds: executable from
	until    int64   // unix seconds: void after
	proposer address
}

var (
	admin    address
	recovery address
	guardian address

	// Seconds every power-granting change waits. Starts at zero so the
	// deploy can wire and hand out roles in one sitting; the deploy raises
	// it before anything is worth stealing. Changing it is itself
	// timelocked, or a thief would simply set it to zero.
	timelockDelay int64

	// One slot per kind (kind -> *pendingOp), so one in-flight proposal
	// cannot freeze the whole governance surface.
	pending avl.Tree

	// kind -> *veto: until when the admin may not propose that kind again,
	// because recovery or the guardian vetoed it, and who did (see the note
	// at the top).
	vetoes avl.Tree
)

type veto struct {
	until int64
	by    address
}

// -- roles: an empty role matches nobody --

func isAdmin(a address) bool    { return admin.IsValid() && a == admin }
func isRecovery(a address) bool { return recovery.IsValid() && a == recovery }
func isGuardian(a address) bool { return guardian.IsValid() && a == guardian }

func assertAdmin(caller address) {
	if !isAdmin(caller) {
		panic("nsnft: admin only")
	}
}

func assertAdminOrRecovery(caller address) {
	if !isAdmin(caller) && !isRecovery(caller) {
		panic("nsnft: admin or recovery only")
	}
}

func assertCanRevoke(caller address) {
	if !isAdmin(caller) && !isRecovery(caller) && !isGuardian(caller) {
		panic("nsnft: admin, recovery or guardian only")
	}
}

/*
isRealmPath accepts only a realm package path on this chain. A registry
or a view proves what it is by BEING that realm, and its address is
derived from the path here, so a wallet can never be trusted (nsdata
audit L-4): no wallet address is the hash of a realm path. Ephemeral
`maketx run` realms (gno.land/e/...), pure packages (/p/) and sub-realm
paths (with ':') are refused with it.
*/
func isRealmPath(p string) bool {
	prefix := runtime.ChainDomain() + "/r/"
	if len(p) <= len(prefix) || len(p) > maxPathLen || !strings.HasPrefix(p, prefix) {
		return false
	}
	if strings.HasSuffix(p, "/") || strings.Contains(p, "//") {
		return false
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '/' || c == '_' || c == '-' || c == '.' {
			continue
		}
		return false
	}
	return true
}

// -- the pending slots --

// liveOp is the pending change of one kind, or nil — an expired one is
// treated as absent everywhere, so it can be neither executed nor used to
// block a new proposal.
func liveOp(kind string, now int64) *pendingOp {
	v := pending.Get(kind)
	if v == nil {
		return nil
	}
	op := v.(*pendingOp)
	if now > op.until {
		return nil
	}
	return op
}

/*
canCancel: recovery may cancel anything; the admin what the admin
proposed; the guardian the admin's GRANTS — a registry, the art, the
timelock — and never a rotation. A hot key able to block rotations
could, with recovery lost, block the one change that replaces recovery
(and with it, the guardian) for good.
*/
func canCancel(op *pendingOp, caller address) bool {
	if isRecovery(caller) {
		return true
	}
	if isAdmin(caller) && caller == op.proposer {
		return true
	}
	if isGuardian(caller) && op.proposer != recovery &&
		(op.kind == kindTrust || op.kind == kindRenderer || op.kind == kindDelay) {
		return true
	}
	return false
}

// delayFor is the wait a proposal gets. An admin replacing RECOVERY waits
// twice the timelock: it is the one move by which a stolen admin key
// could eventually take the root role, so it gets the longest window for
// recovery to see it and cancel it. The case it exists for — recovery
// lost — only costs a slower replacement.
func delayFor(kind string, caller address) int64 {
	if kind == kindRecovery && !isRecovery(caller) {
		return 2 * timelockDelay
	}
	return timelockDelay
}

/*
evicting reports a live rotation of the admin that recovery proposed —
recovery replacing a key it no longer trusts. While admin and recovery are
still one key, at the deploy, nothing is an eviction.
*/
func evicting(now int64) bool {
	op := liveOp(kindAdmin, now)
	return op != nil && isRecovery(op.proposer) && !isAdmin(op.proposer)
}

// byTheAdminAlone: proposed by the admin, and the admin is not also recovery.
func byTheAdminAlone(a address) bool { return isAdmin(a) && !isRecovery(a) }

// vetoedUntil is when the admin may propose `kind` again, or 0.
func vetoedUntil(kind string, now int64) int64 {
	if v := vetoes.Get(kind); v != nil && now < v.(*veto).until {
		return v.(*veto).until
	}
	return 0
}

// dropVetoesBy lifts the vetoes one key sent: a guardian replaced or stood
// down, perhaps because it was stolen, does not keep the admin shut out.
func dropVetoesBy(by address) {
	var gone []string
	vetoes.Iterate("", "", func(k string, v any) bool {
		if v.(*veto).by == by {
			gone = append(gone, k)
		}
		return false
	})
	for _, k := range gone {
		vetoes.Remove(k)
		chain.Emit("GovernanceVetoLifted", "kind", k, "by", by.String())
	}
}

// dropProposalsOf removes every pending change `who` proposed: the admin's
// plans, the moment recovery proposes to evict it.
func dropProposalsOf(who address, reason string) {
	var gone []string
	pending.Iterate("", "", func(k string, v any) bool {
		if op := v.(*pendingOp); op.proposer == who && k != kindAdmin {
			gone = append(gone, k)
		}
		return false
	})
	for _, k := range gone {
		op := pending.Get(k).(*pendingOp)
		pending.Remove(k)
		chain.Emit("GovernanceInvalidated", "kind", k, "target", op.target,
			"proposer", op.proposer.String(), "reason", reason)
	}
}

func setPending(caller address, op *pendingOp, now int64) {
	if existing := liveOp(op.kind, now); existing != nil {
		// You may replace only what you could cancel.
		if !canCancel(existing, caller) {
			panic("nsnft: a change of this kind is pending and you may not replace it")
		}
		chain.Emit("GovernanceDisplaced", "kind", existing.kind, "target", existing.target, "by", caller.String())
	}
	if byTheAdminAlone(caller) {
		if evicting(now) {
			panic("nsnft: recovery is replacing the admin; the admin proposes nothing until that lands or lapses")
		}
		if until := vetoedUntil(op.kind, now); until > 0 {
			panic("nsnft: recovery or the guardian vetoed a " + op.kind + " change; the admin may propose one again from unix " + itoa(until))
		}
	}
	op.proposer = caller
	op.at = now + delayFor(op.kind, caller)
	op.until = op.at + executeWindow
	pending.Set(op.kind, op)
	chain.Emit("GovernanceProposed",
		"kind", op.kind,
		"target", op.target,
		"executableAt", itoa(op.at),
		"expiresAt", itoa(op.until),
		"by", caller.String())
}

func proposeTrust(caller address, pkgPath string, now int64) {
	assertAdmin(caller)
	if !isRealmPath(pkgPath) {
		panic("nsnft: a registry must be a realm package path under " + runtime.ChainDomain() + "/r/")
	}
	a := chain.PackageAddress(pkgPath)
	if trusted.Has(a.String()) {
		panic("nsnft: that registry is already trusted")
	}
	setPending(caller, &pendingOp{kind: kindTrust, target: pkgPath, addr: a}, now)
}

func proposeRenderer(caller address, pkgPath string, now int64) {
	assertAdmin(caller)
	if !isRealmPath(pkgPath) {
		panic("nsnft: a renderer must be a realm package path under " + runtime.ChainDomain() + "/r/")
	}
	if pkgPath == rendererPath {
		panic("nsnft: that realm is already the approved renderer")
	}
	setPending(caller, &pendingOp{kind: kindRenderer, target: pkgPath}, now)
}

// proposeDelay bounds the value before anything is computed from it, so
// no input can wrap (nsdata audit L-3), and the proposal shows the value
// it would set, so a monitor can tell "to zero" from "up".
func proposeDelay(caller address, seconds int64, now int64) {
	assertAdmin(caller)
	if seconds < 0 || seconds > maxTimelock {
		panic("nsnft: timelock out of range (0 to " + itoa(maxTimelock) + " seconds)")
	}
	setPending(caller, &pendingOp{kind: kindDelay, target: itoa(seconds), secs: seconds}, now)
}

func proposeAdmin(caller, next address, now int64) {
	assertAdminOrRecovery(caller)
	if !next.IsValid() {
		panic("nsnft: invalid address")
	}
	if next == admin {
		panic("nsnft: that address is already the admin")
	}
	if next == recovery {
		panic("nsnft: admin and recovery must stay separate keys")
	}
	setPending(caller, &pendingOp{kind: kindAdmin, target: next.String(), addr: next}, now)
	if isRecovery(caller) && !isAdmin(caller) && admin.IsValid() {
		// The eviction drops the admin's plans now, not when it lands (see
		// the note at the top).
		dropProposalsOf(admin, "recovery is replacing the admin")
	}
}

func proposeRecovery(caller, next address, now int64) {
	assertAdminOrRecovery(caller)
	if !next.IsValid() {
		panic("nsnft: invalid address")
	}
	if next == recovery {
		panic("nsnft: that address is already recovery")
	}
	if next == admin {
		panic("nsnft: admin and recovery must stay separate keys")
	}
	setPending(caller, &pendingOp{kind: kindRecovery, target: next.String(), addr: next}, now)
}

func cancelPending(caller address, kind string, now int64) {
	op := liveOp(kind, now)
	if op == nil {
		if !isAdmin(caller) && !isRecovery(caller) && !isGuardian(caller) {
			panic("nsnft: admin, recovery or guardian only")
		}
		return // idempotent, so a batched sitting cannot be made to revert
	}
	if !canCancel(op, caller) {
		panic("nsnft: you may not cancel this change")
	}
	pending.Remove(kind)
	// A veto holds for one timelock (see the note at the top): what recovery
	// or the guardian cancelled, the admin cannot simply propose again in the
	// next block. The admin withdrawing its own proposal costs nothing.
	if byTheAdminAlone(op.proposer) && !isAdmin(caller) && timelockDelay > 0 {
		vetoes.Set(kind, &veto{until: now + timelockDelay, by: caller})
		chain.Emit("GovernanceVetoed", "kind", kind, "until", itoa(now+timelockDelay), "by", caller.String())
	}
	chain.Emit("GovernanceCancelled", "kind", kind, "target", op.target, "by", caller.String())
}

func executePending(caller address, kind string, now int64) {
	op := liveOp(kind, now)
	if op == nil {
		panic("nsnft: nothing pending of that kind")
	}
	if now < op.at {
		panic("nsnft: still in the timelock window")
	}
	// The eviction lands first, whoever picks the order (see the note at
	// the top): nothing the admin proposed runs while recovery is replacing
	// it, and the eviction then drops all of it.
	if kind != kindAdmin && byTheAdminAlone(op.proposer) && evicting(now) {
		panic("nsnft: recovery is replacing the admin; the admin's pending changes wait for that, and die with it")
	}
	pending.Remove(kind)
	prev := ""
	switch kind {
	case kindAdmin:
		if op.addr == recovery {
			panic("nsnft: admin and recovery must stay separate keys")
		}
		prev = admin.String()
		admin = op.addr
		// Recovery's eviction landing clears the vetoes it was fighting
		// with; an admin moving to a key of its own choosing does not.
		if isRecovery(op.proposer) {
			vetoes = avl.Tree{}
		}
	case kindRecovery:
		if op.addr == admin {
			panic("nsnft: admin and recovery must stay separate keys")
		}
		prev = recovery.String()
		old := recovery
		recovery = op.addr
		// Recovery moving ITSELF keeps its eviction: it is handed to the new
		// key rather than orphaned. Only the eviction — recovery proposes
		// nothing else that could still be pending — so the new key never
		// inherits what an old deploy key proposed while it held both seats.
		// An admin replacing a lost recovery does not inherit that key's
		// eviction; it is dropped below with every other orphan.
		if op.proposer == old && old != admin {
			if e := liveOp(kindAdmin, now); e != nil && e.proposer == old {
				e.proposer = recovery
				chain.Emit("GovernanceHandedOver", "kind", kindAdmin, "target", e.target,
					"from", old.String(), "to", recovery.String())
			}
		}
	case kindTrust:
		trusted.Set(op.addr.String(), op.target)
		chain.Emit("RegistryTrusted", "addr", op.addr.String(), "path", op.target)
	case kindDelay:
		prev = itoa(timelockDelay)
		timelockDelay = op.secs
	case kindRenderer:
		// The approval moves; whatever the previous view registered stops
		// drawing, and wallets see the built-in card until the newly
		// approved realm registers itself.
		prev = rendererPath
		rendererPath = op.target
		renderer = nil
	default:
		panic("nsnft: unknown pending kind")
	}
	chain.Emit("GovernanceExecuted", "kind", kind, "target", op.target, "previous", prev, "by", caller.String())
	if kind == kindAdmin || kind == kindRecovery {
		dropOrphans()
	}
}

// dropOrphans removes every pending change whose proposer no longer
// holds a role. Called after each rotation; see the note at the top.
func dropOrphans() {
	var gone []string
	pending.Iterate("", "", func(k string, v any) bool {
		op := v.(*pendingOp)
		if op.proposer != admin && op.proposer != recovery {
			gone = append(gone, k)
		}
		return false
	})
	for _, k := range gone {
		op := pending.Get(k).(*pendingOp)
		pending.Remove(k)
		chain.Emit("GovernanceInvalidated", "kind", k, "target", op.target,
			"proposer", op.proposer.String(), "reason", "proposer no longer holds a role")
	}
}

func untrust(caller, registry address) {
	assertCanRevoke(caller)
	v := trusted.Get(registry.String())
	if v == nil {
		panic("nsnft: that registry is not trusted")
	}
	trusted.Remove(registry.String())
	chain.Emit("RegistryUntrusted", "addr", registry.String(), "path", v.(string), "by", caller.String())
}

/*
setGuardian takes recovery, to seat a guardian as much as to replace or
stand down a live one — otherwise the first move of a thief holding the
admin key would be to point the guardian at themselves, disarming the
emergency stop; and seating an EMPTY seat with its own bot left the thief a
key that outlived its eviction, untrusting the registry and vetoing the new
admin's grants, removable only by recovery (re-audit 2026-10-16, L-4). The
deploy seats it while its key still holds recovery. The address must be
real (nsdata audit I-4).
*/
func setGuardian(caller, g address) {
	if !g.IsValid() {
		panic("nsnft: invalid address")
	}
	if !isRecovery(caller) {
		if guardian.IsValid() {
			panic("nsnft: replacing a live guardian takes the recovery key")
		}
		panic("nsnft: seating a guardian takes the recovery key")
	}
	if guardian.IsValid() && guardian != g {
		dropVetoesBy(guardian)
	}
	guardian = g
	chain.Emit("GuardianSet", "addr", g.String(), "by", caller.String())
}

func clearGuardian(caller address) {
	if guardian.IsValid() {
		if !isRecovery(caller) {
			panic("nsnft: standing down a live guardian takes the recovery key")
		}
		dropVetoesBy(guardian)
	} else {
		assertAdminOrRecovery(caller)
	}
	guardian = ""
	chain.Emit("GuardianSet", "addr", "", "by", caller.String())
}

// -- entry points: each reads the caller and the clock, nothing more --

// ProposeTrust starts trusting a registry, by package path, after the
// timelock. Admin only.
func ProposeTrust(cur realm, pkgPath string) {
	assertNoSend(cur)
	proposeTrust(cur.Previous().Address(), pkgPath, time.Now().Unix())
}

// ProposeRenderer approves a view realm to draw the art, after the
// timelock. Admin only. The realm then registers itself (art.gno).
func ProposeRenderer(cur realm, pkgPath string) {
	assertNoSend(cur)
	proposeRenderer(cur.Previous().Address(), pkgPath, time.Now().Unix())
}

// ProposeTimelockDelay changes the timelock, after the current one.
// Admin only.
func ProposeTimelockDelay(cur realm, seconds int64) {
	assertNoSend(cur)
	proposeDelay(cur.Previous().Address(), seconds, time.Now().Unix())
}

// ProposeAdminTransfer rotates the admin after the timelock. Admin or
// recovery; when recovery proposes it, the admin cannot cancel it.
func ProposeAdminTransfer(cur realm, next address) {
	assertNoSend(cur)
	proposeAdmin(cur.Previous().Address(), next, time.Now().Unix())
}

// ProposeRecoveryTransfer rotates recovery after the timelock — twice the
// timelock when the admin proposes it. Admin or recovery; recovery can
// cancel either, so a stolen admin key cannot take it.
func ProposeRecoveryTransfer(cur realm, next address) {
	assertNoSend(cur)
	proposeRecovery(cur.Previous().Address(), next, time.Now().Unix())
}

func CancelPending(cur realm, kind string) {
	assertNoSend(cur)
	cancelPending(cur.Previous().Address(), kind, time.Now().Unix())
}

// ExecutePending applies a matured change. Anyone may call it.
func ExecutePending(cur realm, kind string) {
	assertNoSend(cur)
	executePending(cur.Previous().Address(), kind, time.Now().Unix())
}

// Untrust withdraws a registry's power to mint and burn, at once. Admin,
// recovery or guardian: removing a power is the safe direction, and a
// registry that has gone wrong must be stoppable in one transaction.
func Untrust(cur realm, registry address) {
	assertNoSend(cur)
	untrust(cur.Previous().Address(), registry)
}

func SetGuardian(cur realm, g address) {
	assertNoSend(cur)
	setGuardian(cur.Previous().Address(), g)
}

func ClearGuardian(cur realm) {
	assertNoSend(cur)
	clearGuardian(cur.Previous().Address())
}

// -- reads --

func Admin() address       { return admin }
func Recovery() address    { return recovery }
func Guardian() address    { return guardian }
func TimelockDelay() int64 { return timelockDelay }

// PendingAdmin is the address a pending admin rotation would install, or
// empty.
func PendingAdmin() address {
	if op := liveOp(kindAdmin, time.Now().Unix()); op != nil {
		return op.addr
	}
	return ""
}

// GetPending describes the live pending change of one kind: what it sets,
// when it becomes executable and when it lapses (unix seconds), and who
// proposed it. All empty when nothing is pending.
func GetPending(kind string) (target string, executableAt, expiresAt int64, proposer address) {
	op := liveOp(kind, time.Now().Unix())
	if op == nil {
		return "", 0, 0, ""
	}
	return op.target, op.at, op.until, op.proposer
}

// ListPending names the kinds with a live pending change, comma-separated.
func ListPending() string {
	now := time.Now().Unix()
	out := ""
	pending.Iterate("", "", func(k string, v any) bool {
		if now > v.(*pendingOp).until {
			return false
		}
		if out != "" {
			out += ","
		}
		out += k
		return false
	})
	return out
}

func IsTrusted(registry address) bool { return registry.IsValid() && trusted.Has(registry.String()) }

// Trusted lists every address that may mint or burn, comma-separated.
// nsdata compares this with its own address before adopting tokens, so
// the format is part of the contract: addresses only, no spaces.
func Trusted() string {
	out := ""
	trusted.Iterate("", "", func(a string, _ any) bool {
		if out != "" {
			out += ","
		}
		out += a
		return false
	})
	return out
}

// TrustedPath reports the package path a registry was trusted as, or "".
func TrustedPath(registry address) string {
	if v := trusted.Get(registry.String()); v != nil {
		return v.(string)
	}
	return ""
}
