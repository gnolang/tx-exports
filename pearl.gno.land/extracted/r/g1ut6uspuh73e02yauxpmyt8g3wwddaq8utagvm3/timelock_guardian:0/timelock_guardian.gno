package timelock_guardian

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

// TargetConfig binds a named target to the only address allowed to
// schedule actions against it, an enforced minimum delay, and an
// optional guardian who can veto pending actions. Without this binding
// a timelock attests nothing: anyone could schedule their own
// short-delay action against any name and "execute" it.
type TargetConfig struct {
	Name     string
	Owner    address
	Guardian address // empty = no guardian
	MinDelay int64   // seconds; every action for this target waits at least this
	// PendingOwner is the offered-but-not-accepted new owner (fix Y5:
	// ownership moves in two steps, so a stranger can never have a
	// target — and its quota slot and pending obligations — dumped on
	// them without consenting).
	PendingOwner address
}

// Action represents a scheduled operation that can only execute after
// its delay has elapsed, and only within its grace window.
//
// State model (re-audit 2026-09-02): only PENDING and EXECUTED actions
// are stored. Executed records are permanent attestations consumers
// check via IsExecuted. Cancelled, vetoed, and expired actions are
// REAPED from state — their history lives in emitted events — so the
// live-action cap bounds live exposure and can never be consumed
// permanently by schedule/cancel cycling.
type Action struct {
	ID           string
	Target       string
	Creator      address
	Data         string // encoded call data or description of the action
	ScheduledAt  time.Time
	ExecuteAfter time.Time
	ExpiresAt    time.Time // ExecuteAfter + GracePeriod; not executable after
	Executed     bool
}

const (
	// MinDelayFloor is the smallest minimum delay a target may register.
	// A timelock with a 1-second delay protects nothing.
	MinDelayFloor = int64(60)

	// MaxDelay bounds both registered minimum delays and per-action
	// delays. Also the overflow guard: MaxDelay seconds in nanoseconds
	// is far below int64 range, so ExecuteAfter arithmetic cannot wrap
	// into the past.
	MaxDelay = int64(10 * 365 * 24 * 3600) // 10 years

	// GracePeriod is how long an action stays executable once ready.
	// After it, the action expires: something scheduled and forgotten
	// cannot be sprung on a target years later.
	GracePeriod = int64(30 * 24 * 3600) // 30 days

	// Quotas are PER-OWNER only (re-audit round 3): any global cap is a
	// shared resource a few sybil accounts can exhaust forever (10y
	// delays defeat expiry sweeping), bricking every other tenant. With
	// per-owner quotas an attacker only ever consumes their own budget;
	// state growth is priced in gas and funded accounts.
	MaxTargetsPerOwner  = 10
	MaxPendingPerTarget = 20
	MaxTargetNameLen    = 64
	MaxDataLen          = 2000
	MaxRenderActions    = 100
	// RenderIndexCap bounds the render-ordering index (fix Y4): the
	// index self-trims to this size, so reaping an entry from it is a
	// bounded scan no matter how many actions the realm has ever seen.
	// Records older than the window stay in state (GetAction/IsExecuted
	// are map reads and permanent); they only leave the front page.
	RenderIndexCap = 2 * MaxRenderActions
)

var (
	targets      map[string]*TargetConfig
	targetNames  []string // insertion-ordered for deterministic iteration
	ownerTargets map[address]int
	actions      map[string]*Action
	actionIDs    []string // insertion-ordered render window, self-trimmed to RenderIndexCap
	// pending holds each target's LIVE pending action IDs in insertion
	// order (fix Y4): every list is bounded by MaxPendingPerTarget, so
	// scans, sweeps, and removals are bounded per call regardless of how
	// much state OTHER tenants have grown — queue position in a global
	// list is no longer a shared resource.
	pending map[string][]string
	// pendingTargets lists the targets holding >= 1 live pending action,
	// maintained with O(1) swap-remove via ptIndex (round-2 fix Y-1): no
	// write path ever scans a list another tenant can grow, and
	// GetPending/Render iterate only targets that actually have work.
	pendingTargets []string
	ptIndex        map[string]int
	nextID         int
)

