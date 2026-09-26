package timelock_guardian

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	owner    = testutils.TestAddress("owner")
	guardian = testutils.TestAddress("guardian")
	attacker = testutils.TestAddress("attacker")
	newOwner = testutils.TestAddress("newowner")
)

// resetState resets all package-level state between tests.
func resetState() {
	targets = make(map[string]*TargetConfig)
	targetNames = []string{}
	ownerTargets = make(map[address]int)
	actions = make(map[string]*Action)
	actionIDs = []string{}
	pending = make(map[string][]string)
	pendingTargets = []string{}
	ptIndex = make(map[string]int)
	nextID = 1
}

// heights advancing time: SkipHeights moves the clock 5s per height.
func skipSeconds(sec int64) {
	testing.SkipHeights((sec + 4) / 5)
}

func registerUpgrades(cur realm) string {
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterTarget(cross(cur), "upgrades", MinDelayFloor, guardian)
	return "upgrades"
}

// ---------- RegisterTarget ----------

func TestRegisterTarget_Basic(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	RegisterTarget(cross(cur), "upgrades", 120, guardian)

	tc := targets["upgrades"]
	uassert.Equal(t, string(owner), string(tc.Owner))
	uassert.Equal(t, string(guardian), string(tc.Guardian))
	uassert.Equal(t, int64(120), tc.MinDelay)
}

func TestRegisterTarget_NoGuardianAllowed(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	RegisterTarget(cross(cur), "plain", MinDelayFloor, "")
	uassert.Equal(t, "", string(targets["plain"].Guardian))
}

func TestRegisterTarget_DuplicateRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	uassert.AbortsWithMessage(t, cur,
		"target already registered: upgrades",
		func() { RegisterTarget(cross(cur), "upgrades", MinDelayFloor, "") },
	)
}

func TestRegisterTarget_InvalidNameRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	for _, bad := range []string{"", "Upgrades", "has space", strings.Repeat("a", MaxTargetNameLen+1)} {
		uassert.AbortsContains(t, cur,
			"target name must be",
			func() { RegisterTarget(cross(cur), bad, MinDelayFloor, "") },
		)
	}
}

func TestRegisterTarget_DelayBoundsEnforced(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsContains(t, cur,
		"minimum delay must be at least",
		func() { RegisterTarget(cross(cur), "too_fast", MinDelayFloor-1, "") },
	)
	uassert.AbortsContains(t, cur,
		"minimum delay exceeds the maximum",
		func() { RegisterTarget(cross(cur), "too_slow", MaxDelay+1, "") },
	)
}

func TestRegisterTarget_InvalidGuardianRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur,
		"invalid guardian address: junk",
		func() { RegisterTarget(cross(cur), "upgrades", MinDelayFloor, address("junk")) },
	)
}

// ---------- SetGuardian / two-step TransferTargetOwnership ----------

func TestSetGuardian_OwnerOnly(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the target owner can set the guardian",
		func() { SetGuardian(cross(cur), "upgrades", attacker) },
	)

	testing.SetRealm(testing.NewUserRealm(owner))
	SetGuardian(cross(cur), "upgrades", "")
	uassert.Equal(t, "", string(targets["upgrades"].Guardian))
}

