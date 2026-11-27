// Package admitone sells event tickets whose price stays in escrow until the
// holder walks in.
//
// A ticket is a GRC721 token. Buying one locks its price in this realm. The
// holder's own Admit, at the door, releases the price to the organiser. If the
// event is cancelled, every ticket is refunded in full. If a holder never
// shows up, they take back the price minus a no-show fee the organiser fixed
// when creating the event. The organiser can never touch the money in escrow.
//
// Tickets cannot be given or transferred. A holder who cannot go lists the
// ticket on the event's resale desk, at no more than face value plus a capped
// markup. A listing opens to buyers a minute after it is posted, and then the
// first buyer takes it, so handing a seat to a buyer chosen in advance is a
// race the seller can lose rather than a sure thing.
//
// An event can post a one-shot Lamplighter job due at its end, so the no-show
// fees reach the organiser on time without anyone remembering to call Settle.
package admitone

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
)

const (
	denom = "ugnot"

	// LampFee is what an organiser sends with CreateEvent to have the event
	// settled by a Lamplighter job at its end. Sending nothing is fine too:
	// then anyone can call Settle.
	LampFee int64 = 50000

	MaxCapacity        = 1000
	MaxPrice     int64 = 1000000000000 // 1,000,000 GNOT
	MaxMarkupBps int64 = 5000          // resale at up to face + 50%
	MaxNoShowBps int64 = 10000         // up to the whole price

	MinLength int64 = 60                 // an event lasts at least a minute
	MaxLength int64 = 90 * 24 * 60 * 60  // and at most 90 days
	MaxAhead  int64 = 366 * 24 * 60 * 60 // it starts within a year

	// ResaleDelay is how long a listing waits before anyone can buy it, so that
	// a seller cannot list and sell to a chosen buyer in one transaction.
	ResaleDelay int64 = 60

	// ResaleDeposit is what a resale buyer pays the seller on top of the price,
	// for the storage deposit the ticket already carries: the seller locked it
	// when buying, and the chain hands it to whoever finally refunds or
	// discards the ticket, which will be the buyer.
	ResaleDeposit int64 = 600000

	maxNameLen    = 60
	maxDetailsLen = 280
)

type event struct {
	id         uint64
	name       string
	details    string
	organiser  address
	start, end int64
	price      int64
	capacity   int
	maxPerAddr int
	markupBps  int64
	noShowBps  int64

	minted   int // serials handed out, 1..minted
	live     int // tickets not refunded
	admitted int // live tickets that were admitted
	entered  int // tickets admitted at the door, ever (discarding does not lower it)

	cancelled bool
	settled   bool   // the no-show fees have gone to the organiser
	job       uint64 // the Lamplighter job that settles the event, or 0
	reclaimed bool   // the job has been cancelled and its deposit recovered
}

type ticket struct {
	id         string // "<event>-<serial>", also its GRC721 token id
	ev         *event
	serial     int
	admittedAt int64 // 0 until the holder is admitted
	listed     bool
	listPrice  int64
	listedAt   int64
}

var (
	events  avl.Tree // padded event id -> *event
	tickets avl.Tree // padded "<event>-<serial>" -> *ticket
	byOwner avl.Tree // address + "/" + padded ticket key -> *ticket
	byJob   avl.Tree // padded job id -> *event
	nextID  uint64   = 1

	nft    *grc721.Token
	ledger *grc721.PrivateLedger

	// selfPath is this realm's own package path, recorded when it is deployed.
	selfPath string
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	nft, ledger = grc721.NewToken("Admit One tickets", "ADMIT", 0, cur)
}

