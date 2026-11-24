// Package tankardtales is the realm behind Tankard & Tales, a tavern-themed
// quest board and guestbook that lives entirely on Gno.land.
//
// Every visitor can sign the tavern guestbook, post a quest with a tip held
// in escrow by the realm itself, claim somebody else's quest, and get paid
// the moment the poster confirms the work is done. Regulars earn a place on
// the leaderboard for quests completed and tips earned.
//
// The realm is deliberately self-contained: three AVL trees hold all state,
// no external realm is ever called, and no wall-clock value is ever read, so
// every state transition is deterministic and replayable.
package tankardtales

import (
	"chain"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// Quest lifecycle states. A quest is born Open, may be Claimed by one
// adventurer at a time, and ends either Completed (tip paid out) or
// Cancelled (tip refunded to the poster).
const (
	StatusOpen      = "OPEN"
	StatusClaimed   = "CLAIMED"
	StatusCompleted = "COMPLETED"
	StatusCancelled = "CANCELLED"
)

// Input and economy limits. They keep the tavern tidy: long enough for real
// quests and messages, short enough that Render output stays readable and
// nobody can bloat state with essays.
const (
	// MinTipUgnot is the smallest tip a quest may carry: 0.001 GNOT.
	// A quest with no skin in the game is just a notice on the board.
	MinTipUgnot int64 = 1000

	MaxNameLen    = 32   // guestbook display name, bytes
	MaxMessageLen = 280  // guestbook message, bytes
	MaxTitleLen   = 80   // quest title, bytes
	MaxDetailsLen = 1000 // quest details, bytes
)

// Quest is one notice pinned to the tavern board.
type Quest struct {
	ID      int
	Poster  address
	Title   string
	Details string
	Tip     int64 // ugnot, held in escrow by the realm while the quest is live
	Status  string
	Claimer address // zero address while unclaimed
}

// GuestEntry is one signature in the tavern guestbook.
type GuestEntry struct {
	Name    string
	Message string
	Signs   int // how many times this guest has signed (they keep coming back)
}

// Regular is the running tally that feeds the regulars leaderboard.
type Regular struct {
	QuestsPosted int
	QuestsDone   int
	TipsEarned   int64 // ugnot earned by completing quests
	GuestSigns   int
}

var (
	questsTree    = avl.NewTree() // quest ID (decimal string) -> *Quest
	guestbookTree = avl.NewTree() // guest address string -> *GuestEntry
	regularsTree  = avl.NewTree() // address string -> *Regular

	questSeq    int   // monotonic quest counter; quest IDs start at 1
	escrowUgnot int64 // sum of tips currently locked in live quests
)

// ---------------------------------------------------------------------------
// Guestbook
// ---------------------------------------------------------------------------

// SignGuestbook signs the tavern guestbook, or updates an existing
// signature. Signing again refreshes the name and message and counts as
// another visit — the barkeep remembers regulars.
func SignGuestbook(cur realm, name, message string) {
	caller := cur.Previous().Address()

	name = strings.TrimSpace(name)
	message = strings.TrimSpace(message)
	if len(name) == 0 || len(name) > MaxNameLen {
		panic("guestbook: display name must be 1-32 characters")
	}
	if len(message) == 0 || len(message) > MaxMessageLen {
		panic("guestbook: message must be 1-280 characters")
	}

	key := caller.String()
	if v := guestbookTree.Get(key); v != nil {
		entry := v.(*GuestEntry)
		entry.Name = name
		entry.Message = message
		entry.Signs++
		guestbookTree.Set(key, entry)
	} else {
		guestbookTree.Set(key, &GuestEntry{Name: name, Message: message, Signs: 1})
	}

	reg := regularOf(caller)
	reg.GuestSigns++
	regularsTree.Set(key, reg)

	chain.Emit("GuestSigned", "guest", caller.String())
}

// GetGuest returns the guestbook entry for addr, if any.
func GetGuest(addr address) (name, message string, signs int, ok bool) {
	v := guestbookTree.Get(addr.String())
	if v == nil {
		return "", "", 0, false
	}
	entry := v.(*GuestEntry)
	return entry.Name, entry.Message, entry.Signs, true
}

// GuestCount returns how many distinct guests have signed the guestbook.
func GuestCount() int {
	return guestbookTree.Size()
}

// ---------------------------------------------------------------------------
// Regulars
// ---------------------------------------------------------------------------

// regularOf returns the (possibly newly created) tally for addr.
// It is only called from state-mutating flows; read paths use GetRegular.
func regularOf(addr address) *Regular {
	key := addr.String()
	if v := regularsTree.Get(key); v != nil {
		return v.(*Regular)
	}
	reg := &Regular{}
	regularsTree.Set(key, reg)
	return reg
}

// GetRegular returns the leaderboard tally for addr, if any.
func GetRegular(addr address) (posted, done int, tipsEarned int64, guestSigns int, ok bool) {
	v := regularsTree.Get(addr.String())
	if v == nil {
		return 0, 0, 0, 0, false
	}
	reg := v.(*Regular)
	return reg.QuestsPosted, reg.QuestsDone, reg.TipsEarned, reg.GuestSigns, true
}

// EscrowUgnot returns the total tips (in ugnot) currently locked in live
// quests. It always equals the sum of Tip over OPEN and CLAIMED quests.
func EscrowUgnot() int64 {
	return escrowUgnot
}