func TestTransferTargetOwnership_TwoStep(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the target owner can transfer ownership",
		func() { TransferTargetOwnership(cross(cur), "upgrades", attacker) },
	)

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur,
		"invalid new owner address: junk",
		func() { TransferTargetOwnership(cross(cur), "upgrades", address("junk")) },
	)

	uassert.AbortsWithMessage(t, cur,
		"new owner is already the owner",
		func() { TransferTargetOwnership(cross(cur), "upgrades", owner) },
	)

	// the offer alone changes nothing
	TransferTargetOwnership(cross(cur), "upgrades", newOwner)
	uassert.Equal(t, string(owner), string(targets["upgrades"].Owner))
	uassert.Equal(t, string(newOwner), string(targets["upgrades"].PendingOwner))
	uassert.Equal(t, 1, ownerTargets[owner])
	uassert.Equal(t, 0, ownerTargets[newOwner])

	// only the nominee can accept
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"caller is not the pending owner",
		func() { AcceptTargetOwnership(cross(cur), "upgrades") },
	)

	testing.SetRealm(testing.NewUserRealm(newOwner))
	AcceptTargetOwnership(cross(cur), "upgrades")
	uassert.Equal(t, string(newOwner), string(targets["upgrades"].Owner))
	uassert.Equal(t, "", string(targets["upgrades"].PendingOwner))
	uassert.Equal(t, 0, ownerTargets[owner])
	uassert.Equal(t, 1, ownerTargets[newOwner])
}

func TestTransferTargetOwnership_ClearOffer(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	TransferTargetOwnership(cross(cur), "upgrades", newOwner)
	TransferTargetOwnership(cross(cur), "upgrades", "") // clear

	testing.SetRealm(testing.NewUserRealm(newOwner))
	uassert.AbortsWithMessage(t, cur,
		"caller is not the pending owner",
		func() { AcceptTargetOwnership(cross(cur), "upgrades") },
	)
}

func TestTransferTargetOwnership_QuotaCheckedAtAccept(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(newOwner))
	for i := 0; i < MaxTargetsPerOwner; i++ {
		RegisterTarget(cross(cur), "t_"+strings.Repeat("x", i+1), MinDelayFloor, "")
	}

	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	TransferTargetOwnership(cross(cur), "upgrades", newOwner) // offer succeeds

	// ...but accepting past the quota is refused, and ownership is unchanged
	testing.SetRealm(testing.NewUserRealm(newOwner))
	uassert.AbortsWithMessage(t, cur,
		"accepting would exceed the per-owner target limit",
		func() { AcceptTargetOwnership(cross(cur), "upgrades") },
	)
	uassert.Equal(t, string(owner), string(targets["upgrades"].Owner))
}

func TestUnsolicitedOfferConsumesNothing(cur realm, t *testing.T) {
	resetState()
	victim := testutils.TestAddress("victim")

	// fix Y5 regression: an attacker offering targets to a victim must
	// not consume the victim's quota or change any of their state
	testing.SetRealm(testing.NewUserRealm(attacker))
	for i := 0; i < MaxTargetsPerOwner; i++ {
		name := "junk_" + strings.Repeat("x", i+1)
		RegisterTarget(cross(cur), name, MinDelayFloor, "")
		TransferTargetOwnership(cross(cur), name, victim)
	}
	uassert.Equal(t, 0, ownerTargets[victim])

	// the victim can still register a full quota of their own targets
	testing.SetRealm(testing.NewUserRealm(victim))
	for i := 0; i < MaxTargetsPerOwner; i++ {
		RegisterTarget(cross(cur), "mine_"+strings.Repeat("y", i+1), MinDelayFloor, "")
	}
}

// ---------- Schedule ----------

func TestSchedule_OwnerOnly(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	// an attacker cannot schedule an action against someone else's
	// target — the core binding the audit found missing
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the target owner can schedule actions for upgrades",
		func() { Schedule(cross(cur), "upgrades", "malicious upgrade", MinDelayFloor) },
	)
}

func TestSchedule_UnregisteredTargetRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur,
		"target not found: ghost",
		func() { Schedule(cross(cur), "ghost", "data", MinDelayFloor) },
	)
}

func TestSchedule_MinDelayEnforced(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterTarget(cross(cur), "upgrades", 3600, "")

	// a delay below the target's registered minimum is rejected — no
	// more 1-second "timelocks"
	uassert.AbortsWithMessage(t, cur,
		"delay below the target's minimum of 3600 seconds",
		func() { Schedule(cross(cur), "upgrades", "data", 60) },
	)
}

