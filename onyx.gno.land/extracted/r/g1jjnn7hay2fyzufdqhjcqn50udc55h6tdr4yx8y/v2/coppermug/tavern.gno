// Package coppermug is an on-chain social tavern for Gno.land.
//
// Adventurers take a seat, talk in the common room, tip each other, and
// play a push-your-luck dice game called the Cup. Every table, every tale
// and every roll lives in realm state, and the whole place renders in
// gnoweb without a single line of JavaScript.
package coppermug

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
)

const (
	// Version is surfaced on the home page.
	Version = "0.1.0"

	// StartingGold is the purse every new adventurer gets.
	StartingGold int64 = 100
	// MinStake is the smallest Cup stake.
	MinStake int64 = 10
	// RoundCost is what it costs to buy the room a round.
	RoundCost int64 = 25
	// RoundShare is what each neighbour receives from a bought round.
	RoundShare int64 = 2
	// MaxRoundShare caps how many neighbours a round can cover.
	MaxRoundShare = 10

	// MaxNameLen and MinNameLen bound adventurer names.
	MaxNameLen = 20
	MinNameLen = 2
	// MaxPostLen bounds a single message, in bytes.
	MaxPostLen = 240
	// SayCooldown is the number of blocks between two messages.
	SayCooldown int64 = 5

	// MaxFeed is how many posts are kept on the board.
	MaxFeed = 100
	// MaxRecent is how many recently active seats are remembered.
	MaxRecent = 24
)

// Class is an adventurer's trade. It flavours the prose and nothing else.
type Class int

const (
	Fighter Class = iota
	Rogue
	Mage
	Bard
	Wanderer // not selectable; the fallback for unknown trades
)

// Label returns the display name of the class.
func (c Class) Label() string {
	switch c {
	case Fighter:
		return "Fighter"
	case Rogue:
		return "Rogue"
	case Mage:
		return "Mage"
	case Bard:
		return "Bard"
	}
	return "Wanderer"
}

// Sigil returns a small glyph for the class.
func (c Class) Sigil() string {
	switch c {
	case Fighter:
		return "⚔️"
	case Rogue:
		return "🗡️"
	case Mage:
		return "🔮"
	case Bard:
		return "🎻"
	}
	return "🥾"
}

// Adventurer is one seat at the tavern, keyed by wallet address.
type Adventurer struct {
	Name     string
	Class    Class
	Gold     int64
	Rep      int64
	Joined   int64
	LastSeen int64
	LastPost int64

	Wins    int
	Losses  int
	BestPot int64

	// Cup state. InCup is true between OpenCup and Hold (or a bust).
	InCup   bool
	Stake   int64
	Pot     int64
	Rolls   int
	CupDice []int
}

// Post is one line on the common-room board.
type Post struct {
	ID     int64
	Author string // address, as a string
	Name   string
	Class  Class
	Text   string
	Kind   string // join, say, tip, round, win, bust
	Height int64
	Cheers []string // addresses that cheered
}

var (
	seats      = map[string]*Adventurer{}
	byName     = map[string]string{}
	feed       []*Post
	recent     []string
	nextPostID int64
	rollSeq    uint64
)

// caller returns the wallet address behind a transaction, and refuses
// calls that arrive through another realm. The Copper Mug is a place for
// people, not contracts.
func caller(cur realm) (string, address) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("the mug only takes calls from a wallet")
	}
	addr := prev.Address()
	return addr.String(), addr
}

// seatOf returns the caller's seat or panics with a friendly message.
func seatOf(addr string) *Adventurer {
	a, ok := seats[addr]
	if !ok {
		panic("no stool yet: call Join first")
	}
	return a
}

// nameErr trims and checks a display name, returning a message on failure.
func nameErr(name string) string {
	n := strings.TrimSpace(name)
	if len(n) < MinNameLen {
		return "name is too short (2 characters minimum)"
	}
	if len(n) > MaxNameLen {
		return "name is too long (20 characters maximum)"
	}
	for i := 0; i < len(n); i++ {
		c := n[i]
		ok := (c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == ' ' || c == '-' || c == '_'
		if !ok {
			return "names may only use letters, digits, spaces, - and _"
		}
	}
	return ""
}

// classFromString accepts a class name and returns the matching Class.
func classFromString(s string) (Class, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "fighter":
		return Fighter, true
	case "rogue":
		return Rogue, true
	case "mage":
		return Mage, true
	case "bard":
		return Bard, true
	}
	return Wanderer, false
}

// cleanText flattens a message to one line and caps its length.
func cleanText(text string) (string, string) {
	t := strings.TrimSpace(text)
	t = strings.ReplaceAll(t, "\r", " ")
	t = strings.ReplaceAll(t, "\n", " ")
	t = strings.ReplaceAll(t, "\t", " ")
	if t == "" {
		return "", "say something first"
	}
	for strings.Contains(t, "  ") {
		t = strings.ReplaceAll(t, "  ", " ")
	}
	if len(t) > MaxPostLen {
		return "", "that tale is too long (240 characters maximum)"
	}
	return t, ""
}

// escapeMarkdown neutralises the characters that could turn a message
// into a link or raw HTML. Bold and italics stay, because this is a tavern.
func escapeMarkdown(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '[', ']', '<', '>', '`':
			b.WriteByte('\\')
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// addPost appends to the board and trims it to MaxFeed.
func addPost(kind, addr string, a *Adventurer, text string) {
	nextPostID++
	p := &Post{
		ID:     nextPostID,
		Author: addr,
		Name:   a.Name,
		Class:  a.Class,
		Text:   text,
		Kind:   kind,
		Height: runtime.ChainHeight(),
	}
	feed = append(feed, p)
	if len(feed) > MaxFeed {
		kept := make([]*Post, MaxFeed)
		copy(kept, feed[len(feed)-MaxFeed:])
		feed = kept
	}
}

// touch remembers a seat as recently active, newest last.
func touch(addr string) {
	out := make([]string, 0, len(recent)+1)
	for _, x := range recent {
		if x != addr {
			out = append(out, x)
		}
	}
	out = append(out, addr)
	if len(out) > MaxRecent {
		out = out[len(out)-MaxRecent:]
	}
	recent = out
}

// rollDie returns a deterministic d6 derived from the chain height, the
// caller and a realm-wide sequence number.
//
// This is house randomness, not consensus-grade randomness: a player who
// can simulate the next block can predict the roll. The Cup is played for
// tavern gold that has no value outside this realm, and a commit-reveal
// version is the natural next step.
func rollDie(addr string) int {
	rollSeq++
	x := uint64(runtime.ChainHeight()) + 0x9E3779B97F4A7C15*rollSeq
	for i := 0; i < len(addr); i++ {
		x ^= uint64(addr[i])
		x *= 0x100000001B3
	}
	x ^= x >> 30
	x *= 0xBF58476D1CE4E5B9
	x ^= x >> 27
	x *= 0x94D049BB133111EB
	x ^= x >> 31
	return int(x%6) + 1
}

// emit is a thin wrapper so event names stay consistent.
func emit(typ string, attrs ...string) {
	chain.Emit("CopperMug"+typ, attrs...)
}

// itoa is a short alias used all over the renderer.
func itoa(n int64) string { return strconv.FormatInt(n, 10) }
