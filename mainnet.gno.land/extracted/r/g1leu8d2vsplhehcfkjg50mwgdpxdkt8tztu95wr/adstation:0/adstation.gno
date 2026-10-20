// Package adstation sells the panels of gno.world's ad station by the week, for GNOT, to ads an approver has passed
// (jae, his terminal, 2026-10-14: "lets make a site for the ad station, maybe ads.gno.world, where you can bid in gnot
// for your ad to show after approval" … "if somebody comes in and says i want this this this this panel, well, if
// they pay, they get it right? so make it flexible, market based, interesting").
//
// THE UNIT is a panel, by index 0 … Panels()-1; the page maps an index to the station (face, row, column) and offers
// its colour groups as ready-made selections, so the groups can change without this realm knowing. A bid names any
// set of panels ("0-8,27-35"), one ad and one week, and carries its GNOT with it.
//
// THE WEEK starts Monday 00:00 UTC and is named by that unix time. Bids for a week close a day before it starts;
// weeks up to AheadWeeks ahead are open. An approver passes or turns down each ad; a turned-down ad's open bids are
// refunded at once. From the week's start anyone may Settle it: the open bids whose ad is approved are ranked two
// ways — by price per panel, and by the whole amount — each in turn winning if none of its panels is taken yet, and
// the way that pays more decides the week (see allocate); the winners' GNOT goes to the ad station's treasury
// (r/…/adtreasury), everyone else's back to them.
// Refunds are credited and paid by Withdraw (the owner of the money) or PayOut (anyone, for them).
//
// THE ROLES: an owner (two-step hand-off) names the approvers and sets the minimum bid, the panel count of weeks not
// yet bid on, and a pause on new bids; neither the owner nor an approver can move a bid's GNOT anywhere but back to
// its bidder or, by settling, to the treasury. The owner and first approver is Jae's cold key.
//
// Immutable, not private (gnomod.toml).
package adstation

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"sort"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/adtreasury"
)

const (
	pkgPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/adstation" // must match gnomod.toml
	coldKey = address("g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6")              // Jae's: the first owner and approver
	GNOT         = "ugnot"

	WeekLen    = int64(7 * 86400)
	Monday0    = int64(4 * 86400) // 1970-01-05 00:00 UTC, the first Monday after the epoch
	CloseAhead = int64(86400)     // a week's bidding closes a day before it starts
	AheadWeeks = int64(8)         // weeks open for bidding, counting from the next one

	MaxPanels      = 1024 // the most panels a week may have
	MaxBidsWeek       = 200 // bids a week holds (Settle ranks them all in one call); a full week takes a larger bid in place of its smallest
	MaxBidsBidderWeek = 10  // open bids one wallet may hold in one week
	MaxOpenBidsAd     = 32  // open bids one ad may carry (a turn-down refunds them in one call)
	MaxPending        = 100 // ads waiting for an approver with a bid at stake, at once
	MaxPendingOwner   = 5   // … of them one advertiser's
	maxRejectMany     = 10  // ads one RejectMany turns down: ten with 32 open bids each in full weeks cost ~0.94B gas on a node, fifty ~3.57B, more than a block (review round 2, R2-3)
	maxTitle       = 60
	maxLink        = 200
	maxReason      = 120
	maxPanelsSpec  = 2000
	listMax        = 50
	defaultPanels  = 108           // the ring: 27 columns × 2 rows × 2 faces
	defaultMinBid  = 100_000_000   // 100 GNOT (jae: "100 GNOT (~$7)")
)

// Ad is one approved-or-not picture with its link and title; immutable once made, so an approval covers exactly it.
type Ad struct {
	ID      int64
	Owner   address // the advertiser who made it with their first bid
	Image   string  // sha256 hex of the picture as the site stores it
	Link    string  // https://…
	Title   string
	State   string // "pending", "approved", "rejected"
	Reason  string // why it was turned down
	By      address
	At      int64 // when it was decided
	Created int64
	open    []int64 // its open bids
	queued  bool    // counted in pending: waiting, with a bid at stake
}

// Offer is one bid: a price for a set of panels in one week, for one ad, its GNOT held here until the week settles.
type Offer struct {
	ID     int64
	Week   int64 // the week's start
	Ad     int64
	Bidder address
	Panels string // canonical: "0-8,27-35"
	Count  int    // panels in it
	Amount int64  // ugnot
	Placed int64
	State  string // "open", "won", "lost", "refunded" (its ad was turned down), "bumped" (a full week gave its place up)
	bits   []uint64
}

// Week holds a week's bids and, once settled, its winners.
type Week struct {
	Start   int64
	N       int // its panel count, fixed at its first bid
	Settled bool
	Paid    int64 // to the treasury
	bids    []int64
	amts    []int64 // each listed bid's amount, beside bids: a full week finds its smallest bid without reading every bid
	appr    []bool  // beside bids: its ad is approved, so a full week never gives its place up (review round 2, R2-1)
	won     []int64
	per     map[address]int // each bidder's open bids in it, until it settles (a bid counts its bidder's without a scan)
}

