package barkeep

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1vx95s9pfwpg2flkw6x8z35546espgqemks8zkm/bounty/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

const pageSize = 10

// Render draws the tavern notice board in gnoweb.
//
//	""               notice board (open bounties)
//	"status/{s}"     filter: open, claimed, submitted, paid, cancelled, all
//	"bounty/{id}"    bounty details, history and context actions
//	"hunters"        leaderboard
//	"u/{addr}"       profile of an address
//	"help"           how it works
func Render(path string) string {
	r := mux.NewRouter()
	r.HandleFunc("", renderBoard)
	r.HandleFunc("status/{status}", renderBoard)
	r.HandleFunc("bounty/{id}", renderBounty)
	r.HandleFunc("hunters", renderHunters)
	r.HandleFunc("u/{addr}", renderProfile)
	r.HandleFunc("help", renderHelp)
	r.NotFoundHandler = func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write(header() + "> The barkeep shrugs. Nothing pinned here.\n\n[Back to the board](" + link("") + ")\n")
	}
	return r.Render(path)
}

// --- pages ---

func renderBoard(res *mux.ResponseWriter, req *mux.Request) {
	statusName := req.GetVar("status")
	if statusName == "" {
		statusName = "open"
	}
	var filter bounty.Filter
	if statusName != "all" {
		st, ok := bounty.ParseStatus(statusName)
		if !ok {
			res.Write(header() + "> Unknown filter.\n")
			return
		}
		filter = bounty.ByStatus(st)
	}

	page := pageParam(req)
	items, total := board.List(filter, (page-1)*pageSize, pageSize)

	var sb strings.Builder
	sb.WriteString(header())
	sb.WriteString(statsLine())
	sb.WriteString("\n" + postButton() + "\n\n")
	sb.WriteString(tabs(statusName) + "\n\n")

	if total == 0 {
		sb.WriteString("_The board is empty here. Pull up a stool and post the first bounty._\n")
	}
	for _, b := range items {
		sb.WriteString(card(b))
	}
	sb.WriteString(pager(req, page, total))
	sb.WriteString(footer())
	res.Write(sb.String())
}

func renderBounty(res *mux.ResponseWriter, req *mux.Request) {
	id, err := strconv.ParseUint(req.GetVar("id"), 10, 64)
	b, ok := board.Get(id)
	if err != nil || !ok {
		res.Write(header() + "> No bounty with that number.\n\n[Back to the board](" + link("") + ")\n")
		return
	}
	now := time.Now()

	var sb strings.Builder
	sb.WriteString("[← Back to the board](" + link("") + ")\n\n")
	sb.WriteString(ufmt.Sprintf("# #%d · %s\n\n", b.ID, sanitize.InlineText(b.Title)))
	sb.WriteString(ufmt.Sprintf("**%s** · %s · claim window %s\n\n", gnot(b.Reward), badge(b.Status), dur(b.ClaimWindow)))

	if b.Description != "" {
		sb.WriteString(sanitize.Blockquote(b.Description) + "\n\n")
	}

	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString("| Poster | " + who(b.Poster) + " |\n")
	sb.WriteString("| Posted | " + ts(b.CreatedAt) + " |\n")
	switch b.Status {
	case bounty.StatusClaimed:
		sb.WriteString("| Hunter | " + who(b.Hunter) + " |\n")
		sb.WriteString("| Deliver by | " + ts(b.ClaimDeadline()) + " (" + left(now, b.ClaimDeadline()) + ") |\n")
	case bounty.StatusSubmitted:
		sb.WriteString("| Hunter | " + who(b.Hunter) + " |\n")
		sb.WriteString("| Proof | " + proof(b.Proof) + " |\n")
		sb.WriteString("| Review by | " + ts(board.ReviewDeadline(b)) + " (" + left(now, board.ReviewDeadline(b)) + ") |\n")
	case bounty.StatusPaid:
		sb.WriteString("| Paid to | " + who(b.Hunter) + " |\n")
		sb.WriteString("| Proof | " + proof(b.Proof) + " |\n")
		sb.WriteString("| Closed | " + ts(b.ClosedAt) + " |\n")
	case bounty.StatusCancelled:
		sb.WriteString("| Closed | " + ts(b.ClosedAt) + " |\n")
	}

	sb.WriteString("\n## What can happen next\n\n")
	sb.WriteString(actions(b, now))

	sb.WriteString("\n## History\n\n| When | Who | What | Note |\n|---|---|---|---|\n")
	for i := len(b.History) - 1; i >= 0; i-- {
		e := b.History[i]
		sb.WriteString("| " + ts(e.At) + " | " + who(e.Actor) + " | " + e.Action + " | " + sanitize.TableCell(e.Note) + " |\n")
	}
	sb.WriteString(footer())
	res.Write(sb.String())
}

