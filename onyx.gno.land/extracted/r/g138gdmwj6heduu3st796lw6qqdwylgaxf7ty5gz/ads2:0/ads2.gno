// GnoMoji — Ads Realm
// gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/ads2
//
// On-chain ad marketplace for GnoMoji on Gno.land (v1.5.0 / Onyx testnet).
//
// Design: pure AVL state, no banker imports. Follows the same pattern as
// game3 and minter3 which are confirmed working on Onyx testnet.
//
// GNOT flow:
//   Deposit  — frontend calls DepositBid; the realm tracks the credited amount
//              in advertiserBal. The GNOT attached to the MsgCall is held by
//              the realm's address automatically by the VM.
//   Payouts  — ClaimRefEarnings records a pending payout in refPending.
//              The treasury server (same wallet that runs mintPending) reads
//              refPending via RefPendingClaim() and sends GNOT server-side,
//              then calls ClearRefClaim() to zero the entry.
//
// This avoids the chain/banker import that is unavailable on Onyx testnet.

package ads2

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// ── State ─────────────────────────────────────────────────────────────────────

var (
	campaigns     avl.Tree // campaignId → compact JSON string
	advertiserBal avl.Tree // g1addr → ugnot balance as string
	adViews       avl.Tree // campaignId+":"+g1addr+":"+dayStr → "1" (per-day dedup)
	referrals     avl.Tree // advertiserAddr → referrerAddr
	refEarnings   avl.Tree // referrerAddr → ugnot earned as string
	refPending    avl.Tree // referrerAddr → ugnot pending payout as string
	tasks         avl.Tree // taskId → compact JSON string
	taskClaims    avl.Tree // taskId+":"+playerAddr → "pending:proofUrl"|"approved"|"rejected"
	pendingReview avl.Tree // campaignId → "1"
	admin         address
	paused        bool
)

func init(cur realm) {
	admin = cur.Previous().Address()
}

// ── Admin helpers ─────────────────────────────────────────────────────────────

func isAdmin(cur realm) bool {
	return cur.Previous().Address() == admin
}

func requireAdmin(cur realm) {
	if !isAdmin(cur) {
		panic("unauthorized: admin only")
	}
}

func requireNotPaused() {
	if paused {
		panic("realm is paused")
	}
}

func SetPaused(cur realm, p bool) {
	requireAdmin(cur)
	paused = p
}

// ── Write: Deposit ────────────────────────────────────────────────────────────

// DepositBid credits the caller's advertiser balance with the declared ugnot
// amount. The caller must attach matching coins to the MsgCall (the VM holds
// them in the realm's address). The amount is passed explicitly so the realm
// can credit it without importing chain/banker.
//
// Security: the treasury server MUST verify the on-chain balance before
// approving any campaign spend — it should call AdvertiserBalance() to
// cross-check the declared amount matches what was actually deposited.
func DepositBid(cur realm, ugnotAmount string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	amt, err := strconv.ParseUint(ugnotAmount, 10, 64)
	if err != nil || amt == 0 {
		panic("invalid ugnot amount")
	}

	cur64 := uint64(0)
	if advertiserBal.Has(caller) {
		cur64, _ = strconv.ParseUint(advertiserBal.Get(caller).(string), 10, 64)
	}
	advertiserBal.Set(caller, strconv.FormatUint(cur64+amt, 10))
}

// ── Write: Campaigns ─────────────────────────────────────────────────────────

// SubmitCampaign stores a campaign JSON and queues it for admin review.
// Returns the generated campaignId.
// Status is forced to "pending_review" regardless of what the client sends.
func SubmitCampaign(cur realm, campaignJson string) string {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if strings.TrimSpace(campaignJson) == "" {
		panic("campaignJson must not be empty")
	}

	prefix := caller
	if len(prefix) > 8 {
		prefix = prefix[:8]
	}
	campaignId := "ad-" + prefix + "-" + strconv.FormatInt(time.Now().Unix(), 36)

	campaignJson = injectField(campaignJson, "id", campaignId)
	campaignJson = setStatus(campaignJson, "pending_review")

	campaigns.Set(campaignId, campaignJson)
	pendingReview.Set(campaignId, "1")
	return campaignId
}

// ReviewCampaign approves or rejects a campaign.
// Approved campaigns transition to "active" and can receive views.
func ReviewCampaign(cur realm, campaignId string, decision string) {
	requireAdmin(cur)

	if decision != "approved" && decision != "rejected" {
		panic("decision must be 'approved' or 'rejected'")
	}
	if !campaigns.Has(campaignId) {
		panic("campaign not found: " + campaignId)
	}

	json := campaigns.Get(campaignId).(string)
	pendingReview.Remove(campaignId)

	newStatus := decision
	if decision == "approved" {
		newStatus = "active"
	}
	campaigns.Set(campaignId, setStatus(json, newStatus))
}

