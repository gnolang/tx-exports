// Package board is the public OTC board of Trade Window.
//
// A listing says what its owner gives and what they want, in their own
// words. It holds no assets and promises nothing: a deal happens only when
// both parties open a room in gno.land/r/tradewindow/rooms (or wherever that
// realm is deployed) and lock the same version of it. Contact details never
// belong here; everything in this realm is public forever.
package board

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
)

const (
	SideBuy  = "buy"
	SideSell = "sell"
	SideSwap = "swap"

	MaxGiveLen = 80
	MaxWantLen = 80
	MaxNoteLen = 280

	DefaultDays = 7
	MaxDays     = 30

	// MaxActivePerOwner caps open listings per address.
	MaxActivePerOwner = 10

	day = 24 * 60 * 60
)

type listing struct {
	id        uint64
	owner     address
	side      string
	give      string
	want      string
	note      string
	createdAt int64 // unix seconds of block time
	expiresAt int64
	closedAt  int64 // 0 while open
}

var (
	listings avl.Tree // padded id -> *listing
	byOwner  avl.Tree // address -> []uint64 listing ids, oldest first
	lastID   uint64
)

// Post publishes a listing and returns its id. side is buy, sell or swap;
// give and want are short phrases such as "50,000 GNOT"; note is optional.
// days is how long the listing stays up: 0 means 7, the most is 30.
func Post(cur realm, side, give, want, note string, days int) uint64 {
	owner := callerOf(cur)
	refuseCoins(cur)

	side = strings.TrimSpace(side)
	if side != SideBuy && side != SideSell && side != SideSwap {
		panic("side must be buy, sell or swap")
	}
	give = cleanText("give", give, MaxGiveLen, true)
	want = cleanText("want", want, MaxWantLen, true)
	note = cleanText("note", note, MaxNoteLen, false)
	if days == 0 {
		days = DefaultDays
	}
	if days < 1 || days > MaxDays {
		panic("a listing stays up between 1 and 30 days")
	}

	now := time.Now().Unix()
	if activeCount(owner, now) >= MaxActivePerOwner {
		panic("you already have 10 open listings: close one first")
	}

	lastID++
	l := &listing{
		id:        lastID,
		owner:     owner,
		side:      side,
		give:      give,
		want:      want,
		note:      note,
		createdAt: now,
		expiresAt: now + int64(days)*day,
	}
	listings.Set(listingKey(l.id), l)
	var ids []uint64
	if v := byOwner.Get(owner.String()); v != nil {
		ids = v.([]uint64)
	}
	byOwner.Set(owner.String(), append(ids, l.id))

	chain.Emit("ListingPosted",
		"id", strconv.FormatUint(l.id, 10),
		"owner", owner.String(),
		"side", side,
	)
	return l.id
}

// Close takes a listing down. Only its owner can close it.
func Close(cur realm, id uint64) {
	who := callerOf(cur)
	refuseCoins(cur)
	l := mustListing(id)
	if l.owner != who {
		panic("only the owner can close this listing")
	}
	if l.closedAt != 0 {
		panic("this listing is already closed")
	}
	l.closedAt = time.Now().Unix()
	chain.Emit("ListingClosed", "id", strconv.FormatUint(id, 10))
}

func (l *listing) open(now int64) bool {
	return l.closedAt == 0 && now < l.expiresAt
}

// activeCount counts the owner's open listings. Listings older than
// MaxDays cannot be open, so the walk stops there.
func activeCount(owner address, now int64) int {
	v := byOwner.Get(owner.String())
	if v == nil {
		return 0
	}
	ids := v.([]uint64)
	oldest := now - MaxDays*day
	n := 0
	for i := len(ids) - 1; i >= 0 && n < MaxActivePerOwner; i-- {
		l := mustListing(ids[i])
		if l.createdAt < oldest {
			break
		}
		if l.open(now) {
			n++
		}
	}
	return n
}

// cleanText trims s and rejects text that is too long or carries control,
// bidi or zero-width characters.
func cleanText(field, s string, max int, required bool) string {
	s = strings.TrimSpace(s)
	if required && s == "" {
		panic(field + " is required")
	}
	if !utf8.ValidString(s) {
		panic(field + " is not valid text")
	}
	if utf8.RuneCountInString(s) > max {
		panic(field + " is longer than " + strconv.Itoa(max) + " characters")
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) ||
			(r >= 0x200b && r <= 0x200f) || (r >= 0x202a && r <= 0x202e) ||
			(r >= 0x2060 && r <= 0x2069) || r == 0xfeff {
			panic(field + " contains characters that are not allowed")
		}
	}
	return s
}

func callerOf(cur realm) address {
	if !cur.IsCurrent() {
		panic("unauthorized: realm token is not current")
	}
	return cur.Previous().Address()
}

func refuseCoins(cur realm) {
	if !cur.IsCurrent() {
		panic("unauthorized: realm token is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("the board does not take coins")
	}
}

func mustListing(id uint64) *listing {
	v := listings.Get(listingKey(id))
	if v == nil {
		panic("listing not found")
	}
	return v.(*listing)
}

func listingKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	if len(s) < 20 {
		s = strings.Repeat("0", 20-len(s)) + s
	}
	return s
}
