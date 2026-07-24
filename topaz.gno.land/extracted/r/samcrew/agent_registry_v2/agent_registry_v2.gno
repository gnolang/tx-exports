package agent_registry_v2

// Agent Registry — On-chain AI Agent Marketplace for the Memba ecosystem.
//
// Agents self-register with MCP metadata (endpoint, transport, pricing).
// Anyone can query via Render() for agent listings.
// Reviews are stored on-chain with 1-5 star ratings.
// Pay-per-use agents support a prepaid credit system.
//
// Render() contract:
//
//   Home — Render(""):
//     # Memba Agent Registry
//     description
//     ## Agents
//     | ID | Name | Category | Rating | Pricing |
//     | --- | --- | --- | --- | --- |
//     | id | name | category | 4.2 (5) | free |
//
//   Agent — Render("agent/id"):
//     # AgentName
//     description
//     **Category:** category
//     **Creator:** g1addr
//     **Endpoint:** endpoint
//     **Transport:** stdio|sse|streamable-http
//     **Pricing:** free|pay-per-use|subscription
//     **Rating:** 4.2 (5 reviews)
//     ## Capabilities
//     - capability1
//     - capability2
//     ## Reviews
//     **g1addr...** stars (block H)
//     review text
//
//   Stats — Render("stats"):
//     Total agents, total reviews, total calls

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/samcrew/avl"
	"gno.land/p/nt/ufmt/v0"
)

// ── Constants ────────────────────────────────────────────────

const (
	MaxAgents    = 100
	MaxNameLen   = 100
	MaxDescLen   = 1000
	MaxCapsLen   = 2000
	MaxReviewLen = 500
	// AR-1 render-DoS bound: reviews are sybil-growable (one per address, no cap), and
	// renderAgent previously iterated the entire slice — an attacker could make an agent
	// page unrenderable past the query gas cap. Render only the newest window.
	ReviewRenderMax = 20
	AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0" // samcrew-core-test1 multisig

	// AAA-1 B4 — anti-squat + fund-lock-DoS bounds.
	// MaxAgentsPerCreator caps how many agents one address can register, so a
	// single funded address cannot squat the whole MaxAgents global supply.
	MaxAgentsPerCreator = 10
	// MaxDepositorsPerAgent bounds the distinct depositor set per agent. RemoveAgent
	// refunds EVERY depositor in one transaction (the credits prefix scan below); an
	// unbounded set would make RemoveAgent exceed the block gas budget and become
	// permanently uncallable, locking all deposited funds. At this cap the full
	// refund loop measures ≈3M gas in `gno test` — a small fraction of the block
	// budget, so RemoveAgent stays callable with wide headroom.
	MaxDepositorsPerAgent = 50
)

// ── Types ────────────────────────────────────────────────────

type Agent struct {
	ID           string
	Name         string
	Description  string
	Category     string
	Capabilities string // comma-separated
	Creator      address
	Endpoint     string
	Transport    string // "stdio" | "sse" | "streamable-http"
	Pricing      string // "free" | "pay-per-use" | "subscription"
	PricePerCall int64  // in ugnot (0 if free)
	Version      string
	TotalCalls   int64
	RatingSum    int64
	RatingCount  int64
	BlockH       int64
}

type Review struct {
	Reviewer address
	Rating   int // 1-5
	Comment  string
	BlockH   int64
}

// ── State ────────────────────────────────────────────────────

var (
	agents    *avl.Tree // id -> *Agent
	reviews   *avl.Tree // agentId -> []*Review
	reviewers *avl.Tree // "agentId/addr" -> true (dedup: one review per agent per address)
	credits   *avl.Tree // "agentId/userAddr" -> int64 (prepaid credits in ugnot)
	usage     *avl.Tree // "agentId/userAddr" -> int64 (total calls)
	earnings  *avl.Tree // agentId -> int64 (accumulated creator earnings in ugnot)
	paused    bool
)

func init() {
	agents = avl.NewTree()
	reviews = avl.NewTree()
	reviewers = avl.NewTree()
	credits = avl.NewTree()
	usage = avl.NewTree()
	earnings = avl.NewTree()
}

