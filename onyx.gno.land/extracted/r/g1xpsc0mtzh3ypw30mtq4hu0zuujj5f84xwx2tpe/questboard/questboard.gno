// QuestBoard is a tavern-style quest board for gno.land.
//
// Anyone can post a quest with a GNOT reward. The reward is escrowed by
// this realm the moment the quest is posted: the coins sent with the
// PostQuest call stay in the realm's account until the quest is paid out
// or cancelled. Another account claims the quest, does the work, marks it
// done, and the poster approves the hand-in to release the escrow. If a
// quest is still open, its poster can cancel it and take the escrow back.
//
// The board is the realm's Render output: the realm page lists every
// quest, and Render("quest/<id>") shows one quest in full.
package questboard

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

// Quest status values.
const (
	StatusOpen      = "open"      // posted, waiting for a claimer
	StatusClaimed   = "claimed"   // a claimer is working on it
	StatusDone      = "done"      // claimer marked the work done
	StatusPaid      = "paid"      // poster approved, escrow released
	StatusCancelled = "cancelled" // poster cancelled while open, escrow refunded
)

type Quest struct {
	ID      uint64
	Poster  address
	Claimer address
	Title   string
	Desc    string
	Reward  int64 // ugnot held in escrow by this realm
	Status  string
}

var (
	quests  []*Quest
	nextID  uint64 = 1
	paidOut int64  // total ugnot ever released to claimers
)

// PostQuest posts a new quest. The ugnot sent with the call becomes the
// escrowed reward, so the reward can never be promised without being
// funded. Returns the new quest's id.
func PostQuest(cur realm, title string, desc string) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	title = strings.TrimSpace(title)
	if title == "" {
		panic("a quest needs a title")
	}
	if len(title) > 140 {
		panic("title is over 140 characters")
	}
	if len(desc) > 2000 {
		panic("description is over 2000 characters")
	}
	reward := ugnotSent()
	if reward <= 0 {
		panic("send ugnot with the call: the amount sent is the quest's reward")
	}
	q := &Quest{
		ID:     nextID,
		Poster: cur.Previous().Address(),
		Title:  title,
		Desc:   desc,
		Reward: reward,
		Status: StatusOpen,
	}
	nextID++
	quests = append(quests, q)
	return q.ID
}

// ClaimQuest claims an open quest for the caller. One claimer at a time:
// a claimed quest cannot be claimed again until it is finished.
func ClaimQuest(cur realm, id uint64) {
	q := find(id)
	caller := cur.Previous().Address()
	if q.Status != StatusOpen {
		panic("quest " + strconv.FormatUint(id, 10) + " is not open")
	}
	if q.Poster == caller {
		panic("the poster cannot claim their own quest")
	}
	q.Claimer = caller
	q.Status = StatusClaimed
}

// SubmitWork marks a claimed quest done. Only its claimer can do this.
func SubmitWork(cur realm, id uint64) {
	q := find(id)
	if q.Status != StatusClaimed {
		panic("quest is not in claimed state")
	}
	if q.Claimer != cur.Previous().Address() {
		panic("only the claimer can submit the work")
	}
	q.Status = StatusDone
}

// ApproveQuest releases the escrowed reward to the claimer. Only the
// poster can approve, and only after the claimer marked the work done.
func ApproveQuest(cur realm, id uint64) {
	q := find(id)
	if q.Poster != cur.Previous().Address() {
		panic("only the poster can approve the hand-in")
	}
	if q.Status != StatusDone {
		panic("quest is not waiting for approval")
	}
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	banker_.SendCoins(cur.Address(), q.Claimer, chain.NewCoins(chain.NewCoin("ugnot", q.Reward)))
	q.Status = StatusPaid
	paidOut += q.Reward
}

// CancelQuest cancels an open quest and refunds the escrow to its poster.
// A claimed quest cannot be cancelled: the claimer's work is protected
// once they have taken the quest on.
func CancelQuest(cur realm, id uint64) {
	q := find(id)
	if q.Poster != cur.Previous().Address() {
		panic("only the poster can cancel the quest")
	}
	if q.Status != StatusOpen {
		panic("only an open quest can be cancelled")
	}
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	banker_.SendCoins(cur.Address(), q.Poster, chain.NewCoins(chain.NewCoin("ugnot", q.Reward)))
	q.Status = StatusCancelled
}