var (
	owner     = coldKey
	nextOwner address
	approvers avl.Tree // address → true
	minBid    = int64(defaultMinBid)
	panels    = defaultPanels
	paused    bool

	ads     avl.Tree // padded id → *Ad
	bids    avl.Tree // padded id → *Offer
	weeks   avl.Tree // padded start → *Week
	owed    avl.Tree // address → int64 ugnot
	lastAd  int64
	lastBid int64
	byOwner   avl.Tree // advertiser → []int64: their latest ads, oldest first (their own record: json/by/<address>)
	byBidder  avl.Tree // bidder → []int64: their latest bids, oldest first — a bumped or refunded bid leaves its week, not this
	pending   int      // ads waiting for an approver with an open bid (queue, unqueue)
	pendingBy avl.Tree // advertiser → how many of theirs are counted in pending
	earned    int64    // all weeks' winning bids, paid to the treasury
)

func init(cur realm) {
	if cur.Address() != chain.PackageAddress(pkgPath) {
		panic("adstation: deployed at a path other than pkgPath")
	}
	approvers.Set(coldKey.String(), true)
}

// ---------------------------------------------------------------- time --

// WeekOf is the start of the week holding t (unix seconds).
func WeekOf(t int64) int64 {
	if t < Monday0 {
		return Monday0
	}
	return Monday0 + (t-Monday0)/WeekLen*WeekLen
}

// ThisWeek is the start of the week running now; NextWeek the one after it.
func ThisWeek() int64 { return WeekOf(time.Now().Unix()) }
func NextWeek() int64 { return ThisWeek() + WeekLen }

// Closes is when bidding for a week ends.
func Closes(week int64) int64 { return week - CloseAhead }

func isWeek(w int64) bool { return w >= Monday0 && (w-Monday0)%WeekLen == 0 }

// ---------------------------------------------------------------- reading --

func Owner() address        { return owner }
func NextOwner() address    { return nextOwner }
func IsApprover(a address) bool { return approvers.Has(a.String()) }
func MinBid() int64         { return minBid }
func Panels() int           { return panels }
func Paused() bool          { return paused }
func Earned() int64         { return earned }
func Treasury() address     { return adtreasury.Address() } // imported, so this realm cannot go on chain before the treasury
func Address() address      { return chain.PackageAddress(pkgPath) }

// Owed is what an address could withdraw now: refunds of lost and turned-down bids.
func Owed(a address) int64 {
	v := owed.Get(a.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

// GetAd and GetBid are copies.
func GetAd(id int64) Ad   { return *ad(id) }
func GetBid(id int64) Offer { return *bid(id) }

// Approvers lists the approvers.
func Approvers() []address {
	var out []address
	approvers.Iterate("", "", func(k string, _ any) bool {
		out = append(out, address(k))
		return false
	})
	return out
}

func pad(n int64) string {
	s := strconv.FormatInt(n, 10)
	return strings.Repeat("0", 20-len(s)) + s
}

func ad(id int64) *Ad {
	v := ads.Get(pad(id))
	if v == nil {
		panic("adstation: no such ad")
	}
	return v.(*Ad)
}

func bid(id int64) *Offer {
	v := bids.Get(pad(id))
	if v == nil {
		panic("adstation: no such bid")
	}
	return v.(*Offer)
}

func weekRec(w int64) *Week {
	v := weeks.Get(pad(w))
	if v == nil {
		return nil
	}
	return v.(*Week)
}

// ---------------------------------------------------------------- callers and money --

func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("adstation: spoofed realm")
	}
	return cur.Previous().Address()
}

// payer is the signer of a direct call carrying GNOT: a payment entry point refuses relays (MsgRun, another realm),
// which could spend the origin's coins before calling here (gno-security-guide §5.5).
func payer(cur realm) address {
	if !cur.IsCurrent() {
		panic("adstation: spoofed realm")
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("adstation: bid in a direct call from your wallet")
	}
	return prev.Address()
}

// sent is the ugnot carried by the call; any other coin is refused.
func sent() int64 {
	coins := unsafe.OriginSend()
	for _, c := range coins {
		if c.Denom != GNOT {
			panic("adstation: only GNOT is accepted")
		}
	}
	return coins.AmountOf(GNOT)
}

func credit(to address, ugnot int64) {
	if ugnot <= 0 {
		return
	}
	owed.Set(to.String(), Owed(to)+ugnot)
}

func pay(cur realm, to address, ugnot int64) {
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(Address(), to, chain.Coins{{GNOT, ugnot}})
}

// ---------------------------------------------------------------- bidding --

// Bid opens an ad (its picture by hash, a link, a title) and bids for it in one call: the GNOT sent is the bid, for
// the panels named ("3", "0-8", "0-8,27-35") in the week starting at week (a Monday 00:00 UTC, unix seconds).
// Returns the bid's id; the ad's id is GetBid(id).Ad.
func Bid(cur realm, week int64, panelSpec string, image, link, title string) int64 {
	who := payer(cur)
	ugnot := sent()
	checkImage(image)
	checkLink(link)
	checkTitle(title)
	queueRoom(who)
	n, bits, count, bump := admit(who, week, panelSpec, ugnot) // every check before anything is written
	lastAd++
	a := &Ad{ID: lastAd, Owner: who, Image: image, Link: link, Title: title, State: "pending", Created: time.Now().Unix()}
	ads.Set(pad(a.ID), a)
	appendTo(&byOwner, who, a.ID)
	chain.Emit("AdMade", "id", strconv.FormatInt(a.ID, 10), "by", who.String(), "image", image)
	id := place(who, a, week, n, bits, count, ugnot, bump)
	queue(a)
	return id
}

