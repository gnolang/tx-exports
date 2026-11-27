// Package questboard implements the Tavern Quest Board: an on-chain
// bounty board for the Gnome Tavern.
//
// Anyone can post a quest with a reward in ugnot. The reward is paid
// together with the posting transaction and is held in escrow by this
// realm. Another user (the "adventurer") accepts the quest, does the
// work off-chain, and the poster releases the escrowed reward by
// completing the quest. If nobody completes the quest before its
// deadline, the poster can reclaim the escrow in full.
//
// State machine per quest:
//
//	Open --AcceptQuest--> Accepted --CompleteQuest--> Completed (paid)
//	Open --CancelQuest--> Cancelled (refunded)
//	Open|Accepted --ClaimRefund, after deadline--> Expired (refunded)
package questboard

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"time"
)

// Quest lifecycle statuses.
const (
	StatusOpen      uint8 = 0
	StatusAccepted  uint8 = 1
	StatusCompleted uint8 = 2
	StatusCancelled uint8 = 3
	StatusExpired   uint8 = 4
)

// Validation bounds.
const (
	minRewardUgnot  int64 = 1000              // 0.001 GNOT: avoid dust quests
	maxRewardUgnot  int64 = 1000000000000     // 1,000,000 GNOT sanity cap
	maxTitleLen           = 80                // bytes
	maxDescLen            = 512               // bytes
	maxQuestSeconds int64 = 90 * 24 * 60 * 60 // deadlines at most ~90 days out
	ugnotPerGNOT    int64 = 1000000
)

// Quest is a single bounty posting. Quests are never deleted; the
// slice index is always ID-1.
type Quest struct {
	ID          uint64
	Poster      address
	Adventurer  address // zero address until accepted
	Title       string
	Description string
	Reward      int64 // ugnot held in escrow while Open/Accepted
	Deadline    int64 // unix seconds; accept/complete must happen by then
	CreatedAt   int64 // unix seconds
	Status      uint8
}

var (
	quests   []*Quest
	escrowed int64 // sum of Reward over all Open/Accepted quests
)

// ---------------------------------------------------------------------------
// Exported crossing functions (callable via gnokey / gnoweb Actions)
// ---------------------------------------------------------------------------

// PostQuest creates a quest and escrows its reward. The caller must
// attach exactly `reward` ugnot to the call (gnokey: -send <reward>ugnot).
func PostQuest(cur realm, title string, description string, reward int64, deadline int64) uint64 {
	// Payment verification follows the canonical pattern: the caller
	// must be a direct user call, and the ugnot amount is read from
	// this message's send envelope (chain/runtime/unsafe.OriginSend).
	if !cur.Previous().IsUserCall() {
		panic("questboard: PostQuest must be a direct user call")
	}
	sent := unsafe.OriginSend().AmountOf("ugnot")
	poster := cur.Previous().Address()
	return postQuest(poster, title, description, reward, deadline, sent, time.Now().Unix())
}

// AcceptQuest takes an open quest. The poster cannot accept their own
// quest, and an expired quest cannot be accepted.
func AcceptQuest(cur realm, id uint64) {
	caller := cur.Previous().Address()
	acceptQuest(caller, id, time.Now().Unix())
}

// CompleteQuest is called by the poster once the adventurer has done
// the work. It releases the full escrowed reward to the adventurer.
func CompleteQuest(cur realm, id uint64) {
	caller := cur.Previous().Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	completeQuest(caller, id, b, cur.Address())
}

// CancelQuest is called by the poster to withdraw a quest that nobody
// has accepted yet. The escrowed reward is refunded in full.
func CancelQuest(cur realm, id uint64) {
	caller := cur.Previous().Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	cancelQuest(caller, id, b, cur.Address())
}

