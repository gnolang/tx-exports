// Package tickets is GnoRadio's concert tickets rules, release 1. Concerts
// belong to artist profiles of the catalog; a ticket is a GRC721 NFT of the
// permanent realm gno.land/r/nym-alexiscolin000/gnoradio/tickets/nft, drawn on-chain. Ticket
// money goes straight to the artist's owner address in the same transaction,
// the service fee to the GnoRadio treasury: this realm ends every
// transaction holding no coins.
//
// It keeps no state but its admin role. Every record lives in the data realm,
// in the "tickets/…" collections only the current tickets writer may change
// (db.gno), and the NFTs in the NFT realm, which only that writer drives: a
// later release takes over both without copying anything.
package tickets

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/safe/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	catalog "gno.land/r/nym-alexiscolin000/gnoradio/catalog/v2"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
	"gno.land/r/nym-alexiscolin000/gnoradio/tickets/nft"
)

const (
	denom          = "ugnot"
	ugnot          = 1_000_000
	minPrice       = 100_000 // 0.1 GNOT
	maxTicketPrice = 10_000 * ugnot
	maxCapacity    = 10000
	maxPerBuyer    = 4
	maxPerArtist   = 500       // concerts ever created
	maxOpenAhead   = 10        // future, not cancelled concerts per artist
	checkInWindow  = 12 * 3600 // check-in opens 12h before the concert
	checkInClose   = 12 * 3600 // and closes 12h after its start
	presentFor     = 10 * 60   // a Present admits its ticket for 10 minutes
	maxServiceFee  = 10 * ugnot
	maxOwned       = 1000 // tickets one wallet holds
	maxGifted      = 500  // a wallet takes gifts while it holds fewer: gifts never block buying
	maxScan        = 1000 // upcoming index entries one read walks
	nftPath        = "gno.land/r/nym-alexiscolin000/gnoradio/tickets/nft"
)

// Event is a concert.
type Event struct {
	ID        int
	ArtistID  int
	Title     string
	Venue     string
	Link      string // optional https link, public
	Start     int64
	Price     int64 // ugnot, 0 = free
	Capacity  int
	Sold      int
	Cancelled bool
	Hidden    bool
	Removed   string // the moderator's reason while hidden
}

// Ticket is one NFT ticket.
type Ticket struct {
	ID       int
	Event    int
	Serial   int
	Attended bool
}

var (
	self  string     // this realm's path
	admin *role.Role // the moderator; nil when a release before renounced it
)

// init takes the admin over from the previous release (tickets/config
// "admin"), or names the deployer. While this realm is the tickets writer
// (release 1 at deploy) it also makes the collections.
func init(cur realm) {
	self = cur.PkgPath()
	holder, mirrored := data.Get(cConfig, "admin")
	if !mirrored {
		deployer := unsafe.OriginCaller()
		if deployer == "" && runtime.ChainID() == "dev" {
			deployer = chain.PackageAddress(self + "/dev") // gno test: a key nobody holds
		}
		holder = deployer.String()
	}
	if holder != "" {
		admin = role.New("admin", address(holder))
	}
	if data.Writer("tickets") == self {
		setup(cur, address(holder))
	}
}

// ---- concerts ----