// CreateEvent puts an event on sale and returns its id. The caller is the
// organiser. Times are unix seconds. price is in ugnot (0 for a free event,
// where tickets work as an RSVP and an attendance stamp). maxPerAddr caps the
// tickets one address may hold. markupBps caps resale at face value plus that
// many hundredths of a percent; noShowBps is the share of the price the
// organiser keeps from a holder who never shows up.
//
// Send nothing, or exactly LampFee to have a Lamplighter job settle the event
// at its end.
func CreateEvent(cur realm, name, details string, start, end, price int64,
	capacity, maxPerAddr int, markupBps, noShowBps int64) uint64 {
	runtime.AssertOriginCall() // the coins sent are only the caller's on a direct call
	withJob, msg := fundRefusal(unsafe.OriginSend())
	if msg == "" {
		msg = checkEvent(name, details, start, end, price, capacity, maxPerAddr, markupBps, noShowBps, time.Now().Unix())
	}
	if msg != "" {
		panic(msg)
	}

	e := &event{
		id: nextID, name: name, details: details, organiser: cur.Previous().Address(),
		start: start, end: end, price: price, capacity: capacity, maxPerAddr: maxPerAddr,
		markupBps: markupBps, noShowBps: noShowBps,
	}
	nextID++

	if withJob {
		// Post the job that settles the event at its end, and fund it with the
		// fee the organiser sent, in this same call.
		e.job = registry.Register(cross(cur), "Admit One: settle event "+utoa(e.id), end, 0, LampFee, settleJob)
		send(cur, chain.PackageAddress(registry.Path()), LampFee)
		registry.Credit(cross(cur), e.job, LampFee)
		byJob.Set(pad(e.job), e)
	}
	events.Set(pad(e.id), e)
	chain.Emit("EventCreated", "id", utoa(e.id), "organiser", e.organiser.String(),
		"start", itoa(start), "end", itoa(end), "price", itoa(price), "job", utoa(e.job))
	return e.id
}

// Buy sells the next ticket of an event to the caller, who sends exactly the
// price. The price stays here until the holder is admitted. Returns the
// ticket id.
func Buy(cur realm, eventID uint64) string {
	runtime.AssertOriginCall()
	e := mustEvent(eventID)
	mustPay(e.price)
	buyer := cur.Previous().Address()
	if msg := buyRefusal(e, buyer, time.Now().Unix()); msg != "" {
		panic(msg)
	}

	e.minted++
	e.live++
	t := &ticket{id: utoa(e.id) + "-" + strconv.Itoa(e.minted), ev: e, serial: e.minted}
	if err := ledger.Mint(buyer, grc721.TokenID(t.id)); err != nil {
		panic(err)
	}
	tickets.Set(ticketKey(e.id, t.serial), t)
	hold(e, buyer, t, +1)
	chain.Emit("TicketBought", "ticket", t.id, "buyer", buyer.String(), "price", itoa(e.price))
	return t.id
}

// List puts the caller's ticket on the event's resale desk. The price may be
// at most face value plus the event's markup; on a free event it must be 0.
func List(cur realm, ticketID string, price int64) {
	t, holder := mustHold(cur, ticketID)
	e := t.ev
	switch {
	case e.cancelled:
		panic("the event is cancelled")
	case time.Now().Unix() >= e.end:
		panic("the event is over")
	case t.admittedAt != 0:
		panic("an admitted ticket cannot be resold")
	case price < 0 || price > resaleCap(e):
		panic("list at 0 to " + itoa(resaleCap(e)) + " " + denom + ": face value plus at most " + bps(e.markupBps))
	}
	t.listed = true
	t.listPrice = price
	t.listedAt = time.Now().Unix()
	chain.Emit("TicketListed", "ticket", t.id, "seller", holder.String(), "price", itoa(price))
}

// Unlist takes the caller's ticket off the resale desk.
func Unlist(cur realm, ticketID string) {
	t, _ := mustHold(cur, ticketID)
	if !t.listed {
		panic("the ticket is not listed")
	}
	t.listed = false
	t.listPrice = 0
	t.listedAt = 0
	chain.Emit("TicketUnlisted", "ticket", t.id)
}

