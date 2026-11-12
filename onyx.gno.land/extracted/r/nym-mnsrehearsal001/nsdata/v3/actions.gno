package nsdata

import (
	"strconv"
	"strings"
	"time"

	"chain"

	"gno.land/p/nt/avl/v0"
)

/*
TIMELOCKED ADMIN ACTIONS: the vault's clock behind the logic realm's most
dangerous calls.

THE GAP THIS CLOSES. The timelock above guarded two things — granting a
logic realm and rotating a role — and everything the logic realm let the
admin do was instant. An audit took a paid name from its holder, made
names in grace reclaimable by anybody, deleted live names and redirected
all revenue, each in one multi-message transaction with a 48-hour delay
in force and nothing ever proposed. No monitor could act between the
steps.

THE SHAPE. The policy stays in the logic realm — which calls are
dangerous, and what exactly a call's arguments are — and the delay lives
here, where no logic swap can shorten it:

	ProposeAction(id)   admin only, as a direct wallet call; stamped with
	                    the timelock delay in force; emits ActionProposed.
	CancelAction(id)    admin or recovery, instantly; CancelAllActions for
	                    an incident.
	ConsumeAction(id)   trusted logic only; panics unless the action has
	                    matured and has not expired; removes it.

An id names one call and its arguments, canonically — nslogic uses
"<Function> <arg> <arg>…" — so a proposal authorizes exactly one change,
and the event a monitor sees is the change itself rather than a hash it
has to trust. The vault does not interpret ids at all.

A matured action stays executable for actionWindow and is void after it,
so a proposal nobody acted on cannot be executed by surprise a year later.
At most maxPendingActions wait at once; expired ones make room. Every
pending action dies when the admin rotates (dropAdminProposals): an
evicted key's plans do not outlive the key.
*/

type pendingAction struct {
	at      int64 // unix second it becomes executable
	expires int64 // unix second it stops being executable
	by      address
}

var (
	pendingActions avl.Tree // id -> *pendingAction

	maxPendingActions = 32

	// Seconds a matured action stays executable. Settable within bounds by
	// admin or recovery: shortening it only voids proposals sooner, and
	// lengthening it cannot make anything mature faster.
	actionWindow int64 = 7 * 24 * 60 * 60
)

const (
	maxActionIDLen   = 2048
	minActionWindow  = int64(60 * 60)
	maxActionWindowS = int64(90 * 24 * 60 * 60)
)

func getAction(id string) *pendingAction {
	if v := pendingActions.Get(id); v != nil {
		return v.(*pendingAction)
	}
	return nil
}

func assertActionID(id string) {
	if id == "" || len(id) > maxActionIDLen {
		panic("nsdata: an action id is 1-" + strconv.Itoa(maxActionIDLen) + " bytes")
	}
	if strings.ContainsAny(id, "\n\r") {
		panic("nsdata: an action id may not contain newlines")
	}
}

// ProposeAction starts the clock on one admin action. Proposing an id
// already pending restarts its clock: the latest proposal is the one that
// must survive its window.
func ProposeAction(cur realm, id string) {
	assertIsAdmin(cur)
	assertActionID(id)
	// Not while recovery is replacing the admin, nor for one timelock after
	// recovery vetoed one of its actions (governance.gno, re-audit M-1).
	assertAdminMayPropose(cur.Previous().Address(), "action")
	now := time.Now().Unix()
	if getAction(id) == nil {
		pruneExpiredActions(now)
		if pendingActions.Size() >= maxPendingActions {
			panic("nsdata: " + strconv.Itoa(maxPendingActions) + " actions are already pending; cancel some first")
		}
	}
	at := now + int64(timelockDelay/time.Second)
	a := &pendingAction{at: at, expires: at + actionWindow, by: cur.Previous().Address()}
	pendingActions.Set(id, a)
	chain.Emit("ActionProposed", "id", id,
		"executableAt", strconv.FormatInt(a.at, 10),
		"expiresAt", strconv.FormatInt(a.expires, 10),
		"by", a.by.String())
}

// CancelAction withdraws one pending action. Admin or recovery: the admin
// changing its mind, or recovery vetoing a key it no longer trusts.
func CancelAction(cur realm, id string) {
	assertIsAdminOrRecovery(cur)
	a := getAction(id)
	if a == nil {
		return // idempotent: see CancelPending
	}
	pendingActions.Remove(id)
	veto(cur.Previous().Address(), "action", a.by)
	chain.Emit("ActionCancelled", "id", id, "by", cur.Previous().Address().String())
}

