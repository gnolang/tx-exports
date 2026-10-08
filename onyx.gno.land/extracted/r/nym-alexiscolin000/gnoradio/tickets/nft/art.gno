package nft

import (
	"encoding/base64"
	"strconv"
	"time"

	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/svg/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
)

// Tickets are drawn on-chain as SVG in the GnoRadio sober style: white,
// black and greys with a single red accent. The perforation is cut out with a
// mask so it reads as holes on any page background. Text is escaped by
// svg.Text. Nothing extra is stored: a ticket is drawn from its records.
// The artist's name and visibility are read from the catalog's artist
// records in the data realm (nft.gno, CArtists).

const (
	ink    = "#0d0d0d"
	paper  = "#fafaf8"
	grey   = "#9a9a96"
	accent = "#e5432f"
)

// removedTitle replaces the details of a concert hidden by moderation.
const removedTitle = "Removed by moderation"

// concert is what a ticket shows of its concert.
type concert struct {
	id, artist, capacity int
	title, venue         string
	start, price         int64
	cancelled            bool
}

// shown decodes an event record for a ticket: everything while the concert
// and its artist are visible, a neutral placeholder otherwise. ok is false
// when the concert is not visible.
func shown(id int, rec string) (c concert, ok bool) {
	if rec == "" {
		return concert{title: removedTitle}, false
	}
	// store.Field reads "" past a record's end, and texts are checked again
	// here: whatever a later release writes, the metadata is valid JSON (a
	// record that is not a store.Rec may also make the read panic).
	c = concert{id: id, start: text.Atoi64(store.Field(rec, EStart)), capacity: text.Atoi(store.Field(rec, ECapacity)),
		cancelled: store.Field(rec, ECancelled) != ""}
	artist, title, venue := text.Atoi(store.Field(rec, EArtist)), store.Field(rec, ETitle), store.Field(rec, EVenue)
	if store.Field(rec, EHidden) != "" || !artistVisible(artist) || !text.Valid(title, 1, 64) || !text.Valid(venue, 0, 64) {
		c.title = removedTitle
		return c, false
	}
	c.artist, c.title, c.venue, c.price = artist, title, venue, text.Atoi64(store.Field(rec, EPrice))
	return c, true
}

// fields reads ticket id's event, serial and attended mark (ok false when
// unknown).
func fields(id int) (ev, serial int, attended, ok bool) {
	rec := ticket(id)
	if rec == "" {
		return 0, 0, false, false
	}
	return text.Atoi(store.Field(rec, TEvent)), text.Atoi(store.Field(rec, TSerial)), store.Field(rec, TAttended) != "", true
}

// EventSVG is the specimen ticket of a visible concert as a markdown image,
// or "" when the concert is not visible.
func EventSVG(id int) string {
	c, ok := shown(id, event(id))
	if !ok {
		return ""
	}
	return draw(c, 0, false).Image("ticket for " + c.title)
}

// TicketSVG is a ticket as a markdown image, or "" if unknown.
func TicketSVG(id int) string {
	ev, serial, attended, ok := fields(id)
	if !ok {
		return ""
	}
	c, _ := shown(ev, event(ev))
	return draw(c, serial, attended).Image("ticket for " + c.title)
}

// TokenURI is a ticket's GRC721 metadata as a data URI, its artwork drawn on
// the fly. It panics for an unknown ticket.
func TokenURI(tokenID string) string {
	id := text.Atoi(tokenID)
	ev, serial, attended, ok := fields(id)
	if !ok || strconv.Itoa(id) != tokenID {
		panic("nft: unknown ticket")
	}
	c, _ := shown(ev, event(ev))
	meta := `{"name":` + text.Str("GnoRadio · "+c.title+" #"+pad3(serial)) +
		`,"description":"GnoRadio concert ticket, drawn on-chain on gno.land","image":` + text.Str(draw(c, serial, attended).Data()) +
		`,"attributes":[{"trait_type":"event","value":` + strconv.Itoa(c.id) +
		`},{"trait_type":"artist","value":` + text.Str(ArtistName(c.artist)) +
		`},{"trait_type":"attended","value":` + strconv.FormatBool(attended) + `}]}`
	return "data:application/json;base64," + base64.StdEncoding.EncodeToString([]byte(meta))
}