// ── Emergency Pause ────────────────────────────────────────
//
// Pause policy (AAA-1 B3 — one policy, enforced everywhere):
//   While paused, every state-mutating user operation is blocked
//   (RegisterAgent, UpdateAgent, ReviewAgent, RemoveAgent, DepositCredits,
//   UseCredit, WithdrawEarnings) via assertNotPaused().
//
//   EXEMPTION — RefundCredits is deliberately NOT gated: a user must always be
//   able to reclaim their own deposited principal, even during emergency
//   maintenance. A credit balance only ever equals real ugnot the user sent
//   (DepositCredits) minus what they spent (UseCredit), so refunding it is
//   always safe and never exploit-amplifying. WithdrawEarnings (creator profit,
//   which an exploit could inflate) stays blocked by design.

func assertNotPaused() {
	if paused {
		panic("realm is paused — emergency maintenance")
	}
}

// Pause blocks all state-mutating operations EXCEPT RefundCredits (users keep the
// right to reclaim their own deposits). Admin only. See the pause policy above.
func Pause(cur realm) {
	caller := unsafe.PreviousRealm().Address()
	if caller != address(AdminAddress) {
		panic("only admin can pause")
	}
	paused = true
}

// Unpause resumes normal operations. Admin only.
func Unpause(cur realm) {
	caller := unsafe.PreviousRealm().Address()
	if caller != address(AdminAddress) {
		panic("only admin can unpause")
	}
	paused = false
}

// IsPaused returns the current pause state.
func IsPaused() bool {
	return paused
}

// ── Public Functions ─────────────────────────────────────────

// RegisterAgent registers a new agent in the registry.
func RegisterAgent(
	cur realm,
	id, name, description, category, capabilities,
	endpoint, transport, pricing, version string,
	pricePerCall int64,
) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	if _, exists := agents.Get(id); exists {
		panic("agent ID already exists: " + id)
	}
	if len(id) == 0 || len(id) > 50 {
		panic("ID must be 1-50 characters")
	}
	if !isValidAgentID(id) {
		panic("ID must contain only alphanumeric characters, hyphens, or underscores")
	}
	if len(name) == 0 || len(name) > MaxNameLen {
		panic(ufmt.Sprintf("name must be 1-%d characters", MaxNameLen))
	}
	if len(description) > MaxDescLen {
		panic("description too long")
	}
	if len(capabilities) > MaxCapsLen {
		panic("capabilities too long")
	}
	if len(category) > MaxNameLen {
		panic("category too long")
	}
	if len(endpoint) > MaxDescLen {
		panic("endpoint too long")
	}
	if len(version) > 50 {
		panic("version too long")
	}
	if agents.Size() >= MaxAgents {
		panic("registry full")
	}
	// B4: per-creator cap — stop a single address squatting the global supply.
	if countAgentsByCreator(caller) >= MaxAgentsPerCreator {
		panic("creator agent limit reached")
	}
	if !isValidTransport(transport) {
		panic("transport must be stdio, sse, or streamable-http")
	}
	if !isValidPricing(pricing) {
		panic("pricing must be free, pay-per-use, or subscription")
	}
	if pricePerCall < 0 {
		panic("pricePerCall must be >= 0")
	}

	a := &Agent{
		ID:           id,
		Name:         name,
		Description:  description,
		Category:     category,
		Capabilities: capabilities,
		Creator:      caller,
		Endpoint:     endpoint,
		Transport:    transport,
		Pricing:      pricing,
		PricePerCall: pricePerCall,
		Version:      version,
		BlockH:       runtime.ChainHeight(),
	}
	agents.Set(id, a)
	reviews.Set(id, []*Review{})

	chain.Emit("AgentRegistered",
		"id", id,
		"name", name,
		"creator", caller.String(),
		"pricing", pricing,
	)
}