// BidAd bids again with an ad of yours, approved or still waiting: the GNOT sent is the bid.
func BidAd(cur realm, adID int64, week int64, panelSpec string) int64 {
	who := payer(cur)
	ugnot := sent()
	a := ad(adID)
	if a.Owner != who {
		panic("adstation: that ad is someone else's")
	}
	if a.State == "rejected" {
		panic("adstation: that ad was turned down")
	}
	if len(a.open) >= MaxOpenBidsAd {
		panic("adstation: that ad has too many open bids")
	}
	if a.State == "pending" && !a.queued { // a waiting ad whose bids were all decided comes back into the queue with this one
		queueRoom(who)
	}
	n, bits, count, bump := admit(who, week, panelSpec, ugnot)
	id := place(who, a, week, n, bits, count, ugnot, bump)
	queue(a)
	return id
}

// appendTo adds an id to an address's list in an index. Only the latest listMax are ever shown, so the list keeps at
// most twice that: a bid costs the same however many came before it (review round 2, R2-5: the whole history was read
// and written on every bid).
func appendTo(t *avl.Tree, who address, id int64) {
	var list []int64
	if v := t.Get(who.String()); v != nil {
		list = v.([]int64)
	}
	list = append(list, id)
	if len(list) > 2*listMax {
		list = append([]int64(nil), list[len(list)-listMax:]...)
	}
	t.Set(who.String(), list)
}

// THE APPROVERS' QUEUE counts only the waiting ads that have a bid at stake (the review of 2026-10-14, F2: an ad whose
// bids had all been decided still held one of the queue's places, so a hundred of them, every GNOT already refunded,
// shut the queue for nothing), at most MaxPendingOwner of them one advertiser's. queueRoom checks before anything is
// written; queue and unqueue keep the counts.
func queueRoom(who address) {
	if pending >= MaxPending {
		panic("adstation: too many ads are waiting for an approver; try again later")
	}
	if waitingOf(who) >= MaxPendingOwner {
		panic("adstation: you have " + strconv.Itoa(MaxPendingOwner) + " ads waiting for an approver already")
	}
}

func waitingOf(o address) int {
	v := pendingBy.Get(o.String())
	if v == nil {
		return 0
	}
	return v.(int)
}

func queue(a *Ad) {
	if a.queued || a.State != "pending" || len(a.open) == 0 {
		return
	}
	a.queued = true
	pending++
	pendingBy.Set(a.Owner.String(), waitingOf(a.Owner)+1)
}

func unqueue(a *Ad) {
	if !a.queued {
		return
	}
	a.queued = false
	pending--
	if n := waitingOf(a.Owner) - 1; n > 0 {
		pendingBy.Set(a.Owner.String(), n)
	} else {
		pendingBy.Remove(a.Owner.String())
	}
}

// admit checks a bid before anything is written: the pause, the least bid, the week (a Monday, still open, not too
// far ahead), the bidder's open bids in it, room for another bid, and the panels against the week's count. Returns
// that count, the parsed set, and the bid a full week gives up for this one (0 for none).
func admit(who address, week int64, panelSpec string, ugnot int64) (int, []uint64, int, int64) {
	if paused {
		panic("adstation: bidding is paused")
	}
	if ugnot < minBid {
		panic("adstation: the least bid is " + gnot(minBid))
	}
	now := time.Now().Unix()
	if !isWeek(week) {
		panic("adstation: a week is named by its start, a Monday 00:00 UTC")
	}
	if now >= Closes(week) {
		panic("adstation: bidding for that week has closed")
	}
	if week > ThisWeek()+AheadWeeks*WeekLen {
		panic("adstation: that week is not open yet")
	}
	n, bump := panels, int64(0)
	if w := weekRec(week); w != nil {
		n = w.N
		if w.per[who] >= MaxBidsBidderWeek {
			panic("adstation: you hold " + strconv.Itoa(MaxBidsBidderWeek) + " open bids in that week already; raise one instead")
		}
		// A FULL WEEK TAKES A LARGER BID (the review of 2026-10-14, F1: a week's places, once filled, stayed filled — even by
		// bids an approver had turned down — so the leader could fill the week and keep it): the new bid takes the place of the
		// week's smallest open bid of an ad not yet approved (the newest of equals), which is refunded; a bid no larger than
		// that one is refused. An approved ad's bid keeps its place (round 2, R2-1: bids of ads nobody approved bumped approved
		// bids in the minute before the close, then lost and were refunded in full). The scan runs only when the week is full.
		if len(w.bids) >= MaxBidsWeek {
			low := -1 // the smallest bid of an ad not approved; listed in id order: the later of equal amounts is the newer bid
			for i := range w.amts {
				if !w.appr[i] && (low < 0 || w.amts[i] <= w.amts[low]) {
					low = i
				}
			}
			if low < 0 {
				panic("adstation: that week is full of bids for approved ads; a place frees when one is turned down")
			}
			if ugnot <= w.amts[low] {
				panic("adstation: that week is full: bid more than " + gnot(w.amts[low]) + " to take the place of its smallest bid")
			}
			bump = w.bids[low]
		}
	}
	bits, count := parsePanels(panelSpec, n)
	return n, bits, count, bump
}


