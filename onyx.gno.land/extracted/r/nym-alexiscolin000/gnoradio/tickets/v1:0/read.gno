package tickets

import (
	"strconv"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	catalog "gno.land/r/nym-alexiscolin000/gnoradio/catalog/v1"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
	"gno.land/r/nym-alexiscolin000/gnoradio/tickets/nft"
)

// Read API for the home realm and the GnoRadio app (values only).

// TicketOwner returns the current holder of a ticket.
func TicketOwner(ticketID int) address {
	mustTicket(ticketID)
	return nft.OwnerOf(text.Itoa(ticketID))
}

// EventInfo returns a copy of a visible concert; ok is false otherwise.
func EventInfo(id int) (Event, bool) {
	if e := getEvent(id); visible(e) {
		return *e, true
	}
	return Event{}, false
}

// HiddenNote says why a concert is hidden: "Removed by moderation: <reason>", or "".
func HiddenNote(eventID int) string {
	if e := getEvent(eventID); e != nil && e.Hidden {
		return "Removed by moderation: " + e.Removed
	}
	return ""
}

// TicketInfo returns a copy of a ticket.
func TicketInfo(id int) (Ticket, bool) {
	if tk := getTicket(id); tk != nil {
		return *tk, true
	}
	return Ticket{}, false
}

func EventCount() int  { return metaCount(meta(), mEvents) }
func TicketCount() int { return metaCount(meta(), mTickets) }

// Attended returns how many concerts a holder checked in at.
func Attended(holder address) int { return text.Atoi(get(cAttended, holder.String())) }

// PresentedAt is when the ticket's current holder last presented it at the
// door (Present) with this door code, unix seconds; 0 when they did not, or
// it changed hands since, or it was checked in. CheckIn takes it for 10
// minutes.
func PresentedAt(ticketID int, code string) int64 {
	rec := get(cPresent, store.Pad(ticketID))
	if rec == "" || code == "" || address(store.Field(rec, 0)) != nft.Holder(ticketID) || store.Field(rec, 2) != code {
		return 0
	}
	return text.Atoi64(store.Field(rec, 1))
}

// ServiceFee returns the per-ticket service fee in ugnot (0 while no treasury is set).
func ServiceFee() int64 { return serviceFee() }

// Admin is the moderator ("" once renounced).
func Admin() address { return adminAddr() }

// PendingAdmin is the address the moderator role is offered to ("" if none).
func PendingAdmin() address { return admin.Pending() }

// TicketsOf returns up to limit ticket ids held by owner, newest first.
func TicketsOf(owner address, offset, limit int) []int {
	limit = store.Limit(limit, 50)
	if offset < 0 {
		offset = 0
	}
	return store.Page(get(cOwned, owner.String()), offset, limit, true)
}

// ArtistEvents returns up to limit visible concert ids of an artist, newest
// first.
func ArtistEvents(artistID, limit int) []int {
	limit = store.Limit(limit, 50)
	if !catalog.ArtistVisible(artistID) {
		return nil
	}
	var ids []int
	p := store.Pad(artistID)
	for end := p + "0"; ; {
		keys, _ := store.Rows(data.Page(cByArtist, p+"/", end, 100, true))
		for _, k := range keys {
			if e := getEvent(idOf(k)); !e.Hidden {
				if ids = append(ids, e.ID); len(ids) >= limit {
					return ids
				}
			}
		}
		if len(keys) < 100 {
			return ids
		}
		end = keys[len(keys)-1]
	}
}

// Upcoming returns up to n visible, not cancelled future concerts, soonest
// first.
func Upcoming(n int) []Event {
	n = store.Limit(n, 50)
	var out []Event
	eachUpcoming(n, func(e *Event) bool {
		out = append(out, *e)
		return len(out) >= n
	})
	return out
}

// PastEvents returns up to limit (1-100) ids of the concerts that have
// started, were not cancelled and are not hidden, latest first from offset,
// and how many there are. The start-time index pages them: cancelled or
// hidden concerts take no room, however many there are.
func PastEvents(offset, limit int) (ids []int, total int) {
	limit = store.Limit(limit, 100)
	total = data.Index(cUpcoming, store.TimeKey(now()+1))
	if offset < 0 || offset >= total {
		return nil, total
	}
	if offset+limit > total {
		limit = total - offset
	}
	keys, _ := store.Rows(data.PageAt(cUpcoming, data.Size(cUpcoming)-total+offset, limit, true))
	for _, k := range keys {
		ids = append(ids, idOf(k))
	}
	return ids, total
}