// CreateEvent announces a concert by the caller's artist profile.
// start is "YYYY-MM-DD HH:MM" in UTC; price is in GNOT ("0" for free, "2.5");
// link is an optional https URL (stream or venue page, public).
func CreateEvent(cur realm, title, venue, link, start, price string, capacity int) int {
	caller := userCaller(cur)
	noPayment()
	artistID := mustArtistOf(caller)
	p := store.Pad(artistID)
	if count(cByArtist, p+"/", p+"0") >= maxPerArtist {
		panic("tickets: concert limit reached for this artist")
	}
	if count(cAhead, p+"/"+store.TimeKey(now()+1), p+"0") >= maxOpenAhead {
		panic("tickets: an artist can announce " + text.Itoa(maxOpenAhead) + " upcoming concerts at a time")
	}
	title, venue, link = strings.TrimSpace(title), strings.TrimSpace(venue), strings.TrimSpace(link)
	mustText("title", title, 2, 48)
	mustText("venue", venue, 2, 48)
	if link != "" && !text.HTTPS(link, 200) {
		panic("tickets: link must start with https:// (max 200 chars, no spaces)")
	}
	when, err := time.Parse("2006-01-02 15:04", strings.TrimSpace(start))
	if err != nil {
		panic("tickets: start must look like 2026-11-20 21:00 (UTC)")
	}
	if when.Unix() <= now() {
		panic("tickets: the concert must be in the future")
	}
	pr, ok := parseGNOT(price)
	if !ok || pr > maxTicketPrice || (pr > 0 && pr < minPrice) {
		panic("tickets: price must be 0 (free) or between 0.1 and 10000 GNOT")
	}
	if capacity < 1 || capacity > maxCapacity {
		panic("tickets: capacity must be between 1 and 10000")
	}
	m := meta()
	e := &Event{ID: metaCount(m, mEvents) + 1, ArtistID: artistID, Title: title, Venue: venue, Link: link,
		Start: when.Unix(), Price: pr, Capacity: capacity}
	save(cur, store.Ops{}.Set(cEvents, store.Pad(e.ID), record(e)).Set(cByArtist, p+"/"+store.Pad(e.ID), "").
		Set(cUpcoming, upKey(e), "").Set(cAhead, aheadKey(e), "").Set(cMeta, "n", store.With(m, mEvents, text.Itoa(e.ID))))
	chain.Emit("EventCreated", "id", text.Itoa(e.ID), "artist", text.Itoa(artistID), "start", text.Itoa64(e.Start), "price", text.Itoa64(pr))
	return e.ID
}

// CancelEvent stops ticket sales. GnoRadio never held the payments: they
// went straight to the artist, who handles refunds directly. Artist owner
// only.
func CancelEvent(cur realm, eventID int) {
	caller := userCaller(cur)
	noPayment()
	e := mustEvent(eventID)
	if catalog.ArtistOwner(e.ArtistID) != caller {
		panic("tickets: only the artist can cancel this concert")
	}
	e.Cancelled = true
	save(cur, store.Ops{}.Set(cEvents, store.Pad(e.ID), record(e)).Del(cUpcoming, upKey(e)).Del(cAhead, aheadKey(e)))
	chain.Emit("EventCancelled", "id", text.Itoa(e.ID))
}

// BuyTicket mints a ticket to the caller. A paid ticket needs the exact
// price plus the service fee attached: the price goes straight to the
// artist, the fee to the GnoRadio treasury.
func BuyTicket(cur realm, eventID int) int {
	caller := userCaller(cur)
	e := getEvent(eventID)
	if e == nil || e.Hidden {
		panic("tickets: unknown concert")
	}
	owner, verified, shown := catalog.ArtistPayee(e.ArtistID) // mustEvent's check and the payee, one read
	if !shown {
		panic("tickets: unknown concert")
	}
	if e.Cancelled {
		panic("tickets: this concert is cancelled")
	}
	if now() >= e.Start {
		panic("tickets: ticket sales are closed")
	}
	if e.Sold >= e.Capacity {
		panic("tickets: sold out")
	}
	if e.Price > 0 && (owner == "" || !verified) {
		panic("tickets: this artist has not verified their profile yet")
	}
	buyKey := store.Pad(e.ID) + "/" + caller.String()
	bought := text.Atoi(get(cBuyers, buyKey))
	if bought >= maxPerBuyer || (e.Price == 0 && bought >= 1) {
		panic("tickets: ticket limit reached for this concert (1 free or 4 paid per wallet)")
	}
	fee, to := int64(0), address("")
	if e.Price == 0 {
		noPayment()
	} else {
		if fee = serviceFee(); fee > 0 {
			to = catalog.Treasury() // serviceFee is 0 while none is set
		}
		if paid() != e.Price+fee {
			panic("tickets: attach exactly " + text.GNOT(e.Price+fee))
		}
	}

	m := meta()
	tk := &Ticket{ID: metaCount(m, mTickets) + 1, Event: e.ID, Serial: e.Sold + 1}
	k, i := store.Slot(tk.ID, nft.Chunk)
	ch := store.Rec(ticketRecord(tk))
	if i > 0 {
		ch = store.Append(get(cTickets, k), ticketRecord(tk))
	}
	e.Sold = tk.Serial
	ops := store.Ops{}.Set(cEvents, store.Pad(e.ID), record(e)).
		Set(cBuyers, buyKey, text.Itoa(bought+1)).Set(cMeta, "n", store.With(m, mTickets, text.Itoa(tk.ID))).Set(cTickets, k, ch)
	save(cur, own(ops, caller, tk.ID, true))
	nft.Mint(cross(cur), caller, tk.ID)
	if e.Price > 0 {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(cur.Address(), owner, chain.Coins{{Denom: denom, Amount: e.Price}})
		if fee > 0 {
			bk.SendCoins(cur.Address(), to, chain.Coins{{Denom: denom, Amount: fee}})
		}
	}
	chain.Emit("TicketBought", "event", text.Itoa(e.ID), "ticket", text.Itoa(tk.ID), "by", caller.String(), "price", text.Itoa64(e.Price), "fee", text.Itoa64(fee))
	return tk.ID
}

