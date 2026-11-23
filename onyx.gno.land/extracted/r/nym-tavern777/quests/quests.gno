// Package quests is the Tavern Quests realm: an on-chain quest board
// where anyone can post a task with GNOT escrowed in the realm, another
// user claims and delivers it, and the poster releases the escrow on
// approval — a working bounty market that lives entirely in one realm
// and renders its board in gnoweb.
//
// All lifecycle rules (who may act, which transitions are legal) live in
// the pure package gno.land/p/nym-tavern777/escrow; this realm only stores the
// records, verifies the payment attached to a new quest, and moves coins
// when the state machine reaches a payout or refund transition.
package quests

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nym-tavern777/escrow"
)

// denom is the only coin this board escrows: GNOT's base denom.
const denom = "ugnot"

var (
	quests  []*escrow.Quest
	counter int64
)

// PostQuest creates a quest, escrowing the ugnot sent with the call as
// the reward. The call must carry exactly one coin type (ugnot); the
// realm holds it until ApproveQuest pays the claimant or CancelQuest
// refunds the poster.
//
// Only a direct user call (maketx call) is accepted: OriginSend describes
// a real payment to this realm only when the caller is a pure EOA. An
// intermediate realm could otherwise consume the send envelope elsewhere
// and have this realm record a phantom escrow against its own balance.
func PostQuest(cur realm, title string, description string) int64 {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	poster := cur.Previous().Address()

	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom {
		panic("send exactly " + denom + " as the quest reward")
	}
	reward := sent[0].Amount

	if err := escrow.ValidateNew(title, description, reward); err != nil {
		panic(err.Error())
	}

	counter++
	q := &escrow.Quest{
		ID:          counter,
		Poster:      poster,
		Title:       title,
		Description: description,
		Reward:      reward,
		Status:      escrow.Open,
	}
	quests = append(quests, q)
	return q.ID
}

// ClaimQuest claims an open quest for the caller. One claimant per quest;
// the poster cannot claim their own quest.
func ClaimQuest(cur realm, id int64) {
	caller := cur.Previous().Address()
	q := mustGet(id)
	if err := escrow.Claim(q, caller); err != nil {
		panic(err.Error())
	}
}

// SubmitWork records the claimant's delivery note (a link or reference
// to the delivered work) and marks the quest submitted.
func SubmitWork(cur realm, id int64, note string) {
	caller := cur.Previous().Address()
	q := mustGet(id)
	if err := escrow.Submit(q, caller, note); err != nil {
		panic(err.Error())
	}
}

// ApproveQuest releases the escrowed reward to the claimant. Poster only,
// and only after work has been submitted.
func ApproveQuest(cur realm, id int64) {
	caller := cur.Previous().Address()
	q := mustGet(id)
	if err := escrow.Approve(q, caller); err != nil {
		panic(err.Error())
	}
	pay(cur, q.Claimant, q.Reward)
}

// RejectQuest sends a submitted quest back to the claimant for another
// attempt, clearing the delivery note. Poster only.
func RejectQuest(cur realm, id int64) {
	caller := cur.Previous().Address()
	q := mustGet(id)
	if err := escrow.Reject(q, caller); err != nil {
		panic(err.Error())
	}
}

// CancelQuest closes an open (not yet claimed) quest and refunds the
// escrowed reward to the poster. Poster only.
func CancelQuest(cur realm, id int64) {
	caller := cur.Previous().Address()
	q := mustGet(id)
	if err := escrow.Cancel(q, caller); err != nil {
		panic(err.Error())
	}
	pay(cur, q.Poster, q.Reward)
}

// pay sends amt ugnot out of the realm's own balance.
func pay(cur realm, to address, amt int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{{Denom: denom, Amount: amt}})
}

func mustGet(id int64) *escrow.Quest {
	if id < 1 || id > int64(len(quests)) {
		panic("unknown quest id")
	}
	return quests[id-1]
}

