package questmaster

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/escrow"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
)

// Pages (gnoweb shows Render's Markdown):
//
//	""                 home: intro, totals, open quests, how it works
//	"quest/<id>"       one quest and what can happen next
//	"poster/<address>" quests posted by an address
//	"builder/<address>" quests an address has worked on (history)
//	"paid"             finished, paid quests
//	"help"             how to use every function, with gnokey commands
//
// List pages take "?page=N" (PageSize per page). Render never panics: any
// unknown path, bad id or bad address gives a "not found" page.

// PageSize is the number of quests per list page.
const PageSize = 20

// maxPage bounds ?page= so offsets stay small.
const maxPage = 1_000_000

// SourceRepo is where the source code is published, shown in the footer of
// every page.
const SourceRepo = "https://github.com/elangrr/questmaster"

// Render returns the gnoweb page for path, with the footer.
func Render(path string) string {
	return renderPage(path) + footer()
}

// footer ends every page: attribution and where the source is.
func footer() string {
	src := "source: " + SourceRepo
	if strings.HasPrefix(SourceRepo, "https://") {
		src = "[source](" + SourceRepo + ")"
	}
	return "\n---\n\nBuilt on [gno.land](https://gno.land) · " + src + "\n"
}

func renderPage(path string) string {
	p, query := splitQuery(path)
	page := pageArg(query)
	switch {
	case p == "":
		return renderHome(page)
	case p == "help":
		return renderHelp()
	case p == "paid":
		return renderPaid(page)
	case strings.HasPrefix(p, "quest/"):
		id, ok := parseID(strings.TrimPrefix(p, "quest/"))
		if !ok {
			return renderNotFound("There is no quest with that number.")
		}
		return renderQuest(id)
	case strings.HasPrefix(p, "poster/"):
		addr, ok := parseAddress(strings.TrimPrefix(p, "poster/"))
		if !ok {
			return renderNotFound("That is not a valid address.")
		}
		return renderUser(addr, true, page)
	case strings.HasPrefix(p, "builder/"):
		addr, ok := parseAddress(strings.TrimPrefix(p, "builder/"))
		if !ok {
			return renderNotFound("That is not a valid address.")
		}
		return renderUser(addr, false, page)
	}
	return renderNotFound("This page does not exist.")
}

// ---------------------------------------------------------------------------
// Pages