// BuyListed buys a ticket from the resale desk, once the listing has been up
// for ResaleDelay seconds. The caller sends exactly the listed price plus
// ResaleDeposit; both go straight to the seller. The face value stays in
// escrow with the ticket.
func BuyListed(cur realm, ticketID string) {
	runtime.AssertOriginCall()
	t := mustTicket(ticketID)
	e := t.ev
	buyer := cur.Previous().Address()
	if msg := buyListedRefusal(t, buyer, time.Now().Unix()); msg != "" {
		panic(msg)
	}
	mustPay(t.listPrice + ResaleDeposit)
	seller := ownerOf(t)

	price := t.listPrice
	t.listed = false
	t.listPrice = 0
	t.listedAt = 0
	if err := ledger.TransferFrom(seller, seller, buyer, grc721.TokenID(t.id)); err != nil {
		panic(err)
	}
	hold(e, seller, t, -1)
	hold(e, buyer, t, +1)
	send(cur, seller, price+ResaleDeposit)
	chain.Emit("TicketResold", "ticket", t.id, "seller", seller.String(), "buyer", buyer.String(), "price", itoa(price))
}

// Admit is the holder walking in. It works only while the event is on, and
// releases the ticket's price from escrow to the organiser. The ticket stays
// with the holder, marked admitted: whoever checks the door reads it on the
// ticket's page.
func Admit(cur realm, ticketID string) {
	t, holder := mustHold(cur, ticketID)
	e := t.ev
	now := time.Now().Unix()
	switch {
	case e.cancelled:
		panic("the event is cancelled")
	case now < e.start:
		panic("doors open at " + when(e.start))
	case now >= e.end:
		panic("the event is over")
	case t.admittedAt != 0:
		panic("already admitted")
	}
	t.admittedAt = now
	t.listed = false
	t.listPrice = 0
	t.listedAt = 0
	e.admitted++
	e.entered++
	if e.price > 0 {
		send(cur, e.organiser, e.price)
	}
	chain.Emit("TicketAdmitted", "ticket", t.id, "holder", holder.String())
}

// Cancel calls an event off before it starts. Every ticket becomes refundable
// in full, and the event's Lamplighter job, if any, is cancelled with its fee
// returned to the organiser. Only the organiser can cancel.
func Cancel(cur realm, eventID uint64) {
	e := mustEvent(eventID)
	if cur.Previous().Address() != e.organiser {
		panic("only the organiser can cancel the event")
	}
	if e.cancelled {
		panic("the event is already cancelled")
	}
	if time.Now().Unix() >= e.start {
		panic("an event that has started cannot be cancelled")
	}
	e.cancelled = true
	if e.job != 0 && !e.reclaimed {
		e.reclaimed = true
		byJob.Remove(pad(e.job))
		registry.Cancel(cross(cur), e.job, e.organiser)
	}
	chain.Emit("EventCancelled", "id", utoa(e.id))
}

// Settle pays the organiser the no-show fee of every ticket that was neither
// admitted nor refunded. Anyone can call it once the event is over; the
// event's Lamplighter job, if it has one, does the same.
func Settle(cur realm, eventID uint64) {
	e := mustEvent(eventID)
	mustSettle(e)
	settle(cur, e)
}

// settleJob is the callback the Lamplighter registry holds for every event
// that posted a job. The registry runs any callback for anyone, so the job id
// must be one this realm posted: it says which event to settle.
func settleJob(cur realm, job uint64) error {
	if cur.Previous().PkgPath() != registry.Path() {
		return errors.New("only the lamplighter registry runs this")
	}
	e, ok := byJob.Get(pad(job)).(*event)
	if !ok {
		return errors.New("not a job of this realm")
	}
	if e.settled {
		// Somebody called Settle first. Succeed anyway, so that the job
		// completes, its runner is paid, and it leaves the queue.
		return nil
	}
	if err := settleable(e); err != nil {
		return err
	}
	settle(cur, e)
	return nil
}

func settle(cur realm, e *event) {
	e.settled = true
	due := noShowFee(e) * int64(e.live-e.admitted)
	if due > 0 {
		send(cur, e.organiser, due)
	}
	chain.Emit("EventSettled", "id", utoa(e.id), "noShows", strconv.Itoa(e.live-e.admitted), "paid", itoa(due))
}

