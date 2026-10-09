package tickets

import (
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	catalog "gno.land/r/nym-alexiscolin000/gnoradio/catalog/v2"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
	"gno.land/r/nym-alexiscolin000/gnoradio/tickets/nft"
)

// The tickets' collections in the data realm (docs/ARCHITECTURE-v1.md,
// section 3). P(n) is store.Pad, T(t) a 12-digit unix time. The event and
// ticket records are laid out as the permanent NFT realm reads them
// (nft.E*, nft.T*).
const (
	cEvents   = nft.CEvents        // P(id) -> event record
	cTickets  = nft.CTickets       // P((id-1)/16) -> 16 ticket records
	cByArtist = "tickets/byartist" // P(artist)/P(event) -> ""
	cUpcoming = "tickets/upcoming" // T(start)/P(event) -> "" (not cancelled, not hidden)
	cAhead    = "tickets/ahead"    // P(artist)/T(start)/P(event) -> "" (not cancelled)
	cOwned    = "tickets/owned"    // address -> packed ticket ids held
	cBuyers   = "tickets/buyers"   // P(event)/address -> tickets bought
	cAttended = "tickets/attended" // address -> concerts checked in at
	cMeta     = "tickets/meta"     // "n" -> Rec(events, tickets)
	cConfig   = "tickets/config"   // admin, fee
	cPresent  = "tickets/present"  // P(ticket) -> Rec(holder, unix time, door code) of its last Present
)

var collections = []string{cEvents, cTickets, cByArtist, cUpcoming, cAhead, cOwned, cBuyers, cAttended, cMeta, cConfig, cPresent}

// setup makes the collections and the first settings, once: a later
// release finds them made (it is not the writer in its init).
func setup(cur realm, holder address) {
	for _, c := range collections {
		data.Make(cross(cur), c)
	}
	if !data.Has(cMeta, "n") {
		save(cur, store.Ops{}.Set(cMeta, "n", store.Rec("0", "0")).Set(cConfig, "admin", holder.String()))
	}
}

// save writes ops in one call: data.Set or data.Remove for one op, else one
// data.Batch.
func save(cur realm, ops store.Ops) {
	switch {
	case len(ops) == 0:
	case len(ops) > 4:
		data.Batch(cross(cur), ops)
	case ops[0] == store.OpSet:
		data.Set(cross(cur), ops[1], ops[2], ops[3])
	default:
		data.Remove(cross(cur), ops[1], ops[2])
	}
}

func get(c, k string) string {
	v, _ := data.Get(c, k)
	return v
}

func upKey(e *Event) string { return store.TimeKey(e.Start) + "/" + store.Pad(e.ID) }

func aheadKey(e *Event) string { return store.Pad(e.ArtistID) + "/" + upKey(e) }

// idOf reads the event id at the end of an index key.
func idOf(k string) int { return text.Atoi(k[strings.LastIndex(k, "/")+1:]) }

// count is the number of keys of c with start <= key < end.
func count(c, start, end string) int { return data.Index(c, end) - data.Index(c, start) }

// ---- counts: tickets/meta "n" ----

const (
	mEvents = iota
	mTickets
)

func meta() string { return get(cMeta, "n") }

func metaCount(m string, i int) int {
	if m == "" {
		return 0
	}
	return text.Atoi(store.Field(m, i))
}

// ---- events ----

// decode reads an event record ("" gives nil).
func decode(id int, rec string) *Event {
	if rec == "" {
		return nil
	}
	f := store.Fields(rec)
	return &Event{ID: id, ArtistID: text.Atoi(f[nft.EArtist]), Title: f[nft.ETitle], Venue: f[nft.EVenue], Link: f[nft.ELink],
		Start: text.Atoi64(f[nft.EStart]), Price: text.Atoi64(f[nft.EPrice]), Capacity: text.Atoi(f[nft.ECapacity]), Sold: text.Atoi(f[nft.ESold]),
		Cancelled: f[nft.ECancelled] != "", Hidden: f[nft.EHidden] != "", Removed: f[nft.ERemoved]}
}

// record encodes an event in the order of nft.E*.
func record(e *Event) string {
	f := make([]string, nft.EFields)
	f[nft.ESold], f[nft.EArtist], f[nft.EStart], f[nft.EPrice], f[nft.ECapacity] =
		text.Itoa(e.Sold), text.Itoa(e.ArtistID), text.Itoa64(e.Start), text.Itoa64(e.Price), text.Itoa(e.Capacity)
	f[nft.ECancelled], f[nft.EHidden], f[nft.ERemoved] = text.Flag(e.Cancelled), text.Flag(e.Hidden), e.Removed
	f[nft.ETitle], f[nft.EVenue], f[nft.ELink] = e.Title, e.Venue, e.Link
	return store.Rec(f...)
}

func getEvent(id int) *Event {
	if id < 1 {
		return nil
	}
	return decode(id, get(cEvents, store.Pad(id)))
}

// visible: not hidden by moderation, and its artist profile is visible.
func visible(e *Event) bool { return e != nil && !e.Hidden && catalog.ArtistVisible(e.ArtistID) }

func mustEvent(id int) *Event {
	e := getEvent(id)
	if !visible(e) {
		panic("tickets: unknown concert")
	}
	return e
}

// ---- tickets: chunks of nft.Chunk records ----

// chunks reads ticket records, each chunk once per call.
type chunks map[string]string

func (cs chunks) ticket(id int) *Ticket {
	if id < 1 {
		return nil
	}
	k, i := store.Slot(id, nft.Chunk)
	ch, ok := cs[k]
	if !ok {
		ch = get(cTickets, k)
		cs[k] = ch
	}
	if ch == "" {
		return nil
	}
	rec := store.Field(ch, i)
	if rec == "" {
		return nil
	}
	return &Ticket{ID: id, Event: text.Atoi(store.Field(rec, nft.TEvent)), Serial: text.Atoi(store.Field(rec, nft.TSerial)),
		Attended: store.Field(rec, nft.TAttended) != ""}
}

func getTicket(id int) *Ticket { return chunks{}.ticket(id) }

func mustTicket(id int) *Ticket {
	tk := getTicket(id)
	if tk == nil {
		panic("tickets: unknown ticket")
	}
	return tk
}

func ticketRecord(tk *Ticket) string {
	return store.Rec(text.Itoa(tk.Event), text.Itoa(tk.Serial), text.Flag(tk.Attended))
}

// ---- holders' lists ----

// own adds id to addr's list (remove: takes it out) as an op.
func own(ops store.Ops, addr address, id int, add bool) store.Ops {
	list := get(cOwned, addr.String())
	if add {
		if store.Count(list) >= maxOwned {
			panic("tickets: this wallet holds " + text.Itoa(maxOwned) + " tickets, the most it can")
		}
		list, _ = store.Add(list, id)
	} else {
		list, _ = store.Remove(list, id)
	}
	if list == "" {
		return ops.Del(cOwned, addr.String())
	}
	return ops.Set(cOwned, addr.String(), list)
}