// UpdateAgent allows the creator to update their agent.
func UpdateAgent(
	cur realm,
	id, description, capabilities, endpoint, version, pricing string,
	pricePerCall int64,
) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	val, exists := agents.Get(id)
	if !exists {
		panic("agent not found: " + id)
	}
	a := val.(*Agent)
	if a.Creator != caller {
		panic("only the creator can update")
	}
	if len(description) > 0 {
		if len(description) > MaxDescLen {
			panic("description too long")
		}
		a.Description = description
	}
	if len(capabilities) > 0 {
		if len(capabilities) > MaxCapsLen {
			panic("capabilities too long")
		}
		a.Capabilities = capabilities
	}
	if len(endpoint) > 0 {
		a.Endpoint = endpoint
	}
	if len(version) > 0 {
		a.Version = version
	}
	if pricePerCall < 0 {
		panic("pricePerCall must be >= 0")
	}
	if len(pricing) > 0 {
		if !isValidPricing(pricing) {
			panic("pricing must be free, pay-per-use, or subscription")
		}
		// Prevent pricing model change when ANY credit entry exists for this agent,
		// including zero-balance entries. This closes the price-lock bypass where
		// the creator drains user balances to 0 then raises the price before the
		// user's next deposit lands.
		if pricing != a.Pricing && hasAnyCreditsEntry(id) {
			panic("cannot change pricing model while credit entries exist for this agent")
		}
		a.Pricing = pricing
	}
	if pricePerCall != a.PricePerCall && hasAnyCreditsEntry(id) {
		panic("cannot change price per call while credit entries exist for this agent")
	}
	a.PricePerCall = pricePerCall
	agents.Set(id, a)

	chain.Emit("AgentUpdated",
		"id", id,
		"creator", caller.String(),
	)
}

// ReviewAgent adds a review for an agent. One review per address per agent.
func ReviewAgent(cur realm, agentId string, rating int, comment string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	val, exists := agents.Get(agentId)
	if !exists {
		panic("agent not found")
	}
	if rating < 1 || rating > 5 {
		panic("rating must be 1-5")
	}
	if len(comment) > MaxReviewLen {
		panic("review too long")
	}

	// Enforce one review per address per agent
	reviewKey := agentId + "/" + caller.String()
	if _, already := reviewers.Get(reviewKey); already {
		panic("already reviewed this agent")
	}
	reviewers.Set(reviewKey, true)

	a := val.(*Agent)
	a.RatingSum += int64(rating)
	a.RatingCount++
	agents.Set(agentId, a)

	rval, _ := reviews.Get(agentId)
	revs := rval.([]*Review)
	revs = append(revs, &Review{
		Reviewer: caller,
		Rating:   rating,
		Comment:  comment,
		BlockH:   runtime.ChainHeight(),
	})
	reviews.Set(agentId, revs)

	chain.Emit("AgentReviewed",
		"agentId", agentId,
		"reviewer", caller.String(),
		"rating", strconv.Itoa(rating),
	)
}