// Refund returns a ticket that was not used, and burns it: the full price if
// the event was cancelled, otherwise, once the event is over, the price minus
// the no-show fee. Burning the ticket also hands its storage deposit back to
// the holder.
func Refund(cur realm, ticketID string) {
	t, holder := mustHold(cur, ticketID)
	e := t.ev
	if t.admittedAt != 0 {
		panic("an admitted ticket has been used")
	}
	amount, feeNow := e.price, int64(0)
	if !e.cancelled {
		if time.Now().Unix() < e.end {
			panic("refunds open when the event is cancelled or over")
		}
		fee := noShowFee(e)
		amount -= fee
		if !e.settled {
			// Settle has not run, so this ticket's fee has not been paid yet.
			feeNow = fee
		}
	}

	e.live--
	hold(e, holder, t, -1)
	tickets.Remove(ticketKey(e.id, t.serial))
	if err := ledger.Burn(grc721.TokenID(t.id)); err != nil {
		panic(err)
	}
	if feeNow > 0 {
		send(cur, e.organiser, feeNow)
	}
	if amount > 0 {
		send(cur, holder, amount)
	}
	chain.Emit("TicketRefunded", "ticket", t.id, "holder", holder.String(), "amount", itoa(amount))
}

// Discard burns an admitted ticket once the event is over. The ticket is the
// holder's stamp of having been there; throwing it away hands back the storage
// deposit buying it locked. Nothing else changes: the money already went to the
// organiser at the door.
func Discard(cur realm, ticketID string) {
	t, holder := mustHold(cur, ticketID)
	e := t.ev
	if t.admittedAt == 0 {
		panic("only an admitted ticket can be discarded; refund an unused one")
	}
	if time.Now().Unix() < e.end {
		panic("keep it until the event is over")
	}
	e.live--
	e.admitted--
	hold(e, holder, t, -1)
	tickets.Remove(ticketKey(e.id, t.serial))
	if err := ledger.Burn(grc721.TokenID(t.id)); err != nil {
		panic(err)
	}
	chain.Emit("TicketDiscarded", "ticket", t.id, "holder", holder.String())
}

// Reclaim cancels the finished Lamplighter job of a settled event. Creating
// the event locked a storage deposit from the organiser for that job's state;
// freeing it hands the deposit back to whoever sends this, so only the
// organiser can.
func Reclaim(cur realm, eventID uint64) {
	e := mustEvent(eventID)
	if cur.Previous().Address() != e.organiser {
		panic("only the organiser can reclaim the job's deposit")
	}
	if e.job == 0 || e.reclaimed {
		panic("there is no job to reclaim")
	}
	if !e.settled {
		panic("the event is not settled yet")
	}
	e.reclaimed = true
	byJob.Remove(pad(e.job))
	registry.Cancel(cross(cur), e.job, e.organiser)
}

// ---- queries ---------------------------------------------------------------

// Token is a read-only view of the ticket ledger (GRC721).
func Token() grc721.Teller { return nft.ReadonlyTeller() }

// OwnerOf returns the holder of a ticket.
func OwnerOf(ticketID string) address { return ownerOf(mustTicket(ticketID)) }

// IsAdmitted reports whether a ticket has been used to get in.
func IsAdmitted(ticketID string) bool { return mustTicket(ticketID).admittedAt != 0 }

// Attended reports whether addr holds an admitted ticket for an event. Other
// realms can use it to gate something to the people who were there.
func Attended(eventID uint64, addr address) bool {
	found := false
	prefix := addr.String() + "/" + pad(eventID) + "-"
	byOwner.Iterate(prefix, prefix+"~", func(_ string, v any) bool {
		found = v.(*ticket).admittedAt != 0
		return found
	})
	return found
}

// Seats returns how many tickets of an event are held, how many were admitted
// at the door, and the capacity.
func Seats(eventID uint64) (held, entered, capacity int) {
	e := mustEvent(eventID)
	return e.live, e.entered, e.capacity
}

// InEscrow returns the ugnot this realm holds for an event's tickets.
func InEscrow(eventID uint64) int64 { return escrow(mustEvent(eventID)) }