func init() {
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

func now() time.Time {
	return time.Now()
}

// ---------- helpers ----------

// rejectStraySend aborts when coins are attached to a call (fix Y6):
// this realm handles no funds and holds no banker, so an attached send
// would strand on the realm address forever. Aborting reverts the
// transfer back to the sender. Fails open for realm-routed calls, whose
// attached send lands on the intermediary realm, never here.
func rejectStraySend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this realm does not accept coins")
	}
}

func mustGetTarget(name string) *TargetConfig {
	t, ok := targets[name]
	if !ok {
		panic("target not found: " + name)
	}
	return t
}

func mustGet(id string) *Action {
	a, ok := actions[id]
	if !ok {
		panic("action not found: " + id)
	}
	return a
}

func isValidName(name string) bool {
	if name == "" || len(name) > MaxTargetNameLen {
		return false
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}

func expired(a *Action) bool {
	return !a.Executed && now().After(a.ExpiresAt)
}

func removeID(list []string, id string) []string {
	for i, x := range list {
		if x == id {
			return append(list[:i], list[i+1:]...)
		}
	}
	return list
}

func addPendingTarget(target string) {
	if _, ok := ptIndex[target]; ok {
		return
	}
	ptIndex[target] = len(pendingTargets)
	pendingTargets = append(pendingTargets, target)
}

// removePendingTarget drops a target from the with-pendings list in
// O(1) by swapping the last entry into its slot. Order afterwards is
// deterministic (a pure function of the operation history), which is
// all iteration needs.
func removePendingTarget(target string) {
	i, ok := ptIndex[target]
	if !ok {
		return
	}
	last := len(pendingTargets) - 1
	moved := pendingTargets[last]
	pendingTargets[i] = moved
	ptIndex[moved] = i
	pendingTargets = pendingTargets[:last]
	delete(ptIndex, target)
}

// dropPending removes id from its target's pending list. Bounded: the
// list never exceeds MaxPendingPerTarget.
func dropPending(target, id string) {
	l := removeID(pending[target], id)
	if len(l) == 0 {
		delete(pending, target)
		removePendingTarget(target)
	} else {
		pending[target] = l
	}
}

// reap removes a non-executed action from state entirely; its history
// is the emitted event. Executed records are permanent attestations:
// reap refuses them outright (round-2 hardening), so no future caller
// can erase one by mistake.
func reap(id string) {
	a := actions[id]
	if a != nil && a.Executed {
		return
	}
	if a != nil {
		dropPending(a.Target, id)
	}
	delete(actions, id)
	actionIDs = removeID(actionIDs, id)
}

// sweepExpired reaps the expired pending actions of ONE target (fix
// Y4/Y2: the old global budget-windowed sweep let long-delay entries at
// the front of a shared queue starve everything behind them). A
// target's list is bounded by MaxPendingPerTarget, so the sweep is a
// bounded scan. Expiry history is the emitted event.
func sweepExpired(target string) {
	var live []string
	for _, id := range pending[target] {
		a := actions[id]
		if a == nil {
			continue
		}
		if expired(a) {
			chain.Emit("timelock_expired", "id", id, "target", a.Target)
			delete(actions, id)
			actionIDs = removeID(actionIDs, id)
			continue
		}
		live = append(live, id)
	}
	if len(live) == 0 {
		delete(pending, target)
		removePendingTarget(target)
	} else {
		pending[target] = live
	}
}

// pendingCount is the length of the target's live list. The counter it
// replaces (fix Y4) could desync from the lists it mirrored; a length
// cannot. It may briefly include not-yet-swept expired actions; those
// are reaped by the next Schedule's sweep or by anyone's Expire, and in
// the worst case an owner briefly under-uses their own quota — never
// another tenant's.
func pendingCount(target string) int {
	return len(pending[target])
}

// sanitize makes attacker-controlled text safe to embed in markdown and
// single-line summaries: backticks, pipes, newlines, link syntax, and
// raw HTML brackets (fix Y3: gnoweb has no HTML sanitization layer, so
// a literal <script> tag must never reach the page) are replaced so a
// Data string cannot break out of its cell, inject rows or markup, or
// render a live link.
func sanitize(s string) string {
	r := strings.NewReplacer(
		"`", "'", "|", "/", "\n", " ", "\r", " ",
		"[", "(", "]", ")", "*", "·", "_", "-",
		"<", "(", ">", ")",
	)
	return r.Replace(s)
}

// truncate shortens s to at most n runes without splitting a multibyte
// character. n is clamped to a minimum of 4 (re-audit: n<=2 sliced out
// of bounds).
func truncate(s string, n int) string {
	if n < 4 {
		n = 4
	}
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n-3]) + "..."
}

