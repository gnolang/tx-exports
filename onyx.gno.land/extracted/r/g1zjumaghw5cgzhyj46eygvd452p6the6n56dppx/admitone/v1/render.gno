package admitone

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
)

const (
	perPage      = 20  // events per home page, newest first
	shownTickets = 100 // tickets on an event's door list
	shownListed  = 50  // listings on an event's resale desk
	shownHeld    = 200 // tickets on a holder's page

	// depositNote says what buying adds on top of the price. The deposit is the
	// chain's, not the organiser's: it comes back when the ticket is burned.
	depositNote = "plus a storage deposit of about 0.6 GNOT, which comes back when you refund or discard the ticket"
)

// Render serves the realm's pages:
//
//	""              the newest events
//	"page/<n>"      older events, 20 a page
//	"event/<id>"    one event: seats, risks, buying, the resale desk, the door list
//	"ticket/<id>"   one ticket, drawn, with what its holder can do
//	"u/<address>"   the tickets an address holds
func Render(path string) string {
	switch {
	case path == "":
		return renderHome(1)
	case strings.HasPrefix(path, "page/"):
		if n, err := strconv.Atoi(strings.TrimPrefix(path, "page/")); err == nil && n >= 1 {
			return renderHome(n)
		}
	case strings.HasPrefix(path, "event/"):
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "event/"), 10, 64)
		if e, ok := events.Get(pad(id)).(*event); err == nil && ok {
			return renderEvent(e)
		}
	case strings.HasPrefix(path, "ticket/"):
		if k, ok := keyOf(strings.TrimPrefix(path, "ticket/")); ok {
			if t, found := tickets.Get(k).(*ticket); found {
				return renderTicket(t)
			}
		}
		return "# Ticket not found\n\nIt was never sold, or it was refunded and burned.\n\n[All events](" + home() + ")\n"
	case strings.HasPrefix(path, "u/"):
		return renderHolder(strings.TrimPrefix(path, "u/"))
	}
	return "# Not found\n\n[All events](" + home() + ")\n"
}

func renderHome(page int) string {
	now := time.Now().Unix()
	var b strings.Builder
	b.WriteString("# Admit One\n\n")
	b.WriteString("**Event tickets that pay at the door.**\n\n")
	b.WriteString("- Your ticket's price waits in this realm until you walk in. Admitting yourself at the door is what pays the organiser.\n")
	b.WriteString("- If the event is cancelled, you get everything back. If you never show up, you get it back minus a no-show fee the event states up front.\n")
	b.WriteString("- Tickets cannot be passed around privately. If you cannot go, put yours on the resale desk at no more than the capped price, and the first buyer takes it.\n\n")

	start := now + 3600
	b.WriteString("[Create an event](" + txlink.NewLink("CreateEvent").AddArgs(
		"name", "", "details", "",
		"start", itoa(start), "end", itoa(start+3*3600),
		"price", "1000000", "capacity", "20", "maxPerAddr", "2",
		"markupBps", "1000", "noShowBps", "2000").URL() + ")")
	b.WriteString(" · times are unix seconds (now: " + itoa(now) + "); attach " + gnot(LampFee) +
		" to have a [Lamplighter](" + strings.TrimPrefix(registry.Path(), "gno.land") + ") job settle it when it ends.\n\n")

	total := events.Size()
	if total == 0 {
		b.WriteString("No events yet.\n")
		return b.String()
	}
	offset := (page - 1) * perPage
	if offset >= total {
		b.WriteString("No events on page " + strconv.Itoa(page) + ". [Newest events](" + home() + ")\n")
		return b.String()
	}
	b.WriteString("## Events\n\n| # | Event | When | Price | Seats | |\n|---|---|---|---|---|---|\n")
	events.ReverseIterateByOffset(offset, perPage, func(_ string, v any) bool {
		e := v.(*event)
		b.WriteString("| " + utoa(e.id) + " | [" + sanitize.TableCell(e.name) + "](" + eventURL(e) + ") | " +
			when(e.start) + " | " + priceLabel(e.price) + " | " + strconv.Itoa(e.live) + " / " +
			strconv.Itoa(e.capacity) + " | " + status(e, now) + " |\n")
		return false
	})
	var nav []string
	if page > 1 {
		nav = append(nav, "[newer]("+pageURL(page-1)+")")
	}
	if offset+perPage < total {
		nav = append(nav, "[older]("+pageURL(page+1)+")")
	}
	if len(nav) > 0 {
		b.WriteString("\nPage " + strconv.Itoa(page) + " · " + strings.Join(nav, " · ") + "\n")
	}
	return b.String()
}