// TransferTicket gives one of the caller's tickets to someone else. There is
// no built-in resale market.
func TransferTicket(cur realm, to address, ticketID int) {
	caller := userCaller(cur)
	noPayment()
	tk := mustTicket(ticketID)
	if tk.Attended {
		panic("tickets: a checked-in ticket can no longer be gifted")
	}
	if !role.Canonical(to) || to == caller || data.IsGnoRadio(to) || to == cur.Address() {
		panic("tickets: invalid recipient")
	}
	if nft.Holder(ticketID) != caller {
		panic("tickets: you do not hold this ticket")
	}
	if store.Count(get(cOwned, to.String())) >= maxGifted {
		panic("tickets: this wallet holds " + text.Itoa(maxGifted) + " tickets and takes no more gifts")
	}
	save(cur, own(own(nil, caller, ticketID, false), to, ticketID, true))
	nft.Transfer(cross(cur), caller, to, ticketID)
	chain.Emit("TicketGifted", "ticket", text.Itoa(ticketID), "from", caller.String(), "to", to.String())
}

// Present shows a ticket at the door: its holder signs from their own
// wallet, with the door code the staff's screen shows after scanning the
// ticket's QR. A QR built from public data (the ticket id and its holder)
// cannot do that for them, and a stranger with a copied QR gets another
// code: the holder's Present does not admit them. CheckIn then admits the
// ticket with that code for 10 minutes. Only while the door is open: from
// 12h before the concert to 12h after its start.
func Present(cur realm, ticketID int, code string) {
	caller := userCaller(cur)
	noPayment()
	mustDoorCode(code)
	tk := mustTicket(ticketID)
	e := mustEvent(tk.Event)
	if nft.Holder(ticketID) != caller {
		panic("tickets: you do not hold this ticket")
	}
	mustDoorOpen(e, tk)
	data.Set(cross(cur), cPresent, store.Pad(ticketID), store.Rec(caller.String(), text.Itoa64(now()), code))
	chain.Emit("TicketPresented", "ticket", text.Itoa(ticketID), "holder", caller.String())
}

// CheckIn marks a ticket as used at the door; its holder earns the
// "I was there" stamp. The concert's artist owner only, while the door is
// open, and only for a ticket its current holder presented (Present) with
// this door code in the last 10 minutes.
func CheckIn(cur realm, ticketID int, code string) {
	caller := userCaller(cur)
	noPayment()
	mustDoorCode(code)
	tk := mustTicket(ticketID)
	e := mustEvent(tk.Event)
	if catalog.ArtistOwner(e.ArtistID) != caller {
		panic("tickets: only the concert's artist can check tickets in")
	}
	mustDoorOpen(e, tk)
	if at := PresentedAt(ticketID, code); at == 0 || now()-at > presentFor {
		panic("tickets: the holder must present this ticket from their wallet with this door code first (it counts for 10 minutes)")
	}
	tk.Attended = true
	k, i := store.Slot(tk.ID, nft.Chunk)
	holder := nft.Holder(ticketID)
	save(cur, store.Ops{}.Set(cTickets, k, store.With(get(cTickets, k), i, ticketRecord(tk))).
		Set(cAttended, holder.String(), text.Itoa(Attended(holder)+1)).Del(cPresent, store.Pad(ticketID)))
	chain.Emit("CheckedIn", "ticket", text.Itoa(ticketID), "holder", holder.String())
}

// mustDoorCode refuses a door code that is not 4 to 8 digits.
func mustDoorCode(code string) {
	if len(code) < 4 || len(code) > 8 {
		panic("tickets: the door code is 4 to 8 digits")
	}
	for i := 0; i < len(code); i++ {
		if code[i] < '0' || code[i] > '9' {
			panic("tickets: the door code is 4 to 8 digits")
		}
	}
}