// RemoveAgent removes an agent (admin or creator only).
// All outstanding credits are refunded to their depositors before removal.
func RemoveAgent(cur realm, id string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	val, exists := agents.Get(id)
	if !exists {
		panic("agent not found")
	}
	a := val.(*Agent)
	if a.Creator != caller && caller != address(AdminAddress) {
		panic("only creator or admin can remove")
	}

	// Refund all outstanding credits before removal.
	// Use prefix + "\xff" as exclusive upper bound for the AVL prefix scan —
	// any key starting with "id/" sorts strictly before "id/\xff".
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := unsafe.CurrentRealm().Address()
	prefix := id + "/"
	var creditsToRefund []string
	credits.Iterate(prefix, prefix+"\xff", func(key string, value interface{}) bool {
		creditsToRefund = append(creditsToRefund, key)
		return false
	})
	for _, key := range creditsToRefund {
		cval, cok := credits.Get(key)
		if !cok {
			continue
		}
		balance := cval.(int64)
		if balance > 0 {
			userAddr := key[len(prefix):]
			// STATE-BEFORE-SEND: zero balance before coin transfer
			credits.Set(key, int64(0))
			bnk.SendCoins(realmAddr, address(userAddr),
				chain.Coins{chain.NewCoin("ugnot", balance)})
		}
	}

	// Pay out the creator's accrued earnings BEFORE deleting the record.
	// UseCredit moves ugnot from credits -> earnings, so these are real funds
	// the realm holds; removing the record without paying would strand them
	// permanently (WithdrawEarnings would then panic "agent not found").
	if earned := GetEarnings(id); earned > 0 {
		earnings.Set(id, int64(0)) // STATE-BEFORE-SEND
		bnk.SendCoins(realmAddr, a.Creator,
			chain.Coins{chain.NewCoin("ugnot", earned)})
	}

	// Clean up orphaned state: earnings and usage entries for this agent
	earnings.Remove(id)
	// Clean up usage entries with this agent prefix
	usagePrefix := id + "/"
	var usageToRemove []string
	usage.Iterate(usagePrefix, usagePrefix+"\xff", func(k string, _ interface{}) bool {
		usageToRemove = append(usageToRemove, k)
		return false
	})
	for _, k := range usageToRemove {
		usage.Remove(k)
	}
	// Also clean up any zero-balance residual credit entries
	var creditsToRemove []string
	credits.Iterate(usagePrefix, usagePrefix+"\xff", func(k string, _ interface{}) bool {
		creditsToRemove = append(creditsToRemove, k)
		return false
	})
	for _, k := range creditsToRemove {
		credits.Remove(k)
	}

	agents.Remove(id)
	reviews.Remove(id)

	chain.Emit("AgentRemoved",
		"id", id,
		"remover", caller.String(),
	)
}

// ── Pay-Per-Use Credit System ────────────────────────────────

// DepositCredits deposits GNOT as prepaid credits for an agent.
// Send ugnot with the transaction to fund the credits.
func DepositCredits(cur realm, agentId string) {
	assertNotPaused()

	// P0 fund-guard: a payable entrypoint MUST be a direct user call. unsafe.OriginSend()
	// reports the tx-level `--send`, credited to the DIRECT message target realm — not to
	// an inner realm reached via a cross-call. Without this guard an attacker deposits
	// through their own intermediary realm (coins land there), this realm credits an amount
	// it never received, then the attacker drains real pooled prepaid credits via
	// RefundCredits/WithdrawEarnings. Requiring a direct user call forces this realm to be
	// the message target, the one case where the OriginSend coins are in its own account.
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("DepositCredits must be a direct user call")
	}

	caller := unsafe.PreviousRealm().Address()
	if _, exists := agents.Get(agentId); !exists {
		panic("agent not found")
	}

	sent := unsafe.OriginSend()
	amount := int64(0)
	for _, coin := range sent {
		if coin.Denom == "ugnot" {
			amount += coin.Amount
		}
	}
	if amount == 0 {
		panic("must send ugnot to deposit credits")
	}

	key := agentId + "/" + caller.String()
	existing := int64(0)
	alreadyDepositor := false
	if val, ok := credits.Get(key); ok {
		existing = val.(int64)
		alreadyDepositor = true
	}
	// B4: bound the distinct depositor set so RemoveAgent's refund loop stays within
	// the gas budget. Existing depositors may always top up; only NEW depositors are
	// capped.
	if !alreadyDepositor && countDepositors(agentId) >= MaxDepositorsPerAgent {
		panic("agent depositor limit reached")
	}
	credits.Set(key, existing+amount)

	chain.Emit("CreditsDeposited",
		"agentId", agentId,
		"user", caller.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
}

