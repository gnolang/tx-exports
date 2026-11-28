// Tavern Quests — an on-chain quest board for the Gnome Tavern.
//
// Anyone can post a quest on the tavern board, another adventurer can
// claim it, and when the poster confirms the work is done the claimer
// earns on-chain reputation points. The board is rendered readably in
// gnoweb via Render().
package tavernquests

import (
	"strconv"
	"strings"
)

// QuestStatus describes where a quest is in its lifecycle.
type QuestStatus int

const (
	StatusOpen QuestStatus = iota
	StatusClaimed
	StatusCompleted
	StatusCancelled
)

func (s QuestStatus) String() string {
	switch s {
	case StatusOpen:
		return "OPEN"
	case StatusClaimed:
		return "CLAIMED"
	case StatusCompleted:
		return "COMPLETED"
	case StatusCancelled:
		return "CANCELLED"
	}
	return "UNKNOWN"
}

// Quest is a single posting on the tavern board.
type Quest struct {
	ID          uint64
	Title       string
	Description string
	Reward      uint64 // reputation points paid out on completion
	Poster      address
	Claimer     address
	Status      QuestStatus
}

var (
	quests     []*Quest
	reputation = map[address]uint64{}
	nextID     uint64 = 1
)

// ---------------------------------------------------------------------------
// Public entry points (callable on-chain)
// ---------------------------------------------------------------------------

// PostQuest puts a new quest on the board and returns its ID.
func PostQuest(cur realm, title string, description string, reward uint64) uint64 {
	return postQuest(cur.Previous().Address(), title, description, reward)
}

// ClaimQuest lets an adventurer take an open quest.
func ClaimQuest(cur realm, id uint64) {
	claimQuest(cur.Previous().Address(), id)
}

// CompleteQuest is called by the poster to confirm a claimed quest is
// done; the claimer earns the quest's reputation reward.
func CompleteQuest(cur realm, id uint64) {
	completeQuest(cur.Previous().Address(), id)
}

// AbandonQuest lets the claimer hand a claimed quest back to the board.
func AbandonQuest(cur realm, id uint64) {
	abandonQuest(cur.Previous().Address(), id)
}

// CancelQuest lets the poster withdraw an open (unclaimed) quest.
func CancelQuest(cur realm, id uint64) {
	cancelQuest(cur.Previous().Address(), id)
}

// GetQuestCount returns how many quests have ever been posted.
func GetQuestCount() uint64 {
	return uint64(len(quests))
}

// GetOpenQuestCount returns how many quests are currently open.
func GetOpenQuestCount() uint64 {
	var n uint64
	for _, q := range quests {
		if q.Status == StatusOpen {
			n++
		}
	}
	return n
}

// GetReputation returns the reputation tally of an adventurer.
func GetReputation(addr address) uint64 {
	return reputation[addr]
}

// ---------------------------------------------------------------------------
// Core logic (caller passed in explicitly so it is unit-testable)
// ---------------------------------------------------------------------------

func postQuest(poster address, title string, description string, reward uint64) uint64 {
	if poster == address("") {
		panic("poster address required")
	}
	title = strings.TrimSpace(title)
	if title == "" {
		panic("quest title must not be empty")
	}
	if reward == 0 {
		panic("quest reward must be at least 1 reputation point")
	}
	q := &Quest{
		ID:          nextID,
		Title:       title,
		Description: description,
		Reward:      reward,
		Poster:      poster,
		Status:      StatusOpen,
	}
	nextID++
	quests = append(quests, q)
	return q.ID
}

func claimQuest(claimer address, id uint64) {
	q := findQuest(id)
	if q.Status != StatusOpen {
		panic("quest is not open")
	}
	if claimer == q.Poster {
		panic("you cannot claim your own quest")
	}
	q.Claimer = claimer
	q.Status = StatusClaimed
}

func completeQuest(poster address, id uint64) {
	q := findQuest(id)
	if poster != q.Poster {
		panic("only the quest poster can confirm completion")
	}
	if q.Status != StatusClaimed {
		panic("quest is not in claimed state")
	}
	q.Status = StatusCompleted
	reputation[q.Claimer] += q.Reward
}