// ── Write: Views ──────────────────────────────────────────────────────────────

// RecordView bills the advertiser one bid_per_view for a player watching an ad.
// Deduplicated per (campaignId, callerAddr, UTC day).
// Splits 50% of the bid to the referrer if one is registered for the advertiser.
func RecordView(cur realm, campaignId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if !campaigns.Has(campaignId) {
		panic("campaign not found: " + campaignId)
	}

	// Per-day dedup: campaignId:addr:dayNumber
	dayStr := strconv.FormatInt(time.Now().Unix()/86400, 10)
	dedupKey := campaignId + ":" + caller + ":" + dayStr
	if adViews.Has(dedupKey) {
		return // already recorded today — silent skip
	}

	json := campaigns.Get(campaignId).(string)

	if extractField(json, "status") != "active" {
		return
	}

	bidStr := extractField(json, "bid_per_view")
	bid, err := strconv.ParseUint(bidStr, 10, 64)
	if err != nil || bid == 0 {
		return
	}

	advertiserAddr := extractField(json, "advertiser")
	if advertiserAddr == "" {
		return
	}

	balStr := "0"
	if advertiserBal.Has(advertiserAddr) {
		balStr = advertiserBal.Get(advertiserAddr).(string)
	}
	bal, _ := strconv.ParseUint(balStr, 10, 64)
	if bal < bid {
		campaigns.Set(campaignId, setStatus(json, "paused"))
		return
	}

	// Deduct bid from advertiser balance
	bal -= bid
	advertiserBal.Set(advertiserAddr, strconv.FormatUint(bal, 10))

	// Mark view for dedup
	adViews.Set(dedupKey, "1")

	// Increment total view counter
	totalKey := campaignId + ":total"
	totalStr := "0"
	if adViews.Has(totalKey) {
		totalStr = adViews.Get(totalKey).(string)
	}
	total, _ := strconv.ParseUint(totalStr, 10, 64)
	adViews.Set(totalKey, strconv.FormatUint(total+1, 10))

	// Referral split: 50% of bid goes to referrer earnings
	if referrals.Has(advertiserAddr) {
		referrer := referrals.Get(advertiserAddr).(string)
		half := bid / 2
		if half > 0 {
			refBal := uint64(0)
			if refEarnings.Has(referrer) {
				refBal, _ = strconv.ParseUint(refEarnings.Get(referrer).(string), 10, 64)
			}
			refEarnings.Set(referrer, strconv.FormatUint(refBal+half, 10))
		}
	}

	// Auto-pause if balance is now below one bid
	if bal < bid {
		campaigns.Set(campaignId, setStatus(json, "paused"))
	}
}

// ── Write: Referrals ──────────────────────────────────────────────────────────

// RegisterReferral permanently links the calling advertiser to a referrer.
// Each advertiser may register exactly one referrer; cannot be changed.
func RegisterReferral(cur realm, referrerAddr string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if referrals.Has(caller) {
		panic("referral already registered for this advertiser")
	}
	if referrerAddr == caller {
		panic("cannot refer yourself")
	}
	if !strings.HasPrefix(referrerAddr, "g1") {
		panic("invalid referrer address: must start with g1")
	}
	referrals.Set(caller, referrerAddr)
}

// ClaimRefEarnings moves the caller's accumulated referral earnings into a
// pending payout queue. The treasury server reads RefPendingClaim(), sends
// GNOT from the treasury wallet, then calls ClearRefClaim() to zero it.
func ClaimRefEarnings(cur realm) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	earnedStr := "0"
	if refEarnings.Has(caller) {
		earnedStr = refEarnings.Get(caller).(string)
	}
	earned, _ := strconv.ParseUint(earnedStr, 10, 64)
	if earned == 0 {
		panic("nothing to claim")
	}

	// Add to pending payout (may accumulate across multiple claims)
	pending := uint64(0)
	if refPending.Has(caller) {
		pending, _ = strconv.ParseUint(refPending.Get(caller).(string), 10, 64)
	}
	refPending.Set(caller, strconv.FormatUint(pending+earned, 10))

	// Zero out earned balance
	refEarnings.Set(caller, "0")
}

// ClearRefClaim is called by the admin/treasury after disbursing GNOT to a
// referrer. Zeroes the pending payout entry.
func ClearRefClaim(cur realm, referrerAddr string) {
	requireAdmin(cur)
	refPending.Set(referrerAddr, "0")
}