// place writes an admitted bid, after the bid it bumps (if any) is refunded and out of the week.
func place(who address, a *Ad, week int64, n int, bits []uint64, count int, ugnot int64, bump int64) int64 {
	if bump != 0 {
		b := bid(bump)
		b.State = "bumped"
		credit(b.Bidder, b.Amount)
		unlist(b)
		dropOpen(b)
		chain.Emit("Bumped", "id", strconv.FormatInt(b.ID, 10))
	}
	w := weekRec(week)
	if w == nil {
		w = &Week{Start: week, N: n}
		weeks.Set(pad(week), w)
	}
	now := time.Now().Unix()
	lastBid++
	b := &Offer{ID: lastBid, Week: week, Ad: a.ID, Bidder: who, Panels: canonical(bits, w.N), Count: count, Amount: ugnot, Placed: now, State: "open", bits: bits}
	bids.Set(pad(b.ID), b)
	appendTo(&byBidder, who, b.ID)
	w.bids = append(w.bids, b.ID)
	w.amts = append(w.amts, b.Amount)
	w.appr = append(w.appr, a.State == "approved")
	if w.per == nil {
		w.per = map[address]int{}
	}
	w.per[who]++
	a.open = append(a.open, b.ID)
	chain.Emit("Bid", "id", strconv.FormatInt(b.ID, 10), "week", strconv.FormatInt(week, 10), "ad", strconv.FormatInt(a.ID, 10), "by", who.String(), "panels", b.Panels, "ugnot", strconv.FormatInt(ugnot, 10))
	return b.ID
}

// Raise adds the GNOT sent to an open bid of yours, before its week closes.
func Raise(cur realm, bidID int64) {
	who := payer(cur)
	ugnot := sent()
	b := bid(bidID)
	if b.Bidder != who {
		panic("adstation: that bid is someone else's")
	}
	if b.State != "open" {
		panic("adstation: that bid is no longer open")
	}
	if paused {
		panic("adstation: bidding is paused")
	}
	if time.Now().Unix() >= Closes(b.Week) {
		panic("adstation: bidding for that week has closed")
	}
	if ugnot <= 0 {
		panic("adstation: send the GNOT to add")
	}
	b.Amount += ugnot
	if w := weekRec(b.Week); w != nil {
		for i, id := range w.bids {
			if id == b.ID {
				w.amts[i] = b.Amount
			}
		}
	}
	chain.Emit("Raised", "id", strconv.FormatInt(b.ID, 10), "ugnot", strconv.FormatInt(b.Amount, 10))
}

// ---------------------------------------------------------------- approving --

func mustApprove(cur realm) address {
	who := caller(cur)
	if !IsApprover(who) {
		panic("adstation: only an approver")
	}
	return who
}

// Approve passes a waiting ad: its bids compete when their weeks settle.
func Approve(cur realm, adID int64) {
	who := mustApprove(cur)
	a := ad(adID)
	if a.State != "pending" {
		panic("adstation: that ad is not waiting")
	}
	unqueue(a)
	a.State, a.By, a.At = "approved", who, time.Now().Unix()
	for _, id := range a.open { // its listed bids now hold their places
		b := bid(id)
		if w := weekRec(b.Week); w != nil {
			for i, x := range w.bids {
				if x == id {
					w.appr[i] = true
				}
			}
		}
	}
	chain.Emit("Approved", "id", strconv.FormatInt(a.ID, 10), "by", who.String())
}

// Reject turns an ad down, waiting or approved, with a reason (plain text): every open bid of it is refunded now and
// leaves its week, whose place it frees. Weeks it already won stay paid.
func Reject(cur realm, adID int64, reason string) {
	who := mustApprove(cur)
	checkReason(reason)
	a := ad(adID)
	if a.State == "rejected" {
		panic("adstation: that ad was already turned down")
	}
	reject(a, who, reason)
}

// RejectMany turns down several ads in one call ("4,9,12", at most 50), with one reason; ads already turned down are
// passed over. Returns how many it turned down.
func RejectMany(cur realm, adIDs string, reason string) int {
	who := mustApprove(cur)
	checkReason(reason)
	parts := strings.Split(adIDs, ",")
	if adIDs == "" || len(parts) > maxRejectMany {
		panic("adstation: name 1 to " + strconv.Itoa(maxRejectMany) + " ads, like 4,9,12")
	}
	var list []*Ad
	for _, p := range parts { // every number checked before any ad is turned down
		id, err := strconv.ParseInt(strings.TrimSpace(p), 10, 64)
		if err != nil {
			panic("adstation: ads are named by their numbers, like 4,9,12")
		}
		list = append(list, ad(id))
	}
	n := 0
	for _, a := range list {
		if a.State == "rejected" {
			continue
		}
		reject(a, who, reason)
		n++
	}
	return n
}

func checkReason(reason string) {
	if len(reason) > maxReason {
		panic("adstation: the reason is at most " + strconv.Itoa(maxReason) + " characters")
	}
	plain(reason, "the reason")
}

func reject(a *Ad, who address, reason string) {
	unqueue(a)
	a.State, a.Reason, a.By, a.At = "rejected", reason, who, time.Now().Unix()
	for _, id := range a.open {
		b := bid(id)
		if b.State == "open" {
			b.State = "refunded"
			credit(b.Bidder, b.Amount)
			unlist(b)
		}
	}
	a.open = nil
	chain.Emit("Rejected", "id", strconv.FormatInt(a.ID, 10), "by", who.String())
}

// unlist takes a bid out of its week's list (it stays readable by GetBid): a refunded bid holds no place there, and no
// longer counts among its bidder's.
func unlist(b *Offer) {
	w := weekRec(b.Week)
	if w == nil {
		return
	}
	if w.per[b.Bidder] > 1 {
		w.per[b.Bidder]--
	} else {
		delete(w.per, b.Bidder)
	}
	keep, amts, appr := make([]int64, 0, len(w.bids)), make([]int64, 0, len(w.amts)), make([]bool, 0, len(w.appr))
	for i, id := range w.bids {
		if id != b.ID {
			keep, amts, appr = append(keep, id), append(amts, w.amts[i]), append(appr, w.appr[i])
		}
	}
	w.bids, w.amts, w.appr = keep, amts, appr
}