// Render draws the board for gnoweb: with no path, the quest list grouped
// by status with counts; with a quest id as path, that quest's detail.
func Render(path string) string {
	if path != "" {
		id, err := strconv.ParseInt(path, 10, 64)
		if err != nil || id < 1 || id > int64(len(quests)) {
			return "# Tavern Quests\n\nUnknown quest: " + sanitizeInline(path) + "\n"
		}
		return renderQuest(quests[id-1])
	}

	var open, claimed, submitted, completed, cancelled int
	for _, q := range quests {
		switch q.Status {
		case escrow.Open:
			open++
		case escrow.Claimed:
			claimed++
		case escrow.Submitted:
			submitted++
		case escrow.Completed:
			completed++
		case escrow.Cancelled:
			cancelled++
		}
	}

	var sb strings.Builder
	sb.WriteString("# Tavern Quests\n\n")
	sb.WriteString("Post a task with GNOT in escrow, claim someone else's, get paid on delivery.\n\n")
	sb.WriteString("**" + strconv.Itoa(len(quests)) + " quests** — " +
		strconv.Itoa(open) + " open · " +
		strconv.Itoa(claimed) + " claimed · " +
		strconv.Itoa(submitted) + " submitted · " +
		strconv.Itoa(completed) + " completed · " +
		strconv.Itoa(cancelled) + " cancelled\n\n")

	if len(quests) == 0 {
		sb.WriteString("No quests yet. Post the first one.\n")
		return sb.String()
	}

	sb.WriteString("## Quests\n\n")
	// Newest first.
	for i := len(quests) - 1; i >= 0; i-- {
		q := quests[i]
		id := strconv.FormatInt(q.ID, 10)
		sb.WriteString("- [" + q.Status.String() + " #" + id + "](" + id + ") — " +
			sanitizeInline(q.Title) + " — reward **" + formatReward(q.Reward) +
			"** — poster " + q.Poster.String() + "\n")
	}
	return sb.String()
}

func renderQuest(q *escrow.Quest) string {
	var sb strings.Builder
	sb.WriteString("# Quest #" + strconv.FormatInt(q.ID, 10) + " — " + sanitizeInline(q.Title) + "\n\n")
	sb.WriteString("- Status: **" + q.Status.String() + "**\n")
	sb.WriteString("- Reward: **" + formatReward(q.Reward) + "** (escrowed in this realm)\n")
	sb.WriteString("- Poster: " + q.Poster.String() + "\n")
	if q.Claimant != "" {
		sb.WriteString("- Claimant: " + q.Claimant.String() + "\n")
	}
	if q.Description != "" {
		sb.WriteString("\n## Description\n\n")
		sb.WriteString(sanitizeBlock(q.Description))
		sb.WriteString("\n")
	}
	if q.Submission != "" {
		sb.WriteString("\n## Submission\n\n")
		sb.WriteString(sanitizeBlock(q.Submission))
		sb.WriteString("\n")
	}
	sb.WriteString("\n[← Back to the board](./)\n")
	return sb.String()
}

// formatReward renders a ugnot amount as a decimal GNOT string.
func formatReward(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	fracStr = strings.TrimRight(fracStr, "0")
	return strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

// sanitizeInline makes user-supplied text safe to embed in a markdown
// line: it escapes markdown control characters and flattens newlines, so
// a crafted title cannot break the board layout or inject headings/links.
func sanitizeInline(s string) string {
	r := strings.NewReplacer(
		"\\", "\\\\",
		"`", "\\`",
		"*", "\\*",
		"_", "\\_",
		"[", "\\[",
		"]", "\\]",
		"<", "&lt;",
		">", "&gt;",
		"|", "\\|",
		"\r", " ",
		"\n", " ",
	)
	return r.Replace(s)
}

// sanitizeBlock is sanitizeInline for multi-line text: newlines are kept
// (they are paragraph structure, not layout attacks), control characters
// are still escaped.
func sanitizeBlock(s string) string {
	r := strings.NewReplacer(
		"\\", "\\\\",
		"`", "\\`",
		"*", "\\*",
		"_", "\\_",
		"[", "\\[",
		"]", "\\]",
		"<", "&lt;",
		">", "&gt;",
	)
	return r.Replace(s)
}