func TestSchedule_MaxDelayEnforced(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	// overflow regression: a delay past MaxDelay must abort, never wrap
	// ExecuteAfter into the past
	uassert.AbortsContains(t, cur,
		"delay exceeds the maximum",
		func() { Schedule(cross(cur), "upgrades", "data", MaxDelay+1) },
	)
}

func TestSchedule_DataValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	uassert.AbortsWithMessage(t, cur,
		"data must not be empty",
		func() { Schedule(cross(cur), "upgrades", "", MinDelayFloor) },
	)
	uassert.AbortsContains(t, cur,
		"data exceeds",
		func() { Schedule(cross(cur), "upgrades", strings.Repeat("x", MaxDataLen+1), MinDelayFloor) },
	)
}

func TestSchedule_PendingCap(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	for i := 0; i < MaxPendingPerTarget; i++ {
		Schedule(cross(cur), "upgrades", "op", MinDelayFloor)
	}
	uassert.AbortsWithMessage(t, cur,
		"too many pending actions for target upgrades",
		func() { Schedule(cross(cur), "upgrades", "op", MinDelayFloor) },
	)
}

func TestSchedule_SetsWindows(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	id := Schedule(cross(cur), "upgrades", "rotate keys", 120)
	a := actions[id]
	uassert.Equal(t, int64(120), int64(a.ExecuteAfter.Sub(a.ScheduledAt).Seconds()))
	uassert.Equal(t, GracePeriod, int64(a.ExpiresAt.Sub(a.ExecuteAfter).Seconds()))
}

// ---------- Execute ----------

func TestExecute_TooEarlyBlocked(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)

	uassert.AbortsContains(t, cur, "too early", func() { Execute(cross(cur), id) })
	uassert.False(t, IsReady(id), "must not be ready before the delay")
}

func TestExecute_ReadyAfterDelay_AnyoneCanExecute(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)

	skipSeconds(MinDelayFloor)
	uassert.True(t, IsReady(id), "must be ready after the delay")

	// executor identity is deliberately unrestricted
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.Equal(t, "executed: "+id, Execute(cross(cur), id))
	uassert.True(t, IsExecuted(id), "must record execution")
}

func TestExecute_TwiceBlocked(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)
	skipSeconds(MinDelayFloor)
	Execute(cross(cur), id)

	uassert.AbortsWithMessage(t, cur, "action already executed", func() { Execute(cross(cur), id) })
}

func TestExecute_ExpiredBlocked(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)

	// travel past the grace window: stale actions cannot be sprung later
	skipSeconds(MinDelayFloor + GracePeriod + 10)
	uassert.False(t, IsReady(id), "expired action must not be ready")
	uassert.AbortsContains(t, cur, "action expired", func() { Execute(cross(cur), id) })
	uassert.Equal(t, "none", GetPending())
}

// ---------- Cancel / Veto ----------

func TestCancel_CurrentOwnerOnly(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the target owner can cancel",
		func() { Cancel(cross(cur), id) },
	)

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.Equal(t, "cancelled: "+id, Cancel(cross(cur), id))
	_, present := actions[id]
	uassert.False(t, present, "cancelled action must be reaped from state")

	// re-audit P3: after an ownership transfer the SCHEDULING creator
	// loses cancel rights; only the current owner holds them
	id2 := Schedule(cross(cur), "upgrades", "op2", MinDelayFloor)
	TransferTargetOwnership(cross(cur), "upgrades", newOwner)
	testing.SetRealm(testing.NewUserRealm(newOwner))
	AcceptTargetOwnership(cross(cur), "upgrades")
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur,
		"only the target owner can cancel",
		func() { Cancel(cross(cur), id2) },
	)
	testing.SetRealm(testing.NewUserRealm(newOwner))
	uassert.Equal(t, "cancelled: "+id2, Cancel(cross(cur), id2))
}

