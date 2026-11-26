// Package tavernboard is TavernBoard, a small community message board
// realm for Gno.land, built for the Gnome Tavern Hackathon.
//
// Anyone can post a short message on chain, and anyone can cheer
// (like) a message once. Messages are listed newest first by Render.
// There is no admin, no delete, and no edit: what is posted stays
// posted, which keeps the board simple, reliable, and auditable.
package tavernboard

import (
	"chain/runtime"
	"strconv"
	"strings"
)

// MaxMessageLen caps message size in bytes so one post cannot bloat
// chain state.
const MaxMessageLen = 280

// MaxMessagesShown caps how many messages Render lists at once, so
// the board page stays readable as the board grows.
const MaxMessagesShown = 50

// Message is one board entry. Author is the address that posted it,
// Height is the block height at posting time, and LikedBy records
// which addresses have cheered it (one cheer per address).
type Message struct {
	Author  address
	Text    string
	Height  int64
	Likes   int
	LikedBy map[address]bool
}

// messages holds every post in posting order. A message ID is its
// index in this slice: IDs start at 0 and never change.
var messages []Message

// PostMessage adds a message from the caller and returns its ID.
// It panics if the text is empty or longer than MaxMessageLen bytes.
func PostMessage(cur realm, text string) int {
	if !cur.IsCurrent() {
		panic("tavernboard: PostMessage must be called as a crossing function")
	}
	messages = append(messages, Message{
		Author:  cur.Previous().Address(),
		Text:    cleanText(text),
		Height:  runtime.ChainHeight(),
		Likes:   0,
		LikedBy: map[address]bool{},
	})
	return len(messages) - 1
}

// LikeMessage cheers a message. Each address can cheer a given
// message at most once. It returns the new cheer count and panics
// on an unknown ID or a repeat cheer.
func LikeMessage(cur realm, id int) int {
	if !cur.IsCurrent() {
		panic("tavernboard: LikeMessage must be called as a crossing function")
	}
	who := cur.Previous().Address()
	checkCanLike(id, who)
	messages[id].LikedBy[who] = true
	messages[id].Likes++
	return messages[id].Likes
}

// cleanText trims a candidate message and enforces the size rules.
// It panics on empty or over-long text. Kept separate from
// PostMessage so the rules can be unit tested without a crossing
// call (panics across a realm crossing cannot be recovered).
func cleanText(text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		panic("tavernboard: message is empty")
	}
	if len(text) > MaxMessageLen {
		panic("tavernboard: message is too long (max " + strconv.Itoa(MaxMessageLen) + " bytes)")
	}
	return text
}

// checkID panics unless id names an existing message.
func checkID(id int) {
	if id < 0 || id >= len(messages) {
		panic("tavernboard: no message with id " + strconv.Itoa(id))
	}
}

// checkCanLike panics unless who may cheer message id: the ID must
// exist and who must not have cheered it already.
func checkCanLike(id int, who address) {
	checkID(id)
	if messages[id].LikedBy[who] {
		panic("tavernboard: already cheered this message")
	}
}

// MessageCount returns how many messages have been posted.
func MessageCount() int {
	return len(messages)
}

// GetMessage returns one message as (author, text, height, likes).
// It panics on an unknown ID. Read-only, so queries can call it
// without a transaction.
func GetMessage(id int) (string, string, int64, int) {
	checkID(id)
	m := messages[id]
	return m.Author.String(), m.Text, m.Height, m.Likes
}

// HasLiked reports whether an address has cheered a message.
// It panics on an unknown ID.
func HasLiked(id int, who address) bool {
	checkID(id)
	return messages[id].LikedBy[who]
}

// Render returns the board as Markdown for gnoweb. The root path
// ("" or "/") lists the newest messages first. A path of the form
// "/<id>" shows a single message in full.
func Render(path string) string {
	if path != "" && path != "/" {
		return renderOne(path)
	}
	out := "# TavernBoard\n\n"
	out += "A community message board on Gno.land. Post a message, cheer the ones you like.\n\n"
	out += "Total messages: " + strconv.Itoa(len(messages)) + "\n"
	if len(messages) == 0 {
		out += "\nNo messages yet. Be the first to post.\n"
		return out
	}
	shown := len(messages)
	if shown > MaxMessagesShown {
		shown = MaxMessagesShown
	}
	for i := 0; i < shown; i++ {
		id := len(messages) - 1 - i
		out += "\n---\n\n" + renderEntry(id)
	}
	if len(messages) > shown {
		out += "\n---\n\nShowing the newest " + strconv.Itoa(shown) + " of " + strconv.Itoa(len(messages)) + " messages. Open a message by ID, for example /0, to see older posts.\n"
	}
	return out
}

// renderOne renders a single message for paths like "/3". Unknown
// paths return a friendly not-found page instead of panicking, so
// gnoweb never shows an error page for a bad link.
func renderOne(path string) string {
	idStr := strings.TrimPrefix(path, "/")
	id, err := strconv.Atoi(idStr)
	if err != nil || id < 0 || id >= len(messages) {
		return "# TavernBoard\n\nMessage not found. The board has " + strconv.Itoa(len(messages)) + " message(s), with IDs from 0 to " + strconv.Itoa(len(messages)-1) + ".\n"
	}
	return "# TavernBoard\n\n" + renderEntry(id)
}

// renderEntry formats one message as a Markdown section.
func renderEntry(id int) string {
	m := messages[id]
	out := "## Message #" + strconv.Itoa(id) + "\n\n"
	out += "- Author: `" + shortAddr(m.Author.String()) + "`\n"
	out += "- Block: " + strconv.FormatInt(m.Height, 10) + "\n"
	out += "- Cheers: " + strconv.Itoa(m.Likes) + "\n\n"
	out += escapeText(m.Text) + "\n"
	return out
}

// shortAddr trims a long g1 address for display, keeping the full
// address available through GetMessage for anyone who needs it.
func shortAddr(a string) string {
	if len(a) <= 16 {
		return a
	}
	return a[:8] + "..." + a[len(a)-4:]
}

// escapeText keeps user text on one line in the rendered page by
// folding newlines to spaces, so a post cannot break the layout.
func escapeText(s string) string {
	s = strings.ReplaceAll(s, "\r\n", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	return strings.TrimSpace(s)
}