// ClaimRefund is called by the poster after the deadline has passed
// without completion. The escrowed reward is refunded in full.
func ClaimRefund(cur realm, id uint64) {
	caller := cur.Previous().Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	claimRefund(caller, id, time.Now().Unix(), b, cur.Address())
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

// QuestCount returns the total number of quests ever posted.
func QuestCount() int {
	return len(quests)
}

// OpenQuestCount returns the number of quests currently Open.
func OpenQuestCount() int {
	n := 0
	for _, q := range quests {
		if q.Status == StatusOpen {
			n++
		}
	}
	return n
}

// EscrowedTotal returns the ugnot currently locked in escrow.
func EscrowedTotal() int64 {
	return escrowed
}

// GetQuest returns a one-line summary of a quest, or "" for unknown IDs.
func GetQuest(id uint64) string {
	q := findQuest(id)
	if q == nil {
		return ""
	}
	return "#" + strconv.FormatInt(int64(q.ID), 10) +
		" [" + StatusName(q.Status) + "] " + q.Title +
		" — reward " + FormatGNOT(q.Reward) +
		", poster " + q.Poster.String() +
		", adventurer " + addrOrDash(q.Adventurer) +
		", deadline " + strconv.FormatInt(q.Deadline, 10)
}

// StatusName maps a status code to its display name.
func StatusName(s uint8) string {
	switch s {
	case StatusOpen:
		return "OPEN"
	case StatusAccepted:
		return "ACCEPTED"
	case StatusCompleted:
		return "COMPLETED"
	case StatusCancelled:
		return "CANCELLED"
	case StatusExpired:
		return "EXPIRED"
	}
	return "UNKNOWN"
}

// FormatGNOT renders a ugnot amount as a GNOT decimal string,
// e.g. 1500000 -> "1.5 GNOT".
func FormatGNOT(ugnot int64) string {
	whole := ugnot / ugnotPerGNOT
	frac := ugnot % ugnotPerGNOT
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	for len(fracStr) > 0 && fracStr[len(fracStr)-1] == '0' {
		fracStr = fracStr[:len(fracStr)-1]
	}
	return strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

// ---------------------------------------------------------------------------
// Internal logic. These functions take the caller, the paid amount, the
// current time and a banker explicitly, so the full state machine can
// be unit-tested without a chain (see questboard_test.gno).
// ---------------------------------------------------------------------------

func postQuest(poster address, title string, description string, reward int64, deadline int64, sent int64, now int64) uint64 {
	if len(title) == 0 || len(title) > maxTitleLen {
		panic("questboard: title must be 1-80 bytes")
	}
	if len(description) > maxDescLen {
		panic("questboard: description must be at most 512 bytes")
	}
	if reward < minRewardUgnot {
		panic("questboard: reward below minimum of 1000ugnot")
	}
	if reward > maxRewardUgnot {
		panic("questboard: reward above maximum")
	}
	if deadline <= now {
		panic("questboard: deadline must be in the future")
	}
	if deadline > now+maxQuestSeconds {
		panic("questboard: deadline more than 90 days out")
	}
	if sent != reward {
		panic("questboard: attached payment must equal the reward exactly")
	}

	q := &Quest{
		ID:          uint64(len(quests)) + 1,
		Poster:      poster,
		Title:       title,
		Description: description,
		Reward:      reward,
		Deadline:    deadline,
		CreatedAt:   now,
		Status:      StatusOpen,
	}
	quests = append(quests, q)
	escrowed += reward

	chain.Emit("QuestPosted",
		"id", strconv.FormatInt(int64(q.ID), 10),
		"poster", poster.String(),
		"reward", strconv.FormatInt(reward, 10),
		"deadline", strconv.FormatInt(deadline, 10))
	return q.ID
}

func acceptQuest(adventurer address, id uint64, now int64) {
	q := mustQuest(id)
	if q.Status != StatusOpen {
		panic("questboard: quest is not open")
	}
	if adventurer == q.Poster {
		panic("questboard: poster cannot accept their own quest")
	}
	if now > q.Deadline {
		panic("questboard: quest deadline has passed")
	}
	q.Adventurer = adventurer
	q.Status = StatusAccepted

	chain.Emit("QuestAccepted",
		"id", strconv.FormatInt(int64(q.ID), 10),
		"adventurer", adventurer.String())
}

func completeQuest(caller address, id uint64, b banker.Banker, realmAddr address) {
	q := mustQuest(id)
	if q.Status != StatusAccepted {
		panic("questboard: quest is not in accepted state")
	}
	if caller != q.Poster {
		panic("questboard: only the poster can complete the quest")
	}
	// Checks-effects-interactions: settle state before moving coins.
	q.Status = StatusCompleted
	escrowed -= q.Reward
	b.SendCoins(realmAddr, q.Adventurer, chain.NewCoins(chain.NewCoin("ugnot", q.Reward)))

	chain.Emit("QuestCompleted",
		"id", strconv.FormatInt(int64(q.ID), 10),
		"adventurer", q.Adventurer.String(),
		"reward", strconv.FormatInt(q.Reward, 10))
}

func cancelQuest(caller address, id uint64, b banker.Banker, realmAddr address) {
	q := mustQuest(id)
	if q.Status != StatusOpen {
		panic("questboard: only an open quest can be cancelled")
	}
	if caller != q.Poster {
		panic("questboard: only the poster can cancel the quest")
	}
	q.Status = StatusCancelled
	escrowed -= q.Reward
	b.SendCoins(realmAddr, q.Poster, chain.NewCoins(chain.NewCoin("ugnot", q.Reward)))

	chain.Emit("QuestCancelled",
		"id", strconv.FormatInt(int64(q.ID), 10),
		"poster", q.Poster.String(),
		"reward", strconv.FormatInt(q.Reward, 10))
}

func claimRefund(caller address, id uint64, now int64, b banker.Banker, realmAddr address) {
	q := mustQuest(id)
	if q.Status != StatusOpen && q.Status != StatusAccepted {
		panic("questboard: quest is not refundable")
	}
	if caller != q.Poster {
		panic("questboard: only the poster can claim a refund")
	}
	if now <= q.Deadline {
		panic("questboard: quest deadline has not passed yet")
	}
	q.Status = StatusExpired
	escrowed -= q.Reward
	b.SendCoins(realmAddr, q.Poster, chain.NewCoins(chain.NewCoin("ugnot", q.Reward)))

	chain.Emit("QuestRefunded",
		"id", strconv.FormatInt(int64(q.ID), 10),
		"poster", q.Poster.String(),
		"reward", strconv.FormatInt(q.Reward, 10))
}

func findQuest(id uint64) *Quest {
	if id == 0 || id > uint64(len(quests)) {
		return nil
	}
	return quests[id-1]
}

func mustQuest(id uint64) *Quest {
	q := findQuest(id)
	if q == nil {
		panic("questboard: quest not found")
	}
	return q
}

func addrOrDash(a address) string {
	if a == address("") {
		return "-"
	}
	return a.String()
}
