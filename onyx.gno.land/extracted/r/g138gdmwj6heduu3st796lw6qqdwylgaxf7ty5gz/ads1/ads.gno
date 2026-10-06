// GnoMoji — Ads Realm
// gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/ads1
//
// On-chain ad marketplace for GnoMoji on Gno.land (v1.5.0 / Onyx testnet).
// Advertisers deposit GNOT, submit campaigns, and pay per view.
// Players earn referral GNOT. Admins review campaigns before they go live.

package ads1

import (
	"strconv"
	"strings"
	"time"

	"chain"
	"chain/banker"
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// ── State ─────────────────────────────────────────────────────────────────────

var (
	campaigns     avl.Tree // campaignId → compact JSON string
	advertiserBal avl.Tree // g1addr → ugnot balance as string
	adViews       avl.Tree // campaignId+":"+g1addr+":"+dayStr → "1" (dedup per day)
	referrals     avl.Tree // advertiserAddr → referrerAddr
	refEarnings   avl.Tree // referrerAddr → ugnot earned as string
	tasks         avl.Tree // taskId → compact JSON string
	taskClaims    avl.Tree // taskId+":"+playerAddr → "pending:proofUrl" | "approved" | "rejected"
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

// DepositBid credits the caller's advertiser balance with the ugnot attached
// to this transaction. The frontend must attach coins via MsgCall.Send.
func DepositBid(cur realm) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	sent := banker.OriginSend()
	ugnot := sent.AmountOf("ugnot")
	if ugnot == 0 {
		panic("must attach ugnot to deposit")
	}

	cur64 := uint64(0)
	if advertiserBal.Has(caller) {
		cur64, _ = strconv.ParseUint(advertiserBal.Get(caller).(string), 10, 64)
	}
	advertiserBal.Set(caller, strconv.FormatUint(cur64+uint64(ugnot), 10))
}

// ── Write: Campaigns ─────────────────────────────────────────────────────────

// SubmitCampaign stores a campaign JSON submitted by an advertiser and queues
// it for admin review. Returns the generated campaignId.
//
// The frontend must supply a JSON object with at minimum:
//   title, type, bid_per_view, advertiser (g1addr)
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

	// Force status to pending_review and inject the generated id.
	// Replace any client-supplied status/id fields, or append them.
	campaignJson = injectField(campaignJson, "id", campaignId)
	campaignJson = setStatus(campaignJson, "pending_review")

	campaigns.Set(campaignId, campaignJson)
	pendingReview.Set(campaignId, "1")
	return campaignId
}

// ReviewCampaign is called by the admin to approve or reject a campaign.
// decision must be "approved" or "rejected".
func ReviewCampaign(cur realm, campaignId string, decision string) {
	requireAdmin(cur)

	if decision != "approved" && decision != "rejected" {
		panic("decision must be 'approved' or 'rejected'")
	}
	if !campaigns.Has(campaignId) {
		panic("campaign not found: " + campaignId)
	}

	json := campaigns.Get(campaignId).(string)
	// Remove from pending queue
	pendingReview.Remove(campaignId)
	// Update status — if approved, set to "active" so it can receive views
	newStatus := decision
	if decision == "approved" {
		newStatus = "active"
	}
	campaigns.Set(campaignId, setStatus(json, newStatus))
}

// ── Write: Views ──────────────────────────────────────────────────────────────

// RecordView bills the advertiser one bid_per_view for a player watching their
// campaign. Deduplicated per (campaignId, callerAddr, UTC day).
// Splits 50% to the referrer if one is registered for the advertiser.
func RecordView(cur realm, campaignId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if !campaigns.Has(campaignId) {
		panic("campaign not found: " + campaignId)
	}

	// ── Per-day dedup ────────────────────────────────────────────────────────
	dayStr := strconv.FormatInt(time.Now().Unix()/86400, 10)
	dedupKey := campaignId + ":" + caller + ":" + dayStr
	if adViews.Has(dedupKey) {
		// Already recorded a view today — silently skip
		return
	}

	json := campaigns.Get(campaignId).(string)

	// Only bill active campaigns
	status := extractField(json, "status")
	if status != "active" {
		return
	}

	// Parse bid_per_view
	bidStr := extractField(json, "bid_per_view")
	bid, err := strconv.ParseUint(bidStr, 10, 64)
	if err != nil || bid == 0 {
		return
	}

	// Get advertiser address
	advertiserAddr := extractField(json, "advertiser")
	if advertiserAddr == "" {
		return
	}

	// Check balance
	balStr := ""
	if advertiserBal.Has(advertiserAddr) {
		balStr = advertiserBal.Get(advertiserAddr).(string)
	}
	bal, _ := strconv.ParseUint(balStr, 10, 64)
	if bal < bid {
		// Insufficient balance — pause the campaign
		campaigns.Set(campaignId, setStatus(json, "paused"))
		return
	}

	// Deduct bid
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

	// Referral split: 50% goes to referrer if registered
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
	// Remaining balance (or full bid if no referrer) stays as platform revenue.
	// If balance now too low for next view, pause.
	if bal < bid {
		campaigns.Set(campaignId, setStatus(json, "paused"))
	}
}

// ── Write: Referrals ──────────────────────────────────────────────────────────

// RegisterReferral links the calling advertiser to a referrer permanently.
// Each advertiser may register exactly one referrer, and it cannot be changed.
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

