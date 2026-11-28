// Package tavern is a short message board built on Torchbeat from another
// namespace: only players the hub records as having cleared at least one room
// may post, and every post is shown with its author's live stats read from
// the hub. An author may post once every 5 blocks, the board keeps the newest
// 50, and Since lets a polling client read what it has not seen yet.
package tavern

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/sys/users"
	torchbeat "gno.land/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
)

const (
	maxPosts = 50
	maxLen   = 140
	cooldown = 5 // blocks between two posts by one author
	hubPage  = "/r/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/v1"
)

type post struct {
	seq    int
	author address
	msg    string
	height int64
}

// ring holds the newest maxPosts posts in place: post number seq lives at
// ring[seq%maxPosts], so the backing storage stays one bounded object.
var ring [maxPosts]post

// newest is the seq of the latest post; the first post is 1. It only grows.
var newest int

// lastPost maps an author's address to the block height of their last post.
var lastPost avl.Tree

// Post puts msg on the board for the caller, at most once every 5 blocks
// ("slow down"): 1 to 140 characters of letters, digits, spaces and . , ! ? ' -
// ("message"), from a player who has cleared at least one Torchbeat room
// ("explore first").
func Post(cur realm, msg string) {
	if !validMessage(msg) {
		panic("message")
	}
	caller := cur.Previous().Address()
	if torchbeat.RoomsCleared(caller) < 1 {
		panic("explore first")
	}
	submit(caller, msg)
}

func validMessage(s string) bool {
	if len(s) < 1 || len(s) > maxLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
			c == ' ' || c == '.' || c == ',' || c == '!' || c == '?' || c == '\'' || c == '-') {
			return false
		}
	}
	return true
}

// submit refuses a post made within cooldown blocks of the author's last one,
// else records it.
func submit(author address, msg string) {
	if v := lastPost.Get(string(author)); v != nil && runtime.ChainHeight() < v.(int64)+cooldown {
		panic("slow down")
	}
	record(author, msg)
}

// record stores a checked post as the newest, overwriting the oldest slot once
// the ring is full, and notes the author's post height for the cooldown.
func record(author address, msg string) {
	h := runtime.ChainHeight()
	newest++
	ring[newest%maxPosts] = post{seq: newest, author: author, msg: msg, height: h}
	lastPost.Set(string(author), h)
}

// retained is the seq of the oldest post still in the ring (newest+1 if none).
func retained() int {
	if newest > maxPosts {
		return newest - maxPosts + 1
	}
	return 1
}

// Since returns JSON {"seq":N,"posts":[...]}: N is the newest seq (0 when
// empty) and posts are the retained posts with seq greater than the argument,
// oldest first. A client resumes by passing back the N it last saw; a gap
// larger than the ring shows as a first seq above its argument plus one.
func Since(seq int) string {
	if seq < 0 {
		seq = 0
	}
	first := retained()
	if seq+1 > first {
		first = seq + 1
	}
	b := append([]byte(`{"seq":`), strconv.Itoa(newest)...)
	b = append(b, `,"posts":[`...)
	for s := first; s <= newest; s++ {
		p := ring[s%maxPosts]
		if s > first {
			b = append(b, ',')
		}
		b = append(b, `{"seq":`...)
		b = append(b, strconv.Itoa(p.seq)...)
		b = append(b, `,"author":`...)
		b = appendQuoted(b, p.author.String())
		b = append(b, `,"name":`...)
		b = appendQuoted(b, userName(p.author))
		b = append(b, `,"msg":`...)
		b = appendQuoted(b, p.msg)
		b = append(b, `,"height":`...)
		b = append(b, strconv.FormatInt(p.height, 10)...)
		b = append(b, '}')
	}
	return string(append(b, ']', '}'))
}

const hexDigits = "0123456789abcdef"

// appendQuoted appends s as a JSON string: quote and backslash are
// backslash-escaped, control characters become \u00XX.
func appendQuoted(b []byte, s string) []byte {
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b = append(b, '\\', c)
		case c < 0x20:
			b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&0xf])
		default:
			b = append(b, c)
		}
	}
	return append(b, '"')
}

// userName is a's r/sys/users name without "@", or "" if it has none.
func userName(a address) string {
	if u := users.ResolveAddress(a); u != nil {
		return u.Name()
	}
	return ""
}

// Render lists the posts newest first. Each poster's rooms cleared and renown
// are read from the hub at render time, so they stay current.
func Render(path string) string {
	var b strings.Builder
	b.WriteString("# The Tavern\n\n")
	b.WriteString("*Smoke, low beams and the smell of torch pitch. Only those who have cleared a room of the [Torchbeat](" +
		hubPage + ") dungeon may speak here. Call `Post` with up to 140 characters.*\n\n")
	if newest == 0 {
		b.WriteString("No one has spoken yet.\n")
		return b.String()
	}
	for s := newest; s >= retained(); s-- {
		p := ring[s%maxPosts]
		a := p.author.String()
		b.WriteString("**[" + sanitize.InlineText(displayName(p.author)) + "](" + hubPage + ":player/" + a + ")** · " +
			plural(torchbeat.RoomsCleared(p.author), "room") + " cleared · renown " +
			strconv.Itoa(torchbeat.Renown(p.author)) + " · block " + strconv.FormatInt(p.height, 10) + "\n\n" +
			sanitize.InlineText(p.msg) + "\n\n")
	}
	return b.String()
}

func plural(n int, noun string) string {
	if n != 1 {
		noun += "s"
	}
	return strconv.Itoa(n) + " " + noun
}

// displayName is a's r/sys/users name as "@name", or the shortened address.
func displayName(a address) string {
	if u := users.ResolveAddress(a); u != nil {
		return "@" + u.Name()
	}
	s := a.String()
	if len(s) <= 10 {
		return s
	}
	return s[:6] + "…" + s[len(s)-4:]
}