// JobOf returns the Lamplighter job that settles an event, or 0.
func JobOf(eventID uint64) uint64 { return mustEvent(eventID).job }

// ---- helpers ---------------------------------------------------------------

func escrow(e *event) int64 {
	unused := int64(e.live - e.admitted)
	if e.settled {
		return unused * (e.price - noShowFee(e))
	}
	return unused * e.price
}

func noShowFee(e *event) int64 {
	if e.cancelled {
		return 0
	}
	return e.price * e.noShowBps / 10000
}

func resaleCap(e *event) int64 { return e.price + e.price*e.markupBps/10000 }

func settleable(e *event) error {
	switch {
	case e.cancelled:
		return errors.New("event " + utoa(e.id) + " was cancelled")
	case e.settled:
		return errors.New("event " + utoa(e.id) + " is already settled")
	case time.Now().Unix() < e.end:
		return errors.New("event " + utoa(e.id) + " is not over yet")
	}
	return nil
}

func mustSettle(e *event) {
	if err := settleable(e); err != nil {
		panic(err.Error())
	}
}

// mustPay checks that the call carries exactly amount ugnot and nothing else.
func mustPay(amount int64) {
	if msg := payRefusal(unsafe.OriginSend(), amount); msg != "" {
		panic(msg)
	}
}

// The refusals below are plain functions, so that tests can check each one
// without a direct call from a user, which the paying functions require.

func payRefusal(sent chain.Coins, amount int64) string {
	if amount == 0 {
		if len(sent) != 0 {
			return "send nothing: it is free"
		}
		return ""
	}
	if len(sent) != 1 || sent.AmountOf(denom) != amount {
		return "send exactly " + itoa(amount) + " " + denom
	}
	return ""
}

// fundRefusal reads what CreateEvent was sent: nothing, or the fee for a job.
func fundRefusal(sent chain.Coins) (withJob bool, msg string) {
	if len(sent) == 0 {
		return false, ""
	}
	if len(sent) == 1 && sent.AmountOf(denom) == LampFee {
		return true, ""
	}
	return false, "send nothing, or exactly " + itoa(LampFee) + " " + denom + " to have a Lamplighter job settle the event"
}

func checkEvent(name, details string, start, end, price int64, capacity, maxPerAddr int,
	markupBps, noShowBps, now int64) string {
	switch {
	case !validText(name, maxNameLen):
		return "name must be 1 to " + strconv.Itoa(maxNameLen) + " bytes of printable text"
	case details != "" && !validText(details, maxDetailsLen):
		return "details must be at most " + strconv.Itoa(maxDetailsLen) + " bytes of printable text"
	case start < now || start > now+MaxAhead:
		return "start must be between now and a year from now"
	case end-start < MinLength || end-start > MaxLength:
		return "an event lasts 1 minute to 90 days"
	case price < 0 || price > MaxPrice:
		return "price must be 0 to " + itoa(MaxPrice) + " " + denom
	case capacity < 1 || capacity > MaxCapacity:
		return "capacity must be 1 to " + strconv.Itoa(MaxCapacity)
	case maxPerAddr < 1 || maxPerAddr > capacity:
		return "maxPerAddr must be 1 to the capacity"
	case markupBps < 0 || markupBps > MaxMarkupBps:
		return "markupBps must be 0 to " + itoa(MaxMarkupBps)
	case noShowBps < 0 || noShowBps > MaxNoShowBps:
		return "noShowBps must be 0 to " + itoa(MaxNoShowBps)
	}
	return ""
}

func buyRefusal(e *event, buyer address, now int64) string {
	switch {
	case e.cancelled:
		return "the event is cancelled"
	case now >= e.end:
		return "the event is over"
	case e.live >= e.capacity:
		return "sold out"
	case held(e, buyer) >= e.maxPerAddr:
		return capMessage(e)
	}
	return ""
}