func renderHome(page int) string {
	var b strings.Builder
	t := GetTotals()
	b.WriteString("# QuestMaster\n\n")
	b.WriteString("A bounty board for small tasks, paid in GNOT. A poster describes a task and locks the reward in this realm. " +
		"A builder takes the task, does the work and sends a link to it. When the poster approves, the realm pays the builder. " +
		"If the poster never answers, the builder can collect the reward after the review window. Nobody else, not even the authors, can move the locked GNOT.\n\n")

	b.WriteString("_Runs on the Onyx test network with test GNOT._\n\n")
	b.WriteString("**Post a quest:** " + postLinks() + " · [How it works](#how-it-works) · [Help and commands](" + pageURL("help") + ") · [Paid quests](" + pageURL("paid") + ")\n\n")

	b.WriteString("## Board\n\n")
	b.WriteString("| Open quests | GNOT locked | GNOT paid out | Quests paid |\n")
	b.WriteString("|---|---|---|---|\n")
	b.WriteString("| " + strconv.Itoa(t.OpenQuests) + " | " + gnotStr(t.Locked) + " | " + gnotStr(t.Paid) + " | " + strconv.Itoa(t.PaidQuests) + " |\n\n")

	b.WriteString("## Open quests\n\n")
	ids, nav := pageOf(&openIDs, page, "")
	if openIDs.Size() == 0 {
		b.WriteString("No open quests right now. [Post the first one](" + postLink() + ").\n\n")
	} else if len(ids) == 0 {
		b.WriteString("This page is empty. [Back to the first page](" + pageURL("") + ")\n\n")
	} else {
		b.WriteString("| # | Quest | Reward | Work window | Rejected |\n")
		b.WriteString("|---|---|---|---|---|\n")
		for _, id := range ids {
			q := mustGet(id)
			b.WriteString("| " + idStr(id) + " | " + questLink(q) + " | " + gnotStr(q.Reward()) + " GNOT | " +
				blocksStr(q.WorkBlocks()) + " (" + approx(q.WorkBlocks()) + ") | " + strconv.Itoa(q.RejectCount()) + " |\n")
		}
		b.WriteString("\n" + nav)
	}

	b.WriteString("## How it works\n\n")
	b.WriteString("1. **Post.** The poster writes a title, details and a work window, and sends the reward (at least 1 GNOT) with the call. The GNOT is locked here.\n")
	b.WriteString("2. **Claim.** Anyone except the poster takes the quest. Only one builder works on a quest at a time.\n")
	b.WriteString("3. **Submit.** The builder sends a link to the work (it must start with `https://`) before the work window ends.\n")
	b.WriteString("4. **Review.** The poster approves (the builder is paid at once) or rejects with a reason (the quest opens again, and the reject count goes up for everyone to see).\n")
	b.WriteString("5. **Paid.** The reward goes to the builder.\n\n")
	b.WriteString("A poster can cancel an open quest and get the reward back at once. Anyone can claim an open quest; once a builder has it, the poster can **close** the quest instead: the builder keeps their turn, and if it ends without approval the reward goes back to the poster.\n\n")
	b.WriteString(reviewWarning())
	b.WriteString("Two deadlines keep things moving:\n\n")
	b.WriteString("- **Work window** (set by the poster, " + blocksStr(escrow.MinWorkBlocks) + " to " + blocksStr(escrow.MaxWorkBlocks) +
		" blocks): if the builder has not submitted by then, anyone can release the quest so someone else can take it.\n")
	b.WriteString("- **Review window** (" + blocksStr(escrow.ReviewBlocks) + " blocks, " + approx(escrow.ReviewBlocks) +
		"): if the poster has not approved or rejected by then, the builder can claim the reward.\n\n")
	b.WriteString(timeNote())
	return b.String()
}

func renderQuest(id uint64) string {
	v := quests.Get(questKey(id))
	if v == nil {
		return renderNotFound("There is no quest with that number.")
	}
	q := v.(*escrow.Quest)
	h := runtime.ChainHeight()
	var b strings.Builder

	b.WriteString("# Quest " + idStr(id) + ": " + esc(q.Title()) + "\n\n")
	b.WriteString("[Board](" + pageURL("") + ") · [Help](" + pageURL("help") + ")\n\n")

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| State | **" + questState(q) + "** |\n")
	b.WriteString("| Reward | " + gnotStr(q.Reward()) + " GNOT |\n")
	b.WriteString("| Poster | " + userLink(q.Poster(), true) + " |\n")
	if q.Builder() != "" {
		b.WriteString("| Builder | " + userLink(q.Builder(), false) + " |\n")
	}
	b.WriteString("| Work window | " + blocksStr(q.WorkBlocks()) + " blocks (" + approx(q.WorkBlocks()) + ") |\n")
	b.WriteString("| Posted at block | " + blocksStr(q.CreatedAt()) + " |\n")
	switch q.State() {
	case escrow.Claimed:
		b.WriteString("| Claimed at block | " + blocksStr(q.ClaimedAt()) + " |\n")
		b.WriteString("| Work deadline | block " + blocksStr(q.WorkDeadline()) + " (" + left(q.WorkDeadline(), h) + ") |\n")
	case escrow.Submitted:
		b.WriteString("| Submitted at block | " + blocksStr(q.SubmittedAt()) + " |\n")
		b.WriteString("| Review deadline | block " + blocksStr(q.ReviewDeadline()) + " (" + left(q.ReviewDeadline(), h) + ") |\n")
	}
	if q.WorkLink() != "" {
		b.WriteString("| Work | " + linkOrText(q.WorkLink()) + " |\n")
	}
	b.WriteString("| Times rejected | " + strconv.Itoa(q.RejectCount()) + " |\n")
	b.WriteString("| Current block | " + blocksStr(h) + " |\n\n")
	if q.Closing() {
		b.WriteString("> [!NOTE]\n> **Closing**: the reward returns to the poster when the current builder's turn ends, unless the work is approved.\n\n")
	}

	b.WriteString("## Details\n\n")
	if strings.TrimSpace(q.Details()) == "" {
		b.WriteString("_No details given._\n\n")
	} else {
		b.WriteString(escBlock(q.Details()) + "\n")
	}

	if q.RejectCount() > 0 {
		b.WriteString("## Last reject reason\n\n")
		b.WriteString(escBlock(q.LastRejectReason()) + "\n")
	}

	b.WriteString("## What can happen next\n\n")
	b.WriteString(nextSteps(q, h))
	b.WriteString(timeNote())
	return b.String()
}