// UseCredit deducts one invocation credit. Only the agent creator or admin can call.
// Returns the remaining credits.
func UseCredit(cur realm, agentId, userAddr string) int64 {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	val, exists := agents.Get(agentId)
	if !exists {
		panic("agent not found")
	}
	a := val.(*Agent)

	// Only the agent creator (who runs the MCP backend) or platform admin
	// can deduct credits on behalf of users
	if a.Creator != caller && caller != address(AdminAddress) {
		panic("only agent creator or admin can deduct credits")
	}

	key := agentId + "/" + userAddr
	if a.Pricing == "pay-per-use" && a.PricePerCall > 0 {
		cval, cexists := credits.Get(key)
		if !cexists {
			panic("no credits deposited")
		}
		balance := cval.(int64)
		if balance < a.PricePerCall {
			panic(ufmt.Sprintf("insufficient credits: %d < %d", balance, a.PricePerCall))
		}
		credits.Set(key, balance-a.PricePerCall)

		// Track earnings for creator withdrawal
		earned := int64(0)
		if ev, eok := earnings.Get(agentId); eok {
			earned = ev.(int64)
		}
		earnings.Set(agentId, earned+a.PricePerCall)
	}

	// Track usage
	a.TotalCalls++
	agents.Set(agentId, a)

	uval := int64(0)
	if uv, uok := usage.Get(key); uok {
		uval = uv.(int64)
	}
	usage.Set(key, uval+1)

	remaining := int64(0)
	if rv, rok := credits.Get(key); rok {
		remaining = rv.(int64)
	}

	// B6: every state transition emits a typed event for indexers/agents.
	chain.Emit("CreditUsed",
		"agentId", agentId,
		"user", userAddr,
		"caller", caller.String(),
		"remaining", strconv.FormatInt(remaining, 10),
	)
	return remaining
}

// GetCredits returns the credit balance for a user on an agent.
func GetCredits(agentId, userAddr string) int64 {
	key := agentId + "/" + userAddr
	if val, ok := credits.Get(key); ok {
		return val.(int64)
	}
	return 0
}

// GetUsage returns the total invocation count for a user on an agent.
func GetUsage(agentId, userAddr string) int64 {
	key := agentId + "/" + userAddr
	if val, ok := usage.Get(key); ok {
		return val.(int64)
	}
	return 0
}

// GetEarnings returns accumulated earnings for an agent.
func GetEarnings(agentId string) int64 {
	if val, ok := earnings.Get(agentId); ok {
		return val.(int64)
	}
	return 0
}

// WithdrawEarnings allows the agent creator to withdraw accumulated usage fees.
// Earnings accumulate when UseCredit deducts from user credit balances.
func WithdrawEarnings(cur realm, agentId string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	val, exists := agents.Get(agentId)
	if !exists {
		panic("agent not found")
	}
	a := val.(*Agent)
	if a.Creator != caller {
		panic("only agent creator can withdraw earnings")
	}

	earned := int64(0)
	if ev, eok := earnings.Get(agentId); eok {
		earned = ev.(int64)
	}
	if earned == 0 {
		panic("no earnings to withdraw")
	}

	// STATE-BEFORE-SEND: zero earnings before coin transfer
	earnings.Set(agentId, int64(0))

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(
		unsafe.CurrentRealm().Address(),
		caller,
		chain.Coins{chain.NewCoin("ugnot", earned)},
	)

	chain.Emit("EarningsWithdrawn",
		"agentId", agentId,
		"creator", caller.String(),
		"amount", strconv.FormatInt(earned, 10),
	)
}

// RefundCredits refunds remaining credits to the caller.
func RefundCredits(cur realm, agentId string) {
	caller := unsafe.PreviousRealm().Address()
	key := agentId + "/" + caller.String()

	cval, cexists := credits.Get(key)
	if !cexists {
		panic("no credits to refund")
	}
	balance := cval.(int64)
	if balance == 0 {
		panic("zero balance")
	}

	// STATE-BEFORE-SEND: fully REMOVE the entry (not just zero it) so that the
	// pricing lock in UpdateAgent doesn't remain triggered after a full refund.
	credits.Remove(key)

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(
		unsafe.CurrentRealm().Address(),
		caller,
		chain.Coins{chain.NewCoin("ugnot", balance)},
	)

	chain.Emit("CreditsRefunded",
		"agentId", agentId,
		"user", caller.String(),
		"amount", strconv.FormatInt(balance, 10),
	)
}

