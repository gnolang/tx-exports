// Package bounties is Guildhall's escrowed bounty board.
//
// Anyone can post a task, fund it with GNOT (or any native coin) or any token
// in the grc20 registry, and split it into milestones. Funds sit in this
// realm until the bounty's reviewers approve a milestone, at which point the
// milestone is paid to the contributor and a record of the work is written to
// gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation. Contested milestones go to an arbiter, who
// can pay the worker, refund the poster, or split the difference.
//
// The rules live in gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounty. This realm holds the funds,
// authenticates callers, moves coins, and renders the board.
package bounties

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounty/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
	"gno.land/r/nt/grc20reg/v0"
)

const maxWorkWindowDays = 365

var (
	bounties avl.Tree // padded id -> *bounty.Bounty
	lastID   uint64
	byUser   avl.Tree // address -> *avl.Tree(padded id -> struct{})
	// councilArbitrated holds the ids of bounties whose arbiter is "the
	// council" rather than a fixed address, so they follow the council if
	// it changes hands.
	councilArbitrated avl.Tree
	statusCount       = map[bounty.Status]int{}
	escrowed          avl.Tree // denom key -> int64 currently held

	council *ownable.Ownable
	paused  bool
)

// InitialCouncil owns this namespace and is the only key that can deploy
// here. It holds the council seat until TransferCouncil hands it on.
const InitialCouncil address = "g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm"

func init() {
	council = ownable.NewWithAddress(InitialCouncil)
}

// ---------------------------------------------------------------------------
// Posting