// step is one possible move on a quest page.
type step struct{ text, fn string }

func closeStep() step {
	return step{"**Close quest**: the poster stops the quest. No coins move now; the builder keeps their turn, and if it ends without approval the reward goes back to the poster. It cannot be undone.", "CancelQuest"}
}

// reviewWarning is shown to posters on the home and help pages.
func reviewWarning() string {
	return "> [!WARNING]\n> **Posters: check your quest.** If you do not approve or reject a submission within the review window (" +
		approx(escrow.ReviewBlocks) + "), the builder is paid automatically.\n\n"
}

// questState is the state as shown in tables and on the quest page.
func questState(q *escrow.Quest) string {
	if q.Closing() && !q.State().IsFinal() {
		return stateText(q.State()) + ", closing"
	}
	return stateText(q.State())
}

// nextSteps lists the moves valid in q's state, who may make each, and a
// transaction link and gnokey command for each.
func nextSteps(q *escrow.Quest, h int64) string {
	id := idStr(q.ID())
	var b strings.Builder
	var steps []step
	switch q.State() {
	case escrow.Open:
		steps = []step{
			{"**Claim**: anyone except the poster can take this quest and start working.", "ClaimQuest"},
			{"**Cancel**: the poster can close the quest and get the " + gnotStr(q.Reward()) + " GNOT back.", "CancelQuest"},
		}
	case escrow.Claimed:
		if h <= q.WorkDeadline() {
			steps = append(steps, step{"**Submit work**: the builder sends a link to the work (starting with `https://`), until block " + blocksStr(q.WorkDeadline()) + ".", "SubmitWork"})
		}
		if q.Closing() {
			steps = append(steps, step{"**Unclaim**: the builder gives the quest back. It is closing, so it ends and the reward goes back to the poster.", "UnclaimQuest"})
		} else {
			steps = append(steps, step{"**Unclaim**: the builder gives the quest back so others can take it.", "UnclaimQuest"})
			steps = append(steps, closeStep())
		}
		if q.CanRelease(h) {
			if q.Closing() {
				steps = append(steps, step{"**Release**: the work deadline has passed without a submission, so anyone can end the quest; the reward goes back to the poster.", "ReleaseQuest"})
			} else {
				steps = append(steps, step{"**Release**: the work deadline has passed without a submission, so anyone can reopen the quest.", "ReleaseQuest"})
			}
		} else if q.Closing() {
			b.WriteString("If nothing is submitted by block " + blocksStr(q.WorkDeadline()) + ", anyone can end the quest from block " + blocksStr(q.WorkDeadline()+1) + " and the reward goes back to the poster.\n\n")
		} else {
			b.WriteString("If nothing is submitted by block " + blocksStr(q.WorkDeadline()) + ", anyone can release the quest from block " + blocksStr(q.WorkDeadline()+1) + ".\n\n")
		}
	case escrow.Submitted:
		steps = append(steps, step{"**Approve**: the poster accepts the work and the builder is paid " + gnotStr(q.Reward()) + " GNOT.", "ApproveWork"})
		if h <= q.ReviewDeadline() {
			if q.Closing() {
				steps = append(steps, step{"**Reject**: the poster refuses the work with a reason, until block " + blocksStr(q.ReviewDeadline()) + ". The quest is closing, so it ends and the reward goes back to the poster.", "RejectWork"})
			} else {
				steps = append(steps, step{"**Reject**: the poster refuses the work with a reason, until block " + blocksStr(q.ReviewDeadline()) + ". The quest opens again.", "RejectWork"})
			}
		}
		if !q.Closing() {
			steps = append(steps, closeStep())
		}
		if q.CanClaimPayout(h) {
			steps = append(steps, step{"**Claim payout**: the poster did not answer in time, so the builder can take the reward.", "ClaimPayout"})
		} else {
			b.WriteString("If the poster does not answer by block " + blocksStr(q.ReviewDeadline()) + ", the builder can claim the reward from block " + blocksStr(q.ReviewDeadline()+1) + ".\n\n")
		}
	case escrow.Paid:
		return "Nothing: this quest is finished and the builder was paid " + gnotStr(q.Reward()) + " GNOT.\n\n"
	case escrow.Cancelled:
		return "Nothing: this quest was cancelled and the reward went back to the poster.\n\n"
	}
	for _, s := range steps {
		b.WriteString("- " + s.text + " [Open in gnoweb](" + txLink(s.fn).AddArgs("id", id).URL() + ")\n")
	}
	b.WriteString("\nWith gnokey on Onyx (replace `KEY` with your key name):\n\n```\n")
	for _, s := range steps {
		b.WriteString(gnokeyCall(s.fn, id, extraArg(s.fn), "") + "\n")
	}
	b.WriteString("```\n\n")
	return b.String()
}