// ---------- target registration ----------

// RegisterTarget creates a named target. The caller becomes its owner —
// the only address that may schedule actions against it. minDelay is
// the enforced floor for every action's delay. guardian may be empty
// (no guardian) or an address empowered to veto pending actions.
func RegisterTarget(cur realm, name string, minDelay int64, guardian address) {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	if !isValidName(name) {
		panic("target name must be 1-" + strconv.Itoa(MaxTargetNameLen) +
			" chars, lowercase alphanumeric with underscores only")
	}
	if _, exists := targets[name]; exists {
		panic("target already registered: " + name)
	}
	if ownerTargets[owner] >= MaxTargetsPerOwner {
		panic("per-owner target limit reached")
	}
	if minDelay < MinDelayFloor {
		panic("minimum delay must be at least " + strconv.FormatInt(MinDelayFloor, 10) + " seconds")
	}
	if minDelay > MaxDelay {
		panic("minimum delay exceeds the maximum of " + strconv.FormatInt(MaxDelay, 10) + " seconds")
	}
	if guardian != "" && !guardian.IsValid() {
		panic("invalid guardian address: " + string(guardian))
	}

	targets[name] = &TargetConfig{
		Name:     name,
		Owner:    owner,
		Guardian: guardian,
		MinDelay: minDelay,
	}
	targetNames = append(targetNames, name)
	ownerTargets[owner]++
	chain.Emit("timelock_target_registered", "target", name,
		"owner", string(owner), "guardian", string(guardian),
		"min_delay", strconv.FormatInt(minDelay, 10))
}

// SetGuardian changes (or clears, with "") the target's guardian.
// Owner only, and REFUSED while the target has pending actions: the
// guardian's veto power exists precisely to check the owner during a
// delay window, so the owner must not be able to strip it mid-window.
//
// KNOWN LIMIT (documented, round-3 audit): the owner can cancel all
// pending actions, change the guardian, and reschedule — the price is
// a full fresh MinDelay on every rescheduled action, and every step
// emits an event (cancellations + the guardian change below), so
// observers always get MinDelay of warning under the new guardian
// regime. Guardians protect open windows, not the owner's future.
func SetGuardian(cur realm, targetName string, guardian address) {
	rejectStraySend(cur)
	t := mustGetTarget(targetName)
	if cur.Previous().Address() != t.Owner {
		panic("only the target owner can set the guardian")
	}
	// expired-but-unswept actions protect nothing; sweep them so they
	// cannot block a guardian rotation (round-2 hardening)
	sweepExpired(targetName)
	if pendingCount(targetName) > 0 {
		panic("cannot change the guardian while actions are pending")
	}
	if guardian != "" && !guardian.IsValid() {
		panic("invalid guardian address: " + string(guardian))
	}
	t.Guardian = guardian
	chain.Emit("timelock_guardian_changed", "target", targetName,
		"guardian", string(guardian))
}

// TransferTargetOwnership OFFERS a target to a new owner; the nominee
// must AcceptTargetOwnership to complete it (fix Y5: a one-step
// transfer let anyone fill a stranger's per-owner quota and dump
// pending obligations — with an attacker-chosen guardian — on an
// address that never asked). Owner only. Pass "" to clear a pending
// offer. Nothing changes hands until the nominee accepts.
func TransferTargetOwnership(cur realm, targetName string, newOwner address) {
	rejectStraySend(cur)
	t := mustGetTarget(targetName)
	if cur.Previous().Address() != t.Owner {
		panic("only the target owner can transfer ownership")
	}
	if newOwner == "" {
		t.PendingOwner = ""
		chain.Emit("timelock_ownership_offer_cleared", "target", targetName)
		return
	}
	if !newOwner.IsValid() {
		panic("invalid new owner address: " + string(newOwner))
	}
	if newOwner == t.Owner {
		panic("new owner is already the owner")
	}
	t.PendingOwner = newOwner
	chain.Emit("timelock_ownership_offered", "target", targetName,
		"pending_owner", string(newOwner))
}