// mustDoorOpen refuses a ticket the door cannot take now.
func mustDoorOpen(e *Event, tk *Ticket) {
	if e.Cancelled {
		panic("tickets: this concert is cancelled")
	}
	if tk.Attended {
		panic("tickets: ticket already checked in")
	}
	switch t := now(); {
	case t < e.Start-checkInWindow:
		panic("tickets: check-in opens 12h before the concert")
	case t > e.Start+checkInClose:
		panic("tickets: this concert is over, check-in is closed")
	}
}

// ---- moderation ----

// HideEvent hides or restores a concert. Admin only; hiding takes a public
// reason (4-200 characters). Tickets stay with their holders.
func HideEvent(cur realm, eventID int, hidden bool, reason string) {
	onlyAdmin(cur)
	e := getEvent(eventID)
	if e == nil {
		panic("tickets: unknown concert")
	}
	reason = strings.TrimSpace(reason)
	if hidden {
		mustText("reason", reason, 4, 200)
	} else {
		reason = ""
	}
	e.Hidden, e.Removed = hidden, reason
	ops := store.Ops{}.Set(cEvents, store.Pad(e.ID), record(e))
	if visible(e) && !e.Cancelled && e.Start > now() {
		ops = ops.Set(cUpcoming, upKey(e), "")
	} else {
		ops = ops.Del(cUpcoming, upKey(e))
	}
	save(cur, ops)
	chain.Emit("Moderated", "kind", "event", "target", text.Itoa(eventID), "hidden", strconv.FormatBool(hidden), "reason", reason, "by", "moderator")
}

// RefreshArtist re-reads an artist's visibility in the catalog and updates
// the Upcoming index for its future concerts (at most maxOpenAhead): once
// moderators hide a profile, its concerts stop taking places in the
// Upcoming scan; a restored artist's come back. Anyone may call it.
func RefreshArtist(cur realm, artistID int) {
	noPayment()
	p := store.Pad(artistID) + "/"
	keys, _ := store.Rows(data.Page(cAhead, p+store.TimeKey(now()+1), p+"~", maxOpenAhead, false))
	reindex(cur, artistID, keys)
}

// RefreshArtistPast does the same for up to 50 of an artist's past concerts
// from offset (oldest first; the 500 an artist may have take ten calls), so
// a hidden profile's past concerts leave the past-concerts index too.
// Anyone may call it.
func RefreshArtistPast(cur realm, artistID, offset int) {
	noPayment()
	p := store.Pad(artistID) + "/"
	lo, hi := data.Index(cAhead, p), data.Index(cAhead, p+store.TimeKey(now()+1))
	if offset < 0 || lo+offset >= hi {
		panic("tickets: no past concert of this artist there")
	}
	n := hi - lo - offset
	if n > 50 {
		n = 50
	}
	keys, _ := store.Rows(data.PageAt(cAhead, lo+offset, n, false))
	reindex(cur, artistID, keys)
}

// reindex re-files an artist's concerts (their cAhead keys) in the Upcoming
// index by visibility.
func reindex(cur realm, artistID int, keys []string) {
	var ops store.Ops
	for _, k := range keys {
		e := getEvent(idOf(k))
		if visible(e) && !e.Cancelled {
			ops = ops.Set(cUpcoming, upKey(e), "")
		} else {
			ops = ops.Del(cUpcoming, upKey(e))
		}
	}
	save(cur, ops)
	chain.Emit("ArtistRefreshed", "artist", text.Itoa(artistID), "concerts", text.Itoa(len(keys)))
}

// SetServiceFee sets the per-ticket service fee in ugnot (0..10 GNOT), paid
// by buyers of paid tickets on top of the price and forwarded to the GnoRadio
// treasury. Admin only.
func SetServiceFee(cur realm, ugnot int64) {
	onlyAdmin(cur)
	if ugnot < 0 || ugnot > maxServiceFee {
		panic("tickets: service fee must be between 0 and 10 GNOT")
	}
	data.Set(cross(cur), cConfig, "fee", text.Itoa64(ugnot))
	chain.Emit("ServiceFee", "ugnot", text.Itoa64(ugnot))
}

// ---- release and admin ----