// GetQuest returns one quest's fields for other realms and tooling.
func GetQuest(id uint64) (poster address, claimer address, title string, reward int64, status string) {
	q := find(id)
	return q.Poster, q.Claimer, q.Title, q.Reward, q.Status
}

// QuestCount returns how many quests have ever been posted.
func QuestCount() int {
	return len(quests)
}

func Render(path string) string {
	if strings.HasPrefix(path, "quest/") {
		idStr := strings.TrimPrefix(path, "quest/")
		id, err := strconv.ParseUint(idStr, 10, 64)
		if err != nil {
			return "# QuestBoard\n\nNo such quest.\n"
		}
		return renderQuest(findOrNil(id))
	}
	var b strings.Builder
	b.WriteString("# QuestBoard\n\n")
	b.WriteString("A tavern board of quests with escrowed GNOT rewards. Post a quest with `PostQuest` (the ugnot sent with the call is the reward), claim one with `ClaimQuest`, mark it done with `SubmitWork`, and the poster releases the escrow with `ApproveQuest`.\n\n")
	b.WriteString("Quests posted: " + strconv.Itoa(len(quests)) +
		" · Rewards paid out so far: " + formatGnot(paidOut) + "\n\n")
	if len(quests) == 0 {
		b.WriteString("The board is empty. Be the first to post a quest.\n")
		return b.String()
	}
	b.WriteString("| # | Quest | Reward | Status | Poster |\n")
	b.WriteString("|---|-------|--------|--------|--------|\n")
	for _, q := range quests {
		b.WriteString("| " + strconv.FormatUint(q.ID, 10) +
			" | [" + sanitizeInline(q.Title) + "](quest/" + strconv.FormatUint(q.ID, 10) + ")" +
			" | " + formatGnot(q.Reward) +
			" | " + q.Status +
			" | " + string(q.Poster) + " |\n")
	}
	return b.String()
}

func renderQuest(q *Quest) string {
	if q == nil {
		return "# QuestBoard\n\nNo such quest.\n"
	}
	var b strings.Builder
	b.WriteString("# Quest " + strconv.FormatUint(q.ID, 10) + ": " + sanitizeInline(q.Title) + "\n\n")
	if q.Desc != "" {
		b.WriteString(sanitizeInline(q.Desc) + "\n\n")
	}
	b.WriteString("- Reward (escrowed): " + formatGnot(q.Reward) + "\n")
	b.WriteString("- Status: " + q.Status + "\n")
	b.WriteString("- Poster: " + string(q.Poster) + "\n")
	if q.Claimer != "" {
		b.WriteString("- Claimer: " + string(q.Claimer) + "\n")
	}
	b.WriteString("\n[Back to the board]()\n")
	return b.String()
}

func find(id uint64) *Quest {
	q := findOrNil(id)
	if q == nil {
		panic("no quest with id " + strconv.FormatUint(id, 10))
	}
	return q
}

func findOrNil(id uint64) *Quest {
	for _, q := range quests {
		if q.ID == id {
			return q
		}
	}
	return nil
}

// sanitizeInline flattens user-supplied text for markdown output: Render
// paths and stored titles/descriptions are attacker-controlled, so the
// characters that could break out of a table cell, a link label or a
// paragraph are neutralised before anything is written to the page.
func sanitizeInline(s string) string {
	r := strings.NewReplacer(
		"[", "(",
		"]", ")",
		"|", "/",
		"`", "'",
		"<", "(",
		">", ")",
		"\n", " ",
		"\r", " ",
	)
	return r.Replace(s)
}

// ugnotSent returns how much ugnot the current call carried in.
func ugnotSent() int64 {
	for _, c := range unsafe.OriginSend() {
		if c.Denom == "ugnot" {
			return c.Amount
		}
	}
	return 0
}

// formatGnot renders a ugnot amount as a GNOT amount (1 GNOT = 1e6 ugnot).
func formatGnot(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fracStr := strconv.FormatInt(frac+1_000_000, 10)[1:]
	fracStr = strings.TrimRight(fracStr, "0")
	return strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}
