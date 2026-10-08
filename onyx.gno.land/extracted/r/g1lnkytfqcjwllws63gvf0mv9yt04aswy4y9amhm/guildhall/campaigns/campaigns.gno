// Package campaigns is Guildhall's escrow for many-hands tasks: a fixed
// reward per claim, a fixed number of slots, and one reviewer approval per
// claim. "10 GNOT each to the first 100 people who write about X" is one
// campaign holding 1000 GNOT.
//
// Each approved claim pays the claimant and writes a reputation record to
// gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation
// at ClaimShareBps of a normal record's weight, vouched for by the reviewer
// who approved it. Small, repeatable tasks therefore count for something
// without outweighing reviewed bounty work.
//
// The rules live in gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/campaign.
// This realm holds the funds, authenticates callers, moves coins, and
// renders the campaigns.
package campaigns

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/campaign/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	// ClaimShareBps is the weight of a claim's reputation record relative to
	// a fully approved bounty milestone (10000).
	ClaimShareBps = 500

	maxDeadlineDays = 365
)

var (
	campaigns   avl.Tree // padded id -> *campaign.Campaign
	lastID      uint64
	byUser      avl.Tree // address -> *avl.Tree(padded id -> struct{})
	statusCount = map[campaign.Status]int{}
	escrowed    avl.Tree // denom key -> int64 currently held

	council *ownable.Ownable
	paused  bool
)

// InitialCouncil owns this namespace and is the only key that can deploy
// here. It can pause new campaigns until TransferCouncil hands the seat on.
const InitialCouncil address = "g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm"

func init() {
	council = ownable.NewWithAddress(InitialCouncil)
}

// ---------------------------------------------------------------------------
// Posting