func extraArg(fn string) string {
	switch fn {
	case "SubmitWork":
		return "https://link-to-your-work"
	case "RejectWork":
		return "What is missing"
	}
	return ""
}

func renderUser(addr address, asPoster bool, page int) string {
	var b strings.Builder
	idx, other, title, what := &byBuilder, "poster", "Builder ", "Quests this address has claimed, with their current state. A quest stays here after the builder gives it up or is rejected."
	if asPoster {
		idx, other, title, what = &byPoster, "builder", "Poster ", "Quests posted by this address, with their current state."
	}
	b.WriteString("# " + title + shortAddr(addr) + "\n\n")
	b.WriteString("[Board](" + pageURL("") + ") · [Same address as " + other + "](" + pageURL(other+"/"+addr.String()) + ")\n\n")
	b.WriteString("Address: `" + addr.String() + "`\n\n" + what + "\n\n")

	var ids []uint64
	var nav string
	base := "builder/" + addr.String()
	if asPoster {
		base = "poster/" + addr.String()
	}
	if v := idx.Get(addr.String()); v != nil {
		ids, nav = pageOf(v.(*avl.Tree), page, base)
	}
	if len(ids) == 0 {
		if page > 1 {
			b.WriteString("This page is empty. [Back to the first page](" + pageURL(base) + ")\n")
			return b.String()
		}
		b.WriteString("No quests yet.\n")
		return b.String()
	}
	b.WriteString("| # | Quest | Reward | State | " + capital(other) + " |\n|---|---|---|---|---|\n")
	for _, id := range ids {
		q := mustGet(id)
		who := q.Builder()
		if !asPoster {
			who = q.Poster()
		}
		whoText := "-"
		if who != "" {
			whoText = userLink(who, !asPoster)
		}
		b.WriteString("| " + idStr(id) + " | " + questLink(q) + " | " + gnotStr(q.Reward()) + " GNOT | " + questState(q) + " | " + whoText + " |\n")
	}
	b.WriteString("\n" + nav)
	return b.String()
}

func renderPaid(page int) string {
	var b strings.Builder
	b.WriteString("# Paid quests\n\n")
	b.WriteString("[Board](" + pageURL("") + ")\n\n")
	b.WriteString("Every quest below was paid by this realm to its builder: " + plural(paidIDs.Size(), "quest") + ", " + gnotStr(totalPaid) + " GNOT in total.\n\n")
	ids, nav := pageOf(&paidIDs, page, "paid")
	if paidIDs.Size() == 0 {
		b.WriteString("No quest has been paid yet.\n")
		return b.String()
	}
	if len(ids) == 0 {
		b.WriteString("This page is empty. [Back to the first page](" + pageURL("paid") + ")\n")
		return b.String()
	}
	b.WriteString("| # | Quest | Reward | Builder | Times rejected |\n|---|---|---|---|---|\n")
	for _, id := range ids {
		q := mustGet(id)
		b.WriteString("| " + idStr(id) + " | " + questLink(q) + " | " + gnotStr(q.Reward()) + " GNOT | " + userLink(q.Builder(), false) + " | " + strconv.Itoa(q.RejectCount()) + " |\n")
	}
	b.WriteString("\n" + nav)
	return b.String()
}