func renderHunters(res *mux.ResponseWriter, _ *mux.Request) {
	var sb strings.Builder
	sb.WriteString(header())
	sb.WriteString("## 🏆 Hall of Hunters\n\n")
	top := board.Leaderboard(25)
	if len(top) == 0 {
		sb.WriteString("_No bounty has been paid yet. Be the first legend of the tavern._\n")
	} else {
		sb.WriteString("| # | Hunter | Score | Done | Earned | Rejected | Abandoned |\n|---|---|---|---|---|---|---|\n")
		for i, s := range top {
			sb.WriteString(ufmt.Sprintf("| %d %s | %s | %d | %d | %s | %d | %d |\n",
				i+1, medal(i), who(s.Address), s.Score(), s.Completed, gnot(s.Earned), s.Rejected, s.Abandoned))
		}
		sb.WriteString("\n_Score = 10 per completed bounty − 3 per abandoned claim − 2 per rejected submission._\n")
	}
	sb.WriteString(footer())
	res.Write(sb.String())
}

func renderProfile(res *mux.ResponseWriter, req *mux.Request) {
	addr := address(req.GetVar("addr"))
	if !addr.IsValid() {
		res.Write(header() + "> That is not a valid address.\n")
		return
	}
	s := board.Stats(addr)

	var sb strings.Builder
	sb.WriteString("[← Back to the board](" + link("") + ")\n\n")
	sb.WriteString("# 🧙 " + short(addr) + "\n\n`" + addr.String() + "`\n\n")
	sb.WriteString("| As hunter | | As poster | |\n|---|---|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Score | **%d** | Posted | %d |\n", s.Score(), s.Posted))
	sb.WriteString(ufmt.Sprintf("| Completed | %d | Paid out | %s |\n", s.Completed, gnot(s.PaidOut)))
	sb.WriteString(ufmt.Sprintf("| Earned | %s | Rejections made | %d |\n", gnot(s.Earned), s.RejectionsMade))
	sb.WriteString(ufmt.Sprintf("| Rejected | %d | Cancelled | %d |\n", s.Rejected, s.Cancelled))
	sb.WriteString(ufmt.Sprintf("| Abandoned | %d | | |\n\n", s.Abandoned))

	items, total := board.List(bounty.ByAddress(addr), 0, 20)
	sb.WriteString(ufmt.Sprintf("## Bounties (%d)\n\n", total))
	for _, b := range items {
		sb.WriteString(card(b))
	}
	sb.WriteString(footer())
	res.Write(sb.String())
}

func renderHelp(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write(header() + `## How the tavern works

1. **Post** a task and attach the reward in GNOT. The coins are locked in this realm's escrow, with no admin key.
2. A hunter **claims** it and has the claim window to deliver.
3. The hunter **submits** proof (a link, a PR, a tx hash).
4. You **approve** and the hunter is paid right away, or **reject** and the bounty goes back on the board.

**Fair play rules**

- Didn't review a submission within **72 hours**? The hunter can **collect** the reward.
- A hunter didn't deliver in time? **Anyone** can **release** the claim so others can take it.
- Changed your mind? **Cancel** an open bounty and get a full refund.
- Every rejection, abandoned claim and payout is public, on both sides.

**For builders:** the board logic is the pure package ` + "`gno.land/p/g1vx95s9pfwpg2flkw6x8z35546espgqemks8zkm/bounty/v0`" + `. Import it to give your DAO, game or project its own bounty board.

[Back to the board](` + link("") + `)
` + footer())
}

// --- building blocks ---

func header() string {
	return "# 🍺 Barkeep\n\n_The tavern notice board of Gno.land: post a task, put GNOT on it, pay whoever gets it done._\n\n"
}

func footer() string {
	return "\n---\n\n[Board](" + link("") + ") · [Hall of Hunters](" + link("hunters") + ") · [How it works](" + link("help") + ")\n"
}

func statsLine() string {
	open := board.Count(bounty.ByStatus(bounty.StatusOpen))
	working := board.Count(bounty.ByStatus(bounty.StatusClaimed, bounty.StatusSubmitted))
	return ufmt.Sprintf("**%d** open · **%d** in progress · **%s** in escrow · **%s** paid out · **%d** patrons\n",
		open, working, gnot(board.Escrowed()), gnot(board.TotalPaid()), board.Participants())
}

func postButton() string {
	url := txlink.NewLink("Post").
		AddArgs("title", "", "description", "", "claimHours", "48").
		SetSend("5000000ugnot").
		URL()
	return "[📌 Pin a new bounty](" + url + ")"
}

func tabs(active string) string {
	names := []string{"open", "claimed", "submitted", "paid", "cancelled", "all"}
	labels := []string{"Open", "Claimed", "In review", "Paid", "Cancelled", "All"}
	var parts []string
	for i, n := range names {
		if n == active {
			parts = append(parts, "**"+labels[i]+"**")
		} else {
			parts = append(parts, "["+labels[i]+"]("+link("status/"+n)+")")
		}
	}
	return strings.Join(parts, " · ")
}

