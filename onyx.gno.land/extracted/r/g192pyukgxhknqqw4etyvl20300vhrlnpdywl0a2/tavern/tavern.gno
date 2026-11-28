// Package tavern implements the Tavern Guestbook realm: a cozy social
// corner of gno.land where visitors sign a shared guestbook and check in
// once a day to build a streak and climb the Regulars Board.
//
// State is deliberately lean (on-chain storage is metered per byte):
//   - the guestbook keeps only the most recent guestbookKeep entries,
//     plus a counter of every signature ever left;
//   - each patron costs one small record (last check-in day, current
//     streak, best streak, total check-ins);
//   - the Regulars Board is a bounded slice of at most boardSize
//     addresses, re-ranked on every check-in.
package tavern

import (
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	// maxMessageRunes caps a guestbook message at 140 characters.
	maxMessageRunes = 140
	// guestbookKeep bounds how many recent guestbook entries are stored.
	guestbookKeep = 50
	// boardSize bounds the Regulars Board.
	boardSize = 10
	// secondsPerDay converts a unix timestamp into a UTC day number.
	secondsPerDay = 86400
)

// entry is one guestbook signature.
type entry struct {
	author address
	day    int64 // UTC day number (unix seconds / 86400)
	msg    string
}

// patron is one visitor's check-in record.
type patron struct {
	lastDay int64 // UTC day number of the most recent check-in
	streak  int   // current run of consecutive daily check-ins
	best    int   // longest streak ever reached
	total   int   // lifetime check-ins
}

var (
	book          []entry
	board         []address
	patrons       = map[address]*patron{}
	totalSigns    int
	totalCheckIns int
)

// today returns the current UTC day number, derived from the block time
// (the stdlib time package reports the executing block's timestamp).
func today() int64 {
	return time.Now().Unix() / secondsPerDay
}

// Sign leaves a message in the guestbook for the calling address.
// The message must be a single line of at most 140 characters.
func Sign(cur realm, msg string) string {
	author := cur.Previous().Address()

	clean, reason := validateMessage(msg)
	if reason != "" {
		panic(reason)
	}

	book = append(book, entry{author: author, day: today(), msg: clean})
	if len(book) > guestbookKeep {
		book = book[len(book)-guestbookKeep:]
	}
	totalSigns++

	return "Signed the guestbook — you are guest #" + strconv.Itoa(totalSigns) + "."
}

// validateMessage trims a guestbook message and checks it against the
// tavern rules, returning the cleaned message, or a rejection reason.
func validateMessage(msg string) (string, string) {
	msg = strings.TrimSpace(msg)
	if msg == "" {
		return "", "tavern: message is empty"
	}
	if strings.ContainsAny(msg, "\n\r\t") {
		return "", "tavern: message must be a single line"
	}
	if utf8.RuneCountInString(msg) > maxMessageRunes {
		return "", "tavern: message is too long (max " + strconv.Itoa(maxMessageRunes) + " characters)"
	}
	return msg, ""
}

// CheckIn records a daily check-in for the calling address. Checking in
// on back-to-back days grows the streak; missing a day restarts it at 1.
// A second check-in on the same day changes nothing and simply reports
// the current standing.
func CheckIn(cur realm) string {
	return checkIn(cur.Previous().Address(), today())
}

func checkIn(who address, day int64) string {
	p := patrons[who]
	if p == nil {
		patrons[who] = &patron{lastDay: day, streak: 1, best: 1, total: 1}
		totalCheckIns++
		updateBoard(who)
		return "Welcome to the tavern, " + shortAddr(who) + "! First check-in — streak of 1 day."
	}
	if p.lastDay == day {
		return "Already checked in today, " + shortAddr(who) +
			". Streak: " + strconv.Itoa(p.streak) + " day(s), visits: " + strconv.Itoa(p.total) + "."
	}
	if p.lastDay == day-1 {
		p.streak++
	} else {
		p.streak = 1
	}
	if p.streak > p.best {
		p.best = p.streak
	}
	p.total++
	p.lastDay = day
	totalCheckIns++
	updateBoard(who)
	return "Checked in, " + shortAddr(who) + "! Streak: " + strconv.Itoa(p.streak) +
		" day(s), visits: " + strconv.Itoa(p.total) + "."
}

// ranksBefore reports whether patron a belongs ahead of patron b on the
// Regulars Board: higher streak first, then more visits, then the lower
// address (so the order is fully deterministic).
func ranksBefore(a, b address) bool {
	pa, pb := patrons[a], patrons[b]
	if pa.streak != pb.streak {
		return pa.streak > pb.streak
	}
	if pa.total != pb.total {
		return pa.total > pb.total
	}
	return a.String() < b.String()
}

// updateBoard re-inserts a patron into the Regulars Board after a
// check-in and trims the board back to boardSize entries.
func updateBoard(who address) {
	for i, a := range board {
		if a == who {
			board = append(board[:i], board[i+1:]...)
			break
		}
	}
	pos := len(board)
	for i, a := range board {
		if ranksBefore(who, a) {
			pos = i
			break
		}
	}
	board = append(board, who)
	for i := len(board) - 1; i > pos; i-- {
		board[i] = board[i-1]
	}
	board[pos] = who
	if len(board) > boardSize {
		board = board[:boardSize]
	}
}

// GuestCount returns how many guestbook signatures have ever been left.
func GuestCount() int {
	return totalSigns
}

// CheckInCount returns how many check-ins have ever been poured.
func CheckInCount() int {
	return totalCheckIns
}

// PatronStats returns the check-in record of one address:
// current streak, best streak, total check-ins, and whether the
// address has ever checked in.
func PatronStats(addr address) (streak, best, total int, ok bool) {
	p := patrons[addr]
	if p == nil {
		return 0, 0, 0, false
	}
	return p.streak, p.best, p.total, true
}

// shortAddr renders an address in a compact, human-friendly form.
func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 18 {
		return s
	}
	return s[:11] + "…" + s[len(s)-5:]
}