// ── Write: Tasks ─────────────────────────────────────────────────────────────

// SubmitTaskDef creates a new paid social task. Returns the taskId.
func SubmitTaskDef(cur realm, taskJson string) string {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if strings.TrimSpace(taskJson) == "" {
		panic("taskJson must not be empty")
	}

	prefix := caller
	if len(prefix) > 8 {
		prefix = prefix[:8]
	}
	taskId := "task-" + prefix + "-" + strconv.FormatInt(time.Now().Unix(), 36)
	taskJson = injectField(taskJson, "id", taskId)
	tasks.Set(taskId, taskJson)
	return taskId
}

// SubmitTask records a player's proof-of-completion claim on a paid task.
func SubmitTask(cur realm, taskId string, proofUrl string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if !tasks.Has(taskId) {
		panic("task not found: " + taskId)
	}
	claimKey := taskId + ":" + caller
	if taskClaims.Has(claimKey) {
		panic("already submitted a claim for this task")
	}
	taskClaims.Set(claimKey, "pending:"+proofUrl)
}

// ApproveTask marks a task claim as approved. Only the task's advertiser or
// the admin may approve. Coin reward is handled server-side via the minter.
func ApproveTask(cur realm, taskId string, claimerAddr string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if !tasks.Has(taskId) {
		panic("task not found: " + taskId)
	}

	json := tasks.Get(taskId).(string)
	advertiserAddr := extractField(json, "advertiser")

	if caller != advertiserAddr && !isAdmin(cur) {
		panic("unauthorized: only task advertiser or admin can approve")
	}

	claimKey := taskId + ":" + claimerAddr
	if !taskClaims.Has(claimKey) {
		panic("claim not found")
	}
	taskClaims.Set(claimKey, "approved")
}

// ── Read functions (pure queries) ─────────────────────────────────────────────

// GetCampaign returns the JSON string for a single campaign, or "null".
func GetCampaign(campaignId string) string {
	if !campaigns.Has(campaignId) {
		return "null"
	}
	return campaigns.Get(campaignId).(string)
}

// ListCampaigns returns a JSON array of campaigns submitted by advertiserAddr.
func ListCampaigns(advertiserAddr string) string {
	var parts []string
	campaigns.Iterate("", "\xFF", func(key string, val any) bool {
		json := val.(string)
		if strings.Contains(json, `"advertiser":"`+advertiserAddr+`"`) {
			parts = append(parts, json)
		}
		return false
	})
	return "[" + strings.Join(parts, ",") + "]"
}

// SelectAd returns the JSON of the winning campaign for the given viewer level,
// chosen by weighted auction (higher bid_per_view = proportionally more weight).
// Returns "null" if no eligible campaign exists.
//
// NOTE: uses time.Now().UnixNano() % totalWeight as deterministic pseudo-random.
// Not cryptographic — sufficient for ad placement.
func SelectAd(viewerLevel int) string {
	type candidate struct {
		json string
		bid  uint64
	}

	var pool []candidate
	totalWeight := uint64(0)

	campaigns.Iterate("", "\xFF", func(key string, val any) bool {
		json := val.(string)

		if extractField(json, "status") != "active" {
			return false
		}

		bidStr := extractField(json, "bid_per_view")
		bid, err := strconv.ParseUint(bidStr, 10, 64)
		if err != nil || bid == 0 {
			return false
		}

		advertiserAddr := extractField(json, "advertiser")
		balStr := "0"
		if advertiserBal.Has(advertiserAddr) {
			balStr = advertiserBal.Get(advertiserAddr).(string)
		}
		bal, _ := strconv.ParseUint(balStr, 10, 64)
		if bal < bid {
			return false
		}

		minLvlStr := extractField(json, "target_min_level")
		maxLvlStr := extractField(json, "target_max_level")
		if minLvlStr != "" {
			minLvl, _ := strconv.Atoi(minLvlStr)
			if viewerLevel < minLvl {
				return false
			}
		}
		if maxLvlStr != "" {
			maxLvl, _ := strconv.Atoi(maxLvlStr)
			if maxLvl > 0 && viewerLevel > maxLvl {
				return false
			}
		}

		pool = append(pool, candidate{json, bid})
		totalWeight += bid
		return false
	})

	if len(pool) == 0 || totalWeight == 0 {
		return "null"
	}

	pick := uint64(time.Now().UnixNano()) % totalWeight
	running := uint64(0)
	for _, c := range pool {
		running += c.bid
		if pick < running {
			return c.json
		}
	}
	return pool[len(pool)-1].json
}