func renderHelp() string {
	var b strings.Builder
	b.WriteString("# How to use QuestMaster\n\n")
	b.WriteString("[Board](" + pageURL("") + ")\n\n")
	b.WriteString("> [!NOTE]\n> QuestMaster runs on the **Onyx test network** (`onyx-1`) and uses **test GNOT** from the faucet, not real money.\n\n")
	b.WriteString("Every action is a transaction on this realm. Use either:\n\n")
	b.WriteString("- **gnoweb**: the action links on each quest page open a form for the function, with the quest number filled in. Sign it with a browser wallet such as Adena, or copy the gnokey command the form shows.\n")
	b.WriteString("- **gnokey**: the commands below, already set for Onyx. Replace `KEY` with your key name and `ID` with the quest number.\n\n")
	b.WriteString("Only direct calls from a wallet are accepted (not calls from other realms or `maketx run` scripts). Only `PostQuest` takes coins; every other call must send none.\n\n")

	b.WriteString(reviewWarning())
	b.WriteString("## Post a quest\n\n")
	b.WriteString("Send the reward with the call: exactly one coin, in `ugnot`, at least " + gnotStr(MinReward) + " GNOT (1 GNOT = 1000000 ugnot). " +
		"Arguments: title (up to " + strconv.Itoa(escrow.MaxTitleLen) + " characters, one line), details (up to " + strconv.Itoa(escrow.MaxDetailsLen) +
		" characters), work window in blocks (" + blocksStr(escrow.MinWorkBlocks) + " to " + blocksStr(escrow.MaxWorkBlocks) + "). " +
		"Anyone except you can claim your quest while it is open; once it is claimed, closing it (below) stops new claims. " +
		"Posting also stores the quest on chain. The chain charges a storage deposit for that, paid by the poster on top of the reward: " +
		"about 0.65 to 0.8 GNOT for a new quest at 100 ugnot per byte, the price on Onyx (measured on a local node). It is held by the chain, not by this realm, and is not part of the escrow; when a later call makes the stored data smaller, the chain returns that share to whoever made the call.\n\n")
	b.WriteString("With gnoweb, pick a reward: " + postLinks() + ". The form shows the amount and asks you to confirm adding the coins. " +
		"For another amount, change `.send=` in the link's address or use gnokey.\n\n")
	b.WriteString("```\n" + gnokeyCall("PostQuest", "", "", "5000000ugnot") + "\n```\n\n")

	sections := []struct{ title, text, fn, arg string }{
		{"Claim a quest", "Anyone except the poster. The work window starts now.", "ClaimQuest", ""},
		{"Submit work", "The builder only, until the work deadline. The link must start with `https://`.", "SubmitWork", "https://link-to-your-work"},
		{"Approve work", "The poster only. The builder is paid at once.", "ApproveWork", ""},
		{"Reject work", "The poster only, until the review deadline. The quest opens again (or, if you closed it, ends with a refund to you); the reason and the reject count are public.", "RejectWork", "What is missing"},
		{"Cancel or close a quest", "The poster only. An open quest is cancelled at once and the reward is refunded. A claimed or submitted quest is closed instead: no coins move now, the builder keeps their turn, and the reward goes back to you when that turn ends without approval (the builder unclaims, the work deadline passes and anyone releases it, or you reject the work). Nobody can claim it again. Closing cannot be undone.", "CancelQuest", ""},
		{"Unclaim a quest", "The builder only, before submitting. The quest opens again (or, if the poster closed it, ends with a refund to the poster).", "UnclaimQuest", ""},
		{"Release a quest", "Anyone, once the work deadline has passed without a submission. The quest opens again (or, if the poster closed it, ends with a refund to the poster).", "ReleaseQuest", ""},
		{"Claim a timeout payout", "The builder only, once the review deadline has passed without an answer from the poster.", "ClaimPayout", ""},
	}
	for _, s := range sections {
		b.WriteString("## " + s.title + "\n\n" + s.text + "\n\n```\n" + gnokeyCall(s.fn, "ID", s.arg, "") + "\n```\n\n")
	}

	b.WriteString("## Reading the board\n\n")
	b.WriteString("- `" + pageURL("quest/ID") + "`: one quest\n")
	b.WriteString("- `" + pageURL("poster/ADDRESS") + "` and `" + pageURL("builder/ADDRESS") + "`: one address's quests\n")
	b.WriteString("- `" + pageURL("paid") + "`: paid quests\n")
	b.WriteString("- Lists take `?page=2` and so on, " + strconv.Itoa(PageSize) + " quests per page.\n\n")
	b.WriteString(timeNote())
	return b.String()
}