func TestCancel_ExecutedBlocked(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)
	skipSeconds(MinDelayFloor)
	Execute(cross(cur), id)

	uassert.AbortsWithMessage(t, cur,
		"cannot cancel an already-executed action",
		func() { Cancel(cross(cur), id) },
	)
}

func TestVeto_GuardianOnly(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the target guardian can veto",
		func() { Veto(cross(cur), id) },
	)

	testing.SetRealm(testing.NewUserRealm(guardian))
	uassert.Equal(t, "vetoed: "+id, Veto(cross(cur), id))
	_, present := actions[id]
	uassert.False(t, present, "vetoed action must be reaped from state")

	// a vetoed action can never execute
	skipSeconds(MinDelayFloor)
	uassert.AbortsWithMessage(t, cur, "action not found: "+id, func() { Execute(cross(cur), id) })
}

func TestVeto_NoGuardianTargetBlocked(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterTarget(cross(cur), "plain", MinDelayFloor, "")
	id := Schedule(cross(cur), "plain", "op", MinDelayFloor)

	testing.SetRealm(testing.NewUserRealm(guardian))
	uassert.AbortsWithMessage(t, cur,
		"target has no guardian: plain",
		func() { Veto(cross(cur), id) },
	)
}

// ---------- Expire (fix Y2) ----------

func TestExpire_PermissionlessRecovery(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	// fill the target's quota, then let everything expire
	var ids []string
	for i := 0; i < MaxPendingPerTarget; i++ {
		ids = append(ids, Schedule(cross(cur), "upgrades", "op", MinDelayFloor))
	}
	skipSeconds(MinDelayFloor + GracePeriod + 10)

	// fix Y2 regression: ANYONE — not just a lucky sweep window — can
	// reap a provably expired action and free the slot it wedges
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.Equal(t, "expired: "+ids[0], Expire(cross(cur), ids[0]))
	_, present := actions[ids[0]]
	uassert.False(t, present, "expired action must be reaped from state")

	// reap the rest as the owner; quota and SetGuardian both recover
	testing.SetRealm(testing.NewUserRealm(owner))
	for _, id := range ids[1:] {
		Expire(cross(cur), id)
	}
	uassert.Equal(t, 0, pendingCount("upgrades"))
	SetGuardian(cross(cur), "upgrades", "") // no longer blocked
	Schedule(cross(cur), "upgrades", "fresh", MinDelayFloor)
}

func TestExpire_RefusesLiveAndExecuted(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	live := Schedule(cross(cur), "upgrades", "live", MinDelayFloor)
	done := Schedule(cross(cur), "upgrades", "done", MinDelayFloor)
	skipSeconds(MinDelayFloor)
	Execute(cross(cur), done)

	uassert.AbortsWithMessage(t, cur, "action is not expired",
		func() { Expire(cross(cur), live) })
	uassert.AbortsWithMessage(t, cur, "action already executed",
		func() { Expire(cross(cur), done) })
	uassert.AbortsWithMessage(t, cur, "action not found: ghost",
		func() { Expire(cross(cur), "ghost") })
}

// ---------- stray sends (fix Y6) ----------

func TestStraySendRejectedEverywhere(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)

	// fix Y6 regression: this realm holds no banker, so an attached
	// send would strand on the realm address forever — every crossing
	// function must abort it (the abort reverts the transfer)
	msg := "this realm does not accept coins"
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 5}})
	uassert.AbortsWithMessage(t, cur, msg, func() { RegisterTarget(cross(cur), "paid", MinDelayFloor, "") })
	uassert.AbortsWithMessage(t, cur, msg, func() { Schedule(cross(cur), "upgrades", "op2", MinDelayFloor) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Cancel(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, msg, func() { SetGuardian(cross(cur), "upgrades", "") })
	uassert.AbortsWithMessage(t, cur, msg, func() { TransferTargetOwnership(cross(cur), "upgrades", newOwner) })
	uassert.AbortsWithMessage(t, cur, msg, func() { AcceptTargetOwnership(cross(cur), "upgrades") })
	uassert.AbortsWithMessage(t, cur, msg, func() { Veto(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Expire(cross(cur), id) })
	// SkipHeights resets the test context (wiping the send envelope),
	// so re-arm it before probing the ready-action Execute path
	skipSeconds(MinDelayFloor)
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 5}})
	uassert.AbortsWithMessage(t, cur, msg, func() { Execute(cross(cur), id) })
	testing.SetOriginSend(nil)

	// without coins the same call succeeds
	uassert.Equal(t, "executed: "+id, Execute(cross(cur), id))
}

