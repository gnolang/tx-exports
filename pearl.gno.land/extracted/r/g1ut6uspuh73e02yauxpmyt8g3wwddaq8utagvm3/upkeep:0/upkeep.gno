// Package upkeep pays people to run the ecosystem's permissionless
// valves. The portfolio's realms deliberately expose maintenance
// entrypoints that anyone may call — subscriptions.Expire frees a lapsed
// subscription slot, timelock_guardian.Execute fires a matured timelocked
// action — because no slot's liveness may depend on an interested party
// showing up. This realm adds the missing economics: funders finance a
// reward pot, and whoever triggers a valve THROUGH this realm is credited
// a bounded reward, claimable by pull.
//
// THE REALM-TO-REALM BOUNDARY, PRECISELY:
//
//	which calls which     : upkeep -> subscriptions.Expire(cross, id)
//	                        upkeep -> timelock_guardian.Execute(cross, id)
//	why it is necessary   : the reward must be conditioned on the valve
//	                        actually firing. Only making the call from
//	                        inside this realm ties "the valve fired" and
//	                        "the reward is credited" into one atomic
//	                        transaction; observing from outside cannot.
//	caller identity       : downstream sees cur.Previous() = THIS realm,
//	                        not the poking EOA. Both valves are
//	                        permissionless BY DESIGN and use the caller
//	                        identity for nothing, so the intermediary
//	                        changes no authorization outcome. This realm
//	                        is not a deputy for any downstream authority
//	                        — it holds none to confuse.
//	authorization boundary: upstream, anyone may poke (the reward is the
//	                        only thing at stake and the pot is the only
//	                        source). Downstream, each valve enforces its
//	                        own STATE conditions (grace elapsed, delay
//	                        matured) exactly as it would for a direct
//	                        caller.
//	ordering              : downstream call FIRST, reward accounting
//	                        AFTER. A downstream abort therefore reverts
//	                        the whole transaction before any pot or
//	                        ledger mutation exists.
//	failure behavior      : any downstream panic (not expirable, too
//	                        early, already executed, unknown id...)
//	                        aborts this transaction. No partial state,
//	                        no reward, by VM atomicity — not by cleanup
//	                        code.
//	atomicity assumptions : a Gno transaction is all-or-nothing across
//	                        realm boundaries; there is no catch/recover
//	                        anywhere on this path (and none may be added
//	                        — recovery would break exactly this
//	                        guarantee).
//	value movement        : none crosses the boundary. Both valves move
//	                        no coins; the poke transaction must carry no
//	                        coins (subscriptions' assertNoSend reads the
//	                        ORIGIN envelope unconditionally — measured,
//	                        not assumed). Rewards move only inside this
//	                        realm's ledger, funded by explicit Fund
//	                        transactions.
//	downstream rejection  : reward denied automatically — the abort is
//	                        the denial.
//	downstream trust      : neither valve trusts nor validates the
//	                        caller; both validate state. This realm
//	                        symmetrically does not trust the downstream
//	                        REPLY beyond "it did not abort".
//	replay                : enforced downstream. A second Expire on the
//	                        same subscription aborts ("subscription is
//	                        expired"); a second Execute aborts ("action
//	                        already executed"). A poker cannot be paid
//	                        twice for one valve event.
//	adversarial callers   : an EOA or realm poking with bogus ids,
//	                        premature targets, or replays hits a
//	                        downstream abort and pays its own gas. The
//	                        remaining economic edge — manufacturing
//	                        expirable state to farm rewards — differs
//	                        per task. sub_expire: every farmed
//	                        subscription permanently locks a sub-record
//	                        storage deposit of roughly 30,000ugnot at
//	                        the observed 100ugnot/byte rate (Expire
//	                        flips status; it does not free the record),
//	                        which exceeds MaxReward before price and
//	                        gas — loss-making at any legal setting.
//	                        timelock_execute: a farmed Action record is
//	                        small and its deposit can sit below the
//	                        cap, so farming resistance there rests on
//	                        the admin keeping the setting below the
//	                        measured cycle cost. Funders trust the cap
//	                        AND the admin's reward policy, not the cap
//	                        alone. The pot is a donation either way —
//	                        farming can drain it, never third-party
//	                        balances.
//
// Rewards default to 0 per task; the admin sets them within the
// compile-time MaxReward. The pot only moves down via successful pokes
// and only up via Fund. Conservation: Held == pot + UsersTotal
// (+ out-of-band surplus, recoverable above that reserve by SweepDenom).
// The ledger's fee cap is 0 — no fee exists anywhere in this realm.
package upkeep

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"

	subs "gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/subscriptions"
	guardian "gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/timelock_guardian"
)

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