// Ready tells the data realm that this release is on chain (see
// data.Propose). Anyone may call it.
func Ready(cur realm) {
	noPayment()
	data.Ready(cross(cur))
}

// OfferAdmin offers the admin role to an address (offering it to the admin
// cancels the offer); AcceptAdmin takes it. Each change is mirrored to the
// data realm, so the next release keeps the admin.
func OfferAdmin(cur realm, to address) {
	onlyAdmin(cur)
	admin.Offer(0, cur, to)
}

func AcceptAdmin(cur realm) {
	noPayment()
	syncAdmin()
	if admin == nil {
		panic("tickets: nothing offered to you")
	}
	admin.Accept(0, cur)
	data.Set(cross(cur), cConfig, "admin", admin.Holder().String())
}

// RenounceAdmin gives the admin role up for good, for this release and the
// next ones.
func RenounceAdmin(cur realm) {
	onlyAdmin(cur)
	admin.Renounce(0, cur)
	data.Set(cross(cur), cConfig, "admin", "")
}

// Render points gnoweb visitors to the GnoRadio site; a retired release says
// which realm took over.
func Render(_ string) string {
	home := strings.TrimPrefix(data.Writer("home"), "gno.land") // the home of the release in force
	out := "# GnoRadio · tickets\n\nThis contract holds GnoRadio's ticket rules; the tickets are NFTs of [" +
		strings.TrimPrefix(nftPath, "gno.land") + "](" + strings.TrimPrefix(nftPath, "gno.land") +
		"). The site lives at [" + home + "](" + home + ").\n"
	if w := data.Writer("tickets"); w != self {
		out += "\nThis release is retired: the tickets rules are now `" + w + "`.\n"
	}
	return out
}

// ---- helpers ----

func now() int64 { return time.Now().Unix() }

func userCaller(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("tickets: call this directly from your wallet")
	}
	return cur.Previous().Address()
}

// adminAddr is the admin: the data realm's mirror is the authority, so a
// change the previous release made after this one was deployed counts.
func adminAddr() address {
	h, ok := data.Get(cConfig, "admin")
	return role.Mirror(admin, h, ok)
}

// syncAdmin adopts the mirror when the previous release changed it after
// this one's init (during the release's delay).
func syncAdmin() {
	h, ok := data.Get(cConfig, "admin")
	admin = role.Adopt(admin, "admin", h, ok)
}

func onlyAdmin(cur realm) {
	syncAdmin()
	if admin == nil || !admin.Is(0, cur) {
		panic("tickets: admin only")
	}
	noPayment()
}

func noPayment() {
	if len(unsafe.OriginSend()) != 0 {
		panic("tickets: this action takes no coins")
	}
}

// paid returns the ugnot attached to the call; anything else is refused.
func paid() int64 {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount <= 0 {
		panic("tickets: attach a single ugnot amount")
	}
	return sent[0].Amount
}

// serviceFee is the stored fee, 0 while no treasury is set: the fee has nowhere to go, so buyers never pay it.
func serviceFee() int64 {
	if v := get(cConfig, "fee"); v != "" && catalog.Treasury().IsValid() {
		return text.MustAtoi64(v)
	}
	return 0
}

func mustArtistOf(addr address) int {
	id := catalog.ArtistOf(addr)
	if id == 0 || !catalog.ArtistVisible(id) {
		panic("tickets: create your artist profile first")
	}
	return id
}

func mustText(field, s string, min, max int) {
	if !text.Valid(s, min, max) {
		panic("tickets: " + field + " must be " + text.Itoa(min) + "-" + text.Itoa(max) +
			" characters (letters, digits, spaces and . , ' - ! ? : / &)")
	}
	if safe.Slur(s) {
		panic("tickets: " + field + " holds a slur")
	}
}

// parseGNOT parses a decimal GNOT amount ("10", "2.5") into ugnot.
func parseGNOT(s string) (int64, bool) {
	s = strings.TrimSpace(s)
	whole, frac, _ := strings.Cut(s, ".")
	if whole == "" || len(whole) > 9 || len(frac) > 6 || !text.Digits(whole) || (frac != "" && !text.Digits(frac)) {
		return 0, false
	}
	w, _ := strconv.ParseInt(whole, 10, 64)
	f, _ := strconv.ParseInt(frac+"000000"[len(frac):], 10, 64)
	return w*ugnot + f, true
}