// ---------- queries + render ----------

func TestGetPending_ExcludesFinished(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id1 := Schedule(cross(cur), "upgrades", "op1", MinDelayFloor)
	id2 := Schedule(cross(cur), "upgrades", "op2", MinDelayFloor)
	id3 := Schedule(cross(cur), "upgrades", "op3", MinDelayFloor)

	Cancel(cross(cur), id2)
	skipSeconds(MinDelayFloor)
	Execute(cross(cur), id1)

	uassert.Equal(t, id3, GetPending())
}

func TestGetPending_GroupedByTarget(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterTarget(cross(cur), "alpha", MinDelayFloor, "")
	RegisterTarget(cross(cur), "beta", MinDelayFloor, "")

	// interleave scheduling across targets; output groups by target in
	// registration order (fix Y4 bookkeeping), insertion-ordered within
	a1 := Schedule(cross(cur), "alpha", "a1", MinDelayFloor)
	b1 := Schedule(cross(cur), "beta", "b1", MinDelayFloor)
	a2 := Schedule(cross(cur), "alpha", "a2", MinDelayFloor)

	uassert.Equal(t, a1+", "+a2+", "+b1, GetPending())
	uassert.Equal(t, 2, pendingCount("alpha"))
	uassert.Equal(t, 1, pendingCount("beta"))

	Cancel(cross(cur), a1)
	uassert.Equal(t, a2+", "+b1, GetPending())
	uassert.Equal(t, 1, pendingCount("alpha"))
}

func TestGetTarget_Summary(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	out := GetTarget("upgrades")
	uassert.True(t, strings.Contains(out, string(owner)), "must show owner")
	uassert.True(t, strings.Contains(out, string(guardian)), "must show guardian")
	uassert.True(t, strings.Contains(out, "Min delay: 60s"), "must show min delay")

	TransferTargetOwnership(cross(cur), "upgrades", newOwner)
	uassert.True(t, strings.Contains(GetTarget("upgrades"), "Pending owner: "+string(newOwner)),
		"must show a pending ownership offer")
}

func TestRender_SanitizesInjection(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	Schedule(cross(cur), "upgrades", "evil` | injected\nrow", MinDelayFloor)

	out := Render("")
	uassert.False(t, strings.Contains(out, "evil`"), "backticks must be sanitized")
	uassert.False(t, strings.Contains(out, "injected\nrow"), "newlines must be sanitized")
}

func TestRender_SanitizesHTMLBrackets(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	// fix Y3 regression: raw HTML must never reach the page
	Schedule(cross(cur), "upgrades", "<script>alert(1)</script>", MinDelayFloor)

	out := Render("")
	uassert.False(t, strings.Contains(out, "<script"), "script tags must be sanitized in Render")
	uassert.False(t, strings.Contains(out, "</script"), "closing tags must be sanitized in Render")
	one := GetAction(GetPending())
	uassert.False(t, strings.Contains(one, "<script"), "script tags must be sanitized in GetAction")
}

func TestRender_EmptyState(cur realm, t *testing.T) {
	resetState()
	uassert.Equal(t, "# Timelock Guardian\n\nNo actions scheduled.\n", Render(""))
}