// Task identifiers — the two supported valves.
const (
	TaskSubExpire       = "sub_expire"
	TaskTimelockExecute = "timelock_execute"
)

// MaxReward is the compile-time ceiling on the per-poke reward:
// 20,000ugnot (0.02 GNOT). It bounds what any single poke can extract
// from the pot. For sub_expire it also defeats farming outright: one
// manufactured expirable subscription permanently locks a sub-record
// deposit of ~30,000ugnot at the observed 100ugnot/byte rate — already
// above the cap before price and gas. For timelock_execute the farmed
// Action record is smaller and its deposit can sit below the cap, so
// there the admin's setting, kept below the measured farm-cycle cost,
// is what deters farming. Funders trust the cap and the admin's
// policy together; the pot they fund is an explicit donation either
// way.
const MaxReward = int64(20000)

var (
	admin        address // may set rewards, stage a successor
	pendingAdmin address // staged by TransferAdmin, completes via AcceptAdmin
	sweeper      address // may sweep out-of-band surplus

	self address // this realm's address, captured at deploy
	pot  int64   // funded, not-yet-awarded ugnot

	rewards = map[string]int64{
		TaskSubExpire:       0,
		TaskTimelockExecute: 0,
	}
	ledger = feeledger.MustNew(0)

	// lifetime counters, rendered for operators
	pokes  int64
	funded int64
)

func init() {
	admin = unsafe.OriginCaller()
	sweeper = admin
	self = unsafe.CurrentRealm().Address()
}

// --- funding ---

// Fund adds the attached coins to the reward pot. Anyone may fund;
// funding is a donation to ecosystem maintenance and is not refundable.
func Fund(cur realm) {
	funder, amount := coinio.Receive(0, cur, Denom)
	newPot, ok := checkedAdd(pot, amount)
	if !ok {
		panic("pot would overflow")
	}
	pot = newPot
	funded += amount
	chain.Emit("Funded", "from", funder.String(), "amount", itoa(amount),
		"pot", itoa(pot))
}

// --- the pokes: the realm-to-realm calls ---

// PokeExpire triggers subscriptions.Expire(subID) through this realm and
// credits the caller the sub_expire reward. The downstream realm decides
// whether the subscription is expirable; its abort is the authorization.
// The transaction must attach no coins (the downstream realm checks the
// origin envelope).
func PokeExpire(cur realm, subID int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	reward := requireReward(TaskSubExpire)

	// Downstream first: an abort here reverts everything below.
	subs.Expire(cross(cur), subID)

	award(caller, reward, TaskSubExpire, itoa(subID))
}

// PokeExecute triggers timelock_guardian.Execute(actionID) through this
// realm and credits the caller the timelock_execute reward. The guardian
// decides whether the action is executable; its abort is the
// authorization.
func PokeExecute(cur realm, actionID string) {
	assertNoSend()
	caller := cur.Previous().Address()
	reward := requireReward(TaskTimelockExecute)

	guardian.Execute(cross(cur), actionID)

	award(caller, reward, TaskTimelockExecute, actionID)
}

// award moves reward from the pot to the caller's claimable balance.
// Callers have already established that the pot covers it.
func award(caller address, reward int64, task, target string) {
	pot -= reward
	ledger.MustDeposit(caller.String(), reward, 0)
	pokes++
	chain.Emit("Poked",
		"task", task,
		"target", target,
		"caller", caller.String(),
		"reward", itoa(reward),
		"pot", itoa(pot),
	)
}

// requireReward returns the configured reward for a task, refusing when
// the task is unknown, unrewarded, or the pot cannot cover it. Refusal
// on an empty pot is deliberate: both valves remain directly callable on
// their own realms, so an unrewarded detour through this one is only a
// gas trap for the caller.
func requireReward(task string) int64 {
	r, ok := rewards[task]
	if !ok {
		panic("unknown task: " + task)
	}
	if r <= 0 {
		panic("no reward configured for " + task)
	}
	if pot < r {
		panic("reward pot cannot cover " + task + ": pot " + itoa(pot) +
			", reward " + itoa(r))
	}
	return r
}

