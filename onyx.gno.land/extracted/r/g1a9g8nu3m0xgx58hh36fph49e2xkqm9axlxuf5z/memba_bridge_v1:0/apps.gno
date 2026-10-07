package memba_bridge_v1

import (
	"chain"
	"chain/banker"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

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

// ── Roles: App Store curators, arcade attesters, badge admins, feed
// moderators. Operational work (curating, attesting, minting, moderating)
// is done by the holders the DAO appoints here.

func Grant(cur realm, pid uint64, app string, who address) { role(cur, pid, app, who, true) }

func Revoke(cur realm, pid uint64, app string, who address) { role(cur, pid, app, who, false) }

func role(cur realm, pid uint64, app string, who address, grant bool) {
	approve(cur, pid, rolePlan(app, who, grant))
	switch {
	case app == appAppstore && grant:
		appstore.AddCurator(cross(cur), who)
	case app == appAppstore:
		appstore.RemoveCurator(cross(cur), who)
	case app == appArcade && grant:
		arcade.AddAttester(cross(cur), who)
	case app == appArcade:
		arcade.RemoveAttester(cross(cur), who)
	case app == appBadges && grant:
		badges.AddAdmin(cross(cur), who)
	case app == appBadges:
		badges.RemoveAdmin(cross(cur), who)
	case app == appFeed && grant:
		feed.AddModerator(cross(cur), who)
	default:
		feed.RemoveModerator(cross(cur), who)
	}
}

func rolePlan(app string, who address, grant bool) plan {
	if grant {
		arg(who)
	} else if canonical(who) == self {
		// Revoking its own curator grant would end DAO curation until a hand-over round trip.
		panic("memba_bridge: the bridge keeps its own role")
	}
	// A stale grant held by another protected realm can be revoked.
	if hasRole(app, who) == grant {
		panic("memba_bridge: role already in that state")
	}
	op := "Revoke"
	if grant {
		op = "Grant"
	}
	args := daoauth.New().Addr(who)
	if app == appBadges {
		args.Int(int64(badges.GetAdminCount()))
	}
	return newPlan(app, op, args, app, gov.Critical)
}

func hasRole(app string, who address) bool {
	switch app {
	case appAppstore:
		return appstore.IsCurator(string(who))
	case appArcade:
		return arcade.IsAttester(string(who))
	case appBadges:
		return badges.IsAdmin(who)
	case appFeed:
		return feed.IsModerator(who)
	}
	panic("memba_bridge: " + app + " has no role to grant")
}

// ── App Store ───────────────────────────────────────────────────────────

// Curate runs a curator action on one listing: approve, reject (with a
// reason), delist, restore or clearflags. Every approval binds the listing's
// status; approve and restore, which publish, also bind its content, and
// clearflags binds the flags it clears. Editing or flagging a listing thus
// cannot void a reject or delist vote, and cannot slip new content past one.
func Curate(cur realm, pid uint64, op, pkgPath, reason string) {
	approve(cur, pid, curatePlan(op, pkgPath, reason))
	switch op {
	case "approve":
		appstore.ApproveApp(cross(cur), pkgPath)
	case "reject":
		appstore.RejectApp(cross(cur), pkgPath, reason)
	case "delist":
		appstore.DelistApp(cross(cur), pkgPath)
	case "restore":
		appstore.RestoreApp(cross(cur), pkgPath)
	default:
		appstore.ClearFlags(cross(cur), pkgPath)
	}
}

func curatePlan(op, pkgPath, reason string) plan {
	switch {
	case op != "approve" && op != "reject" && op != "delist" && op != "restore" && op != "clearflags":
		panic("memba_bridge: unknown curation " + op)
	case (op == "reject") != (reason != ""):
		panic("memba_bridge: a reason goes with reject only")
	}
	l := appstore.GetGovernanceListing(pkgPath, op == "clearflags")
	if !l.Exists {
		panic("memba_bridge: no listing " + pkgPath)
	}
	args := daoauth.New().Str(op).Str(pkgPath).Str(reason).Str(l.Status)
	if op == "approve" || op == "restore" {
		args.Str(l.ContentHash)
	}
	if op == "clearflags" {
		keys := sha256.Sum256([]byte(l.ClearKeys))
		args.Int(int64(l.Flags)).Str(hex.EncodeToString(keys[:]))
	}
	return newPlan(appAppstore, "Curate", args, appAppstore+"/l/"+pkgPath, gov.Routine)
}

func SetRegistrationFee(cur realm, pid uint64, fee int64) {
	approve(cur, pid, registrationFeePlan(fee))
	appstore.SetRegistrationFee(cross(cur), fee)
}

func registrationFeePlan(fee int64) plan {
	if fee < 0 || fee > appstore.MaxRegistrationFee {
		panic("memba_bridge: the registration fee is 0 to " + strconv.FormatInt(appstore.MaxRegistrationFee, 10) + " ugnot")
	}
	return newPlan(appAppstore, "SetRegistrationFee", daoauth.New().Int(fee).Int(appstore.GetRegistrationFee()), appAppstore, gov.Financial)
}

// SetTreasury points the fees of market_config (which escrow also pays
// into) or of the App Store at addr.
func SetTreasury(cur realm, pid uint64, app string, addr address) {
	approve(cur, pid, treasuryPlan(app, addr))
	if app == appMarket {
		market.SetTreasury(cross(cur), addr)
	} else {
		appstore.SetTreasury(cross(cur), addr)
	}
}

func treasuryPlan(app string, addr address) plan {
	var current address
	switch app {
	case appMarket:
		current = market.GetTreasury()
	case appAppstore:
		current = appstore.GetTreasury()
	default:
		panic("memba_bridge: " + app + " has no treasury")
	}
	return newPlan(app, "SetTreasury", daoauth.New().Addr(arg(addr)).Str(string(current)), app, gov.Critical)
}

// ── Market config ───────────────────────────────────────────────────────

func SetFee(cur realm, pid uint64, lane string, bps int64) {
	approve(cur, pid, feePlan(lane, bps))
	market.SetFeeBPS(cross(cur), lane, bps)
}

func feePlan(lane string, bps int64) plan {
	if lane == "" || bps < 0 || bps > market.MaxFeeBPS {
		panic("memba_bridge: a fee names its lane and is 0 to " + strconv.FormatInt(market.MaxFeeBPS, 10) + " bps")
	}
	return newPlan(appMarket, "SetFee", daoauth.New().Str(lane).Int(bps).Int(int64(market.GetFeeBPS(lane))), appMarket, gov.Financial)
}

// ── Escrow ──────────────────────────────────────────────────────────────

// ResolveDispute settles one disputed milestone: refund pays the client
// the whole amount, otherwise the freelancer is paid less the fee. Either
// way escrow pays out at most the milestone's amount, which is checked. A
// milestone is disputed at most once (a resolution is final); binding the
// height of that dispute means no approval can be voted before it exists.
func ResolveDispute(cur realm, pid uint64, contractID string, milestone int, refund bool) {
	p, amount := disputePlan(contractID, milestone, refund)
	approve(cur, pid, p)
	before := escrowBalance()
	escrow.ResolveDispute(cross(cur), contractID, milestone, refund)
	if paid := before - escrowBalance(); paid < 0 || paid > amount {
		panic("memba_bridge: escrow paid out more than the milestone")
	}
}

// disputePlan returns the approval and the milestone's amount.
func disputePlan(contractID string, milestone int, refund bool) (plan, int64) {
	c := escrow.GetGovernanceContract(contractID)
	if !c.Exists || milestone < 0 || milestone >= c.Count {
		panic("memba_bridge: no such contract milestone")
	}
	m := c.Milestones[milestone]
	if m.Status != "disputed" {
		panic("memba_bridge: milestone is " + m.Status + ", not disputed")
	}
	args := daoauth.New().Str(contractID).Int(int64(milestone)).Bool(refund).
		Str(m.Status).Str(m.PreDisputeStatus).Int(m.Amount).Int(m.DisputedAt)
	if !refund {
		terms := escrow.GetGovernanceFeeTerms()
		args.Int(terms.EffectiveBPS).Str(string(terms.EffectiveTreasury))
	}
	return newPlan(appEscrow, "ResolveDispute", args, appEscrow+"/c/"+contractID+"/m/"+strconv.Itoa(milestone), gov.Financial), m.Amount
}

func escrowBalance() int64 {
	// One denom only: junk denoms sent to escrow cost nothing to read past.
	return banker.NewReadonlyBanker().GetCoin(chain.PackageAddress("gno.land/r/g1a9g8nu3m0xgx58hh36fph49e2xkqm9axlxuf5z/"+appEscrow), "ugnot")
}

// ProposeFeeRecipient stages escrow's fallback fee recipient, used only when
// market_config's treasury is unusable.
func ProposeFeeRecipient(cur realm, pid uint64, addr address) {
	approve(cur, pid, feeRecipientPlan(addr))
	escrow.ProposeFeeRecipient(cross(cur), addr)
}

func feeRecipientPlan(addr address) plan {
	return newPlan(appEscrow, "ProposeFeeRecipient", daoauth.New().Addr(arg(addr)).
		Str(escrow.GetFeeRecipient()).Str(escrow.GetPendingFeeRecipient()), appEscrow, gov.Critical)
}

func CancelFeeRecipient(cur realm, pid uint64) {
	approve(cur, pid, cancelFeeRecipientPlan())
	escrow.CancelFeeRecipientProposal(cross(cur))
}

func cancelFeeRecipientPlan() plan {
	pending := escrow.GetPendingFeeRecipient()
	if pending == "" {
		panic("memba_bridge: no fee recipient staged")
	}
	return newPlan(appEscrow, "CancelFeeRecipient", daoauth.New().Str(pending), appEscrow, gov.Financial)
}

// ── Reviews ─────────────────────────────────────────────────────────────

func HideReview(cur realm, pid uint64, id uint64)  { moderate(cur, pid, "HideReview", id) }
func HideComment(cur realm, pid uint64, id uint64) { moderate(cur, pid, "HideComment", id) }

// Unhide shows an item again and dismisses its flags.
func Unhide(cur realm, pid uint64, id uint64) { moderate(cur, pid, "Unhide", id) }

// moderate binds the item's kind and visibility; Unhide, which shows the
// item again, also binds its content, so an author editing it can neither
// void a hide vote nor slip new text past an unhide vote.
func moderate(cur realm, pid uint64, op string, id uint64) {
	approve(cur, pid, moderationPlan(op, id))
	switch op {
	case "HideReview":
		reviews.HideReview(cross(cur), id)
	case "HideComment":
		reviews.HideComment(cross(cur), id)
	default:
		reviews.Unhide(cross(cur), id)
	}
}

func moderationPlan(op string, id uint64) plan {
	s := reviews.GetModerationState(id)
	switch {
	case s.ID == 0:
		// Ids are predictable: an approval for an item not posted yet would hide whatever takes the id.
		panic("memba_bridge: no review or comment " + strconv.FormatUint(id, 10))
	case op == "HideReview" && !s.Review:
		panic("memba_bridge: item " + strconv.FormatUint(id, 10) + " is a comment, not a review")
	case op == "HideComment" && s.Review:
		panic("memba_bridge: item " + strconv.FormatUint(id, 10) + " is a review, not a comment")
	case op != "Unhide" && (s.Hidden || s.Deleted):
		panic("memba_bridge: already hidden or deleted")
	case op == "Unhide" && !s.Hidden && !s.Flagged:
		panic("memba_bridge: neither hidden nor flagged")
	}
	// The author and creation time pin the item itself.
	args := daoauth.New().Uint(id).Bool(s.Review).Bool(s.Hidden).Bool(s.Deleted).Addr(s.Author).Int(s.CreatedAt)
	if op == "Unhide" {
		// The text is bound by its hash and edit height. Unhide also dismisses
		// flags; the flagged bit is bound, not a count (reviews_v2 exposes none),
		// so a flag added after the vote to an item already flagged is
		// dismissed with the others.
		args.Str(s.BodyHash).Int(s.EditedAt).Bool(s.Flagged)
	}
	return newPlan(appReviews, op, args, appReviews+"/i/"+strconv.FormatUint(id, 10), gov.Routine)
}

// ── Quests ──────────────────────────────────────────────────────────────

// SetQuestSigner rotates the key every quest voucher is checked against.
func SetQuestSigner(cur realm, pid uint64, pubKeyHex string) {
	approve(cur, pid, signerPlan(pubKeyHex))
	quest.SetSigner(cross(cur), pubKeyHex)
}

func signerPlan(pubKeyHex string) plan {
	if len(pubKeyHex) != 64 || strings.Trim(pubKeyHex, "0123456789abcdef") != "" || pubKeyHex == quest.GetSigner() {
		panic("memba_bridge: a new signer is 64 lowercase hex digits")
	}
	return newPlan(appQuest, "SetSigner", daoauth.New().Str(pubKeyHex).Str(quest.GetSigner()), appQuest, gov.Critical)
}

// ── Channels and feedback membership ────────────────────────────────────

// AddMember adds a new member; it never rewrites an existing member's roles.
func AddMember(cur realm, pid uint64, app string, addr address, roles string) {
	member(cur, pid, app, "AddMember", addr, roles)
}

func RemoveMember(cur realm, pid uint64, app string, addr address) {
	member(cur, pid, app, "RemoveMember", addr, "")
}

func SetRoles(cur realm, pid uint64, app string, addr address, roles string) {
	member(cur, pid, app, "SetRoles", addr, roles)
}

func member(cur realm, pid uint64, app, op string, who address, roles string) {
	approve(cur, pid, memberPlan(app, op, who, roles))
	switch {
	case app == appChannels && op == "AddMember":
		channels.AddMember(cross(cur), who, roles)
	case app == appChannels && op == "RemoveMember":
		channels.RemoveMember(cross(cur), who)
	case app == appChannels:
		channels.UpdateMemberRoles(cross(cur), who, roles)
	case op == "AddMember":
		feedback.AddMember(cross(cur), who, roles)
	case op == "RemoveMember":
		feedback.RemoveMember(cross(cur), who)
	default:
		feedback.UpdateMemberRoles(cross(cur), who, roles)
	}
}

func memberPlan(app, op string, who address, roles string) plan {
	if op == "RemoveMember" {
		canonical(who) // a stale membership of a protected realm can be removed
	} else {
		arg(who)
	}
	var revision uint64
	var current string
	switch app {
	case appChannels:
		revision, current = channels.GetMembershipRevision(), channels.GetMemberRoles(who)
	case appFeedback:
		revision, current = feedback.GetMembershipRevision(), feedback.GetMemberRoles(who)
	default:
		panic("memba_bridge: " + app + " has no members")
	}
	if (op == "AddMember") != (current == "") || (op != "RemoveMember" && !validRoles(roles)) {
		panic("memba_bridge: add a non-member, change a member, roles an ordered subset of admin,dev,ops,member")
	}
	return newPlan(app, op, daoauth.New().Addr(who).Str(roles).Uint(revision).Str(current), app, gov.Critical)
}

// validRoles accepts a non-empty, ordered, duplicate-free subset of
// admin,dev,ops,member.
func validRoles(r string) bool {
	names := []string{"admin", "dev", "ops", "member"}
	next := 0
	for _, x := range strings.Split(r, ",") {
		for next < len(names) && names[next] != x {
			next++
		}
		if next == len(names) {
			return false
		}
		next++
	}
	return true
}

// CreateChannel adds a channel. Channels are permanent (at most 20).
func CreateChannel(cur realm, pid uint64, app, name, description, ctype string) {
	approve(cur, pid, channelPlan(app, name, description, ctype))
	if app == appChannels {
		channels.CreateChannel(cross(cur), name, description, ctype)
	} else {
		feedback.CreateChannel(cross(cur), name, description, ctype)
	}
}

func channelPlan(app, name, description, ctype string) plan {
	if ctype != "text" && ctype != "announcements" && ctype != "readonly" || description == "" || len(description) > 200 || !daoauth.ValidText(description) {
		panic("memba_bridge: type text, announcements or readonly; description 1-200 printable ASCII characters")
	}
	var count int
	var exists bool
	switch app {
	case appChannels:
		count, exists, _, _, _, _ = channels.GetChannelState(name)
	case appFeedback:
		count, exists, _, _, _, _ = feedback.GetChannelState(name)
	default:
		panic("memba_bridge: " + app + " has no channels")
	}
	if exists {
		panic("memba_bridge: channel exists")
	}
	if !channelName(name) || count >= 20 {
		panic("memba_bridge: a channel name is 1-50 of a-z, 0-9 or -, and an app holds at most 20 channels")
	}
	return newPlan(app, "CreateChannel", daoauth.New().Str(name).Str(description).Str(ctype).Int(int64(count)), app, gov.Critical)
}

// channelName is the apps' own channel-name rule.
func channelName(name string) bool {
	if name == "" || len(name) > 50 {
		return false
	}
	return strings.Trim(name, "abcdefghijklmnopqrstuvwxyz0123456789-") == ""
}