func TestRender_Sections(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id1 := Schedule(cross(cur), "upgrades", "op1", MinDelayFloor)
	id2 := Schedule(cross(cur), "upgrades", "op2", MinDelayFloor)
	Schedule(cross(cur), "upgrades", "op3", MinDelayFloor)
	skipSeconds(MinDelayFloor)
	Execute(cross(cur), id1)
	Cancel(cross(cur), id2)

	out := Render("")
	uassert.True(t, strings.Contains(out, "## Executed (1)"), "executed section")
	uassert.True(t, strings.Contains(out, "## Pending (1)"), "pending section")
	uassert.False(t, strings.Contains(out, "Cancelled"), "cancelled actions are reaped, not rendered")
}

// ---------- re-audit regressions (2026-09-02) ----------

func TestScheduleCancelCycling_CannotBrickTheRealm(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	// re-audit P1: the old lifetime cap could be consumed forever by
	// schedule+cancel cycling; the cap now bounds LIVE actions and
	// cancelled records are reaped, so heavy cycling leaves no residue
	for i := 0; i < 3*MaxPendingPerTarget; i++ {
		id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)
		Cancel(cross(cur), id)
	}
	uassert.Equal(t, 0, len(actions), "cycling must leave no state residue")
	uassert.Equal(t, 0, pendingCount("upgrades"), "no live actions after cycling")
	Schedule(cross(cur), "upgrades", "op", MinDelayFloor) // must not abort
}

func TestSetGuardian_BlockedWhilePending(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "rug", MinDelayFloor)

	// re-audit P2: the owner must not be able to strip the guardian
	// during the delay window the guardian exists to police
	uassert.AbortsWithMessage(t, cur,
		"cannot change the guardian while actions are pending",
		func() { SetGuardian(cross(cur), "upgrades", "") },
	)

	// once nothing is pending, the owner may change the guardian
	Cancel(cross(cur), id)
	SetGuardian(cross(cur), "upgrades", "")
	uassert.Equal(t, "", string(targets["upgrades"].Guardian))
}