// ---------------------------------------------------------------- settling --

// Settle closes the books of a week that has started (anyone may call it, once): it picks the winners among the open
// bids whose ad is approved (allocate), pays the winners' GNOT to the treasury and credits everyone else's back.
// Returns the winning bids' total.
func Settle(cur realm, week int64) int64 {
	caller(cur)
	if !isWeek(week) {
		panic("adstation: a week is named by its start, a Monday 00:00 UTC")
	}
	if time.Now().Unix() < week {
		panic("adstation: that week has not started")
	}
	w := weekRec(week)
	if w == nil {
		panic("adstation: nobody bid for that week")
	}
	if w.Settled {
		panic("adstation: that week is settled")
	}
	won := allocate(w)
	isWon := map[int64]bool{}
	for _, id := range won {
		isWon[id] = true
	}
	var paid int64
	for _, id := range w.bids {
		b := bid(id)
		if b.State != "open" {
			continue
		}
		if isWon[id] {
			b.State = "won"
			paid += b.Amount
		} else {
			b.State = "lost"
			credit(b.Bidder, b.Amount)
		}
		dropOpen(b)
	}
	w.Settled, w.won, w.Paid, w.per = true, won, paid, nil
	earned += paid
	if paid > 0 {
		pay(cur, Treasury(), paid)
	}
	chain.Emit("Settled", "week", strconv.FormatInt(week, 10), "winners", strconv.Itoa(len(won)), "ugnot", strconv.FormatInt(paid, 10))
	return paid
}

func dropOpen(b *Offer) {
	a := ad(b.Ad)
	keep := make([]int64, 0, len(a.open))
	for _, id := range a.open {
		if id != b.ID {
			keep = append(keep, id)
		}
	}
	a.open = keep
	if len(a.open) == 0 {
		unqueue(a) // nothing at stake: it leaves the approvers' queue until it bids again
	}
}

// allocate picks a week's winners among its open bids for approved ads: each in turn of an order wins if none of its
// panels is taken yet, and of two orders — price per panel (cross-multiplied, so no rounding), and the whole amount —
// the one that pays the treasury more wins (then the one that sells more panels, then price per panel). THE REVIEW OF
// 2026-10-14, F3: by price per panel alone, one least bid for one panel placed a minute before the close voided a
// bid five times its size for the whole ring, and the treasury took the small one with 107 panels dark. Deterministic.
func allocate(w *Week) []int64 {
	var byP, byA []*Offer
	for _, id := range w.bids {
		b := bid(id)
		if b.State == "open" && ad(b.Ad).State == "approved" {
			byP = append(byP, b)
			byA = append(byA, b)
		}
	}
	sort.Sort(byPrice(byP))
	sort.Sort(byAmount(byA))
	wonP, paidP, soldP := greedy(byP, w.N)
	wonA, paidA, soldA := greedy(byA, w.N)
	if paidA > paidP || paidA == paidP && soldA > soldP {
		return wonA
	}
	return wonP
}

// greedy takes the bids in order, each if none of its panels is taken: the winners, what they pay, the panels sold.
func greedy(order []*Offer, n int) ([]int64, int64, int) {
	taken := make([]uint64, words(n))
	var won []int64
	var paid int64
	sold := 0
	for _, b := range order {
		if overlaps(taken, b.bits) {
			continue
		}
		for i := range taken {
			taken[i] |= b.bits[i]
		}
		won = append(won, b.ID)
		paid += b.Amount
		sold += b.Count
	}
	return won, paid, sold
}

// byAmount orders bids by the whole amount, then price per panel, then the earlier id.
type byAmount []*Offer

func (p byAmount) Len() int      { return len(p) }
func (p byAmount) Swap(i, j int) { p[i], p[j] = p[j], p[i] }
func (p byAmount) Less(i, j int) bool {
	x, y := p[i], p[j]
	if x.Amount != y.Amount {
		return x.Amount > y.Amount
	}
	l, r := x.Amount*int64(y.Count), y.Amount*int64(x.Count)
	if l != r {
		return l > r
	}
	return x.ID < y.ID
}

// byPrice orders bids best first: price per panel (cross-multiplied, no rounding), then amount, then the earlier id.
type byPrice []*Offer

func (p byPrice) Len() int      { return len(p) }
func (p byPrice) Swap(i, j int) { p[i], p[j] = p[j], p[i] }
func (p byPrice) Less(i, j int) bool {
	x, y := p[i], p[j]
	l, r := x.Amount*int64(y.Count), y.Amount*int64(x.Count)
	if l != r {
		return l > r
	}
	if x.Amount != y.Amount {
		return x.Amount > y.Amount
	}
	return x.ID < y.ID
}

// Winners is the week's winning bids: final once it is settled, else as things stand now.
func Winners(week int64) []int64 {
	w := weekRec(week)
	if w == nil {
		return nil
	}
	if w.Settled {
		return append([]int64(nil), w.won...)
	}
	return allocate(w)
}

// ---------------------------------------------------------------- refunds --

// Withdraw pays you what you are owed.
func Withdraw(cur realm) int64 {
	who := caller(cur)
	return payOut(cur, who)
}

