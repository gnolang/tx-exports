// Package memba_bridge_v1 governs the ten Memba application realms published
// before memba_gov. It becomes each app's admin through the app's own
// two-step handover, so the apps' code does not change, and turns memba_gov
// approvals into the app's owner-only calls.
//
// Every governed entrypoint is a direct call by a seated member. It reads the
// app's live pre-state, encodes it with the call's arguments and the app's
// tenure (how many times the bridge has accepted it), and consumes exactly
// that approval from memba_gov before calling the app: an approval voted on
// another state, app, action, argument or tenure never matches. Action ids
// are "<app>.<Op>"; the invalidation scope is the app, or an object of it
// where actions are independent.
//
// Accept, ExpirePause and the reads need no vote. EmergencyPause needs a
// seated member, no vote, and expires by itself. Approval tells a proposer
// exactly what an entrypoint call would consume, from the same code.
package memba_bridge_v1

import (
	"chain"
	"strconv"
	"time"

	"gno.land/p/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/daoauth"
	gov "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_gov"
	escrow "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/escrow_v4"
	badges "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/gnobuilders_badges_v2"
	appstore "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_appstore_v3"
	arcade "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_arcade_leaderboard_v1"
	channels "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_dao_channels_v2"
	feed "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_feed_v1"
	feedback "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_feedback_v2"
	market "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_market_config"
	quest "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_quest_attestation_v1"
	reviews "gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_reviews_v2"
)

const (
	appMarket   = "memba_market_config"
	appEscrow   = "escrow_v4"
	appAppstore = "memba_appstore_v3"
	appReviews  = "memba_reviews_v2"
	appQuest    = "memba_quest_attestation_v1"
	appArcade   = "memba_arcade_leaderboard_v1"
	appBadges   = "gnobuilders_badges_v2"
	appFeed     = "memba_feed_v1"
	appChannels = "memba_dao_channels_v2"
	appFeedback = "memba_feedback_v2"
)

var (
	self = chain.PackageAddress("gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_bridge_v1")
	apps = []string{appMarket, appEscrow, appAppstore, appReviews, appQuest, appArcade, appBadges, appFeed, appChannels, appFeedback}
	// Addresses no governed argument may name: fees sent there are locked
	// for good, and a role given to one of them is unusable.
	protected   = map[address]bool{}
	tenure      = map[string]uint64{}    // app -> times the bridge accepted it
	pausedUntil = map[string]time.Time{} // app -> end of the bridge's pause
	episodes    = map[string]uint64{}    // app -> pauses the bridge started
	lastPause   = map[string]time.Time{} // member id -> last emergency pause
)

func init() {
	for _, path := range []string{"memba_bridge_v1", "memba_gov", "memba_dao", "escrow_v3"} {
		protected[chain.PackageAddress("gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/"+path)] = true
	}
	for _, app := range apps {
		protected[chain.PackageAddress("gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/"+app)] = true
	}
}

// ── Authorisation ───────────────────────────────────────────────────────

// direct returns the account that called the bridge directly.
func direct(cur realm) address {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("memba_bridge: call directly from your account")
	}
	return cur.Previous().Address()
}

// A plan is the approval one governed call needs: action app.op, args
// (completed by the app's tenure, which voids approvals voted while the app
// was away), the invalidation scope and the minimum class.
type plan struct {
	app, op string
	args    *daoauth.Args
	scope   string
	class   int
}

// newPlan refuses an approval for an app the bridge does not govern now: no
// call could consume it.
func newPlan(app, op string, args *daoauth.Args, scope string, class int) plan {
	if !governs(app) {
		panic("memba_bridge: the bridge does not govern " + app)
	}
	return plan{app, op, args, scope, class}
}

func (p plan) voted() string { return p.args.Uint(tenure[p.app]).String() }

// approve consumes proposal pid for p; memba_gov checks the executor, the
// bridge's direct caller, is a seated member.
func approve(cur realm, pid uint64, p plan) {
	executor := direct(cur)
	gov.Consume(cross(cur), pid, p.app+"."+p.op, p.voted(), p.scope, p.class, executor)
}

