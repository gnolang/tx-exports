package tankardtales

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// Posting a quest (the only function that takes money)
// ---------------------------------------------------------------------------

// PostQuest pins a new quest to the board and locks its tip in escrow.
//
// The tip must arrive with the call itself: the caller attaches exactly
// `tip` ugnot via `maketx call -send <tip>ugnot`. Following the upstream
// payment-verification pattern, the call must come straight from a user
// (no intermediate or ephemeral realm may touch the send envelope first)
// and the envelope must contain exactly the declared tip — no more, no
// less, and nothing in any other denom. The coins land in the realm's own
// account, where they sit until CompleteQuest pays them to the adventurer
// or CancelQuest refunds them to the poster.
//
// Returns the new quest's ID as a decimal string.
func PostQuest(cur realm, title, details string, tip int64) string {
	if !cur.Previous().IsUserCall() {
		panic("quest: PostQuest must be called directly by a user")
	}
	poster := cur.Previous().Address()

	verifyTipPayment(tip)

	id := postQuest(poster, title, details, tip)

	chain.Emit("QuestPosted",
		"id", strconv.Itoa(id),
		"poster", poster.String(),
		"tip", strconv.FormatInt(tip, 10),
	)
	return strconv.Itoa(id)
}

// verifyTipPayment checks that exactly `tip` ugnot was sent with the call.
func verifyTipPayment(tip int64) {
	if tip < MinTipUgnot {
		panic("quest: tip is below the minimum of 1000ugnot")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != tip {
		panic("quest: send exactly the tip amount in ugnot with this call")
	}
}

// postQuest is the state transition behind PostQuest, split out so the
// board logic can be unit-tested without a payment envelope.
func postQuest(poster address, title, details string, tip int64) int {
	title = strings.TrimSpace(title)
	details = strings.TrimSpace(details)
	if len(title) < 3 || len(title) > MaxTitleLen {
		panic("quest: title must be 3-80 characters")
	}
	if len(details) == 0 || len(details) > MaxDetailsLen {
		panic("quest: details must be 1-1000 characters")
	}
	if tip < MinTipUgnot {
		panic("quest: tip is below the minimum of 1000ugnot")
	}

	questSeq++
	q := &Quest{
		ID:      questSeq,
		Poster:  poster,
		Title:   title,
		Details: details,
		Tip:     tip,
		Status:  StatusOpen,
	}
	questsTree.Set(strconv.Itoa(q.ID), q)
	escrowUgnot += tip

	reg := regularOf(poster)
	reg.QuestsPosted++
	regularsTree.Set(poster.String(), reg)

	return q.ID
}

// ---------------------------------------------------------------------------
// Working a quest
// ---------------------------------------------------------------------------

// ClaimQuest makes the caller the one adventurer working on an open quest.
// A poster cannot claim their own quest — no paying yourself, friend.
func ClaimQuest(cur realm, id string) {
	caller := cur.Previous().Address()
	q := mustQuest(id)

	if q.Status != StatusOpen {
		panic("quest: not open for claiming")
	}
	if caller == q.Poster {
		panic("quest: you cannot claim your own quest")
	}

	q.Status = StatusClaimed
	q.Claimer = caller
	questsTree.Set(id, q)

	chain.Emit("QuestClaimed", "id", id, "claimer", caller.String())
}

// AbandonQuest releases a claimed quest back to the board. Only the
// current claimer may abandon it; the tip stays in escrow.
func AbandonQuest(cur realm, id string) {
	caller := cur.Previous().Address()
	q := mustQuest(id)

	if q.Status != StatusClaimed {
		panic("quest: not claimed")
	}
	if caller != q.Claimer {
		panic("quest: only the claimer can abandon this quest")
	}

	q.Status = StatusOpen
	q.Claimer = address("")
	questsTree.Set(id, q)

	chain.Emit("QuestAbandoned", "id", id, "claimer", caller.String())
}

// CompleteQuest is the poster confirming the work is done. The escrowed
// tip moves from the realm's account to the claimer, and the claimer's
// regulars tally grows. This is the moment the tavern lives for.
func CompleteQuest(cur realm, id string) {
	caller := cur.Previous().Address()
	q := mustQuest(id)

	if caller != q.Poster {
		panic("quest: only the poster can complete this quest")
	}
	if q.Status != StatusClaimed {
		panic("quest: not claimed, so it cannot be completed")
	}

	claimer := q.Claimer
	tip := q.Tip

	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	banker_.SendCoins(cur.Address(), claimer, chain.NewCoins(chain.NewCoin("ugnot", tip)))

	q.Status = StatusCompleted
	questsTree.Set(id, q)
	escrowUgnot -= tip

	reg := regularOf(claimer)
	reg.QuestsDone++
	reg.TipsEarned += tip
	regularsTree.Set(claimer.String(), reg)

	chain.Emit("QuestCompleted",
		"id", id,
		"claimer", claimer.String(),
		"tip", strconv.FormatInt(tip, 10),
	)
}

// CancelQuest takes an unclaimed quest off the board and refunds the
// escrowed tip to the poster. A claimed quest cannot be cancelled out
// from under its adventurer — they must abandon it first.
func CancelQuest(cur realm, id string) {
	caller := cur.Previous().Address()
	q := mustQuest(id)

	if caller != q.Poster {
		panic("quest: only the poster can cancel this quest")
	}
	if q.Status != StatusOpen {
		panic("quest: only an open (unclaimed) quest can be cancelled")
	}

	tip := q.Tip

	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	banker_.SendCoins(cur.Address(), q.Poster, chain.NewCoins(chain.NewCoin("ugnot", tip)))

	q.Status = StatusCancelled
	questsTree.Set(id, q)
	escrowUgnot -= tip

	chain.Emit("QuestCancelled",
		"id", id,
		"poster", q.Poster.String(),
		"tip", strconv.FormatInt(tip, 10),
	)
}

// ---------------------------------------------------------------------------
// Reading the board
// ---------------------------------------------------------------------------

// mustQuest loads a quest or panics trying.
func mustQuest(id string) *Quest {
	v := questsTree.Get(id)
	if v == nil {
		panic("quest: no quest with id " + id)
	}
	return v.(*Quest)
}

// GetQuest returns one quest's public fields.
func GetQuest(id string) (poster address, title, details string, tip int64, status string, claimer address, ok bool) {
	v := questsTree.Get(id)
	if v == nil {
		return "", "", "", 0, "", "", false
	}
	q := v.(*Quest)
	return q.Poster, q.Title, q.Details, q.Tip, q.Status, q.Claimer, true
}

// QuestCount returns how many quests have ever been posted.
func QuestCount() int {
	return questSeq
}

// OpenQuestCount returns how many quests are open or claimed right now.
func OpenQuestCount() int {
	n := 0
	questsTree.Iterate("", "", func(_ string, v any) bool {
		q := v.(*Quest)
		if q.Status == StatusOpen || q.Status == StatusClaimed {
			n++
		}
		return false
	})
	return n
}

// allQuests returns every quest, in posting order. Render paths sort and
// trim the result themselves; the board is small by design.
func allQuests() []*Quest {
	out := make([]*Quest, 0, questsTree.Size())
	questsTree.Iterate("", "", func(_ string, v any) bool {
		out = append(out, v.(*Quest))
		return false
	})
	return out
}