func abandonQuest(claimer address, id uint64) {
	q := findQuest(id)
	if q.Status != StatusClaimed {
		panic("quest is not in claimed state")
	}
	if claimer != q.Claimer {
		panic("only the claimer can abandon this quest")
	}
	q.Claimer = address("")
	q.Status = StatusOpen
}

func cancelQuest(poster address, id uint64) {
	q := findQuest(id)
	if poster != q.Poster {
		panic("only the quest poster can cancel this quest")
	}
	if q.Status != StatusOpen {
		panic("only an open quest can be cancelled")
	}
	q.Status = StatusCancelled
}

func findQuest(id uint64) *Quest {
	for _, q := range quests {
		if q.ID == id {
			return q
		}
	}
	panic("quest not found: " + strconv.FormatUint(id, 10))
}

// ---------------------------------------------------------------------------
// Rendering for gnoweb
// ---------------------------------------------------------------------------

// Render draws the tavern board. Paths:
//   ""              -> the whole board + adventurer leaderboard
//   "quest/<id>"    -> one quest in detail
//   "adventurers"   -> the reputation leaderboard
func Render(path string) string {
	if path == "adventurers" {
		return renderLeaderboard()
	}
	if strings.HasPrefix(path, "quest/") {
		idStr := strings.TrimPrefix(path, "quest/")
		id, err := strconv.ParseUint(idStr, 10, 64)
		if err != nil {
			return "# Tavern Quests\n\nUnknown quest: " + path + "\n"
		}
		for _, q := range quests {
			if q.ID == id {
				return renderQuest(q)
			}
		}
		return "# Tavern Quests\n\nQuest not found: " + idStr + "\n"
	}
	return renderBoard()
}

func renderBoard() string {
	var b strings.Builder
	b.WriteString("# Tavern Quests\n\n")
	b.WriteString("Welcome to the tavern board, traveller. Post a quest, claim one, " +
		"and earn on-chain reputation when the poster confirms your work.\n\n")
	b.WriteString("Quests posted: " + strconv.FormatUint(uint64(len(quests)), 10) +
		" · Open now: " + strconv.FormatUint(GetOpenQuestCount(), 10) + "\n\n")
	b.WriteString("## Quest board\n\n")
	if len(quests) == 0 {
		b.WriteString("The board is empty — be the first to post a quest.\n")
	}
	for _, q := range quests {
		b.WriteString("- **#" + strconv.FormatUint(q.ID, 10) + " " + q.Title + "** — " +
			strconv.FormatUint(q.Reward, 10) + " reputation · " + q.Status.String() +
			" · posted by " + q.Poster.String() + "\n")
	}
	b.WriteString("\n")
	b.WriteString(renderLeaderboard())
	return b.String()
}

func renderQuest(q *Quest) string {
	var b strings.Builder
	b.WriteString("# Quest #" + strconv.FormatUint(q.ID, 10) + ": " + q.Title + "\n\n")
	b.WriteString(q.Description + "\n\n")
	b.WriteString("- Reward: " + strconv.FormatUint(q.Reward, 10) + " reputation\n")
	b.WriteString("- Status: " + q.Status.String() + "\n")
	b.WriteString("- Poster: " + q.Poster.String() + "\n")
	if q.Claimer != address("") {
		b.WriteString("- Claimer: " + q.Claimer.String() + "\n")
	}
	return b.String()
}

func renderLeaderboard() string {
	var b strings.Builder
	b.WriteString("## Adventurers by reputation\n\n")
	if len(reputation) == 0 {
		b.WriteString("No reputation earned yet. Complete a quest to appear here.\n")
		return b.String()
	}
	addrs := make([]address, 0, len(reputation))
	for a := range reputation {
		addrs = append(addrs, a)
	}
	// Insertion sort by reputation, descending (boards are small).
	for i := 1; i < len(addrs); i++ {
		for j := i; j > 0 && reputation[addrs[j]] > reputation[addrs[j-1]]; j-- {
			addrs[j], addrs[j-1] = addrs[j-1], addrs[j]
		}
	}
	for i, a := range addrs {
		b.WriteString(strconv.Itoa(i+1) + ". " + a.String() + " — " +
			strconv.FormatUint(reputation[a], 10) + " reputation\n")
	}
	return b.String()
}