// AdvertiserBalance returns the ugnot balance for an advertiser address.
func AdvertiserBalance(addr string) string {
	if !advertiserBal.Has(addr) {
		return "0"
	}
	return advertiserBal.Get(addr).(string)
}

// PendingReviews returns a JSON array of campaigns awaiting admin review.
func PendingReviews() string {
	var parts []string
	pendingReview.Iterate("", "\xFF", func(key string, val any) bool {
		if campaigns.Has(key) {
			parts = append(parts, campaigns.Get(key).(string))
		}
		return false
	})
	return "[" + strings.Join(parts, ",") + "]"
}

// GetTask returns the JSON for a single task, or "null".
func GetTask(taskId string) string {
	if !tasks.Has(taskId) {
		return "null"
	}
	return tasks.Get(taskId).(string)
}

// ListTasks returns a JSON array of tasks submitted by advertiserAddr.
func ListTasks(advertiserAddr string) string {
	var parts []string
	tasks.Iterate("", "\xFF", func(key string, val any) bool {
		json := val.(string)
		if strings.Contains(json, `"advertiser":"`+advertiserAddr+`"`) {
			parts = append(parts, json)
		}
		return false
	})
	return "[" + strings.Join(parts, ",") + "]"
}

// RefEarnings returns the claimable referral earnings for an address.
func RefEarnings(addr string) string {
	if !refEarnings.Has(addr) {
		return "0"
	}
	return refEarnings.Get(addr).(string)
}

// RefPendingClaim returns the pending payout amount for a referrer address.
// The treasury server calls this before sending GNOT.
func RefPendingClaim(addr string) string {
	if !refPending.Has(addr) {
		return "0"
	}
	return refPending.Get(addr).(string)
}

// TotalViews returns the total recorded view count for a campaign.
func TotalViews(campaignId string) string {
	totalKey := campaignId + ":total"
	if !adViews.Has(totalKey) {
		return "0"
	}
	return adViews.Get(totalKey).(string)
}

// GetTaskClaim returns the claim status string for a taskId+claimerAddr pair.
func GetTaskClaim(taskId string, claimerAddr string) string {
	key := taskId + ":" + claimerAddr
	if !taskClaims.Has(key) {
		return "null"
	}
	return taskClaims.Get(key).(string)
}

// ── Render ────────────────────────────────────────────────────────────────────

func Render(_ string) string {
	return ufmt.Sprintf(
		"# GnoMoji Ads Realm\n\n"+
			"Admin: `%s`\n\n"+
			"Path: `gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/ads2`\n\n"+
			"On-chain ad marketplace for GnoMoji. Advertisers deposit GNOT, "+
			"campaigns are reviewed before going live, players earn referral rewards.\n",
		admin.String(),
	)
}

// ── JSON helpers ──────────────────────────────────────────────────────────────

// extractField pulls the value of a simple string or numeric JSON field.
// Returns "" if the field is absent.
func extractField(json string, field string) string {
	needle := `"` + field + `":`
	idx := strings.Index(json, needle)
	if idx < 0 {
		return ""
	}
	rest := strings.TrimSpace(json[idx+len(needle):])
	if len(rest) == 0 {
		return ""
	}
	if rest[0] == '"' {
		rest = rest[1:]
		end := strings.Index(rest, `"`)
		if end < 0 {
			return rest
		}
		return rest[:end]
	}
	// Numeric / boolean: read until delimiter
	end := strings.IndexAny(rest, ",}")
	if end < 0 {
		return strings.TrimSpace(rest)
	}
	return strings.TrimSpace(rest[:end])
}

// setStatus replaces or appends the "status" field in a JSON object.
func setStatus(json string, status string) string {
	needle := `"status":"`
	idx := strings.Index(json, needle)
	if idx >= 0 {
		start := idx + len(needle)
		end := strings.Index(json[start:], `"`)
		if end >= 0 {
			return json[:start] + status + json[start+end:]
		}
	}
	closeIdx := strings.LastIndex(json, "}")
	if closeIdx < 0 {
		return json
	}
	return json[:closeIdx] + `,"status":"` + status + `"}` + json[closeIdx+1:]
}

// injectField sets a string field in a JSON object, replacing an existing
// value or appending before the closing brace.
func injectField(json string, field string, value string) string {
	needle := `"` + field + `":"`
	idx := strings.Index(json, needle)
	if idx >= 0 {
		start := idx + len(needle)
		end := strings.Index(json[start:], `"`)
		if end >= 0 {
			return json[:start] + value + json[start+end:]
		}
	}
	closeIdx := strings.LastIndex(json, "}")
	if closeIdx < 0 {
		return json
	}
	return json[:closeIdx] + `,"` + field + `":"` + value + `"}` + json[closeIdx+1:]
}