func card(b *bounty.Bounty) string {
	line := ufmt.Sprintf("### [#%d %s](%s)\n\n**%s** · %s · by %s",
		b.ID, sanitize.InlineText(b.Title), link("bounty/"+idStr(b.ID)), gnot(b.Reward), badge(b.Status), who(b.Poster))
	if b.Hunter != "" {
		line += " · hunter " + who(b.Hunter)
	}
	return line + "\n\n"
}

func actions(b *bounty.Bounty, now time.Time) string {
	id := idStr(b.ID)
	var out []string
	add := func(label, fn, note string, args ...string) {
		all := append([]string{"id", id}, args...)
		out = append(out, "- ["+label+"]("+txlink.NewLink(fn).AddArgs(all...).URL()+") "+note)
	}

	switch b.Status {
	case bounty.StatusOpen:
		add("🗡️ Claim this bounty", "Claim", "– you get "+dur(b.ClaimWindow)+" to deliver.")
		add("✖️ Cancel & refund", "Cancel", "– poster only.")
	case bounty.StatusClaimed:
		add("📜 Submit proof", "Submit", "– hunter only.", "proof", "")
		add("↩️ Give it back", "Unclaim", "– hunter only.")
		if b.ClaimExpired(now) {
			add("⏰ Release expired claim", "Release", "– anyone, the claim window is over.")
		}
	case bounty.StatusSubmitted:
		add("✅ Approve & pay", "Approve", "– poster only, pays "+gnot(b.Reward)+".")
		add("❌ Reject", "Reject", "– poster only, reopens the bounty.", "reason", "")
		add("📜 Update proof", "Submit", "– hunter only.", "proof", "")
		if now.After(board.ReviewDeadline(b)) {
			add("💰 Collect (poster did not review)", "Collect", "– hunter only.")
		}
	default:
		return "_This bounty is closed._\n"
	}
	return strings.Join(out, "\n") + "\n"
}

func pager(req *mux.Request, page, total int) string {
	pages := (total + pageSize - 1) / pageSize
	if pages <= 1 {
		return ""
	}
	base := req.Path
	s := "\n"
	if page > 1 {
		s += "[← newer](" + link(base) + "?page=" + strconv.Itoa(page-1) + ") "
	}
	s += ufmt.Sprintf("page %d of %d", page, pages)
	if page < pages {
		s += " [older →](" + link(base) + "?page=" + strconv.Itoa(page+1) + ")"
	}
	return s + "\n"
}

func pageParam(req *mux.Request) int {
	p, err := strconv.Atoi(req.Query.Get("page"))
	if err != nil || p < 1 {
		return 1
	}
	return p
}

func badge(s bounty.Status) string {
	switch s {
	case bounty.StatusOpen:
		return "🟢 open"
	case bounty.StatusClaimed:
		return "🟡 claimed"
	case bounty.StatusSubmitted:
		return "🔵 in review"
	case bounty.StatusPaid:
		return "💰 paid"
	case bounty.StatusCancelled:
		return "⚪ cancelled"
	}
	return s.String()
}

func medal(i int) string {
	switch i {
	case 0:
		return "🥇"
	case 1:
		return "🥈"
	case 2:
		return "🥉"
	}
	return ""
}

func who(a address) string {
	if a == "" {
		return "–"
	}
	return "[" + short(a) + "](" + link("u/"+a.String()) + ")"
}

func short(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:7] + "…" + s[len(s)-4:]
}

func proof(p string) string {
	if u := sanitize.URL(p); u != "" && (strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://")) {
		return "[" + sanitize.LinkTitle(p) + "](" + u + ")"
	}
	return sanitize.TableCell(p)
}

// link builds a path inside this realm, e.g. link("hunters") -> "/r/…/barkeep:hunters".
func link(sub string) string {
	if sub == "" {
		return realmURL()
	}
	return realmURL() + ":" + sub
}

func realmURL() string {
	return strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), runtime.ChainDomain())
}

// gnot formats ugnot as GNOT with up to 6 decimals, e.g. 1500000 -> "1.5 GNOT".
func gnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fs := strconv.FormatInt(frac+1_000_000, 10)[1:] // zero-padded to 6 digits
	fs = strings.TrimRight(fs, "0")
	return strconv.FormatInt(whole, 10) + "." + fs + " GNOT"
}

func ts(t time.Time) string {
	if t.IsZero() {
		return "–"
	}
	return t.UTC().Format("2006-01-02 15:04 UTC")
}

func dur(d time.Duration) string {
	h := int(d / time.Hour)
	if h >= 48 && h%24 == 0 {
		return strconv.Itoa(h/24) + " days"
	}
	if h == 1 {
		return "1 hour"
	}
	return strconv.Itoa(h) + " hours"
}

func left(now, deadline time.Time) string {
	if now.After(deadline) {
		return "expired"
	}
	d := deadline.Sub(now)
	if d < time.Hour {
		return strconv.Itoa(int(d/time.Minute)) + " min left"
	}
	return dur(d.Truncate(time.Hour)) + " left"
}