// PayOut pays an address what it is owed; anyone may call it for anyone (the money has one destination).
func PayOut(cur realm, to address) int64 {
	caller(cur)
	return payOut(cur, to)
}

func payOut(cur realm, to address) int64 {
	n := Owed(to)
	if n <= 0 {
		panic("adstation: nothing is owed to " + to.String())
	}
	owed.Remove(to.String())
	pay(cur, to, n)
	chain.Emit("Paid", "to", to.String(), "ugnot", strconv.FormatInt(n, 10))
	return n
}

// ---------------------------------------------------------------- the owner --

func mustOwn(cur realm) address {
	who := caller(cur)
	if who != owner {
		panic("adstation: only the owner")
	}
	return who
}

// AddApprover and RemoveApprover name who may pass or turn down ads.
func AddApprover(cur realm, a address) {
	mustOwn(cur)
	if !a.IsValid() {
		panic("adstation: not an address")
	}
	approvers.Set(a.String(), true)
	chain.Emit("ApproverAdded", "who", a.String())
}

func RemoveApprover(cur realm, a address) {
	mustOwn(cur)
	if _, removed := approvers.Remove(a.String()); !removed {
		panic("adstation: not an approver")
	}
	chain.Emit("ApproverRemoved", "who", a.String())
}

// SetMinBid sets the least bid, in ugnot, for bids placed from now on.
func SetMinBid(cur realm, ugnot int64) {
	mustOwn(cur)
	if ugnot <= 0 {
		panic("adstation: the least bid must be positive")
	}
	minBid = ugnot
	chain.Emit("MinBid", "ugnot", strconv.FormatInt(ugnot, 10))
}

// SetPanels sets the panel count of weeks nobody has bid on yet (the station's panels can change; a week keeps the
// count it had at its first bid).
func SetPanels(cur realm, n int) {
	mustOwn(cur)
	if n < 1 || n > MaxPanels {
		panic("adstation: panels are between 1 and " + strconv.Itoa(MaxPanels))
	}
	panels = n
	chain.Emit("Panels", "n", strconv.Itoa(n))
}

// SetPaused stops (true) or resumes new bids and raises; approving, settling and refunds go on.
func SetPaused(cur realm, p bool) {
	mustOwn(cur)
	paused = p
	chain.Emit("Paused", "paused", strconv.FormatBool(p))
}

// SetOwner names the next owner; nothing changes until they AcceptOwner. "" withdraws the offer.
func SetOwner(cur realm, to address) {
	mustOwn(cur)
	if to != "" && !to.IsValid() {
		panic("adstation: not an address")
	}
	nextOwner = to
	chain.Emit("OwnerNamed", "next", to.String())
}

// AcceptOwner takes the owner role, by the one named (a user or a realm).
func AcceptOwner(cur realm) {
	who := caller(cur)
	if nextOwner == "" || who != nextOwner {
		panic("adstation: not the one named")
	}
	prev := owner
	owner, nextOwner = who, ""
	chain.Emit("OwnerChanged", "from", prev.String(), "to", who.String())
}

// ---------------------------------------------------------------- checks --

func checkImage(s string) {
	if len(s) != 64 {
		panic("adstation: the image is its sha256, 64 hex characters")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			panic("adstation: the image is its sha256, 64 lowercase hex characters")
		}
	}
}

// checkLink: https only, from a character set that cannot break the pages (markdown, JSON) that show it.
func checkLink(s string) {
	if len(s) > maxLink {
		panic("adstation: the link is at most " + strconv.Itoa(maxLink) + " characters")
	}
	if !strings.HasPrefix(s, "https://") || len(s) <= len("https://") {
		panic("adstation: the link starts with https://")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte("-._~:/?#@!$&+,;=%", c) >= 0 {
			continue
		}
		panic("adstation: the link has a character it cannot carry")
	}
}

func checkTitle(s string) {
	if strings.TrimSpace(s) == "" || len(s) > maxTitle {
		panic("adstation: the title is 1 to " + strconv.Itoa(maxTitle) + " characters")
	}
	plain(s, "the title")
}

// plain refuses control characters and anything the pages would read as markup or that breaks their JSON.
func plain(s, what string) {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f || strings.IndexByte("[]()<>`*_#|\\!~\"", s[i]) >= 0 {
			panic("adstation: " + what + " is plain text without markup")
		}
	}
}

// ---------------------------------------------------------------- panels --

func words(n int) int { return (n + 63) / 64 }

// parsePanels reads "3", "0-8", "0-8,27-35" against n panels: the set as bits and how many.
func parsePanels(s string, n int) ([]uint64, int) {
	if s == "" || len(s) > maxPanelsSpec {
		panic("adstation: name the panels, e.g. 0-8,27-35")
	}
	bits := make([]uint64, words(n))
	for _, part := range strings.Split(s, ",") {
		lo, hi := part, part
		if i := strings.IndexByte(part, '-'); i >= 0 {
			lo, hi = part[:i], part[i+1:]
		}
		a, err1 := strconv.Atoi(lo)
		b, err2 := strconv.Atoi(hi)
		if err1 != nil || err2 != nil || a < 0 || b < a || b >= n {
			panic("adstation: panels are numbers 0 to " + strconv.Itoa(n-1) + ", like 0-8,27-35")
		}
		for p := a; p <= b; p++ {
			bits[p/64] |= 1 << uint(p%64)
		}
	}
	count := 0
	for _, x := range bits {
		for ; x != 0; x &= x - 1 {
			count++
		}
	}
	return bits, count
}