// ClaimRefEarnings transfers accumulated referral earnings to the caller.
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

	// Send GNOT from realm to caller
	realmAddr := runtime.CurrentRealm().Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend)
	b.SendCoins(realmAddr, address(caller), chain.NewCoins(chain.NewCoin("ugnot", int64(earned))))

	// Reset earnings
	refEarnings.Set(caller, "0")
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

// SubmitTask records a player's claim on a paid task (proof of completion).
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
// the admin may approve. Actual coin reward is handled frontend-side via
// the minter realm — this function just records the approval on-chain.
func ApproveTask(cur realm, taskId string, claimerAddr string) {
	requireNotPaused()
	caller := cur.Previous().Address()

	if !tasks.Has(taskId) {
		panic("task not found: " + taskId)
	}

	json := tasks.Get(taskId).(string)
	advertiserAddr := extractField(json, "advertiser")

	if caller.String() != advertiserAddr && !isAdmin(cur) {
		panic("unauthorized: only task advertiser or admin can approve")
	}

	claimKey := taskId + ":" + claimerAddr
	if !taskClaims.Has(claimKey) {
		panic("claim not found")
	}
	taskClaims.Set(claimKey, "approved")
}

// ── Read functions (pure queries — no cur realm needed) ───────────────────────

// GetCampaign returns the JSON string for a single campaign, or "null".
func GetCampaign(campaignId string) string {
	if !campaigns.Has(campaignId) {
		return "null"
	}
	return campaigns.Get(campaignId).(string)
}

// ListCampaigns returns a JSON array of all campaigns submitted by advertiserAddr.
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

// SelectAd returns the JSON of the winning campaign for a viewer at the given
// level, chosen by a weighted auction (higher bid_per_view = more weight).
// Returns "null" if no eligible campaign exists.
//
// NOTE: selection uses time.Now().UnixNano() % totalWeight as a deterministic
// pseudo-random — not cryptographic, but sufficient for ad placement.
func SelectAd(viewerLevel int) string {
	type candidate struct {
		json string
		bid  uint64
	}

	var pool []candidate
	totalWeight := uint64(0)

	campaigns.Iterate("", "\xFF", func(key string, val any) bool {
		json := val.(string)

		// Only active campaigns
		if extractField(json, "status") != "active" {
			return false
		}

		// Parse bid_per_view
		bidStr := extractField(json, "bid_per_view")
		bid, err := strconv.ParseUint(bidStr, 10, 64)
		if err != nil || bid == 0 {
			return false
		}

		// Check advertiser has funds
		advertiserAddr := extractField(json, "advertiser")
		balStr := "0"
		if advertiserBal.Has(advertiserAddr) {
			balStr = advertiserBal.Get(advertiserAddr).(string)
		}
		bal, _ := strconv.ParseUint(balStr, 10, 64)
		if bal < bid {
			return false
		}

		// Apply viewer level filter if present
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

	// Weighted pseudo-random selection
	pick := uint64(time.Now().UnixNano()) % totalWeight
	running := uint64(0)
	for _, c := range pool {
		running += c.bid
		if pick < running {
			return c.json
		}
	}
	// Fallback: return last candidate
	return pool[len(pool)-1].json
}

// AdvertiserBalance returns the ugnot balance (as a string) for an advertiser.
func AdvertiserBalance(addr string) string {
	if !advertiserBal.Has(addr) {
		return "0"
	}
	return advertiserBal.Get(addr).(string)
}

// PendingReviews returns a JSON array of all campaigns awaiting admin review.
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

// ListTasks returns a JSON array of all tasks submitted by advertiserAddr.
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

// RefEarnings returns the claimable referral earnings (ugnot) for an address.
func RefEarnings(addr string) string {
	if !refEarnings.Has(addr) {
		return "0"
	}
	return refEarnings.Get(addr).(string)
}

// TotalViews returns the total recorded view count for a campaign.
func TotalViews(campaignId string) string {
	totalKey := campaignId + ":total"
	if !adViews.Has(totalKey) {
		return "0"
	}
	return adViews.Get(totalKey).(string)
}

// GetTaskClaim returns the claim status string for a given task+claimer pair.
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
			"Path: `gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/ads1`\n\n"+
			"On-chain ad marketplace for GnoMoji. Advertisers deposit GNOT, "+
			"players earn referral rewards, campaigns are reviewed before going live.\n",
		admin.String(),
	)
}

// ── JSON helpers ──────────────────────────────────────────────────────────────

// extractField extracts the value of a simple string or number JSON field.
// Handles both `"field":"value"` and `"field":123` forms.
// Returns "" if the field is not found.
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
		// String value
		rest = rest[1:]
		end := strings.Index(rest, `"`)
		if end < 0 {
			return rest
		}
		return rest[:end]
	}
	// Numeric or boolean value — read until delimiter
	end := strings.IndexAny(rest, ",}")
	if end < 0 {
		return strings.TrimSpace(rest)
	}
	return strings.TrimSpace(rest[:end])
}

// setStatus replaces the "status" field in a JSON string.
// If the field is not present, it appends it before the closing brace.
func setStatus(json string, status string) string {
	// Try to replace an existing status field (any value)
	needle := `"status":"`
	idx := strings.Index(json, needle)
	if idx >= 0 {
		// Find end of value
		start := idx + len(needle)
		end := strings.Index(json[start:], `"`)
		if end >= 0 {
			return json[:start] + status + json[start+end:]
		}
	}
	// No status field — inject before closing brace
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
	// Append before closing brace
	closeIdx := strings.LastIndex(json, "}")
	if closeIdx < 0 {
		return json
	}
	return json[:closeIdx] + `,"` + field + `":"` + value + `"}` + json[closeIdx+1:]
}