// Approval returns, as JSON, the proposal a governed entrypoint call would
// consume if made now: target this realm, with the action, args, scope and
// minimum class given. call is the entrypoint's name and its arguments after
// pid, daoauth-encoded in order (strings s:, addresses a:, integers i: or
// u:, booleans b:). It refuses a call its entrypoint would refuse before
// voting, and holds only while the state it binds is unchanged.
func Approval(call string) string {
	c := parseCall(call)
	var p plan
	switch name := c.str(); name {
	case "TransferAdmin":
		p = transferPlan(c.str(), c.addr())
	case "CancelTransfer":
		p = cancelPlan(c.str())
	case "SetPause":
		p = pausePlan(c.str(), c.i64())
	case "Grant", "Revoke":
		p = rolePlan(c.str(), c.addr(), name == "Grant")
	case "Curate":
		p = curatePlan(c.str(), c.str(), c.str())
	case "SetRegistrationFee":
		p = registrationFeePlan(c.i64())
	case "SetTreasury":
		p = treasuryPlan(c.str(), c.addr())
	case "SetFee":
		p = feePlan(c.str(), c.i64())
	case "ResolveDispute":
		p, _ = disputePlan(c.str(), int(c.i64()), c.flag())
	case "ProposeFeeRecipient":
		p = feeRecipientPlan(c.addr())
	case "CancelFeeRecipient":
		p = cancelFeeRecipientPlan()
	case "HideReview", "HideComment", "Unhide":
		p = moderationPlan(name, c.u64())
	case "SetQuestSigner":
		p = signerPlan(c.str())
	case "AddMember", "SetRoles":
		p = memberPlan(c.str(), name, c.addr(), c.str())
	case "RemoveMember":
		p = memberPlan(c.str(), name, c.addr(), "")
	case "CreateChannel":
		p = channelPlan(c.str(), c.str(), c.str(), c.str())
	default:
		panic("memba_bridge: no governed entrypoint " + name)
	}
	c.done()
	return `{"target":"gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/memba_bridge_v1","action":` + quote(p.app+"."+p.op) +
		`,"args":` + quote(p.voted()) + `,"scope":` + quote(p.scope) + `,"class":` + strconv.Itoa(p.class) + `}`
}

// call reads an Approval call's fields in order, each with its tag.
type call struct{ f []daoauth.Field }

func parseCall(s string) *call {
	f, err := daoauth.Parse(s)
	if err != nil {
		panic(err.Error())
	}
	return &call{f}
}

func (c *call) next(tag byte) string {
	if len(c.f) == 0 || c.f[0].Tag != tag {
		panic("memba_bridge: call argument " + string(tag) + ": expected")
	}
	v := c.f[0].Value
	c.f = c.f[1:]
	return v
}

// daoauth.Parse has checked each value is canonical for its tag.
func (c *call) str() string   { return c.next('s') }
func (c *call) addr() address { return address(c.next('a')) }
func (c *call) i64() int64 {
	n, _ := strconv.ParseInt(c.next('i'), 10, 64)
	return n
}

func (c *call) u64() uint64 {
	n, _ := strconv.ParseUint(c.next('u'), 10, 64)
	return n
}

func (c *call) flag() bool { return c.next('b') == "1" }

func (c *call) done() {
	if len(c.f) != 0 {
		panic("memba_bridge: too many call arguments")
	}
}

// quote returns s, printable ASCII, as a JSON string with < > & escaped.
func quote(s string) string {
	b := make([]byte, 0, 6*len(s)+2)
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		switch c := s[i]; c {
		case '"', '\\':
			b = append(b, '\\', c)
		case '<', '>', '&':
			b = append(b, `\u00`...)
			b = append(b, "0123456789abcdef"[c>>4], "0123456789abcdef"[c&0xf])
		default:
			b = append(b, c)
		}
	}
	return string(append(b, '"'))
}

func checkApp(app string) {
	for _, a := range apps {
		if a == app {
			return
		}
	}
	panic("memba_bridge: unknown app " + app)
}

// arg refuses a non-canonical or protected address as a recipient of a role,
// membership, admin or fees.
func arg(a address) address {
	if protected[a] {
		panic("memba_bridge: address must not be a governance or app realm")
	}
	return canonical(a)
}

// canonical refuses an address the chain would never give a caller.
func canonical(a address) address {
	if !daoauth.ValidAddress(a) {
		panic("memba_bridge: address must be lowercase bech32")
	}
	return a
}

// ── Admin handover (every app) ──────────────────────────────────────────

// Accept takes the admin role the 2-of-3 nominated the bridge for. It needs
// no vote: the nomination is the decision. A paused app is refused: only a
// pause the bridge started can be ended by its rules.
func Accept(cur realm, app string) {
	checkApp(app)
	if hasPause(app) && isPaused(app) {
		panic("memba_bridge: unpause " + app + " before handing it over")
	}
	switch app {
	case appMarket:
		market.AcceptAdmin(cross(cur))
	case appEscrow:
		escrow.AcceptOwnership(cross(cur))
	case appAppstore:
		appstore.AcceptOwnership(cross(cur))
	case appReviews:
		reviews.AcceptOwnership(cross(cur))
	case appQuest:
		quest.AcceptOwnership(cross(cur))
	case appArcade:
		arcade.AcceptOwnership(cross(cur))
	case appBadges:
		badges.AcceptOwnership(cross(cur))
	case appFeed:
		feed.AcceptOwnership(cross(cur))
	case appChannels:
		channels.AcceptOwnership(cross(cur))
	case appFeedback:
		feedback.AcceptOwnership(cross(cur))
	}
	tenure[app]++
	delete(pausedUntil, app) // a record from an earlier tenure never applies
}