func overlaps(a, b []uint64) bool {
	for i := range a {
		if a[i]&b[i] != 0 {
			return true
		}
	}
	return false
}

// canonical writes a set of panels as sorted ranges: "0-8,27-35".
func canonical(bits []uint64, n int) string {
	var out []string
	for p := 0; p < n; p++ {
		if bits[p/64]&(1<<uint(p%64)) == 0 {
			continue
		}
		q := p
		for q+1 < n && bits[(q+1)/64]&(1<<uint((q+1)%64)) != 0 {
			q++
		}
		if q == p {
			out = append(out, strconv.Itoa(p))
		} else {
			out = append(out, strconv.Itoa(p)+"-"+strconv.Itoa(q))
		}
		p = q
	}
	return strings.Join(out, ",")
}

// ---------------------------------------------------------------- pages --

// Render: "" the station's market; "json" its settings; "json/week/<start>" a week's bids and winners;
// "json/ad/<id>" an ad; "json/pending" the ads waiting; "json/owed" who is owed refunds; "json/by/<address>" one
// address's own ads and bids, every state, and what it is owed.
func Render(path string) string {
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return home()
	case path == "json":
		return stateJSON()
	case path == "json/pending":
		return pendingJSON()
	case path == "json/owed":
		return owedJSON()
	case len(parts) == 3 && parts[0] == "json" && parts[1] == "by":
		a := address(parts[2])
		if !a.IsValid() { // echo only a real address
			return "404"
		}
		return byJSON(a)
	case len(parts) == 3 && parts[0] == "json" && parts[1] == "week":
		w, err := strconv.ParseInt(parts[2], 10, 64)
		if err != nil || !isWeek(w) {
			return "404"
		}
		return weekJSON(w)
	case len(parts) == 3 && parts[0] == "json" && parts[1] == "ad":
		id, err := strconv.ParseInt(parts[2], 10, 64)
		if err != nil || id < 1 || id > lastAd {
			return "404"
		}
		return adJSON(ad(id))
	}
	return "404"
}

func q(s string) string { return `"` + s + `"` } // only for text the checks above keep free of quotes and backslashes

func i64(n int64) string { return strconv.FormatInt(n, 10) }

func stateJSON() string {
	var b strings.Builder
	b.WriteString(`{"now":` + i64(time.Now().Unix()) + `,"thisWeek":` + i64(ThisWeek()) + `,"minBid":` + i64(minBid) + `,"panels":` + strconv.Itoa(panels) +
		`,"paused":` + strconv.FormatBool(paused) + `,"owner":` + q(owner.String()) + `,"treasury":` + q(Treasury().String()) + `,"earned":` + i64(earned) +
		`,"ads":` + i64(lastAd) + `,"bids":` + i64(lastBid) + `,"pending":` + strconv.Itoa(pending) + `,"closeAhead":` + i64(CloseAhead) + `,"aheadWeeks":` + i64(AheadWeeks) + `,"approvers":[`)
	for i, a := range Approvers() {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(q(a.String()))
	}
	b.WriteString(`],"weeks":[`)
	first := true
	for w := ThisWeek(); w <= ThisWeek()+AheadWeeks*WeekLen; w += WeekLen {
		if weekRec(w) == nil {
			continue
		}
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(i64(w))
	}
	// THE WEEKS THAT STARTED AND WERE NEVER SETTLED (the review of 2026-10-14, F4: a week the keeper missed dropped out of
	// this list while its bids stayed open, their GNOT held): the latest ten, so the box finds them and anyone can Settle.
	b.WriteString(`],"unsettled":` + ids(Unsettled()) + "}")
	return b.String()
}

// Unsettled is the latest ten weeks that have started, hold bids, and were never settled.
func Unsettled() []int64 {
	var out []int64
	now := ThisWeek()
	weeks.ReverseIterate("", "", func(_ string, v any) bool {
		w := v.(*Week)
		if w.Start < now && !w.Settled && len(w.bids) > 0 {
			out = append(out, w.Start)
		}
		return len(out) >= 10
	})
	return out
}

func bidJSON(x *Offer) string {
	return `{"id":` + i64(x.ID) + `,"week":` + i64(x.Week) + `,"ad":` + i64(x.Ad) + `,"bidder":` + q(x.Bidder.String()) + `,"panels":` + q(x.Panels) +
		`,"count":` + strconv.Itoa(x.Count) + `,"amount":` + i64(x.Amount) + `,"placed":` + i64(x.Placed) + `,"state":` + q(x.State) + `}`
}

func adJSON(a *Ad) string {
	return `{"id":` + i64(a.ID) + `,"owner":` + q(a.Owner.String()) + `,"image":` + q(a.Image) + `,"link":` + q(a.Link) + `,"title":` + q(a.Title) +
		`,"state":` + q(a.State) + `,"reason":` + q(a.Reason) + `,"by":` + q(a.By.String()) + `,"at":` + i64(a.At) + `,"created":` + i64(a.Created) + `,"openBids":` + strconv.Itoa(len(a.open)) + `,"queued":` + strconv.FormatBool(a.queued) + `}`
}

func ids(xs []int64) string {
	var b strings.Builder
	b.WriteString("[")
	for i, x := range xs {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(i64(x))
	}
	b.WriteString("]")
	return b.String()
}

