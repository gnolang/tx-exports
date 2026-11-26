// Package signalboard is an on-chain trading signal board.
//
// Anyone can post a structured trading signal (asset, direction,
// reference price, short rationale). The author later resolves their
// own signal as won or lost. The realm keeps a public, verifiable
// per-author track record (posted / won / lost / win-rate) that is
// rendered as a board on gnoweb.
package signalboard

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
)

// Signal status values.
const (
	StatusOpen = "open"
	StatusWon  = "won"
	StatusLost = "lost"
)

// Event names and attribute keys.
const (
	EventSignalPosted   = "SignalPosted"
	EventSignalResolved = "SignalResolved"

	AttrSignalID  = "SignalID"
	AttrAsset     = "Asset"
	AttrDirection = "Direction"
	AttrStatus    = "Status"
)

// Signal is one structured trading signal posted on the board.
type Signal struct {
	ID        uint64
	Author    address
	Asset     string // e.g. "BTC/USDT"
	Direction string // "long" or "short"
	RefPrice  string // reference price at posting time, kept as written
	Note      string // short strategy note
	Height    int64  // block height when posted
	Status    string // StatusOpen, StatusWon or StatusLost
}

// AuthorStats is the public track record of one signal author.
type AuthorStats struct {
	Posted int
	Won    int
	Lost   int
}

var (
	signals []*Signal
	authors map[address]*AuthorStats
	nextID  uint64
)

func init() {
	authors = make(map[address]*AuthorStats)
	nextID = 1
}

// PostSignal posts a new signal to the board and returns its ID.
//
// The caller must be an end user calling this realm directly.
// direction must be "long" or "short" (case-insensitive). asset and
// refPrice must be non-empty; note may be empty but is capped in size.
// Free-text fields are sanitized before storage so they cannot break
// out of the markdown board rendering.
func PostSignal(cur realm, asset string, direction string, refPrice string, note string) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("PostSignal must be called directly by a user")
	}
	asset = sanitize(asset)
	refPrice = sanitize(refPrice)
	note = sanitize(note)
	dir := strings.ToLower(strings.TrimSpace(direction))

	if asset == "" || len(asset) > 24 {
		panic("invalid asset")
	}
	if dir != "long" && dir != "short" {
		panic("direction must be long or short")
	}
	if refPrice == "" || len(refPrice) > 32 {
		panic("invalid reference price")
	}
	if len(note) > 280 {
		panic("note too long (max 280 chars)")
	}

	author := cur.Previous().Address()
	sig := &Signal{
		ID:        nextID,
		Author:    author,
		Asset:     asset,
		Direction: dir,
		RefPrice:  refPrice,
		Note:      note,
		Height:    runtime.ChainHeight(),
		Status:    StatusOpen,
	}
	nextID++
	signals = append(signals, sig)

	st := statsOf(author)
	st.Posted++

	chain.Emit(EventSignalPosted,
		AttrSignalID, strconv.FormatUint(sig.ID, 10),
		AttrAsset, sig.Asset,
		AttrDirection, sig.Direction,
	)
	return sig.ID
}

// ResolveSignal marks one of the caller's own open signals as won or
// lost and updates the author's track record.
func ResolveSignal(cur realm, id uint64, won bool) {
	if !cur.Previous().IsUserCall() {
		panic("ResolveSignal must be called directly by a user")
	}
	sig := findSignal(id)
	if sig == nil {
		panic("signal not found")
	}
	caller := cur.Previous().Address()
	if sig.Author != caller {
		panic("only the author can resolve this signal")
	}
	if sig.Status != StatusOpen {
		panic("signal already resolved")
	}
	st := statsOf(sig.Author)
	if won {
		sig.Status = StatusWon
		st.Won++
	} else {
		sig.Status = StatusLost
		st.Lost++
	}
	chain.Emit(EventSignalResolved,
		AttrSignalID, strconv.FormatUint(sig.ID, 10),
		AttrStatus, sig.Status,
	)
}

// TotalSignals returns how many signals were ever posted.
func TotalSignals() int {
	return len(signals)
}

// OpenSignals returns how many signals are still unresolved.
func OpenSignals() int {
	n := 0
	for _, s := range signals {
		if s.Status == StatusOpen {
			n++
		}
	}
	return n
}

func statsOf(author address) *AuthorStats {
	st, ok := authors[author]
	if !ok {
		st = &AuthorStats{}
		authors[author] = st
	}
	return st
}

func findSignal(id uint64) *Signal {
	for _, s := range signals {
		if s.ID == id {
			return s
		}
	}
	return nil
}