// TransferAdmin stages to as the app's next admin: the 2-of-3, a successor
// bridge, or anyone the DAO names. The recipient accepts by its own call.
func TransferAdmin(cur realm, pid uint64, app string, to address) {
	approve(cur, pid, transferPlan(app, to))
	switch app {
	case appMarket:
		market.TransferAdmin(cross(cur), to)
	case appEscrow:
		escrow.TransferOwnership(cross(cur), to)
	case appAppstore:
		appstore.TransferOwnership(cross(cur), to)
	case appReviews:
		reviews.TransferOwnership(cross(cur), to)
	case appQuest:
		quest.TransferOwnership(cross(cur), to)
	case appArcade:
		arcade.TransferOwnership(cross(cur), to)
	case appBadges:
		badges.TransferOwnership(cross(cur), to)
	case appFeed:
		feed.TransferOwnership(cross(cur), to)
	case appChannels:
		channels.ProposeOwner(cross(cur), to)
	case appFeedback:
		feedback.TransferOwnership(cross(cur), to)
	}
}

func transferPlan(app string, to address) plan {
	checkApp(app)
	return newPlan(app, "TransferAdmin", daoauth.New().Addr(arg(to)).Str(pendingAdmin(app)), app, gov.Critical)
}

// CancelTransfer withdraws a staged admin before the recipient accepts.
func CancelTransfer(cur realm, pid uint64, app string) {
	approve(cur, pid, cancelPlan(app))
	switch app {
	case appMarket:
		market.CancelAdminTransfer(cross(cur))
	case appEscrow:
		escrow.CancelOwnershipTransfer(cross(cur))
	case appAppstore:
		appstore.CancelOwnershipTransfer(cross(cur))
	case appReviews:
		reviews.CancelOwnershipTransfer(cross(cur))
	case appQuest:
		quest.CancelOwnershipTransfer(cross(cur))
	case appArcade:
		arcade.CancelOwnershipTransfer(cross(cur))
	case appBadges:
		badges.CancelOwnershipTransfer(cross(cur))
	case appFeed:
		feed.CancelOwnershipTransfer(cross(cur))
	case appChannels:
		channels.CancelPendingOwner(cross(cur))
	case appFeedback:
		feedback.CancelOwnershipTransfer(cross(cur))
	}
}

func cancelPlan(app string) plan {
	checkApp(app)
	pending := pendingAdmin(app)
	if pending == "" {
		panic("memba_bridge: nothing staged to cancel for " + app)
	}
	return newPlan(app, "CancelTransfer", daoauth.New().Str(pending), app, gov.Financial)
}

// governs reports whether the bridge is app's admin now.
func governs(app string) bool {
	var admin string
	switch app {
	case appMarket:
		admin = string(market.GetAdmin())
	case appEscrow:
		admin = escrow.GetAdmin()
	case appAppstore:
		admin = string(appstore.GetOwner())
	case appReviews:
		admin = reviews.GetModerator()
	case appQuest:
		admin = quest.GetOwner()
	case appArcade:
		admin = string(arcade.GetOwner())
	case appBadges:
		admin = string(badges.GetOwner())
	case appFeed:
		admin = string(feed.GetOwner())
	case appChannels:
		admin = string(channels.GetOwner())
	case appFeedback:
		admin = string(feedback.GetOwner())
	default:
		return false
	}
	return admin == string(self)
}

func pendingAdmin(app string) string {
	switch app {
	case appMarket:
		return string(market.GetPendingAdmin())
	case appEscrow:
		return escrow.GetPendingAdmin()
	case appAppstore:
		return string(appstore.GetPendingOwner())
	case appReviews:
		return reviews.GetPendingModerator()
	case appQuest:
		return quest.GetPendingOwner()
	case appArcade:
		return string(arcade.GetPendingOwner())
	case appBadges:
		return string(badges.GetPendingOwner())
	case appFeed:
		return string(feed.GetPendingOwner())
	case appChannels:
		return string(channels.GetPendingOwner())
	}
	return string(feedback.GetPendingOwner())
}

// ── Pause (escrow, App Store, arcade, badges, feed, channels, feedback) ──

// EmergencyPause pauses app for 7 days, without a vote. Each member may use
// it once per 30 days, so one key cannot keep an app closed.
func EmergencyPause(cur realm, app string) {
	id := gov.PersonOf(direct(cur))
	if id == "" {
		panic("memba_bridge: not a seated member")
	}
	if !governs(app) {
		panic("memba_bridge: the bridge does not govern " + app)
	}
	// A paused app is refused first, and costs no allowance: an emergency
	// pause must never shorten a longer pause members voted.
	if isPaused(app) {
		panic("memba_bridge: already paused")
	}
	now := time.Now()
	if last, ok := lastPause[id]; ok && now.Before(last.Add(PauseAllowance)) {
		panic("memba_bridge: one emergency pause per member per 30 days")
	}
	setPaused(cur, app, true)
	pausedUntil[app] = now.Add(EmergencyPauseFor)
	episodes[app]++
	lastPause[id] = now
}