// PostCampaign posts a campaign funded with the native coins sent along with
// the call, which must equal reward × slots. reviewers is a comma-separated
// address list (empty means the poster reviews alone); any one of them can
// approve a claim. deadlineDays closes the campaign to new claims after that
// many days (0: no deadline).
func PostCampaign(cur realm, title, description, link, tags, reviewers string, reward int64, slots, deadlineDays int) uint64 {
	assertNotPaused()
	if !cur.Previous().IsUserCall() {
		panic("campaigns: native campaigns must be posted directly by a user (maketx call with -send)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Amount <= 0 {
		panic("campaigns: send exactly one coin denomination to fund the campaign")
	}
	c := newCampaign(cur, sent[0].Denom, false, title, description, link, tags, reviewers, reward, slots, deadlineDays)
	if c.Total() != sent[0].Amount {
		panic(ufmt.Sprintf("campaigns: %d slots × %d is %d%s but %d%s was sent",
			c.Slots, c.Reward, c.Total(), c.Denom, sent[0].Amount, sent[0].Denom))
	}
	return store(c)
}

// PostCampaignGRC20 posts a campaign funded with a registered GRC20 token.
// The caller must first approve this realm's address for reward × slots on
// the token; this call pulls the funds into escrow.
func PostCampaignGRC20(cur realm, tokenKey, title, description, link, tags, reviewers string, reward int64, slots, deadlineDays int) uint64 {
	assertNotPaused()
	if grc20reg.Get(tokenKey) == nil {
		panic("campaigns: unknown token " + strconv.Quote(tokenKey))
	}
	if len(unsafe.OriginSend()) > 0 && cur.Previous().IsUserCall() {
		panic("campaigns: do not send native coins with a GRC20 campaign")
	}
	c := newCampaign(cur, tokenKey, true, title, description, link, tags, reviewers, reward, slots, deadlineDays)
	grc20reg.TransferFrom(0, cur, tokenKey, c.Poster, cur.Address(), c.Total())
	return store(c)
}

func newCampaign(cur realm, denom string, isGRC20 bool, title, description, link, tags, reviewers string, reward int64, slots, deadlineDays int) *campaign.Campaign {
	if deadlineDays < 0 || deadlineDays > maxDeadlineDays {
		panic(ufmt.Sprintf("campaigns: deadline must be 0..%d days", maxDeadlineDays))
	}
	now := time.Now()
	var deadline time.Time
	if deadlineDays > 0 {
		deadline = now.Add(time.Duration(deadlineDays) * 24 * time.Hour)
	}
	c, err := campaign.New(campaign.Params{
		ID:          lastID + 1,
		Poster:      cur.Previous().Address(),
		Title:       title,
		Description: description,
		Link:        link,
		Tags:        strings.Split(tags, ","),
		Denom:       denom,
		IsGRC20:     isGRC20,
		Reward:      reward,
		Slots:       slots,
		Reviewers:   campaign.ParseAddresses(reviewers),
		Deadline:    deadline,
		Now:         now,
	})
	check(err)
	return c
}

func store(c *campaign.Campaign) uint64 {
	lastID = c.ID
	campaigns.Set(idKey(c.ID), c)
	statusCount[c.Status]++
	addEscrow(c, c.Total())
	index(c.Poster, c.ID)
	for _, r := range c.Reviewers {
		index(r, c.ID)
	}
	emit("CampaignPosted", c,
		"poster", c.Poster.String(),
		"denom", c.Denom,
		"reward", strconv.FormatInt(c.Reward, 10),
		"slots", strconv.Itoa(c.Slots))
	return c.ID
}

// ---------------------------------------------------------------------------
// Claims

// Claim asks to be paid for doing the task once. proof is a link to the work
// (the post, the PR, the page). It reserves a slot until a reviewer decides.
// Returns the claim number.
func Claim(cur realm, id uint64, proof string) int {
	c := mustGet(id)
	caller := cur.Previous().Address()
	n, err := c.Claim(caller, proof, time.Now())
	check(err)
	index(caller, id)
	emit("CampaignClaimed", c, "claim", strconv.Itoa(n), "claimant", caller.String())
	return n
}

// ApproveClaim pays a pending claim. Any reviewer of the campaign.
func ApproveClaim(cur realm, id uint64, claim int) {
	c := mustGet(id)
	before := c.Status
	caller := cur.Previous().Address()
	payouts, err := c.Approve(caller, claim, time.Now())
	check(err)
	settle(0, cur, c, payouts, caller)
	moved(c, before)
}

// RejectClaim turns down a pending claim and frees its slot. Any reviewer of
// the campaign.
func RejectClaim(cur realm, id uint64, claim int, reason string) {
	c := mustGet(id)
	caller := cur.Previous().Address()
	payouts, err := c.Reject(caller, claim, reason, time.Now())
	check(err)
	emit("CampaignClaimRejected", c, "claim", strconv.Itoa(claim), "reviewer", caller.String())
	settle(0, cur, c, payouts, caller)
}

// Close stops new claims and refunds the free slots to the poster. The
// poster can close at any time; anyone can close after the deadline. Pending
// claims can still be approved or rejected afterwards.
func Close(cur realm, id uint64) {
	c := mustGet(id)
	before := c.Status
	payouts, err := c.Close(cur.Previous().Address(), time.Now())
	check(err)
	settle(0, cur, c, payouts, "")
	moved(c, before)
	emit("CampaignClosed", c)
}

// ---------------------------------------------------------------------------
// Council

// Council is the address that can pause new campaigns.
func Council() address {
	return council.Owner()
}

// TransferCouncil hands the council seat to another address. Council only.
func TransferCouncil(cur realm, newCouncil address) {
	if err := council.TransferOwnership(0, cur, newCouncil); err != nil {
		panic(err.Error())
	}
	chain.Emit("CampaignsCouncilChanged", "council", newCouncil.String())
}

// SetPaused stops or resumes new campaigns. Existing campaigns, claims and
// payouts are never paused. Council only.
func SetPaused(cur realm, p bool) {
	council.AssertOwnedBy(cur.Previous().Address())
	paused = p
	chain.Emit("CampaignsPaused", "paused", strconv.FormatBool(p))
}

// ---------------------------------------------------------------------------
// Queries

// Count is the number of campaigns ever posted.
func Count() int {
	return campaigns.Size()
}

// CountByStatus counts campaigns in a status ("open" or "closed").
func CountByStatus(status string) int {
	s, ok := campaign.ParseStatus(status)
	if !ok {
		return 0
	}
	return statusCount[s]
}

// Escrowed is the amount of denom (a native denom or a grc20reg key) held.
func Escrowed(denom string) int64 {
	if v := escrowed.Get(denom); v != nil {
		return v.(int64)
	}
	return 0
}

// IsPaused reports whether new campaigns are paused.
func IsPaused() bool {
	return paused
}

// ---------------------------------------------------------------------------
// Internals

func settle(_ int, rlm realm, c *campaign.Campaign, payouts []campaign.Payout, reviewer address) {
	for _, p := range payouts {
		transfer(0, rlm, c, p.To, p.Amount)
		addEscrow(c, -p.Amount)
		emit("CampaignPayout", c,
			"kind", string(p.Kind),
			"to", p.To.String(),
			"amount", strconv.FormatInt(p.Amount, 10),
			"claim", strconv.Itoa(p.Claim))
		if p.Kind != campaign.PayoutWork {
			continue
		}
		cl := c.GetClaim(p.Claim)
		reputation.AddRecord(cross(rlm),
			p.To,
			c.Poster,
			[]address{reviewer},
			ClaimShareBps,
			p.Amount,
			c.Denom,
			clip(c.Title, 300),
			cl.Proof,
			ufmt.Sprintf("c%d/%d", c.ID, p.Claim),
			false,
		)
	}
}

func transfer(_ int, rlm realm, c *campaign.Campaign, to address, amount int64) {
	if amount <= 0 {
		return
	}
	if c.IsGRC20 {
		grc20reg.Transfer(0, rlm, c.Denom, to, amount)
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: c.Denom, Amount: amount}})
}

func mustGet(id uint64) *campaign.Campaign {
	c := getCampaign(id)
	if c == nil {
		panic("campaigns: campaign " + strconv.FormatUint(id, 10) + " not found")
	}
	return c
}

func getCampaign(id uint64) *campaign.Campaign {
	v := campaigns.Get(idKey(id))
	if v == nil {
		return nil
	}
	return v.(*campaign.Campaign)
}

func moved(c *campaign.Campaign, before campaign.Status) {
	if c.Status != before {
		statusCount[before]--
		statusCount[c.Status]++
	}
}

func addEscrow(c *campaign.Campaign, delta int64) {
	cur := int64(0)
	if v := escrowed.Get(c.Denom); v != nil {
		cur = v.(int64)
	}
	escrowed.Set(c.Denom, cur+delta)
}

func index(addr address, id uint64) {
	if addr == "" {
		return
	}
	var t *avl.Tree
	if v := byUser.Get(addr.String()); v != nil {
		t = v.(*avl.Tree)
	} else {
		t = avl.NewTree()
		byUser.Set(addr.String(), t)
	}
	t.Set(idKey(id), struct{}{})
}

func assertNotPaused() {
	if paused {
		panic("campaigns: posting is paused by the council")
	}
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}

func emit(event string, c *campaign.Campaign, kv ...string) {
	attrs := append([]string{"id", strconv.FormatUint(c.ID, 10), "status", c.Status.String()}, kv...)
	chain.Emit(event, attrs...)
}

func idKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}