// AcceptTargetOwnership completes a pending ownership offer; only the
// nominee can accept. The nominee's quota is checked HERE — consent
// time — so an offer can never overfill an account that did not agree
// to carry it.
func AcceptTargetOwnership(cur realm, targetName string) {
	rejectStraySend(cur)
	t := mustGetTarget(targetName)
	a := cur.Previous().Address()
	if t.PendingOwner == "" || a != t.PendingOwner {
		panic("caller is not the pending owner")
	}
	if ownerTargets[a] >= MaxTargetsPerOwner {
		panic("accepting would exceed the per-owner target limit")
	}
	ownerTargets[t.Owner]--
	if ownerTargets[t.Owner] <= 0 {
		delete(ownerTargets, t.Owner)
	}
	ownerTargets[a]++
	t.Owner = a
	t.PendingOwner = ""
	chain.Emit("timelock_ownership_transferred", "target", targetName,
		"new_owner", string(a))
}

// ---------- write operations ----------

// Schedule creates a new timelocked action against a registered target.
// Only the target's owner may schedule. The delay must be at least the
// target's registered minimum and at most MaxDelay. Returns the action ID.
func Schedule(cur realm, targetName, data string, delay int64) string {
	rejectStraySend(cur)
	t := mustGetTarget(targetName)
	caller := cur.Previous().Address()
	if caller != t.Owner {
		panic("only the target owner can schedule actions for " + targetName)
	}
	if data == "" {
		panic("data must not be empty")
	}
	if len(data) > MaxDataLen {
		panic("data exceeds " + strconv.Itoa(MaxDataLen) + " bytes")
	}
	if delay < t.MinDelay {
		panic("delay below the target's minimum of " + strconv.FormatInt(t.MinDelay, 10) + " seconds")
	}
	if delay > MaxDelay {
		panic("delay exceeds the maximum of " + strconv.FormatInt(MaxDelay, 10) + " seconds")
	}

	sweepExpired(targetName)
	if pendingCount(targetName) >= MaxPendingPerTarget {
		panic("too many pending actions for target " + targetName)
	}

	id := "action_" + strconv.Itoa(nextID)
	nextID++

	ts := now()
	execAfter := ts.Add(time.Duration(delay) * time.Second)
	actions[id] = &Action{
		ID:           id,
		Target:       targetName,
		Creator:      caller,
		Data:         data,
		ScheduledAt:  ts,
		ExecuteAfter: execAfter,
		ExpiresAt:    execAfter.Add(time.Duration(GracePeriod) * time.Second),
	}
	actionIDs = append(actionIDs, id)
	// self-trim (fix Y4): the render index stays bounded, so reaping an
	// entry from it can never become an unbounded scan. Trimmed entries
	// remain in the actions map; only front-page ordering forgets them.
	if len(actionIDs) > RenderIndexCap {
		actionIDs = append([]string{}, actionIDs[len(actionIDs)-MaxRenderActions:]...)
	}
	pending[targetName] = append(pending[targetName], id)
	addPendingTarget(targetName)
	// full-attribute event (round-3 audit): reaped records must be
	// reconstructible from events alone
	chain.Emit("timelock_scheduled", "id", id, "target", targetName,
		"creator", string(caller), "data", data,
		"delay", strconv.FormatInt(delay, 10),
		"execute_after", execAfter.Format(time.RFC3339),
		"expires_at", execAfter.Add(time.Duration(GracePeriod)*time.Second).Format(time.RFC3339))
	return id
}

// Execute marks an action as executed. Anyone can call this — the
// timelock is the protection, not the executor's identity. The action
// must exist, be pending, its delay elapsed, and its grace window not
// yet expired.
func Execute(cur realm, actionID string) string {
	rejectStraySend(cur)
	a := mustGet(actionID)
	if a.Executed {
		panic("action already executed")
	}
	if now().Before(a.ExecuteAfter) {
		remaining := a.ExecuteAfter.Sub(now())
		panic("too early: " + strconv.FormatInt(int64(remaining/time.Second), 10) + "s remaining")
	}
	if now().After(a.ExpiresAt) {
		panic("action expired: the grace window of " +
			strconv.FormatInt(GracePeriod, 10) + "s after readiness has passed")
	}

	a.Executed = true
	dropPending(a.Target, actionID)
	chain.Emit("timelock_executed", "id", actionID, "target", a.Target)
	return "executed: " + actionID
}

