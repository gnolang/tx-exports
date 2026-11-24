package tankardtales

import (
	"bytes"
	"sort"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

// BaseURL is the realm's gnoweb path. It must match the module path in
// gnomod.toml (minus the gno.land prefix) — if the deploy path changes,
// change both together.
const BaseURL = "/r/nym-kaycee042/tankardtales"

var router = mux.NewRouter()

func init() {
	router.HandleFunc("", homeHandler)
	router.HandleFunc("quests", questsHandler)
	router.HandleFunc("quests/{id}", questHandler)
	router.HandleFunc("guestbook", guestbookHandler)
	router.HandleFunc("regulars", regularsHandler)
}

// Render is the realm's gnoweb entry point.
func Render(path string) string {
	return router.Render(path)
}

// tipString formats an amount of ugnot for display.
func tipString(amt int64) string {
	if amt >= 1_000_000 && amt%1_000_000 == 0 {
		return ufmt.Sprintf("%d GNOT", amt/1_000_000)
	}
	return ufmt.Sprintf("%d ugnot", amt)
}

func homeHandler(res *mux.ResponseWriter, req *mux.Request) {
	var b bytes.Buffer

	b.WriteString("# Tankard & Tales\n\n")
	b.WriteString("Welcome to the tavern, traveller. Sign the guestbook, " +
		"take a quest from the board, and earn real testnet GNOT for honest work — " +
		"every tip is held in escrow by this realm and paid out on completion.\n\n")

	b.WriteString("## The tavern tonight\n\n")
	b.WriteString(ufmt.Sprintf("- Quests posted: **%d** (%d live)\n", QuestCount(), OpenQuestCount()))
	b.WriteString(ufmt.Sprintf("- Guests in the book: **%d**\n", GuestCount()))
	b.WriteString(ufmt.Sprintf("- Tips in escrow: **%s**\n\n", tipString(EscrowUgnot())))

	b.WriteString("## Pull up a stool\n\n")
	b.WriteString(ufmt.Sprintf("- [Sign the guestbook](%s$help&func=SignGuestbook)\n", BaseURL))
	b.WriteString(ufmt.Sprintf("- [Post a quest](%s$help&func=PostQuest) — attach the tip with your call\n", BaseURL))
	b.WriteString(ufmt.Sprintf("- [Browse the quest board](%s:quests)\n", BaseURL))
	b.WriteString(ufmt.Sprintf("- [Read the guestbook](%s:guestbook)\n", BaseURL))
	b.WriteString(ufmt.Sprintf("- [Meet the regulars](%s:regulars)\n\n", BaseURL))

	latest := latestQuests(5)
	if len(latest) > 0 {
		b.WriteString("## Fresh on the board\n\n")
		for _, q := range latest {
			writeQuestLine(&b, q)
		}
	}

	res.Write(b.String())
}

func questsHandler(res *mux.ResponseWriter, req *mux.Request) {
	var b bytes.Buffer

	b.WriteString("# The Quest Board\n\n")
	b.WriteString(ufmt.Sprintf("Every notice here carries a tip locked in escrow. " +
		"Claim one, do the work, and the poster releases the tip to you.\n\n"))
	b.WriteString(ufmt.Sprintf("[Post your own quest](%s$help&func=PostQuest)\n\n", BaseURL))

	qs := latestQuests(25)
	if len(qs) == 0 {
		b.WriteString("The board is bare. Nail up the first quest.\n")
	}
	for _, q := range qs {
		writeQuestLine(&b, q)
	}

	res.Write(b.String())
}

func questHandler(res *mux.ResponseWriter, req *mux.Request) {
	var b bytes.Buffer
	id := req.GetVar("id")

	v := questsTree.Get(id)
	if v == nil {
		b.WriteString("# No such quest\n\n")
		b.WriteString(ufmt.Sprintf("There is no quest #%s on this board. [Back to the board](%s:quests)\n", sanitize.InlineText(id), BaseURL))
		res.Write(b.String())
		return
	}
	q := v.(*Quest)

	b.WriteString(ufmt.Sprintf("# Quest #%d: %s\n\n", q.ID, sanitize.InlineText(q.Title)))
	b.WriteString(ufmt.Sprintf("- Status: **%s**\n", q.Status))
	b.WriteString(ufmt.Sprintf("- Tip: **%s** (in escrow)\n", tipString(q.Tip)))
	b.WriteString(ufmt.Sprintf("- Posted by: %s\n", q.Poster.String()))
	if q.Claimer != address("") {
		b.WriteString(ufmt.Sprintf("- Claimed by: %s\n", q.Claimer.String()))
	}
	b.WriteString("\n")
	b.WriteString(sanitize.Block(q.Details))
	b.WriteString("\n\n")

	switch q.Status {
	case StatusOpen:
		b.WriteString(ufmt.Sprintf("[Claim this quest](%s$help&func=ClaimQuest&id=%d)\n", BaseURL, q.ID))
	case StatusClaimed:
		b.WriteString(ufmt.Sprintf("If you posted this quest and the work is done: [mark it complete](%s$help&func=CompleteQuest&id=%d) to release the tip.\n", BaseURL, q.ID))
	}

	res.Write(b.String())
}

func guestbookHandler(res *mux.ResponseWriter, req *mux.Request) {
	var b bytes.Buffer

	b.WriteString("# The Guestbook\n\n")
	b.WriteString(ufmt.Sprintf("[Sign the guestbook](%s$help&func=SignGuestbook)\n\n", BaseURL))

	entries := sortedGuests(50)
	if len(entries) == 0 {
		b.WriteString("No signatures yet. The first round is on the house.\n")
	}
	for _, e := range entries {
		b.WriteString(ufmt.Sprintf("- **%s** — %s\n",
			sanitize.InlineText(e.entry.Name),
			sanitize.InlineText(e.entry.Message),
		))
	}

	res.Write(b.String())
}

func regularsHandler(res *mux.ResponseWriter, req *mux.Request) {
	var b bytes.Buffer

	b.WriteString("# The Regulars\n\n")
	b.WriteString("Ranked by tips earned. Complete quests, climb the board, " +
		"become a tavern legend.\n\n")

	regs := sortedRegulars(20)
	if len(regs) == 0 {
		b.WriteString("No regulars yet. The stools are empty and waiting.\n")
	}
	for i, r := range regs {
		b.WriteString(ufmt.Sprintf("%d. %s — %d quests done, %s earned, %d posted\n",
			i+1, r.addr, r.reg.QuestsDone, tipString(r.reg.TipsEarned), r.reg.QuestsPosted))
	}

	res.Write(b.String())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func writeQuestLine(b *bytes.Buffer, q *Quest) {
	b.WriteString(ufmt.Sprintf("- [#%d %s](%s:quests/%d) — %s — **%s** — posted by %s\n",
		q.ID,
		sanitize.InlineText(q.Title),
		BaseURL, q.ID,
		q.Status,
		tipString(q.Tip),
		q.Poster.String(),
	))
}

// Sortable views over the realm's rows. Gno's sort package offers the
// classic Interface-based API (no sort.Slice), so each row type gets a
// small named slice type implementing Len/Less/Swap.

type questsByIDDesc []*Quest

func (s questsByIDDesc) Len() int           { return len(s) }
func (s questsByIDDesc) Less(i, j int) bool { return s[i].ID > s[j].ID }
func (s questsByIDDesc) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }

// latestQuests returns up to n quests, newest first.
func latestQuests(n int) []*Quest {
	qs := allQuests()
	sort.Sort(questsByIDDesc(qs))
	if len(qs) > n {
		qs = qs[:n]
	}
	return qs
}

type guestRow struct {
	addr  string
	entry *GuestEntry
}

type guestRows []guestRow

func (s guestRows) Len() int { return len(s) }
func (s guestRows) Less(i, j int) bool {
	if s[i].entry.Signs != s[j].entry.Signs {
		return s[i].entry.Signs > s[j].entry.Signs
	}
	return s[i].addr < s[j].addr
}
func (s guestRows) Swap(i, j int) { s[i], s[j] = s[j], s[i] }

// sortedGuests returns guestbook entries, most visits first.
func sortedGuests(n int) []guestRow {
	rows := make([]guestRow, 0, guestbookTree.Size())
	guestbookTree.Iterate("", "", func(key string, v any) bool {
		rows = append(rows, guestRow{addr: key, entry: v.(*GuestEntry)})
		return false
	})
	sort.Sort(guestRows(rows))
	if len(rows) > n {
		rows = rows[:n]
	}
	return rows
}

type regularRow struct {
	addr string
	reg  *Regular
}

type regularRows []regularRow

func (s regularRows) Len() int { return len(s) }
func (s regularRows) Less(i, j int) bool {
	if s[i].reg.TipsEarned != s[j].reg.TipsEarned {
		return s[i].reg.TipsEarned > s[j].reg.TipsEarned
	}
	if s[i].reg.QuestsDone != s[j].reg.QuestsDone {
		return s[i].reg.QuestsDone > s[j].reg.QuestsDone
	}
	return s[i].addr < s[j].addr
}
func (s regularRows) Swap(i, j int) { s[i], s[j] = s[j], s[i] }

// sortedRegulars returns the leaderboard: tips earned, then quests done.
func sortedRegulars(n int) []regularRow {
	rows := make([]regularRow, 0, regularsTree.Size())
	regularsTree.Iterate("", "", func(key string, v any) bool {
		rows = append(rows, regularRow{addr: key, reg: v.(*Regular)})
		return false
	})
	sort.Sort(regularRows(rows))
	if len(rows) > n {
		rows = rows[:n]
	}
	return rows
}