// --- claims ---

// Claim sends amount ugnot of the caller's earned balance back to the
// caller.
func Claim(cur realm, amount int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire earned balance back to the caller.
func ClaimAll(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// --- administration ---

// SetReward configures the per-poke reward for a task, bounded by
// MaxReward. Admin only. Zero disables the task.
func SetReward(cur realm, task string, amount int64) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	if _, ok := rewards[task]; !ok {
		panic("unknown task: " + task)
	}
	if amount < 0 || amount > MaxReward {
		panic("reward must be in [0, " + itoa(MaxReward) + "]")
	}
	old := rewards[task]
	rewards[task] = amount
	chain.Emit("RewardChanged", "task", task, "old", itoa(old), "new", itoa(amount))
}

// SweepDenom recovers out-of-band coins to the sweeper. For the pot
// denom the reserve is pot + earned balances — both structurally
// unreachable. Sweeper only.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	if cur.Previous().Address() != sweeper {
		panic("sweeper only")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = pot + ledger.Liabilities()
	}
	swept := coinio.Sweep(0, cur, sweeper, denom, reserve)
	chain.Emit("SurplusSwept", "to", sweeper.String(), "coins", itoa(swept)+denom)
}

// TransferAdmin stages a two-step admin handover.
func TransferAdmin(cur realm, successor address) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	var zero address
	if successor == zero {
		panic("successor must not be the zero address")
	}
	pendingAdmin = successor
	chain.Emit("AdminTransferStaged", "from", admin.String(), "to", successor.String())
}

// AcceptAdmin completes the handover; only the staged successor may.
// The sweeper role moves with the admin.
func AcceptAdmin(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	if caller != pendingAdmin {
		panic("only the staged successor may accept")
	}
	old := admin
	admin = caller
	sweeper = caller
	var zero address
	pendingAdmin = zero
	chain.Emit("AdminTransferred", "from", old.String(), "to", admin.String())
}

// --- views ---

func Admin() address        { return admin }
func PendingAdmin() address { return pendingAdmin }
func Pot() int64            { return pot }
func RewardFor(task string) int64 {
	r, ok := rewards[task]
	if !ok {
		panic("unknown task: " + task)
	}
	return r
}
func BalanceOf(a address) int64 { return ledger.BalanceOf(a.String()) }
func UsersTotal() int64         { return ledger.UsersTotal() }
func Pokes() int64              { return pokes }
func Funded() int64             { return funded }
func Address() address          { return self }
func Held() int64               { return coinio.HeldAt(self, Denom) }

// --- render ---

func Render(path string) string {
	if path != "" {
		return "unknown page; try the realm root"
	}
	out := "# upkeep\n\n"
	out += "Rewards for running the ecosystem's permissionless valves. " +
		"Fund the pot; poke a valve through this realm; claim what you " +
		"earn. A poke succeeds only when the downstream realm accepts " +
		"the valve call in the same transaction.\n\n"
	out += "- pot: " + itoa(pot) + Denom + "\n"
	out += "- earned, unclaimed: " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- lifetime pokes: " + itoa(pokes) + "\n"
	out += "- lifetime funding: " + itoa(funded) + Denom + "\n\n"
	out += "## rewards per poke\n\n"
	out += "- `" + TaskSubExpire + "` (subscriptions.Expire): " +
		itoa(rewards[TaskSubExpire]) + Denom + "\n"
	out += "- `" + TaskTimelockExecute + "` (timelock_guardian.Execute): " +
		itoa(rewards[TaskTimelockExecute]) + Denom + "\n"
	out += "\n(cap per poke: " + itoa(MaxReward) + Denom + ", compile-time)\n"
	return out
}

// --- internals ---

func assertNoSend() {
	if len(unsafe.OriginSend()) != 0 {
		panic("this function does not accept coins")
	}
}

func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

func checkedAdd(a, b int64) (int64, bool) {
	if b > 0 && a > int64(^uint64(0)>>1)-b {
		return 0, false
	}
	return a + b, true
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