// Cancel removes a pending action. Only the target's CURRENT owner can
// cancel (re-audit: the scheduling creator's rights must not survive an
// ownership transfer). The record is reaped; history is the event.
func Cancel(cur realm, actionID string) string {
	rejectStraySend(cur)
	a := mustGet(actionID)
	t := mustGetTarget(a.Target)
	if cur.Previous().Address() != t.Owner {
		panic("only the target owner can cancel")
	}
	if a.Executed {
		panic("cannot cancel an already-executed action")
	}
	if expired(a) {
		panic("action expired: nothing to cancel (use Expire)")
	}

	chain.Emit("timelock_cancelled", "id", actionID, "target", a.Target)
	reap(actionID)
	return "cancelled: " + actionID
}

// Veto cancels a pending action as the target's guardian. This is the
// guardian's whole power: it can stop a scheduled action during the
// delay window, never create or execute one. The record is reaped;
// history is the event.
func Veto(cur realm, actionID string) string {
	rejectStraySend(cur)
	a := mustGet(actionID)
	t := mustGetTarget(a.Target)
	if t.Guardian == "" {
		panic("target has no guardian: " + a.Target)
	}
	if cur.Previous().Address() != t.Guardian {
		panic("only the target guardian can veto")
	}
	if a.Executed {
		panic("cannot veto an already-executed action")
	}
	if expired(a) {
		panic("action expired: nothing to veto (use Expire)")
	}

	chain.Emit("timelock_vetoed", "id", actionID, "target", a.Target)
	reap(actionID)
	return "vetoed: " + actionID
}

// Expire reaps a provably expired action. Permissionless (fix Y2): an
// expired action decides nothing — reaping it only writes down what the
// clock already decided — so anyone may free the quota slot it holds.
// This is the recovery valve that makes a wedged target impossible:
// before it, a phantom expired entry consumed quota and blocked
// SetGuardian until a global sweep happened to reach it; now its own
// target's owner — or anyone else — reaps it directly.
func Expire(cur realm, actionID string) string {
	rejectStraySend(cur)
	a := mustGet(actionID)
	if a.Executed {
		panic("action already executed")
	}
	if !expired(a) {
		panic("action is not expired")
	}
	chain.Emit("timelock_expired", "id", actionID, "target", a.Target)
	reap(actionID)
	return "expired: " + actionID
}

// ---------- read-only queries ----------

// GetTarget returns a formatted summary of a registered target.
func GetTarget(targetName string) string {
	t := mustGetTarget(targetName)
	var b strings.Builder
	b.WriteString("Target: " + t.Name + "\n")
	b.WriteString("Owner: " + string(t.Owner) + "\n")
	guardian := "none"
	if t.Guardian != "" {
		guardian = string(t.Guardian)
	}
	b.WriteString("Guardian: " + guardian + "\n")
	b.WriteString("Min delay: " + strconv.FormatInt(t.MinDelay, 10) + "s\n")
	if t.PendingOwner != "" {
		b.WriteString("Pending owner: " + string(t.PendingOwner) + "\n")
	}
	return b.String()
}

// GetAction returns a formatted summary of a single pending or executed
// action. Cancelled/vetoed/expired actions are reaped — their history
// is in emitted events.
func GetAction(actionID string) string {
	a := mustGet(actionID)
	return formatAction(a)
}

// GetPending returns the IDs of all pending, non-expired actions,
// grouped by target, insertion-ordered within a target. Only targets
// that actually hold live pendings are visited (round-2 fix Y-1), so
// the scan cannot be inflated by registrations alone.
func GetPending() string {
	var results []string
	for _, name := range pendingTargets {
		for _, id := range pending[name] {
			a := actions[id]
			if a == nil || a.Executed || expired(a) {
				continue
			}
			results = append(results, a.ID)
		}
	}
	if len(results) == 0 {
		return "none"
	}
	return strings.Join(results, ", ")
}