// ── Render ───────────────────────────────────────────────────

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if path == "stats" {
		return renderStats()
	}
	if strings.HasPrefix(path, "agent/") {
		agentId := strings.TrimPrefix(path, "agent/")
		return renderAgent(agentId)
	}
	return "# 404\nNot found: " + path
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# Memba Agent Registry\n\n")
	sb.WriteString("On-chain AI Agent Marketplace for the Gno ecosystem.\n\n")

	if agents.Size() == 0 {
		sb.WriteString("*No agents registered yet.*\n")
		return sb.String()
	}

	sb.WriteString("## Agents\n\n")
	sb.WriteString("| ID | Name | Category | Rating | Pricing |\n")
	sb.WriteString("| --- | --- | --- | --- | --- |\n")

	agents.Iterate("", "", func(key string, value interface{}) bool {
		a := value.(*Agent)
		rating := "unrated"
		if a.RatingCount > 0 {
			rating = formatRating(a.RatingSum, a.RatingCount)
		}
		pricing := a.Pricing
		if a.Pricing == "pay-per-use" && a.PricePerCall > 0 {
			pricing = ufmt.Sprintf("pay-per-use (%d ugnot)", a.PricePerCall)
		}
		sb.WriteString(ufmt.Sprintf("| %s | [%s](:agent/%s) | %s | %s | %s |\n",
			a.ID, sanitizeForRender(a.Name), a.ID, sanitizeForRender(a.Category), rating, pricing))
		return false
	})

	return sb.String()
}

func renderAgent(id string) string {
	val, exists := agents.Get(id)
	if !exists {
		return "# 404\nAgent not found: " + id
	}
	a := val.(*Agent)

	var sb strings.Builder
	sb.WriteString("# " + sanitizeForRender(a.Name) + "\n\n")
	sb.WriteString(sanitizeForRender(a.Description) + "\n\n")
	sb.WriteString("**ID:** " + a.ID + "\n")
	sb.WriteString("**Category:** " + sanitizeForRender(a.Category) + "\n")
	sb.WriteString("**Creator:** " + a.Creator.String() + "\n")
	sb.WriteString("**Endpoint:** " + sanitizeForRender(a.Endpoint) + "\n")
	sb.WriteString("**Transport:** " + a.Transport + "\n")
	sb.WriteString("**Pricing:** " + a.Pricing + "\n")
	if a.PricePerCall > 0 {
		sb.WriteString("**Price:** " + strconv.FormatInt(a.PricePerCall, 10) + " ugnot/call\n")
	}
	sb.WriteString("**Version:** " + sanitizeForRender(a.Version) + "\n")
	sb.WriteString("**Total Calls:** " + strconv.FormatInt(a.TotalCalls, 10) + "\n")
	sb.WriteString("**Registered:** block " + strconv.FormatInt(a.BlockH, 10) + "\n")

	if a.RatingCount > 0 {
		sb.WriteString("**Rating:** " + formatRating(a.RatingSum, a.RatingCount) +
			" (" + strconv.FormatInt(a.RatingCount, 10) + " reviews)\n")
	}

	// Capabilities
	sb.WriteString("\n## Capabilities\n\n")
	for _, cap := range strings.Split(a.Capabilities, ",") {
		cap = strings.TrimSpace(cap)
		if len(cap) > 0 {
			sb.WriteString("- " + sanitizeForRender(cap) + "\n")
		}
	}

	// Reviews — AR-1: render only the newest ReviewRenderMax so a sybil review flood can't
	// make this page exceed the query gas cap. AR-2: every user-controlled field sanitized.
	rval, rexists := reviews.Get(id)
	if rexists {
		revs := rval.([]*Review)
		if len(revs) > 0 {
			sb.WriteString("\n## Reviews\n\n")
			start := 0
			if len(revs) > ReviewRenderMax {
				start = len(revs) - ReviewRenderMax
				sb.WriteString(ufmt.Sprintf("_showing newest %d of %d reviews_\n\n",
					ReviewRenderMax, len(revs)))
			}
			for _, r := range revs[start:] {
				stars := strings.Repeat("*", r.Rating) + strings.Repeat(".", 5-r.Rating)
				sb.WriteString(ufmt.Sprintf("**%s** [%s] (block %d)\n\n",
					truncAddr(r.Reviewer), stars, r.BlockH))
				if len(r.Comment) > 0 {
					sb.WriteString(sanitizeForRender(r.Comment) + "\n\n")
				}
				sb.WriteString("---\n\n")
			}
		}
	}

	return sb.String()
}

