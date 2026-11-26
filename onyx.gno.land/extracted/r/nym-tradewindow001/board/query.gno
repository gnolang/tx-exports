package board

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
)

const maxPage = 50

// ListingJSON returns one listing, or null.
func ListingJSON(id uint64) string {
	v := listings.Get(listingKey(id))
	if v == nil {
		return "null"
	}
	return v.(*listing).json(time.Now().Unix())
}

// OpenJSON lists open listings, newest first. side filters by buy, sell or
// swap; "" means all.
func OpenJSON(side string, offset, limit int) string {
	offset, limit = page(offset, limit)
	now := time.Now().Unix()
	items := []string{}
	skipped := 0
	more := false
	oldest := now - MaxDays*day
	listings.ReverseIterate("", "", func(_ string, v any) bool {
		l := v.(*listing)
		if l.createdAt < oldest {
			return true // nothing older can still be open
		}
		if !l.open(now) || (side != "" && l.side != side) {
			return false
		}
		if skipped < offset {
			skipped++
			return false
		}
		if len(items) == limit {
			more = true
			return true
		}
		items = append(items, l.json(now))
		return false
	})
	return jsonObject(
		"listings", jsonArray(items),
		"more", jsonBool(more),
		"total", jsonUint(lastID),
		"now", jsonInt(now),
	)
}

// ListingsOfJSON lists every listing of one owner, newest first.
func ListingsOfJSON(owner string, offset, limit int) string {
	offset, limit = page(offset, limit)
	now := time.Now().Unix()
	items := []string{}
	var ids []uint64
	if v := byOwner.Get(strings.TrimSpace(owner)); v != nil {
		ids = v.([]uint64)
	}
	more := false
	for i := len(ids) - 1 - offset; i >= 0; i-- {
		if len(items) == limit {
			more = true
			break
		}
		items = append(items, mustListing(ids[i]).json(now))
	}
	return jsonObject(
		"listings", jsonArray(items),
		"more", jsonBool(more),
		"now", jsonInt(now),
	)
}

// json describes the listing at block time now (unix seconds).
func (l *listing) json(now int64) string {
	return jsonObject(
		"id", jsonUint(l.id),
		"owner", jsonString(l.owner.String()),
		"side", jsonString(l.side),
		"give", jsonString(l.give),
		"want", jsonString(l.want),
		"note", jsonString(l.note),
		"open", jsonBool(l.open(now)),
		"createdAt", jsonInt(l.createdAt),
		"expiresAt", jsonInt(l.expiresAt),
		"closedAt", jsonInt(l.closedAt),
	)
}

func page(offset, limit int) (int, int) {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > maxPage {
		limit = maxPage
	}
	return offset, limit
}

// Render shows open listings on gnoweb, and one listing at listing/<id>.
func Render(path string) string {
	now := time.Now().Unix()
	path = strings.TrimSpace(path)
	if rest, ok := strings.CutPrefix(path, "listing/"); ok {
		if id, err := strconv.ParseUint(rest, 10, 64); err == nil {
			if v := listings.Get(listingKey(id)); v != nil {
				return renderListing(v.(*listing), now)
			}
		}
		return "# Not found\n\nNo listing at this address.\n"
	}
	if path != "" {
		return "# Not found\n\nNo listing at this address.\n"
	}

	var b strings.Builder
	b.WriteString("# Trade Window board\n\n")
	b.WriteString("Public listings: what someone gives and what they want. ")
	b.WriteString("A listing moves nothing; deals settle in a trade room.\n\n")
	n := 0
	oldest := now - MaxDays*day
	listings.ReverseIterate("", "", func(_ string, v any) bool {
		l := v.(*listing)
		if l.createdAt < oldest {
			return true
		}
		if !l.open(now) {
			return false
		}
		b.WriteString("- [" + sideLabel(l.side) + "](:listing/" + jsonUint(l.id) + "): " +
			sanitize.InlineText(l.give) + " for " + sanitize.InlineText(l.want) + "\n")
		n++
		return n >= 30
	})
	if n == 0 {
		b.WriteString("No open listings.\n")
	}
	return b.String()
}

func renderListing(l *listing, now int64) string {
	var b strings.Builder
	b.WriteString("# " + sideLabel(l.side) + ": " + sanitize.InlineText(l.give) + "\n\n")
	b.WriteString("Wants: " + sanitize.InlineText(l.want) + "\n\n")
	if l.note != "" {
		b.WriteString(sanitize.InlineText(l.note) + "\n\n")
	}
	b.WriteString("Posted by " + sanitize.InlineCode(l.owner.String()) + " on " +
		date(l.createdAt) + ". ")
	if l.open(now) {
		b.WriteString("Open until " + date(l.expiresAt) + ".\n")
	} else {
		b.WriteString("Closed.\n")
	}
	return b.String()
}

func sideLabel(side string) string {
	switch side {
	case SideBuy:
		return "Buying"
	case SideSell:
		return "Selling"
	default:
		return "Swapping"
	}
}

// date writes unix seconds as a UTC calendar date.
func date(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02")
}