// IsReady returns true if the action exists, is pending, its delay has
// elapsed, and it has not expired.
func IsReady(actionID string) bool {
	a, ok := actions[actionID]
	if !ok || a.Executed || expired(a) {
		return false
	}
	return !now().Before(a.ExecuteAfter)
}

// IsExecuted returns true if the action exists and was executed. This is
// the consumer-side check: combined with target registration it attests
// that the target's registered owner scheduled the action, it waited at
// least the registered minimum delay, no guardian vetoed it, and it was
// executed within its grace window. Executed records are permanent.
func IsExecuted(actionID string) bool {
	a, ok := actions[actionID]
	return ok && a.Executed
}

// ---------- render ----------

// Render returns a markdown overview. Never panics. Cancelled, vetoed,
// and expired actions are reaped from state; their history is in
// events. The page shows the most recent actions only (the ordering
// index is bounded — fix Y4); older executed records stay queryable
// via GetAction/IsExecuted forever.
func Render(path string) string {
	if actions == nil || len(actions) == 0 {
		return "# Timelock Guardian\n\nNo actions scheduled.\n"
	}

	// The Pending section reads the live per-target lists, so flooding
	// the realm with executed churn can never push a still-live pending
	// action off the page during its delay window (round-2 fix Y-2).
	var pendingList []*Action
	truncated := false
	for _, name := range pendingTargets {
		for _, id := range pending[name] {
			a := actions[id]
			if a == nil || a.Executed || expired(a) {
				continue
			}
			if len(pendingList) >= MaxRenderActions {
				truncated = true
				break
			}
			pendingList = append(pendingList, a)
		}
		if truncated {
			break
		}
	}

	// The Executed section reads the bounded render index: recent
	// attestations only; older ones stay queryable via GetAction.
	var executedList []*Action
	show := actionIDs
	if len(show) > MaxRenderActions {
		show = show[len(show)-MaxRenderActions:]
		truncated = true
	}
	for _, id := range show {
		a := actions[id]
		if a == nil || !a.Executed {
			continue
		}
		executedList = append(executedList, a)
	}

	var b strings.Builder
	b.WriteString("# Timelock Guardian\n\n")
	if truncated {
		b.WriteString("_Showing at most " + strconv.Itoa(MaxRenderActions) + " actions per section._\n\n")
	}

	section := func(title string, list []*Action) {
		if len(list) == 0 {
			return
		}
		b.WriteString("## " + title + " (" + strconv.Itoa(len(list)) + ")\n\n")
		for _, a := range list {
			b.WriteString(renderActionRow(a))
		}
		b.WriteString("\n")
	}
	section("Pending", pendingList)
	section("Executed", executedList)

	return b.String()
}

// ---------- formatting helpers ----------

func formatAction(a *Action) string {
	var b strings.Builder
	b.WriteString("ID: " + a.ID + "\n")
	b.WriteString("Target: " + sanitize(a.Target) + "\n")
	b.WriteString("Creator: " + string(a.Creator) + "\n")
	b.WriteString("Data: " + sanitize(a.Data) + "\n")
	b.WriteString("Scheduled: " + a.ScheduledAt.Format(time.RFC3339) + "\n")
	b.WriteString("Execute after: " + a.ExecuteAfter.Format(time.RFC3339) + "\n")
	b.WriteString("Expires: " + a.ExpiresAt.Format(time.RFC3339) + "\n")

	switch {
	case a.Executed:
		b.WriteString("Status: executed\n")
	case expired(a):
		b.WriteString("Status: expired\n")
	case now().Before(a.ExecuteAfter):
		remaining := a.ExecuteAfter.Sub(now())
		b.WriteString("Status: locked (" + strconv.FormatInt(int64(remaining/time.Second), 10) + "s remaining)\n")
	default:
		b.WriteString("Status: ready\n")
	}
	return b.String()
}

func renderActionRow(a *Action) string {
	data := truncate(sanitize(a.Data), 40)

	status := "pending"
	switch {
	case a.Executed:
		status = "executed"
	case expired(a):
		status = "expired"
	case !now().Before(a.ExecuteAfter):
		status = "**ready**"
	}

	return "- **" + a.ID + "** | target: `" + sanitize(a.Target) + "` | " + data + " | " + status + "\n"
}