// sanitize strips characters that would let free text break out of
// the markdown tables rendered by Render: newlines and other control
// characters become spaces, and markdown metacharacters are replaced
// with harmless equivalents.
func sanitize(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '|' || r == '`':
			b.WriteRune('/')
		case r == '[' || r == ']' || r == '(' || r == ')' ||
			r == '<' || r == '>' || r == '#' || r == '*' || r == '_':
			// drop markdown metacharacters
		case r < 0x20 || r == 0x7f:
			b.WriteRune(' ')
		default:
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}

// Render renders the board for gnoweb.
//
// "" renders the full board (latest signals + author leaderboard).
// "signal/<id>" renders a single signal in detail.
func Render(path string) string {
	if strings.HasPrefix(path, "signal/") {
		idStr := strings.TrimPrefix(path, "signal/")
		id, err := strconv.ParseUint(idStr, 10, 64)
		if err != nil {
			return "# SignalBoard\n\nInvalid signal id."
		}
		sig := findSignal(id)
		if sig == nil {
			return "# SignalBoard\n\nSignal not found."
		}
		return renderSignal(sig)
	}
	return renderBoard()
}

func renderSignal(sig *Signal) string {
	var b strings.Builder
	b.WriteString("# Signal #")
	b.WriteString(strconv.FormatUint(sig.ID, 10))
	b.WriteString("\n\n")
	b.WriteString("- Asset: **" + sig.Asset + "**\n")
	b.WriteString("- Direction: **" + sig.Direction + "**\n")
	b.WriteString("- Reference price: " + sig.RefPrice + "\n")
	b.WriteString("- Author: " + sig.Author.String() + "\n")
	b.WriteString("- Posted at block: " + strconv.FormatInt(sig.Height, 10) + "\n")
	b.WriteString("- Status: **" + sig.Status + "**\n")
	if sig.Note != "" {
		b.WriteString("- Note: " + sig.Note + "\n")
	}
	b.WriteString("\n[Back to the board](/r/g18hk5n6qmgtxqlljy5athr3u3xg669sqayrfv5z/signalboard)\n")
	return b.String()
}

func renderBoard() string {
	var b strings.Builder
	b.WriteString("# SignalBoard\n\n")
	b.WriteString("On-chain trading signals with a public, verifiable author track record.\n\n")
	b.WriteString("- Total signals: " + strconv.Itoa(len(signals)) + "\n")
	b.WriteString("- Open signals: " + strconv.Itoa(OpenSignals()) + "\n")
	b.WriteString("- Authors: " + strconv.Itoa(len(authors)) + "\n")

	b.WriteString("\n## Latest signals\n\n")
	if len(signals) == 0 {
		b.WriteString("No signals yet. Post the first one with PostSignal.\n")
	} else {
		b.WriteString("| # | Asset | Direction | Ref. price | Author | Status |\n")
		b.WriteString("|---|-------|-----------|------------|--------|--------|\n")
		// newest first, capped at 50 rows
		start := 0
		if len(signals) > 50 {
			start = len(signals) - 50
		}
		for i := len(signals) - 1; i >= start; i-- {
			s := signals[i]
			b.WriteString("| [" + strconv.FormatUint(s.ID, 10) + "](/r/g18hk5n6qmgtxqlljy5athr3u3xg669sqayrfv5z/signalboard:signal/" + strconv.FormatUint(s.ID, 10) + ")")
			b.WriteString(" | " + s.Asset)
			b.WriteString(" | " + s.Direction)
			b.WriteString(" | " + s.RefPrice)
			b.WriteString(" | " + shortAddr(s.Author.String()))
			b.WriteString(" | " + s.Status + " |\n")
		}
	}

	b.WriteString("\n## Author leaderboard\n\n")
	if len(authors) == 0 {
		b.WriteString("No authors yet.\n")
	} else {
		b.WriteString("| Author | Posted | Won | Lost | Win rate |\n")
		b.WriteString("|--------|--------|-----|------|----------|\n")
		for addr, st := range authors {
			resolved := st.Won + st.Lost
			rate := "-"
			if resolved > 0 {
				rate = strconv.Itoa(st.Won*100/resolved) + "%"
			}
			b.WriteString("| " + addr.String())
			b.WriteString(" | " + strconv.Itoa(st.Posted))
			b.WriteString(" | " + strconv.Itoa(st.Won))
			b.WriteString(" | " + strconv.Itoa(st.Lost))
			b.WriteString(" | " + rate + " |\n")
		}
	}
	return b.String()
}

// shortAddr shortens a bech32 address for table display.
func shortAddr(a string) string {
	if len(a) <= 16 {
		return a
	}
	return a[:10] + "..." + a[len(a)-4:]
}