// SetPause ends the bridge's pause of app now (until = 0) or keeps app
// paused until the unix time until, at most 30 days ahead. The approval names
// the pause episode, so it never ends a later pause.
func SetPause(cur realm, pid uint64, app string, until int64) {
	approve(cur, pid, pausePlan(app, until))
	if until == 0 {
		if isPaused(app) {
			setPaused(cur, app, false)
		}
		delete(pausedUntil, app)
		return
	}
	if !isPaused(app) {
		setPaused(cur, app, true)
		episodes[app]++
	}
	pausedUntil[app] = time.Unix(until, 0)
}

func pausePlan(app string, until int64) plan {
	now := time.Now()
	if end := time.Unix(until, 0); until != 0 && (!end.After(now) || end.After(now.Add(MaxPauseAhead))) {
		panic("memba_bridge: pause end must be within the next 30 days")
	}
	// Governance first: an app the bridge does not govern says so before its pause is read.
	p := newPlan(app, "SetPause", daoauth.New(), app, gov.Financial)
	p.args.Int(until).Bool(isPaused(app)).Uint(episodes[app])
	return p
}

// ExpirePause lets anyone end the bridge's pause of app once it is over. A
// SetPause that keeps app paused longer must execute before then. Once the
// bridge no longer governs app, its record no longer applies: anyone drops
// it, and the app, now its new admin's, is left as it is.
func ExpirePause(cur realm, app string) {
	end, ok := pausedUntil[app]
	if ok && !governs(app) {
		delete(pausedUntil, app)
		return
	}
	if !ok || time.Now().Before(end) {
		panic("memba_bridge: no expired pause for " + app)
	}
	delete(pausedUntil, app)
	if isPaused(app) {
		setPaused(cur, app, false)
	}
}

func hasPause(app string) bool {
	return app != appMarket && app != appReviews && app != appQuest
}

func isPaused(app string) bool {
	switch app {
	case appEscrow:
		return escrow.IsPaused()
	case appAppstore:
		return appstore.IsPaused()
	case appArcade:
		return arcade.IsPaused()
	case appBadges:
		return badges.IsPaused()
	case appFeed:
		return feed.IsPaused()
	case appChannels:
		return channels.IsPaused()
	case appFeedback:
		return feedback.IsPaused()
	}
	panic("memba_bridge: " + app + " has no pause")
}

func setPaused(cur realm, app string, on bool) {
	switch {
	case app == appEscrow && on:
		escrow.Pause(cross(cur))
	case app == appEscrow:
		escrow.Unpause(cross(cur))
	case app == appAppstore:
		appstore.Pause(cross(cur), on)
	case app == appArcade:
		arcade.Pause(cross(cur), on)
	case app == appBadges && on:
		badges.Pause(cross(cur))
	case app == appBadges:
		badges.Unpause(cross(cur))
	case app == appFeed && on:
		feed.PauseRealm(cross(cur))
	case app == appFeed:
		feed.UnpauseRealm(cross(cur))
	case app == appChannels && on:
		channels.PauseRealm(cross(cur))
	case app == appChannels:
		channels.UnpauseRealm(cross(cur))
	case app == appFeedback && on:
		feedback.PauseRealm(cross(cur))
	case app == appFeedback:
		feedback.UnpauseRealm(cross(cur))
	}
}

func unixOf(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

// ── Reads ───────────────────────────────────────────────────────────────

// PausedUntil returns the unix end of the bridge's pause of app, or 0 (also
// once the bridge no longer governs app).
func PausedUntil(app string) int64 {
	if !governs(app) {
		return 0
	}
	return unixOf(pausedUntil[app])
}

// PauseEpisode returns how many pauses of app the bridge has started; a
// SetPause approval binds it.
func PauseEpisode(app string) uint64 { return episodes[app] }

// Tenure returns how many times the bridge has accepted app; every approval
// for app binds it as its last argument.
func Tenure(app string) uint64 { return tenure[app] }

func Render(_ string) string {
	out := "# Memba bridge v1\n\nGoverns the ten Memba apps for memba_gov. Bridge pauses:\n\n"
	n := 0
	for _, app := range apps {
		if end, ok := pausedUntil[app]; ok && governs(app) {
			out += "- " + app + " until unix " + strconv.FormatInt(end.Unix(), 10) + "\n"
			n++
		}
	}
	if n == 0 {
		out += "None.\n"
	}
	return out
}
