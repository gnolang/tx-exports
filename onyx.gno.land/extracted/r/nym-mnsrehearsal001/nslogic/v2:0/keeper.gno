package nslogic

import (
	"chain"
	"strconv"
	"time"

	"gno.land/r/nym-mnsrehearsal001/nsdata/v2"
)

/*
THE KEEPER: a hot key that moves the GNOT/USD rate and nothing else
(Ely, 2026-10-16).

WHY A ROLE. The rate is MANUAL (pricing.gno, SetUsdRate): it sits where it
was last written, and a stale rate during a sharp move sells names at the
wrong price. Keeping it current is a job for a bot, and a bot lives on a
server. The admin key must not, so the bot gets a key of its own that can
do exactly one thing.

WHAT IT CAN DO. Call SetUsdRate inside the bounds every instant change
obeys (timelock.gno): a higher rate — GNOT fell — up to four times at once,
every ten minutes, so a crash is followed at once; a lower rate — the
direction that sells names cheap — at most 25%, once an hour. The clocks
are the SAME ones the admin's instant moves use, so the two keys together
still cheapen names one step an hour. Never through the timelock: a
matured proposal belongs to the admin, and the keeper's call refuses an
out-of-bound value even while one is waiting. Every other function refuses
it, because every other function asks for the admin; the admin keeps
SetUsdRate as before.

WHAT ITS THEFT COSTS. Names a quarter cheaper each hour, in public — each
move emits KeeperAction — until the admin, recovery or the guardian calls
ClearKeeper, which is instant; or names made too dear to buy, an outage.
Bounded in size, in rate and in time, and it never touches a name or a
coin directly.

NAMED THROUGH THE TIMELOCK, CLEARED AT ONCE. SetKeeper waits out the vault's
action delay ("SetKeeper <addr>" through nsdata.ProposeAction), like naming
a granter: otherwise a stolen admin key installs a second key that survives
its own rotation. Clearing is the safe direction and is open to all three
governance roles. An admin rotation does not clear the keeper by itself;
the incident runbook does (MAINNET.md §1b).

NEVER THE ADMIN, NEVER RECOVERY. A keeper on the admin's address adds
nothing, and one on recovery's puts the cold key's address on a server.
Both are refused when it is named, and recovery is refused again at call
time, in case a later rotation moved recovery onto the keeper's address.

Stored in the vault's globals like the granter, so a logic swap keeps it,
and listed in managedGlobal, so SetGlobal cannot write round the timelock.
*/

const keyKeeper = "keeper" // global: the address that may move the rate

// Keeper is the address allowed to move the rate, or "" for none.
func Keeper() address { return address(nsdata.GetGlobal(keyKeeper)) }

// SetKeeper names the keeper. Admin only, and TIMELOCKED: propose exactly
// "SetKeeper <addr>" with nsdata.ProposeAction, then call once it matures.
// ClearKeeper removes the role.
func SetKeeper(cur realm, a address) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetKeeper", "addr", a.String())
	if !a.IsValid() {
		panic("nslogic: not an address; ClearKeeper removes the keeper")
	}
	if a == nsdata.GetAdmin() || a == nsdata.GetRecovery() {
		panic("nslogic: the keeper is a key of its own, never the admin or the recovery key")
	}
	requireAction(cur, actionID("SetKeeper", a.String()))
	setGlobal(cur, keyKeeper, a.String())
}

// ClearKeeper removes the keeper at once. Admin, recovery or guardian —
// the guardian bot's answer to a KeeperAction it did not expect. Clearing
// when there is no keeper does nothing and still succeeds, so a bot may
// call it without reading first.
func ClearKeeper(cur realm) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	if !isGovernor(caller) {
		panic("nslogic: only the admin, recovery or the guardian may clear the keeper")
	}
	chain.Emit("KeeperCleared", "keeper", Keeper().String(), "by", caller.String())
	setGlobal(cur, keyKeeper, "")
}

// isGovernor is the vault's three roles, read fresh. An unset role matches
// nobody.
func isGovernor(a address) bool {
	if a == "" {
		return false
	}
	return a == nsdata.GetAdmin() || a == nsdata.GetRecovery() || a == nsdata.GetGuardian()
}

// assertIsKeeper lets the keeper through and nobody else, with the refusal
// a stranger has always had from an admin call.
func assertIsKeeper(caller address) {
	k := Keeper()
	if k == "" || caller != k {
		panic("nslogic: restricted to project admin")
	}
	if k == nsdata.GetRecovery() {
		panic("nslogic: the keeper's address is now the recovery key's; name a new keeper")
	}
}

/*
keeperSetRate is SetUsdRate for the keeper: the same range check, the
bound and the shared hourly slot, and no door into the timelock. Every
move emits KeeperAction, with the value it replaced.
*/
func keeperSetRate(cur realm, ugnotPerUsd int64) {
	caller := cur.Previous().Address()
	assertIsKeeper(caller)
	old := RateUgnotPerUsd()
	chain.Emit("KeeperAction", "fn", "SetUsdRate", "by", caller.String(),
		"ugnotPerUsd", fmtInt(ugnotPerUsd), "was", fmtInt(old))
	if ugnotPerUsd <= 0 || ugnotPerUsd > maxRate {
		panic("nslogic: a rate is 1.." + strconv.FormatInt(maxRate, 10) + " ugnot per USD")
	}
	keeperStep(keyRate, old, ugnotPerUsd)
	setGlobal(cur, keyRate, strconv.FormatInt(ugnotPerUsd, 10))
}

// keeperStep is authorizeTweak with the timelock door bricked up: an
// instant step inside its direction's bound, after that direction's rest,
// or a refusal. It writes the same clocks, so the admin's next instant
// move in that direction waits the same time.
func keeperStep(setting string, old, next int64) {
	if next == old {
		return
	}
	dearer := next > old // the rate: higher means names cost more GNOT
	if !withinStep(old, next, dearer) {
		panic("nslogic: for the keeper, " + stepRefusal(setting, old, next, dearer) +
			"; a larger move is the admin's, through the vault timelock")
	}
	now := time.Now().Unix()
	if !clockRested(setting, dearer, now) {
		panic("nslogic: " + restRefusal(setting, dearer) + "; the keeper waits for the next step")
	}
	lastTweak.Set(clockKey(setting, dearer), now)
}