// CancelAllActions withdraws every pending action at once — the incident
// call, when nobody wants to read a list before acting. From recovery it
// is a veto: the admin proposes no action for one timelock.
func CancelAllActions(cur realm) {
	assertIsAdminOrRecovery(cur)
	n := dropAllActions("cancelled")
	if n > 0 {
		veto(cur.Previous().Address(), "action", admin)
	}
	chain.Emit("ActionsCancelled", "count", strconv.Itoa(n), "by", cur.Previous().Address().String())
}

/*
ConsumeAction spends a matured action. Trusted logic only, so it is also
gated by the pause: a paused registry executes nothing, timelocked or not.

It refuses an action proposed by anybody but the CURRENT admin. Rotation
already drops them all; this is the second lock on the same door, because
a matured proposal is a loaded instruction and the vault should not rely
on one rule to unload it.
*/
func ConsumeAction(cur realm, id string) {
	assertIsTrustedLogic(cur)
	if EvictionPending() {
		panic("nsdata: recovery is replacing the admin; timelocked actions wait for that, and die with it")
	}
	a := getAction(id)
	if a == nil {
		panic("nsdata: action `" + id + "` was never proposed; the admin proposes it with ProposeAction and it waits out the timelock")
	}
	now := time.Now().Unix()
	if now < a.at {
		panic("nsdata: action `" + id + "` is in its timelock until unix " + strconv.FormatInt(a.at, 10))
	}
	if now >= a.expires {
		panic("nsdata: action `" + id + "` expired at unix " + strconv.FormatInt(a.expires, 10) + "; propose it again")
	}
	if a.by != admin {
		panic("nsdata: action `" + id + "` was proposed by a previous admin")
	}
	pendingActions.Remove(id)
	chain.Emit("ActionExecuted", "id", id, "by", cur.Previous().Address().String())
}

// ActionReady reports whether an action could be consumed right now.
func ActionReady(id string) bool {
	a := getAction(id)
	if a == nil {
		return false
	}
	now := time.Now().Unix()
	return now >= a.at && now < a.expires && a.by == admin && !EvictionPending()
}

// GetAction reports a pending action: when it matures, when it expires,
// and who proposed it. All zero when nothing by that id is pending.
func GetAction(id string) (executableAt, expiresAt int64, by address) {
	a := getAction(id)
	if a == nil {
		return 0, 0, ""
	}
	return a.at, a.expires, a.by
}

// ListActions pages through pending action ids, ONE PER LINE: an id may
// contain commas (a price rule does), never a newline.
func ListActions(after string, limit int) (ids, next string) {
	if limit <= 0 || limit > maxPage {
		limit = maxPage
	}
	var b strings.Builder
	n := 0
	last, more := "", false
	pendingActions.Iterate("", "", func(key string, v any) bool {
		if after != "" && key <= after {
			return false
		}
		if n >= limit {
			more = true
			return true
		}
		if n > 0 {
			b.WriteString("\n")
		}
		b.WriteString(key)
		last = key
		n++
		return false
	})
	if !more {
		last = ""
	}
	return b.String(), last
}

func GetActionWindow() int64 { return actionWindow }

// SetActionWindow sets how long a matured action stays executable,
// between an hour and ninety days.
func SetActionWindow(cur realm, seconds int64) {
	assertIsAdminOrRecovery(cur)
	if seconds < minActionWindow || seconds > maxActionWindowS {
		panic("nsdata: the action window is 3600-7776000 seconds")
	}
	actionWindow = seconds
	chain.Emit("ActionWindowSet", "seconds", strconv.FormatInt(seconds, 10),
		"by", cur.Previous().Address().String())
}

// pruneExpiredActions frees the slots of actions nobody can execute any
// more. Bounded by maxPendingActions.
func pruneExpiredActions(now int64) {
	var dead []string
	pendingActions.Iterate("", "", func(key string, v any) bool {
		if now >= v.(*pendingAction).expires {
			dead = append(dead, key)
		}
		return false
	})
	for _, k := range dead {
		pendingActions.Remove(k)
		chain.Emit("ActionExpired", "id", k)
	}
}

func dropAllActions(reason string) int {
	var ids []string
	pendingActions.Iterate("", "", func(key string, v any) bool {
		ids = append(ids, key)
		return false
	})
	for _, k := range ids {
		pendingActions.Remove(k)
		chain.Emit("ActionInvalidated", "id", k, "reason", reason)
	}
	return len(ids)
}