func renderEvent(e *event) string {
	now := time.Now().Unix()
	id := utoa(e.id)
	var b strings.Builder
	b.WriteString("# " + sanitize.InlineText(e.name) + "\n\n")
	if e.details != "" {
		b.WriteString(sanitize.InlineText(e.details) + "\n\n")
	}
	b.WriteString("**" + status(e, now) + "** · " + when(e.start) + " to " + when(e.end) + "\n\n")

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Price | " + priceLabel(e.price) + " |\n")
	b.WriteString("| Seats | " + strconv.Itoa(e.live) + " held of " + strconv.Itoa(e.capacity) +
		", at most " + strconv.Itoa(e.maxPerAddr) + " per address |\n")
	b.WriteString("| At the door | " + strconv.Itoa(e.entered) + " admitted |\n")
	if e.price > 0 && !e.cancelled {
		b.WriteString("| No-show fee | " + bps(e.noShowBps) + " (" + gnot(noShowFee(e)) + ") |\n")
		b.WriteString("| Resale | up to " + gnot(resaleCap(e)) + " (face + " + bps(e.markupBps) + ") |\n")
	}
	if e.price > 0 {
		b.WriteString("| In escrow | " + gnot(escrow(e)) + " |\n")
	}
	b.WriteString("| Organiser | " + e.organiser.String() + " |\n")
	if e.job != 0 {
		b.WriteString("| Settled by | [Lamplighter job " + utoa(e.job) + "](" +
			strings.TrimPrefix(registry.Path(), "gno.land") + ":job/" + utoa(e.job) + ") at the end |\n")
	}
	b.WriteString("\n")

	if e.price > 0 && !e.cancelled {
		b.WriteString("> **What a ticket risks.** The organiser cannot touch the money held for unused tickets. " +
			"If the event is cancelled, a ticket is refunded in full. If its holder never comes, they get " +
			gnot(e.price-noShowFee(e)) + " back once the event is over. If the event simply never happens and is not " +
			"cancelled, that is also what a holder gets back: the no-show fee is the only amount a buyer trusts the organiser with.\n\n")
	}

	// What can be done now.
	open := !e.cancelled && now < e.end
	switch {
	case e.cancelled:
		b.WriteString("This event was cancelled. Holders: open your ticket and refund it in full.\n\n")
	case open && e.live < e.capacity:
		link := txlink.NewLink("Buy").AddArgs("eventID", id)
		if e.price > 0 {
			link = link.SetSend(itoa(e.price) + denom)
		}
		b.WriteString("[**Buy a ticket for " + priceLabel(e.price) + "**](" + link.URL() + ") (" + depositNote + ")\n\n")
	case open:
		b.WriteString("Sold out. Watch the resale desk below.\n\n")
	case !e.settled:
		b.WriteString("The event is over. [Settle it](" + txlink.NewLink("Settle").AddArgs("eventID", id).URL() +
			"): anyone can, and it pays the organiser the no-show fees. Holders who did not come can then refund their tickets.\n\n")
	default:
		b.WriteString("The event is over and settled. Holders who did not come can refund what is left of their ticket.\n\n")
	}

	var desk, door strings.Builder
	n, listed := 0, 0
	prefix := pad(e.id) + "-"
	tickets.Iterate(prefix, prefix+"~", func(_ string, v any) bool {
		t := v.(*ticket)
		if open && t.listed {
			if listed < shownListed {
				desk.WriteString("| [" + t.id + "](" + ticketURL(t) + ") | " + priceLabel(t.listPrice) + " | " + deskAction(t, now) + " |\n")
			}
			listed++
		}
		if n < shownTickets {
			door.WriteString("| [" + t.id + "](" + ticketURL(t) + ") | " + short(ownerOf(t)) + " | " + ticketState(t, now) + " |\n")
		}
		n++
		return false
	})
	if listed > 0 {
		b.WriteString("## Resale desk\n\nA listing opens to buyers " + itoa(ResaleDelay) + " seconds after it is posted; then the first buyer takes it. " +
			"A buyer pays the listed price plus " + gnot(ResaleDeposit) + " to the seller, for the storage deposit the ticket carries, " +
			"which comes back to the buyer when the ticket is refunded or discarded.\n\n")
		b.WriteString("| Ticket | Price | |\n|---|---|---|\n" + desk.String())
		if listed > shownListed {
			b.WriteString("\n" + strconv.Itoa(listed-shownListed) + " more listings not shown.\n")
		}
		b.WriteString("\n")
	}
	if door.Len() > 0 {
		b.WriteString("## Door list\n\n| Ticket | Holder | |\n|---|---|---|\n" + door.String())
		if n > shownTickets {
			b.WriteString("\n" + strconv.Itoa(n-shownTickets) + " more not shown.\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("[All events](" + home() + ")")
	if !e.cancelled && now < e.start {
		b.WriteString(" · organiser: [cancel the event](" + txlink.NewLink("Cancel").AddArgs("eventID", id).URL() + ")")
	}
	if e.job != 0 && e.settled && !e.reclaimed {
		b.WriteString(" · organiser: [reclaim the job's deposit](" + txlink.NewLink("Reclaim").AddArgs("eventID", id).URL() + ")")
	}
	b.WriteString("\n")
	return b.String()
}

// deskAction is the resale desk's action cell for a listing.
func deskAction(t *ticket, now int64) string {
	if wait := t.listedAt + ResaleDelay - now; wait > 0 {
		return "opens in " + itoa(wait) + "s"
	}
	return "[Buy for " + gnot(t.listPrice+ResaleDeposit) + "](" + buyListedURL(t) + ")"
}

func renderTicket(t *ticket) string {
	e := t.ev
	now := time.Now().Unix()
	holder := ownerOf(t)
	var b strings.Builder
	b.WriteString("# Ticket " + t.id + "\n\n")
	b.WriteString(ticketSVG(t, now) + "\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Event | [" + sanitize.TableCell(e.name) + "](" + eventURL(e) + ") |\n")
	b.WriteString("| When | " + when(e.start) + " to " + when(e.end) + " |\n")
	b.WriteString("| Holder | [" + holder.String() + "](" + home() + ":u/" + holder.String() + ") |\n")
	b.WriteString("| State | **" + ticketState(t, now) + "** |\n")
	b.WriteString("| Face value | " + priceLabel(e.price) + " |\n\n")

	b.WriteString("For the holder:\n\n")
	var acts []string
	refund := txlink.NewLink("Refund").AddArgs("ticketID", t.id).URL()
	switch {
	case e.cancelled:
		acts = append(acts, "["+refundLabel(e.price)+"]("+refund+")")
	case t.admittedAt != 0 && now >= e.end:
		acts = append(acts, "keep it as your stamp of having been there, or [discard it]("+
			txlink.NewLink("Discard").AddArgs("ticketID", t.id).URL()+") to take back the storage deposit it locked")
	case t.admittedAt != 0:
		acts = append(acts, "nothing left to do: enjoy the event")
	case now >= e.end:
		acts = append(acts, "["+refundLabel(e.price-noShowFee(e))+"]("+refund+")")
	default:
		if now >= e.start {
			acts = append(acts, "[**Admit me**]("+txlink.NewLink("Admit").AddArgs("ticketID", t.id).URL()+") (at the door; releases the price to the organiser)")
		} else {
			acts = append(acts, "doors open "+when(e.start))
		}
		if t.listed {
			acts = append(acts, "[Take off the resale desk]("+txlink.NewLink("Unlist").AddArgs("ticketID", t.id).URL()+")")
		} else {
			acts = append(acts, "[Put on the resale desk]("+txlink.NewLink("List").AddArgs("ticketID", t.id, "price", itoa(e.price)).URL()+
				") (up to "+priceLabel(resaleCap(e))+")")
		}
	}
	for _, a := range acts {
		b.WriteString("- " + a + "\n")
	}
	if t.listed && now < e.end && !e.cancelled {
		b.WriteString("\nOn the resale desk: " + deskAction(t, now) + "\n")
	}
	return b.String()
}

func renderHolder(addr string) string {
	if !address(addr).IsValid() {
		return "# Not an address\n\n[All events](" + home() + ")\n"
	}
	now := time.Now().Unix()
	var b strings.Builder
	b.WriteString("# Tickets held by " + addr + "\n\n")
	n := 0
	prefix := addr + "/"
	b.WriteString("| Ticket | Event | When | |\n|---|---|---|---|\n")
	byOwner.Iterate(prefix, prefix+"~", func(_ string, v any) bool {
		n++
		if n > shownHeld {
			return true
		}
		t := v.(*ticket)
		b.WriteString("| [" + t.id + "](" + ticketURL(t) + ") | [" + sanitize.TableCell(t.ev.name) + "](" + eventURL(t.ev) +
			") | " + when(t.ev.start) + " | " + ticketState(t, now) + " |\n")
		return false
	})
	if n == 0 {
		return "# Tickets held by " + addr + "\n\nNone.\n\n[All events](" + home() + ")\n"
	}
	if n > shownHeld {
		b.WriteString("\nThe oldest " + strconv.Itoa(shownHeld) + " are shown.\n")
	}
	b.WriteString("\n[All events](" + home() + ")\n")
	return b.String()
}

func status(e *event, now int64) string {
	switch {
	case e.cancelled:
		return "cancelled"
	case now < e.start:
		return "on sale"
	case now < e.end:
		return "doors open"
	case e.settled:
		return "over, settled"
	default:
		return "over"
	}
}

func ticketState(t *ticket, now int64) string {
	switch {
	case t.admittedAt != 0:
		return "ADMITTED " + time.Unix(t.admittedAt, 0).UTC().Format("2006-01-02 15:04 UTC")
	case t.ev.cancelled:
		return "refundable (cancelled)"
	case now >= t.ev.end:
		return "unused"
	case t.listed:
		return "for resale at " + priceLabel(t.listPrice)
	default:
		return "valid"
	}
}

func refundLabel(amount int64) string {
	if amount == 0 {
		return "Refund (gives back its storage deposit)"
	}
	return "Refund " + gnot(amount)
}

func home() string { return strings.TrimPrefix(selfPath, "gno.land") }

func pageURL(n int) string {
	if n == 1 {
		return home()
	}
	return home() + ":page/" + strconv.Itoa(n)
}

func eventURL(e *event) string   { return home() + ":event/" + utoa(e.id) }
func ticketURL(t *ticket) string { return home() + ":ticket/" + t.id }

func buyListedURL(t *ticket) string {
	return txlink.NewLink("BuyListed").AddArgs("ticketID", t.id).SetSend(itoa(t.listPrice+ResaleDeposit) + denom).URL()
}

func priceLabel(p int64) string {
	if p == 0 {
		return "free"
	}
	return gnot(p)
}

// gnot formats ugnot as GNOT without trailing zeros.
func gnot(u int64) string {
	s := itoa(u / 1000000)
	if r := u % 1000000; r != 0 {
		frac := strconv.FormatInt(r+1000000, 10)[1:]
		s += "." + strings.TrimRight(frac, "0")
	}
	return s + " GNOT"
}

func short(a address) string {
	s := a.String()
	if len(s) < 14 {
		return s
	}
	return s[:7] + "…" + s[len(s)-4:]
}