func TestVetoAndCancel_RefuseExpired(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	id := Schedule(cross(cur), "upgrades", "op", MinDelayFloor)
	skipSeconds(MinDelayFloor + GracePeriod + 10)

	// re-audit P3: terminal-state writes on expired actions rewrote
	// history; both must refuse and point at the Expire valve
	uassert.AbortsWithMessage(t, cur, "action expired: nothing to cancel (use Expire)",
		func() { Cancel(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(guardian))
	uassert.AbortsWithMessage(t, cur, "action expired: nothing to veto (use Expire)",
		func() { Veto(cross(cur), id) })
}

func TestExpiredActions_ReapedOnSchedule(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	Schedule(cross(cur), "upgrades", "op", MinDelayFloor)
	skipSeconds(MinDelayFloor + GracePeriod + 10)

	// the next Schedule sweeps expired actions out of state
	Schedule(cross(cur), "upgrades", "op2", MinDelayFloor)
	uassert.Equal(t, 1, len(actions), "expired action must be reaped by the sweep")
}

func TestRender_LinkInjectionSanitized(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	Schedule(cross(cur), "upgrades", "[approve](https://evil.example)", MinDelayFloor)

	out := Render("")
	uassert.False(t, strings.Contains(out, "[approve]"), "link syntax must be sanitized")
}

func TestPerOwnerTargetCap(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	for i := 0; i < MaxTargetsPerOwner; i++ {
		RegisterTarget(cross(cur), "t_"+strings.Repeat("x", i+1), MinDelayFloor, "")
	}
	uassert.AbortsWithMessage(t, cur,
		"per-owner target limit reached",
		func() { RegisterTarget(cross(cur), "one_more", MinDelayFloor, "") },
	)
}

// ---------- round-3 audit regressions (2026-09-02) ----------

func TestSybilsCannotExhaustSharedCapacity(cur realm, t *testing.T) {
	resetState()

	// round-3 P1: two attackers filling their OWN per-owner quotas must
	// never block a third owner's Schedule — there is no shared cap left
	// to exhaust
	sybils := []address{testutils.TestAddress("sybil_a"), testutils.TestAddress("sybil_b")}
	for _, syb := range sybils {
		testing.SetRealm(testing.NewUserRealm(syb))
		for i := 0; i < MaxTargetsPerOwner; i++ {
			name := "t_" + string(syb[len(syb)-4:]) + "_" + strings.Repeat("x", i+1)
			RegisterTarget(cross(cur), name, MinDelayFloor, "")
			for j := 0; j < MaxPendingPerTarget; j++ {
				Schedule(cross(cur), name, "spam", MaxDelay) // 10y delay: sweep reclaims nothing
			}
		}
	}

	// a legitimate owner is entirely unaffected
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterTarget(cross(cur), "legit", MinDelayFloor, "")
	Schedule(cross(cur), "legit", "real work", MinDelayFloor) // must not abort
}

func TestVictimRecoversBehindSybilWall(cur realm, t *testing.T) {
	resetState()

	// fix Y2/Y4 regression — the exact starvation case the old global
	// budget-windowed sweep could not recover from: a wall of long-delay
	// sybil actions in front, a victim whose actions expired behind it.
	// Per-target sweeps and permissionless Expire make recovery local.
	syb := testutils.TestAddress("wall")
	testing.SetRealm(testing.NewUserRealm(syb))
	for i := 0; i < 5; i++ {
		name := "wall_" + strings.Repeat("w", i+1)
		RegisterTarget(cross(cur), name, MinDelayFloor, "")
		for j := 0; j < MaxPendingPerTarget; j++ {
			Schedule(cross(cur), name, "wall", MaxDelay) // 100 live 10y entries
		}
	}

	victim := testutils.TestAddress("victim2")
	testing.SetRealm(testing.NewUserRealm(victim))
	RegisterTarget(cross(cur), "vt", MinDelayFloor, guardian)
	var ids []string
	for j := 0; j < MaxPendingPerTarget; j++ {
		ids = append(ids, Schedule(cross(cur), "vt", "op", MinDelayFloor))
	}
	skipSeconds(MinDelayFloor + GracePeriod + 10) // all 20 expire

	// the victim's own next Schedule sweeps THEIR target despite the wall
	Schedule(cross(cur), "vt", "recovered", MinDelayFloor)
	uassert.Equal(t, 1, pendingCount("vt"), "expired actions swept despite the sybil wall")

	// and Expire frees a wedged slot directly, from any key
	id2 := Schedule(cross(cur), "vt", "will expire", MinDelayFloor)
	testing.SetRealm(testing.NewUserRealm(attacker))
	skipSeconds(MinDelayFloor + GracePeriod + 10)
	Expire(cross(cur), id2)
	_, present := actions[id2]
	uassert.False(t, present, "Expire must reap regardless of global queue position")
}

func TestPendingCounterConsistency(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)

	id1 := Schedule(cross(cur), "upgrades", "a", MinDelayFloor)
	id2 := Schedule(cross(cur), "upgrades", "b", MinDelayFloor)
	Schedule(cross(cur), "upgrades", "c", MinDelayFloor)
	uassert.Equal(t, 3, pendingCount("upgrades"))

	Cancel(cross(cur), id1)
	uassert.Equal(t, 2, pendingCount("upgrades"))
	skipSeconds(MinDelayFloor)
	Execute(cross(cur), id2)
	uassert.Equal(t, 1, pendingCount("upgrades"))

	// expiry: the count drops when the sweep reaps
	skipSeconds(GracePeriod + 10)
	Schedule(cross(cur), "upgrades", "d", MinDelayFloor) // triggers sweep of expired "c"
	uassert.Equal(t, 1, pendingCount("upgrades"))
}

func TestSanitize_EmphasisMarkers(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	Schedule(cross(cur), "upgrades", "**ready** _now_", MinDelayFloor)

	out := Render("")
	uassert.False(t, strings.Contains(out, "**ready** _now_"),
		"emphasis markers in Data must be sanitized")
}

// ---------- render-index bounds (fix Y4) ----------

func TestRenderIndexSelfTrims(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterTarget(cross(cur), "churn", MinDelayFloor, "")

	// execute many actions so actionIDs would grow unboundedly without
	// the trim; the index must stay within RenderIndexCap and old
	// executed records must stay queryable via the map reads
	var first string
	for i := 0; i < RenderIndexCap+30; i++ {
		id := Schedule(cross(cur), "churn", "op", MinDelayFloor)
		if i == 0 {
			first = id
		}
		skipSeconds(MinDelayFloor)
		Execute(cross(cur), id)
	}
	uassert.True(t, len(actionIDs) <= RenderIndexCap, "render index must self-trim")
	uassert.True(t, IsExecuted(first), "trimmed records stay queryable forever")
	uassert.True(t, strings.Contains(GetAction(first), "Status: executed"),
		"GetAction must still serve trimmed records")
}

// ---------- round-2 audit regressions ----------

func TestSetGuardian_SweepsExpiredFirst(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	registerUpgrades(cur)
	Schedule(cross(cur), "upgrades", "op", MinDelayFloor)
	skipSeconds(MinDelayFloor + GracePeriod + 10)

	// round-2 hardening: expired-but-unswept actions protect nothing
	// and must not block a guardian rotation
	SetGuardian(cross(cur), "upgrades", "")
	uassert.Equal(t, "", string(targets["upgrades"].Guardian))
	uassert.Equal(t, 0, pendingCount("upgrades"), "the gate sweep must reap expired actions")
}

func TestRenderShowsPendingDespiteChurn(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterTarget(cross(cur), "vis", MinDelayFloor, "")
	watched := Schedule(cross(cur), "vis", "watched rug", 2*(MinDelayFloor+5*(RenderIndexCap+30)))

	// round-2 fix Y-2: flood the render index with executed churn; the
	// live pending action must remain visible for its whole window
	RegisterTarget(cross(cur), "churn2", MinDelayFloor, "")
	for i := 0; i < RenderIndexCap+30; i++ {
		id := Schedule(cross(cur), "churn2", "noise", MinDelayFloor)
		skipSeconds(MinDelayFloor)
		Execute(cross(cur), id)
	}

	out := Render("")
	uassert.True(t, strings.Contains(out, watched), "a live pending action must survive render-index churn")
	uassert.True(t, strings.Contains(out, "## Pending (1)"), "pending section from live lists")

	// and state stays consistent for an action trimmed out of the
	// render index: Cancel still works (absent-id removeID is a no-op)
	uassert.Equal(t, "cancelled: "+watched, Cancel(cross(cur), watched))
	uassert.Equal(t, 0, pendingCount("vis"))
}

func TestPendingTargetsBookkeeping(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterTarget(cross(cur), "one", MinDelayFloor, "")
	RegisterTarget(cross(cur), "two", MinDelayFloor, "")

	// round-2 fix Y-1: only targets with live pendings are tracked
	uassert.Equal(t, 0, len(pendingTargets))
	a1 := Schedule(cross(cur), "one", "a", MinDelayFloor)
	Schedule(cross(cur), "two", "b", MinDelayFloor)
	uassert.Equal(t, 2, len(pendingTargets))

	Cancel(cross(cur), a1)
	uassert.Equal(t, 1, len(pendingTargets), "emptied target leaves the with-pendings list")
	uassert.Equal(t, 1, len(ptIndex))

	// registration alone never inflates the list
	RegisterTarget(cross(cur), "three", MinDelayFloor, "")
	uassert.Equal(t, 1, len(pendingTargets))
}