func renderStats() string {
	var sb strings.Builder
	sb.WriteString("# Registry Stats\n\n")

	totalAgents := agents.Size()
	totalReviews := int64(0)
	totalCalls := int64(0)

	agents.Iterate("", "", func(key string, value interface{}) bool {
		a := value.(*Agent)
		totalReviews += a.RatingCount
		totalCalls += a.TotalCalls
		return false
	})

	sb.WriteString(ufmt.Sprintf("**Total Agents:** %d\n", totalAgents))
	sb.WriteString(ufmt.Sprintf("**Total Reviews:** %d\n", totalReviews))
	sb.WriteString(ufmt.Sprintf("**Total Calls:** %d\n", totalCalls))

	return sb.String()
}

// ── Helpers ──────────────────────────────────────────────────

// formatRating formats a rating as "X.Y" using integer math (no float in ufmt).
func formatRating(sum, count int64) string {
	if count == 0 {
		return "0.0"
	}
	whole := sum / count
	// One decimal place: (sum * 10 / count) % 10
	frac := ((sum * 10) / count) % 10
	return strconv.FormatInt(whole, 10) + "." + strconv.FormatInt(frac, 10)
}

func truncAddr(addr address) string {
	s := addr.String()
	if len(s) > 13 {
		return s[:10] + "..."
	}
	return s
}

func isValidTransport(t string) bool {
	return t == "stdio" || t == "sse" || t == "streamable-http"
}

func isValidPricing(p string) bool {
	return p == "free" || p == "pay-per-use" || p == "subscription"
}

// sanitizeForRender strips markdown-sensitive characters from user-controlled strings
// before rendering in gnoweb to prevent injection attacks.
func sanitizeForRender(s string) string {
	var out strings.Builder
	for _, c := range s {
		switch c {
		case '[', ']', '(', ')', '#', '*', '`', '!', '<', '>', '|', '\\', '_', '~', '\n', '\r', '\t':
			continue
		default:
			out.WriteRune(c)
		}
	}
	return out.String()
}

// countAgentsByCreator counts how many agents `creator` currently owns (B4 cap).
// Bounded by MaxAgents (global), so O(MaxAgents) worst case.
func countAgentsByCreator(creator address) int {
	n := 0
	agents.Iterate("", "", func(_ string, value interface{}) bool {
		if value.(*Agent).Creator == creator {
			n++
		}
		return false
	})
	return n
}

// countDepositors counts the distinct credit entries for an agent (B4 cap).
// Bounded by MaxDepositorsPerAgent in steady state (the cap enforces its own
// bound), so the scan stays cheap.
func countDepositors(agentId string) int {
	prefix := agentId + "/"
	n := 0
	credits.Iterate(prefix, prefix+"\xff", func(_ string, _ interface{}) bool {
		n++
		return false
	})
	return n
}

// hasAnyCreditsEntry returns true if ANY credit entry exists for the agent,
// even with zero balance. This prevents a price-lock bypass where the creator
// drains a user's balance to 0, then raises the price, then the user tops up.
// Zero-balance entries remain as markers until explicitly cleaned via
// RefundCredits (which removes the entry) or RemoveAgent.
func hasAnyCreditsEntry(agentId string) bool {
	prefix := agentId + "/"
	found := false
	credits.Iterate(prefix, prefix+"\xff", func(key string, value interface{}) bool {
		found = true
		return true // stop iteration
	})
	return found
}

// isValidAgentID ensures the ID contains only safe characters (no "/" or other delimiters
// that would cause key collisions in the credits/usage AVL trees).
func isValidAgentID(id string) bool {
	for _, c := range id {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
			return false
		}
	}
	return true
}