// PostBounty posts a bounty funded with the native coins sent along with the
// call. milestones is "Title=amount;Title=amount" and must add up to exactly
// what was sent; leave it empty for a single milestone worth the whole
// amount. reviewers is a comma-separated address list (empty means the poster
// reviews alone) and quorum is how many of them must approve each milestone.
// An empty arbiter delegates disputes to the Guildhall council.
func PostBounty(cur realm, title, description, link, tags, reviewers string, quorum int, milestones, arbiter string, workWindowDays int) uint64 {
	assertNotPaused()
	if !cur.Previous().IsUserCall() {
		panic("bounties: native bounties must be posted directly by a user (maketx call with -send)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Amount <= 0 {
		panic("bounties: send exactly one coin denomination to fund the bounty")
	}
	coin := sent[0]
	specs, err := bounty.ParseMilestones(milestones, coin.Amount)
	if err != nil {
		panic(err.Error())
	}
	b := newBounty(cur, coin.Denom, false, title, description, link, tags, reviewers, quorum, specs, arbiter, workWindowDays)
	if b.Total() != coin.Amount {
		panic(ufmt.Sprintf("bounties: milestones add up to %d but %d%s was sent", b.Total(), coin.Amount, coin.Denom))
	}
	return store(b)
}

// PostBountyGRC20 posts a bounty funded with a registered GRC20 token. The
// caller must first approve this realm's address for the milestone total on
// the token; this call pulls the funds into escrow.
func PostBountyGRC20(cur realm, tokenKey, title, description, link, tags, reviewers string, quorum int, milestones, arbiter string, workWindowDays int) uint64 {
	assertNotPaused()
	if grc20reg.Get(tokenKey) == nil {
		panic("bounties: unknown token " + strconv.Quote(tokenKey))
	}
	if len(unsafe.OriginSend()) > 0 && cur.Previous().IsUserCall() {
		panic("bounties: do not send native coins with a GRC20 bounty")
	}
	specs, err := bounty.ParseMilestones(milestones, 0)
	if err != nil {
		panic(err.Error())
	}
	b := newBounty(cur, tokenKey, true, title, description, link, tags, reviewers, quorum, specs, arbiter, workWindowDays)
	grc20reg.TransferFrom(0, cur, tokenKey, b.Poster, cur.Address(), b.Total())
	return store(b)
}

func newBounty(cur realm, denom string, isGRC20 bool, title, description, link, tags, reviewers string, quorum int, specs []bounty.MilestoneSpec, arbiter string, workWindowDays int) *bounty.Bounty {
	if workWindowDays < 0 || workWindowDays > maxWorkWindowDays {
		panic(ufmt.Sprintf("bounties: work window must be 0..%d days", maxWorkWindowDays))
	}
	arb := address(strings.TrimSpace(arbiter))
	if arb == "" {
		arb = council.Owner()
	}
	b, err := bounty.New(bounty.Params{
		ID:          lastID + 1,
		Poster:      cur.Previous().Address(),
		Title:       title,
		Description: description,
		Link:        strings.TrimSpace(link),
		Tags:        strings.Split(tags, ","),
		Denom:       denom,
		IsGRC20:     isGRC20,
		Reviewers:   bounty.ParseAddresses(reviewers),
		Quorum:      quorum,
		Arbiter:     arb,
		Milestones:  specs,
		WorkWindow:  time.Duration(workWindowDays) * 24 * time.Hour,
		Now:         time.Now(),
	})
	if err != nil {
		panic(err.Error())
	}
	if strings.TrimSpace(arbiter) == "" {
		councilArbitrated.Set(idKey(b.ID), struct{}{})
	}
	return b
}

func store(b *bounty.Bounty) uint64 {
	lastID = b.ID
	bounties.Set(idKey(b.ID), b)
	statusCount[b.Status]++
	addEscrow(b, b.Total())
	index(b.Poster, b.ID)
	for _, r := range b.Reviewers {
		index(r, b.ID)
	}
	index(b.Arbiter, b.ID)
	emit("BountyPosted", b,
		"poster", b.Poster.String(),
		"denom", b.Denom,
		"total", strconv.FormatInt(b.Total(), 10))
	return b.ID
}

// ---------------------------------------------------------------------------
// Working on a bounty

// Apply asks the poster to be assigned to an open bounty.
func Apply(cur realm, id uint64, pitch string) {
	b := mustGet(id)
	caller := cur.Previous().Address()
	check(b.Apply(caller, pitch, time.Now()))
	index(caller, id)
	emit("BountyApplied", b, "applicant", caller.String())
}

// Assign hands an open bounty to a contributor. Poster only.
func Assign(cur realm, id uint64, assignee address) {
	b := mustGet(id)
	before := b.Status
	check(b.Assign(cur.Previous().Address(), assignee, time.Now()))
	moved(b, before)
	index(assignee, id)
	emit("BountyAssigned", b, "assignee", assignee.String())
}

// Unassign returns an active bounty to the open pool. The assignee may step
// back at any time; the poster may reclaim it once the work window has
// passed. Milestones awaiting review or arbitration must be settled first.
func Unassign(cur realm, id uint64) {
	b := mustGet(id)
	before, prev := b.Status, b.Assignee
	check(b.Unassign(cur.Previous().Address(), time.Now()))
	moved(b, before)
	emit("BountyUnassigned", b, "previous", prev.String())
}

// Submit hands milestone (1-based) in for review, pointing at the work.
func Submit(cur realm, id uint64, milestone int, link string) {
	b := mustGet(id)
	check(b.Submit(cur.Previous().Address(), milestone-1, link, time.Now()))
	emit("MilestoneSubmitted", b, "milestone", strconv.Itoa(milestone), "link", link)
}

// Approve records a reviewer's approval of a submitted milestone. The
// approval that reaches the quorum releases the milestone's funds to the
// contributor and writes a reputation record.
func Approve(cur realm, id uint64, milestone int) {
	b := mustGet(id)
	caller := cur.Previous().Address()
	before := b.Status
	payouts, err := b.Approve(caller, milestone-1, time.Now())
	check(err)
	emit("MilestoneApproved", b, "milestone", strconv.Itoa(milestone), "reviewer", caller.String())
	m, _ := b.Milestone(milestone - 1)
	settle(0, cur, b, payouts, m.Approvals, false)
	moved(b, before)
}

// RequestChanges sends a submitted milestone back with feedback.
func RequestChanges(cur realm, id uint64, milestone int, feedback string) {
	b := mustGet(id)
	check(b.RequestChanges(cur.Previous().Address(), milestone-1, feedback))
	emit("MilestoneChangesRequested", b, "milestone", strconv.Itoa(milestone))
}

// OpenDispute escalates a submitted or rejected milestone to the arbiter.
// The poster or the contributor who submitted it may open one.
func OpenDispute(cur realm, id uint64, milestone int, reason string) {
	b := mustGet(id)
	caller := cur.Previous().Address()
	check(b.OpenDispute(caller, milestone-1, reason, time.Now()))
	emit("MilestoneDisputed", b, "milestone", strconv.Itoa(milestone), "by", caller.String())
}

// Resolve settles a disputed milestone. workerBps is the share, in basis
// points (0..10000), paid to the contributor; the rest is refunded to the
// poster. Arbiter only.
func Resolve(cur realm, id uint64, milestone int, workerBps int, ruling string) {
	b := mustGet(id)
	caller := cur.Previous().Address()
	if councilArbitrated.Has(idKey(id)) {
		// Council-arbitrated bounties follow the council's current owner.
		b.Arbiter = council.Owner()
	}
	before := b.Status
	payouts, err := b.Resolve(caller, milestone-1, int64(workerBps), ruling, time.Now())
	check(err)
	emit("DisputeResolved", b, "milestone", strconv.Itoa(milestone), "worker_bps", strconv.Itoa(workerBps))
	settle(0, cur, b, payouts, []address{caller}, true)
	moved(b, before)
}

// Cancel withdraws an open bounty and refunds every unpaid milestone to the
// poster. Active bounties must be unassigned first.
func Cancel(cur realm, id uint64) {
	b := mustGet(id)
	before := b.Status
	payouts, err := b.Cancel(cur.Previous().Address(), time.Now())
	check(err)
	settle(0, cur, b, payouts, nil, false)
	moved(b, before)
	emit("BountyCancelled", b)
}

// ---------------------------------------------------------------------------
// Council

// Council returns the default arbiter and operator of the board.
func Council() address {
	return council.Owner()
}

// TransferCouncil hands the council seat to a new address, typically an
// arbitration committee's multisig. Bounties posted with the council as
// arbiter follow. Only the current council can move the seat.
func TransferCouncil(cur realm, newCouncil address) {
	if err := council.TransferOwnership(0, cur, newCouncil); err != nil {
		panic(err.Error())
	}
	emitCouncil(newCouncil)
}

func emitCouncil(addr address) {
	chain.Emit("BountiesCouncilChanged", "council", addr.String())
}

// SetPaused stops (or resumes) the posting of new bounties. Work on existing
// bounties, payouts and refunds are never paused.
func SetPaused(cur realm, p bool) {
	council.AssertOwnedBy(cur.Previous().Address())
	paused = p
	chain.Emit("BountiesPaused", "paused", strconv.FormatBool(p))
}

// ---------------------------------------------------------------------------
// Queries

// Count returns the number of bounties ever posted.
func Count() int {
	return bounties.Size()
}

// CountByStatus returns the number of bounties in status ("open", "active",
// "completed" or "cancelled").
func CountByStatus(status string) int {
	s, ok := bounty.ParseStatus(status)
	if !ok {
		return 0
	}
	return statusCount[s]
}

// Escrowed returns what the board currently holds for denom (a native denom
// or a grc20reg key).
func Escrowed(denom string) int64 {
	v := escrowed.Get(denom)
	if v == nil {
		return 0
	}
	return v.(int64)
}

// IsPaused reports whether posting is paused.
func IsPaused() bool {
	return paused
}

// ---------------------------------------------------------------------------
// Internals

// settle executes payouts, crediting reputation for each payment to a worker.
func settle(_ int, rlm realm, b *bounty.Bounty, payouts []bounty.Payout, reviewers []address, arbitrated bool) {
	for _, p := range payouts {
		transfer(0, rlm, b, p.To, p.Amount)
		addEscrow(b, -p.Amount)
		m, _ := b.Milestone(p.Milestone)
		emit("Payout", b,
			"kind", string(p.Kind),
			"to", p.To.String(),
			"amount", strconv.FormatInt(p.Amount, 10),
			"milestone", strconv.Itoa(p.Milestone+1))
		if p.Kind != bounty.PayoutWork {
			continue
		}
		share := int64(bounty.MaxBps)
		if arbitrated && m.Amount > 0 {
			share = p.Amount * bounty.MaxBps / m.Amount
		}
		reputation.AddRecord(cross(rlm),
			p.To,
			b.Poster,
			reviewers,
			share,
			p.Amount,
			b.Denom,
			clip(b.Title+" — "+m.Title, 300),
			m.Submission,
			ufmt.Sprintf("%d/%d", b.ID, p.Milestone+1),
			arbitrated,
		)
	}
}

func transfer(_ int, rlm realm, b *bounty.Bounty, to address, amount int64) {
	if amount <= 0 {
		return
	}
	if b.IsGRC20 {
		grc20reg.Transfer(0, rlm, b.Denom, to, amount)
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: b.Denom, Amount: amount}})
}

func mustGet(id uint64) *bounty.Bounty {
	v := bounties.Get(idKey(id))
	if v == nil {
		panic("bounties: unknown bounty " + strconv.FormatUint(id, 10))
	}
	return v.(*bounty.Bounty)
}

func getBounty(id uint64) *bounty.Bounty {
	v := bounties.Get(idKey(id))
	if v == nil {
		return nil
	}
	return v.(*bounty.Bounty)
}

func moved(b *bounty.Bounty, before bounty.Status) {
	if b.Status == before {
		return
	}
	statusCount[before]--
	statusCount[b.Status]++
}

func addEscrow(b *bounty.Bounty, delta int64) {
	cur := int64(0)
	if v := escrowed.Get(b.Denom); v != nil {
		cur = v.(int64)
	}
	escrowed.Set(b.Denom, cur+delta)
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
		panic("bounties: posting is paused by the council")
	}
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}

func emit(event string, b *bounty.Bounty, kv ...string) {
	attrs := append([]string{"id", strconv.FormatUint(b.ID, 10), "status", b.Status.String()}, kv...)
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