// eachUpcoming walks the visible future concerts, soonest first, until fn
// returns true or maxScan index entries were read; want sizes the first
// page. Past entries are skipped by starting the walk at now.
func eachUpcoming(want int, fn func(e *Event) bool) {
	start, scanned, size := store.TimeKey(now()+1), 0, want+5
	for {
		if size > 100 {
			size = 100
		}
		keys, _ := store.Rows(data.Page(cUpcoming, start, "", size, false))
		for _, k := range keys {
			scanned++
			if e := getEvent(idOf(k)); visible(e) && !e.Cancelled && fn(e) || scanned >= maxScan {
				return
			}
		}
		if len(keys) < size {
			return
		}
		start, size = keys[len(keys)-1]+"\x00", 100
	}
}

// ---- JSON and art ----

// EventSVG returns the specimen ticket of a visible concert as a markdown
// image, or "" when the concert is not visible.
func EventSVG(id int) string { return nft.EventSVG(id) }

// TicketSVG returns a ticket as a markdown image, or "" if unknown.
func TicketSVG(id int) string { return nft.TicketSVG(id) }

func eventJSON(e *Event, fee string) string {
	return `{"id":` + text.Itoa(e.ID) + `,"artist":` + text.Itoa(e.ArtistID) + `,"artistName":` + text.Str(nft.ArtistName(e.ArtistID)) +
		`,"title":` + text.Str(e.Title) + `,"venue":` + text.Str(e.Venue) + `,"link":` + text.Str(e.Link) +
		`,"start":` + text.Itoa64(e.Start) + `,"price":` + text.Itoa64(e.Price) + `,"capacity":` + text.Itoa(e.Capacity) +
		`,"sold":` + text.Itoa(e.Sold) + `,"cancelled":` + strconv.FormatBool(e.Cancelled) + `,"fee":` + fee + `}`
}

// EventsJSON pages through concerts, newest first (limit <= 50): offset and
// limit count stored concerts, hidden ones are left out of the page, and
// "next" gives the offset of the following page (0 at the end).
// upcoming=true lists future, not cancelled, visible concerts instead,
// soonest first, with offset and limit counting listed concerts ("next" is
// then a listed-concert offset, 0 when the scan ended).
func EventsJSON(offset, limit int, upcoming bool) string {
	limit = store.Limit(limit, 50)
	if offset < 0 {
		offset = 0
	}
	fee := text.Itoa64(serviceFee())
	var b strings.Builder
	b.WriteString(`{"total":` + text.Itoa(EventCount()) + `,"events":[`)
	n, next := 0, 0
	add := func(e *Event) {
		if n > 0 {
			b.WriteString(",")
		}
		b.WriteString(eventJSON(e, fee))
		n++
	}
	if upcoming {
		// One concert past a full page proves there is a next page.
		i := 0
		eachUpcoming(offset+limit+1, func(e *Event) bool {
			if n >= limit {
				next = i
				return true
			}
			if i >= offset {
				add(e)
			}
			i++
			return false
		})
	} else {
		// offset and limit count stored concerts, hidden ones included, so
		// the page is found in O(log n); hidden ones are left out.
		keys, recs := store.Rows(data.PageAt(cEvents, offset, limit, true))
		for i, k := range keys {
			if e := decode(text.Atoi(k), recs[i]); visible(e) {
				add(e)
			}
		}
		if offset+len(keys) < data.Size(cEvents) {
			next = offset + len(keys)
		}
	}
	b.WriteString(`],"next":` + text.Itoa(next) + `}`)
	return b.String()
}

// TicketsOfJSON lists the tickets held by owner, newest first (<= 50).
func TicketsOfJSON(owner address) string {
	var b strings.Builder
	b.WriteString(`[`)
	cs := chunks{}
	for i, id := range TicketsOf(owner, 0, 50) {
		tk := cs.ticket(id)
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"id":` + text.Itoa(tk.ID) + `,"event":` + text.Itoa(tk.Event) + `,"serial":` + text.Itoa(tk.Serial) +
			`,"attended":` + strconv.FormatBool(tk.Attended) + `}`)
	}
	b.WriteString(`]`)
	return b.String()
}

// FeesJSON returns the ticket service fee and where it goes.
func FeesJSON() string {
	return `{"serviceFee":` + text.Itoa64(serviceFee()) + `,"treasury":` + text.Str(catalog.Treasury().String()) + `}`
}