func renderNotFound(reason string) string {
	return "# Not found\n\n" + reason + "\n\n[Go to the QuestMaster board](" + pageURL("") + ") · [Help](" + pageURL("help") + ")\n"
}

// ---------------------------------------------------------------------------
// Pieces

func questLink(q *escrow.Quest) string {
	return "[" + escCell(q.Title()) + "](" + pageURL("quest/"+idStr(q.ID())) + ")"
}

// userLink links an address (always a valid bech32 address from storage or
// a validated path) to its poster or builder page.
func userLink(a address, asPoster bool) string {
	page := "builder/"
	if asPoster {
		page = "poster/"
	}
	return "[" + shortAddr(a) + "](" + pageURL(page+a.String()) + ")"
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func stateText(s escrow.State) string {
	switch s {
	case escrow.Open:
		return "Open"
	case escrow.Claimed:
		return "Claimed (work in progress)"
	case escrow.Submitted:
		return "Submitted (waiting for review)"
	case escrow.Paid:
		return "Paid"
	case escrow.Cancelled:
		return "Cancelled (refunded)"
	}
	return "Unknown"
}

// realmPkgPath is this realm's package path, captured once when the realm is
// added. (unsafe.CurrentRealm() inside Render depends on the caller's frame,
// so it is not used there.)
var realmPkgPath string

func init() {
	realmPkgPath = unsafe.CurrentRealm().PkgPath()
}

// realmPath is this realm's web path, e.g. "/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster".
func realmPath() string {
	return strings.TrimPrefix(realmPkgPath, runtime.ChainDomain())
}

// txLink builds a gnoweb transaction link for fn on this realm.
func txLink(fn string) *txlink.TxBuilder {
	return txlink.Realm(realmPkgPath).NewLink(fn)
}

// pageURL links to one of this realm's pages.
func pageURL(p string) string {
	if p == "" {
		return realmPath()
	}
	return realmPath() + ":" + p
}

func postLink() string { return postLinkFor(MinReward) }

func postLinkFor(ugnot int64) string {
	return txLink("PostQuest").SetSend(strconv.FormatInt(ugnot, 10) + "ugnot").URL()
}

// postLinks offers PostQuest forms with a few prefilled rewards.
func postLinks() string {
	var links []string
	for _, n := range []int64{1, 5, 10} {
		links = append(links, "["+strconv.FormatInt(n, 10)+" GNOT]("+postLinkFor(n*1_000_000)+")")
	}
	return strings.Join(links, " · ")
}

// gnokeyCall builds a copy-paste gnokey command. Only realm-chosen text goes
// into it (function names, numbers, fixed example values).
func gnokeyCall(fn, id, arg, send string) string {
	cmd := "gnokey maketx call -pkgpath \"" + realmPkgPath + "\" -func \"" + fn + "\""
	if fn == "PostQuest" {
		cmd += " -args \"Fix a typo in the docs\" -args \"Details of the task\" -args \"20000\""
	}
	if id != "" {
		cmd += " -args \"" + id + "\""
	}
	if arg != "" {
		cmd += " -args \"" + arg + "\""
	}
	if send != "" {
		cmd += " -send \"" + send + "\""
	}
	return cmd + " -gas-fee 100000ugnot -gas-wanted 10000000 -broadcast -chainid " + chainID + " -remote " + chainRPC + " KEY"
}

// QuestMaster runs on the Onyx test network only; every example command
// targets it.
const (
	chainID  = "onyx-1"
	chainRPC = "https://rpc.onyx.testnets.gno.land:443"
)

// pageOf returns the ids for page (newest first) and prev/next links.
func pageOf(t *avl.Tree, pageNum int, base string) ([]uint64, string) {
	total := t.Size()
	offset := (pageNum - 1) * PageSize
	if offset >= total {
		return nil, ""
	}
	ids := page(t, offset, PageSize)
	var nav []string
	if pageNum > 1 {
		nav = append(nav, "[← Newer]("+pageURL(base)+"?page="+strconv.Itoa(pageNum-1)+")")
	}
	if offset+PageSize < total {
		nav = append(nav, "[Older →]("+pageURL(base)+"?page="+strconv.Itoa(pageNum+1)+")")
	}
	if len(nav) == 0 {
		return ids, ""
	}
	last := (total + PageSize - 1) / PageSize
	return ids, "Page " + strconv.Itoa(pageNum) + " of " + strconv.Itoa(last) + " · " + strings.Join(nav, " · ") + "\n\n"
}

// ---------------------------------------------------------------------------
// Parsing (never panics)

func splitQuery(path string) (string, url.Values) {
	i := strings.IndexByte(path, '?')
	if i < 0 {
		return path, url.Values{}
	}
	q, err := url.ParseQuery(path[i+1:])
	if err != nil {
		q = url.Values{}
	}
	return path[:i], q
}

func pageArg(q url.Values) int {
	n, err := strconv.Atoi(q.Get("page"))
	if err != nil || n < 1 {
		return 1
	}
	if n > maxPage {
		return maxPage
	}
	return n
}

func parseID(s string) (uint64, bool) {
	if s == "" || len(s) > 20 {
		return 0, false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	id, err := strconv.ParseUint(s, 10, 64)
	if err != nil || id == 0 || !quests.Has(questKey(id)) {
		return 0, false
	}
	return id, true
}

func parseAddress(s string) (address, bool) {
	if len(s) > 100 {
		return "", false
	}
	a := address(s)
	if !a.IsValid() {
		return "", false
	}
	return a, true
}

// ---------------------------------------------------------------------------
// Numbers

// gnot formats ugnot as GNOT with up to 6 decimals, without floats.
func gnotStr(ugnot int64) string {
	neg := ""
	if ugnot < 0 {
		neg = "-"
		ugnot = -ugnot
	}
	whole := strconv.FormatInt(ugnot/1_000_000, 10)
	frac := ugnot % 1_000_000
	if frac == 0 {
		return neg + whole
	}
	f := strconv.FormatInt(frac, 10)
	for len(f) < 6 {
		f = "0" + f
	}
	return neg + whole + "." + strings.TrimRight(f, "0")
}

// blocksStr formats a block count or height with thousands separators.
func blocksStr(n int64) string {
	s := strconv.FormatInt(n, 10)
	if n < 0 {
		return s
	}
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}

// approx turns a number of blocks into "about N days/hours/minutes", at
// ApproxBlockMillis per block.
func approx(blocks int64) string {
	if blocks <= 0 {
		return "now"
	}
	secs := blocks * ApproxBlockMillis / 1000
	switch {
	case secs >= 2*86400:
		return "about " + strconv.FormatInt((secs+43200)/86400, 10) + " days"
	case secs >= 2*3600:
		return "about " + strconv.FormatInt((secs+1800)/3600, 10) + " hours"
	case secs >= 120:
		return "about " + strconv.FormatInt((secs+30)/60, 10) + " minutes"
	}
	return "about a minute"
}

// left describes the time to a deadline block from height h.
func left(deadline, h int64) string {
	if h > deadline {
		return "passed"
	}
	return approx(deadline-h+1) + " left"
}

// ApproxBlockMillis is the block time used for the approximate times on the
// pages (measured about 3.4 to 3.5 s on Onyx and mainnet in Nov 2026).
const ApproxBlockMillis = 3500

func timeNote() string {
	return "_Times are approximate, at about 3.5 seconds per block; deadlines are exact block heights._\n"
}

func capital(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// plural returns "1 quest" or "N quests".
func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return strconv.Itoa(n) + " " + word + "s"
}