func weekJSON(start int64) string {
	w := weekRec(start)
	if w == nil {
		return `{"start":` + i64(start) + `,"closes":` + i64(Closes(start)) + `,"n":` + strconv.Itoa(panels) + `,"settled":false,"paid":0,"bids":[],"winners":[],"ads":[]}`
	}
	var b strings.Builder
	b.WriteString(`{"start":` + i64(start) + `,"closes":` + i64(Closes(start)) + `,"n":` + strconv.Itoa(w.N) + `,"settled":` + strconv.FormatBool(w.Settled) + `,"paid":` + i64(w.Paid) + `,"bids":[`)
	seen := map[int64]bool{}
	var adIDs []int64
	for i, id := range w.bids {
		if i > 0 {
			b.WriteString(",")
		}
		x := bid(id)
		b.WriteString(bidJSON(x))
		if !seen[x.Ad] {
			seen[x.Ad] = true
			adIDs = append(adIDs, x.Ad)
		}
	}
	b.WriteString(`],"winners":` + ids(Winners(start)) + `,"ads":[`)
	for i, id := range adIDs {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(adJSON(ad(id)))
	}
	b.WriteString("]}")
	return b.String()
}

func pendingJSON() string {
	var b strings.Builder
	b.WriteString("[")
	n := 0
	ads.ReverseIterate("", "", func(_ string, v any) bool {
		a := v.(*Ad)
		if a.State != "pending" || !a.queued { // waiting with a bid at stake: the approvers' queue
			return false
		}
		if n > 0 {
			b.WriteString(",")
		}
		b.WriteString(adJSON(a))
		n++
		return n >= MaxPending
	})
	b.WriteString("]")
	return b.String()
}

// byJSON is one address's own record: its latest ads (with their state and any reason they were turned down) and bids
// (every state: open, won, lost, bumped, refunded), and what it is owed. The weeks' lists carry only their listed bids;
// this is where an advertiser sees what happened to the others.
func byJSON(who address) string {
	var b strings.Builder
	b.WriteString(`{"address":` + q(who.String()) + `,"owed":` + i64(Owed(who)) + `,"ads":[`)
	if v := byOwner.Get(who.String()); v != nil {
		list := v.([]int64)
		from := len(list) - listMax
		if from < 0 {
			from = 0
		}
		for i := len(list) - 1; i >= from; i-- {
			if i < len(list)-1 {
				b.WriteString(",")
			}
			b.WriteString(adJSON(ad(list[i])))
		}
	}
	b.WriteString(`],"bids":[`)
	if v := byBidder.Get(who.String()); v != nil {
		list := v.([]int64)
		from := len(list) - listMax
		if from < 0 {
			from = 0
		}
		for i := len(list) - 1; i >= from; i-- {
			if i < len(list)-1 {
				b.WriteString(",")
			}
			b.WriteString(bidJSON(bid(list[i])))
		}
	}
	b.WriteString("]}")
	return b.String()
}

func owedJSON() string {
	var b strings.Builder
	b.WriteString("[")
	n := 0
	owed.Iterate("", "", func(k string, v any) bool {
		if n > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"to":` + q(k) + `,"ugnot":` + i64(v.(int64)) + `}`)
		n++
		return n >= 500
	})
	b.WriteString("]")
	return b.String()
}

func home() string {
	var b strings.Builder
	b.WriteString("# The ad station\n\n")
	b.WriteString("gno.world's ad station sells its panels by the week, for GNOT, at ads.gno.world. Name any panels, upload your picture, bid; an approver passes the ad; the bids close a day before each Monday (00:00 UTC), and when the week starts the approved bids are ranked two ways, by price per panel and by the whole amount, each in turn winning its panels if none is taken, and the way that pays more decides the week. Every bid that does not win is refunded in full.\n\n")
	b.WriteString("- least bid: " + gnot(minBid) + " · panels: " + strconv.Itoa(panels) + " · weeks open: " + i64(AheadWeeks))
	if paused {
		b.WriteString(" · **bidding paused**")
	}
	b.WriteString("\n- earned so far: " + gnot(earned) + ", paid to the station's treasury " + Treasury().String() + "\n")
	b.WriteString("- ads waiting for an approver: " + strconv.Itoa(pending) + "\n\n")
	b.WriteString("## This week\n\n")
	writeWinners(&b, ThisWeek())
	for w := NextWeek(); w <= ThisWeek()+AheadWeeks*WeekLen; w += WeekLen {
		if weekRec(w) == nil {
			continue
		}
		b.WriteString("\n## Week of " + time.Unix(w, 0).UTC().Format("2006-01-02") + " (bids close " + time.Unix(Closes(w), 0).UTC().Format("Jan 2 15:04") + " UTC; as things stand)\n\n")
		writeWinners(&b, w)
	}
	return b.String()
}

func writeWinners(b *strings.Builder, w int64) {
	won := Winners(w)
	if len(won) == 0 {
		b.WriteString("_No ads._\n")
		return
	}
	for _, id := range won {
		x := bid(id)
		a := ad(x.Ad)
		b.WriteString("- panels `" + x.Panels + "` · " + a.Title + " · `" + a.Link + "` · " + gnot(x.Amount) + "\n")
	}
}

// gnot formats ugnot as GNOT, the trailing zeros trimmed.
func gnot(ugnot int64) string {
	whole, frac := ugnot/1_000_000, ugnot%1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	f := strconv.FormatInt(1_000_000+frac, 10)[1:]
	return strconv.FormatInt(whole, 10) + "." + strings.TrimRight(f, "0") + " GNOT"
}