func buyListedRefusal(t *ticket, buyer address, now int64) string {
	e := t.ev
	switch {
	case !t.listed:
		return "the ticket is not for sale"
	case now < t.listedAt+ResaleDelay:
		return "the listing opens to buyers in " + itoa(t.listedAt+ResaleDelay-now) + "s"
	case buyer == ownerOf(t):
		return "this is already your ticket"
	case e.cancelled:
		return "the event is cancelled"
	case now >= e.end:
		return "the event is over"
	case held(e, buyer) >= e.maxPerAddr:
		return capMessage(e)
	}
	return ""
}

func capMessage(e *event) string {
	return "one address may hold at most " + strconv.Itoa(e.maxPerAddr) + " tickets for this event"
}

func send(cur realm, to address, amount int64) {
	// Paying an account runs no code, so this cannot call back in here.
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), to, chain.Coins{{denom, amount}})
}

// held counts the tickets of an event that addr holds. It walks at most
// maxPerAddr+1 entries of the holder index, which is cheaper than storing a
// counter: every stored tree node is storage someone pays a deposit for.
func held(e *event, addr address) int {
	n := 0
	prefix := addr.String() + "/" + pad(e.id) + "-"
	byOwner.Iterate(prefix, prefix+"~", func(_ string, _ any) bool {
		n++
		return n > e.maxPerAddr
	})
	return n
}

// hold records that addr gained (+1) or lost (-1) ticket t.
func hold(e *event, addr address, t *ticket, delta int) {
	k := addr.String() + "/" + ticketKey(e.id, t.serial)
	if delta > 0 {
		byOwner.Set(k, t)
	} else {
		byOwner.Remove(k)
	}
}

func ownerOf(t *ticket) address {
	owner, err := ledger.ReadToken().OwnerOf(grc721.TokenID(t.id))
	if err != nil {
		panic(err)
	}
	return owner
}

// mustHold returns the ticket and its holder, who must be the caller.
func mustHold(cur realm, ticketID string) (*ticket, address) {
	t := mustTicket(ticketID)
	holder := ownerOf(t)
	if cur.Previous().Address() != holder {
		panic("only the holder can do this")
	}
	return t, holder
}

func mustEvent(id uint64) *event {
	e, ok := events.Get(pad(id)).(*event)
	if !ok {
		panic("unknown event " + utoa(id))
	}
	return e
}

func mustTicket(id string) *ticket {
	k, ok := keyOf(id)
	if ok {
		if t, found := tickets.Get(k).(*ticket); found {
			return t
		}
	}
	panic("unknown ticket " + strconv.Quote(id))
}

// keyOf turns a ticket id such as "3-17" into its sorted tree key.
func keyOf(id string) (string, bool) {
	ev, serial, found := strings.Cut(id, "-")
	if !found {
		return "", false
	}
	e, err1 := strconv.ParseUint(ev, 10, 64)
	s, err2 := strconv.Atoi(serial)
	if err1 != nil || err2 != nil || s < 1 {
		return "", false
	}
	return ticketKey(e, s), true
}

func ticketKey(eventID uint64, serial int) string {
	s := strconv.Itoa(serial)
	for len(s) < 5 {
		s = "0" + s
	}
	return pad(eventID) + "-" + s
}

// validText reports whether s is 1 to max bytes of valid, printable text that
// is not blank once invisible characters are stripped (the registry's rule).
func validText(s string, max int) bool {
	if s == "" || len(s) > max || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) {
			return false
		}
	}
	return strings.TrimSpace(sanitize.StripBidiAndZeroWidth(s)) != ""
}

func pad(id uint64) string {
	s := utoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func when(t int64) string { return time.Unix(t, 0).UTC().Format("2006-01-02 15:04 UTC") }

// bps formats hundredths of a percent: 250 -> "2.5%", 5000 -> "50%".
func bps(b int64) string {
	s := itoa(b / 100)
	if r := b % 100; r != 0 {
		frac := strconv.FormatInt(r+100, 10)[1:]
		s += "." + strings.TrimRight(frac, "0")
	}
	return s + "%"
}

func utoa(n uint64) string { return strconv.FormatUint(n, 10) }
func itoa(n int64) string  { return strconv.FormatInt(n, 10) }