func newCanvas(w, h int) *svg.Canvas {
	return svg.New(w, h, `text{font-family:system-ui,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-weight:600}.m{font-weight:500}.l{font-weight:600;letter-spacing:.08em}.n{font-family:ui-monospace,Menlo,monospace;font-weight:500}`)
}

func drawText(c *svg.Canvas, x, y int, s, fill string, size int, anchor, class string) {
	attrs := ` text-anchor="` + anchor + `"`
	if class != "" {
		attrs += ` class="` + class + `"`
	}
	c.Text(x, y, s, fill, size, attrs)
}

// draw draws a ticket; serial 0 is the specimen shown before purchase.
func draw(e concert, serial int, attended bool) *svg.Canvas {
	c := newCanvas(640, 250)
	// Black ticket with perforation and side notches cut out.
	c.Raw(`<mask id="h"><rect width="640" height="250" fill="#fff"/>`)
	for y := 18; y < 250; y += 16 {
		c.Circle(470, y, 3, "#000")
	}
	c.Circle(470, 0, 14, "#000")
	c.Circle(470, 250, 14, "#000")
	c.Raw(`</mask><g mask="url(#h)">`)
	c.Rect(0, 0, 640, 250, 24, ink, "")
	c.Raw(`</g>`)

	drawText(c, 30, 44, "GNORADIO · ADMIT ONE", grey, 12, "start", "l")
	drawText(c, 30, 96, svg.Clip(e.title, 24), paper, 32, "start", "")
	drawText(c, 30, 128, svg.Clip(ArtistName(e.artist), 34), grey, 18, "start", "m")
	drawText(c, 30, 182, svg.Clip(e.venue, 34), paper, 15, "start", "m")
	drawText(c, 30, 206, time.Unix(e.start, 0).UTC().Format("2006-01-02 15:04")+" UTC", paper, 15, "start", "m")
	price := "FREE"
	if e.price > 0 {
		price = text.GNOT(e.price)
	}
	drawText(c, 440, 206, price, grey, 14, "end", "l")

	// Stub: serial, barcode, red dot.
	num := "SPECIMEN"
	if serial > 0 {
		num = "#" + pad3(serial) + "/" + strconv.Itoa(e.capacity)
	}
	drawText(c, 555, 54, num, paper, 16, "middle", "n")
	h := svg.FNV("event" + strconv.Itoa(e.id) + e.title)
	for i := 0; i < 22; i++ {
		h ^= uint32(i + 1)
		h *= 16777619
		c.Rect(502+i*5, 80, 1+int(h>>24)%3, 80, 0, paper, "")
	}
	c.Circle(555, 200, 14, accent)

	if e.cancelled {
		stamp(c, "CANCELLED")
	} else if attended {
		stamp(c, "I WAS THERE")
	}
	return c
}

func stamp(c *svg.Canvas, label string) {
	c.Raw(`<g transform="rotate(-10 240 125)">`)
	c.Rect(70, 95, 340, 60, 8, "none", ` stroke="`+accent+`" stroke-width="4"`)
	drawText(c, 240, 137, label, accent, 30, "middle", "l")
	c.Raw(`</g>`)
}

func pad3(n int) string {
	s := strconv.Itoa(n)
	for len(s) < 3 {
		s = "0" + s
	}
	return s
}

// artistVisible reports whether artist id exists and is not hidden.
func artistVisible(id int) bool {
	rec := artist(id)
	return rec != "" && store.Field(rec, AHidden) == ""
}

// ArtistName is a visible artist's name, "" otherwise (one data read: the
// catalog's artist record, through the frozen layout).
func ArtistName(id int) string {
	rec := artist(id)
	if rec == "" || store.Field(rec, AHidden) != "" {
		return ""
	}
	name := store.Field(rec, AName)
	if !text.Valid(name, 1, 64) {
		return ""
	}
	return name
}
