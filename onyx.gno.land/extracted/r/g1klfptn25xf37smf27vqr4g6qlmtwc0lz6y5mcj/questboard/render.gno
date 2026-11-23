package questboard

import (
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/jeronimoalbi/mdform/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	listLimit      = 25 // open quests shown on the home page
	recentLimit    = 5  // settled quests shown on the home page
	leaderboardLen = 10
	scanLimit      = 500 // quests scanned per render, newest first
)

// Render serves the board to gnoweb:
//
//	""             the board: stats, how it works, open quests, leaderboard
//	"quest/<id>"   one quest with its backers, hand-ins, awards and actions
//	"u/<address>"  a hunter / poster profile with a rank badge
func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case path == "" || path == "/":
		return renderHome()
	case len(parts) == 2 && parts[0] == "quest":
		id, err := strconv.Atoi(parts[1])
		if err != nil || getQuest(id) == nil {
			return "# Quest not found\n\n[Back to the board](" + boardURL() + ")\n"
		}
		return renderQuest(getQuest(id))
	case len(parts) == 2 && parts[0] == "u":
		addr := address(parts[1])
		if !addr.IsValid() {
			return "# Unknown adventurer\n\n[Back to the board](" + boardURL() + ")\n"
		}
		return renderProfile(addr)
	}
	return "# 404\n\n[Back to the board](" + boardURL() + ")\n"
}

func renderHome() string {
	var b strings.Builder
	now := time.Now()

	b.WriteString("# 🍺 The Quest Board\n\n")
	b.WriteString("*A notice board in the tavern: pin a quest, lock the reward on-chain, pay the gnome who gets it done.*\n\n")

	openCount := 0
	var open, settled []*Quest
	scanned := 0
	quests.ReverseIterate("", "", func(_ string, v any) bool {
		q := v.(*Quest)
		if q.Status == StatusOpen {
			openCount++
			if len(open) < listLimit {
				open = append(open, q)
			}
		} else if len(settled) < recentLimit {
			settled = append(settled, q)
		}
		scanned++
		return scanned >= scanLimit
	})

	b.WriteString("| Open quests | In escrow | Paid to hunters | Hunters paid |\n")
	b.WriteString("| :---: | :---: | :---: | :---: |\n")
	b.WriteString(ufmt.Sprintf("| %d | %s | %s | %d |\n\n", openCount, formatGNOT(totalEscrow), formatGNOT(totalPaid), paidHunters))

	b.WriteString("## How it works\n\n")
	b.WriteString("1. **Pin a quest.** Call `PostQuest` with a title, details and a deadline in days, and attach the reward. The GNOT is locked in this realm, not held by anyone.\n")
	b.WriteString("2. **Chip in.** Anyone can grow a reward with `Fund`. Unused funds go back to every backer pro rata.\n")
	b.WriteString("3. **Hand in work.** Hunters call `Submit` with a link or a short note before the deadline.\n")
	b.WriteString("4. **Get paid.** The poster calls `Award`; the coins go straight from escrow to the hunter. A reward can be split between several hunters.\n")
	b.WriteString("5. **No ghosting.** If a poster never settles, anyone can call `Expire` " + days(GracePeriod) + " after the deadline and every backer is refunded. Posters who let quests expire carry it on their profile.\n\n")

	b.WriteString("**Pin a quest:** ")
	for i, amt := range []int64{1_000_000, 5_000_000, 10_000_000} {
		if i > 0 {
			b.WriteString(" · ")
		}
		b.WriteString(ufmt.Sprintf("[%s reward](%s)", formatGNOT(amt), board().NewLink("PostQuest").AddArgs("days", "7").SetSend(ufmt.Sprintf("%dugnot", amt)).URL()))
	}
	b.WriteString("\n\n")

	b.WriteString("## Open quests\n\n")
	if len(open) == 0 {
		b.WriteString("*The board is empty. Be the first to pin a quest.*\n\n")
	} else {
		b.WriteString("| # | Quest | Reward | Hand-ins | Closes |\n")
		b.WriteString("| :--- | :--- | ---: | :---: | :--- |\n")
		for _, q := range open {
			closes := "in " + humanDuration(q.Deadline.Sub(now))
			if !now.Before(q.Deadline) {
				closes = "awaiting award"
			}
			b.WriteString(ufmt.Sprintf("| %d | [%s](%s) | %s | %d | %s |\n",
				q.ID, sanitize.TableCell(q.Title), questURL(q.ID), formatGNOT(q.Remaining()), len(q.hunters), closes))
		}
		b.WriteString("\n")
	}

	if len(settled) > 0 {
		b.WriteString("## Recently settled\n\n")
		for _, q := range settled {
			b.WriteString(ufmt.Sprintf("- [#%d %s](%s): %s, %s paid to %d hunter(s)\n",
				q.ID, sanitize.InlineText(q.Title), questURL(q.ID), q.Status.String(), formatGNOT(q.Paid), awardedHunters(q)))
		}
		b.WriteString("\n")
	}

	b.WriteString("## Top hunters\n\n")
	top := topHunters(leaderboardLen)
	if len(top) == 0 {
		b.WriteString("*No hunter has been paid yet.*\n")
	} else {
		b.WriteString("| | Hunter | Rank | Quests won | Earned |\n")
		b.WriteString("| :---: | :--- | :--- | :---: | ---: |\n")
		for i, h := range top {
			b.WriteString(ufmt.Sprintf("| %d | %s | %s | %d | %s |\n",
				i+1, userLink(h.addr), rankOf(h.p.Wins).Name, h.p.Wins, formatGNOT(h.p.Earned)))
		}
	}
	return b.String()
}

func renderQuest(q *Quest) string {
	var b strings.Builder
	now := time.Now()

	b.WriteString(ufmt.Sprintf("# Quest #%d: %s\n\n", q.ID, sanitize.InlineText(q.Title)))
	b.WriteString("[← Back to the board](" + boardURL() + ")\n\n")

	b.WriteString("| Status | Reward left | Total pool | Paid out | Deadline |\n")
	b.WriteString("| :---: | :---: | :---: | :---: | :--- |\n")
	b.WriteString(ufmt.Sprintf("| **%s** | %s | %s | %s | %s |\n\n",
		statusLabel(q, now), formatGNOT(q.Remaining()), formatGNOT(q.Pool), formatGNOT(q.Paid), deadlineLabel(q, now)))

	b.WriteString("Pinned by " + userLink(q.Poster) + " " + humanDuration(now.Sub(q.CreatedAt)) + " ago. " + posterTrust(q.Poster) + "\n\n")

	if q.Details != "" {
		b.WriteString("## Details\n\n")
		b.WriteString(sanitize.Block(escapeHTML(q.Details)) + "\n\n")
	}

	if q.Status == StatusOpen {
		b.WriteString(renderActions(q, now))
	}

	b.WriteString(ufmt.Sprintf("## Hand-ins (%d)\n\n", len(q.hunters)))
	if len(q.hunters) == 0 {
		b.WriteString("*Nobody has handed in work yet.*\n\n")
	} else {
		b.WriteString("| Hunter | Proof | Handed in | Awarded |\n")
		b.WriteString("| :--- | :--- | :--- | ---: |\n")
		for _, h := range q.hunters {
			v, _ := lookup(&q.subs, h.String())
			s := v.(*Submission)
			awarded := "-"
			if s.Awarded > 0 {
				awarded = "🏆 " + formatGNOT(s.Awarded)
			}
			b.WriteString(ufmt.Sprintf("| %s | %s | %s ago | %s |\n",
				userLink(h), proofCell(s.Proof), humanDuration(now.Sub(s.At)), awarded))
		}
		b.WriteString("\n")
	}

	if len(q.Awards) > 0 {
		b.WriteString("## Awards\n\n")
		for _, a := range q.Awards {
			line := ufmt.Sprintf("- %s to %s", formatGNOT(a.Amount), userLink(a.Hunter))
			if a.Note != "" {
				line += ": " + sanitize.InlineText(a.Note)
			}
			b.WriteString(line + "\n")
		}
		b.WriteString("\n")
	}

	b.WriteString(ufmt.Sprintf("## Backers (%d)\n\n", len(q.backers)))
	for _, addr := range q.backers {
		v, _ := lookup(&q.contribs, addr.String())
		b.WriteString(ufmt.Sprintf("- %s: %s\n", userLink(addr), formatGNOT(v.(int64))))
	}
	if q.Refunded > 0 {
		b.WriteString(ufmt.Sprintf("\n%s was returned to backers when the quest settled.\n", formatGNOT(q.Refunded)))
	}
	return b.String()
}

func renderActions(q *Quest, now time.Time) string {
	var b strings.Builder
	idStr := strconv.Itoa(q.ID)
	b.WriteString("## Take part\n\n")

	if now.Before(q.Deadline) {
		b.WriteString("**Chip in to the reward:** ")
		for i, amt := range []int64{100_000, 1_000_000, 5_000_000} {
			if i > 0 {
				b.WriteString(" · ")
			}
			b.WriteString(ufmt.Sprintf("[+%s](%s)", formatGNOT(amt), board().NewLink("Fund").AddArgs("id", idStr).SetSend(ufmt.Sprintf("%dugnot", amt)).URL()))
		}
		b.WriteString("\n\n### Hand in your work\n\n")
		b.WriteString(mdform.New("exec", "Submit").
			Input("id", "value", idStr, "readonly", "true").
			Textarea("proof", "placeholder", "Link to your work, or a short note (max 280 characters)", "rows", "3").
			String())
		b.WriteString("\n\n")
	} else {
		b.WriteString("*Hand-ins are closed. The poster has until " + q.Deadline.Add(GracePeriod).UTC().Format("2006-01-02 15:04 UTC") + " to award.*\n\n")
	}

	if len(q.hunters) > 0 {
		b.WriteString("### Poster: award a hunter\n\n")
		b.WriteString("Amount is in ugnot (1 GNOT = 1000000 ugnot). Award several hunters to split the reward.\n\n")
		b.WriteString(mdform.New("exec", "Award").
			Input("id", "value", idStr, "readonly", "true").
			Input("hunter", "placeholder", "g1... address of the hunter").
			Input("amount", "type", mdform.InputTypeNumber, "value", strconv.FormatInt(q.Remaining(), 10)).
			Input("note", "placeholder", "Optional thanks or feedback").
			String())
		b.WriteString("\n\n")
	}

	b.WriteString("**Settle:** ")
	b.WriteString("[Close and refund backers (poster)](" + board().NewLink("Close").AddArgs("id", idStr).URL() + ")")
	if !now.Before(q.Deadline.Add(GracePeriod)) {
		b.WriteString(" · [Expire and refund backers (anyone)](" + board().NewLink("Expire").AddArgs("id", idStr).URL() + ")")
	}
	b.WriteString("\n\n")
	return b.String()
}

func renderProfile(addr address) string {
	var b strings.Builder
	v, ok := lookup(&profiles, addr.String())
	p := &Profile{}
	if ok {
		p = v.(*Profile)
	}
	r := rankOf(p.Wins)

	b.WriteString("# " + shortAddr(addr) + "\n\n")
	b.WriteString("[← Back to the board](" + boardURL() + ")\n\n")
	b.WriteString(badge(r, p.Wins, p.Earned) + "\n\n")
	b.WriteString("`" + addr.String() + "`\n\n")

	b.WriteString("## As a hunter\n\n")
	b.WriteString(ufmt.Sprintf("- Rank: **%s**", r.Name))
	if next := nextRank(p.Wins); next.MinWins > 0 {
		b.WriteString(ufmt.Sprintf(" (%d more win(s) to %s)", next.MinWins-p.Wins, next.Name))
	}
	b.WriteString("\n")
	b.WriteString(ufmt.Sprintf("- Hand-ins: %d\n- Quests won: %d\n- Earned: %s\n\n", p.HandIns, p.Wins, formatGNOT(p.Earned)))

	b.WriteString("## As a poster\n\n")
	b.WriteString(ufmt.Sprintf("- Quests pinned: %d\n- Settled with a payout: %d\n- Settled without a payout: %d\n- Let expire: %d\n- Paid to hunters: %s\n\n",
		p.Posted, p.Completed, p.Cancelled, p.Expired, formatGNOT(p.PaidOut)))

	b.WriteString("## As a backer\n\n")
	b.WriteString(ufmt.Sprintf("- Put into rewards: %s\n\n", formatGNOT(p.Backed)))

	var mine []*Quest
	quests.ReverseIterate("", "", func(_ string, v any) bool {
		q := v.(*Quest)
		if q.Poster == addr {
			mine = append(mine, q)
		} else if _, ok := lookup(&q.subs, addr.String()); ok {
			mine = append(mine, q)
		}
		return len(mine) >= listLimit
	})
	if len(mine) > 0 {
		b.WriteString("## Quests\n\n")
		for _, q := range mine {
			role := "hunter"
			if q.Poster == addr {
				role = "poster"
			}
			b.WriteString(ufmt.Sprintf("- [#%d %s](%s) as %s, %s\n", q.ID, sanitize.InlineText(q.Title), questURL(q.ID), role, q.Status.String()))
		}
	}
	return b.String()
}

// ----------------------------------------------------------------------------
// helpers

type hunterEntry struct {
	addr address
	p    *Profile
}

// topHunters returns the n hunters with the most GNOT earned.
func topHunters(n int) []hunterEntry {
	var top []hunterEntry
	profiles.Iterate("", "", func(k string, v any) bool {
		p := v.(*Profile)
		if p.Earned == 0 {
			return false
		}
		e := hunterEntry{address(k), p}
		i := len(top)
		for i > 0 && top[i-1].p.Earned < p.Earned {
			i--
		}
		if i < n {
			top = append(top, hunterEntry{})
			copy(top[i+1:], top[i:])
			top[i] = e
			if len(top) > n {
				top = top[:n]
			}
		}
		return false
	})
	return top
}

func awardedHunters(q *Quest) int {
	n := 0
	for _, h := range q.hunters {
		v, _ := lookup(&q.subs, h.String())
		if v.(*Submission).Awarded > 0 {
			n++
		}
	}
	return n
}

func posterTrust(addr address) string {
	v, ok := lookup(&profiles, addr.String())
	if !ok {
		return ""
	}
	p := v.(*Profile)
	settled := p.Completed + p.Cancelled
	if settled == 0 {
		return "*First quest from this poster.*"
	}
	s := ufmt.Sprintf("*Poster record: %d of %d settled quest(s) paid a hunter", p.Completed, settled)
	if p.Expired > 0 {
		s += ufmt.Sprintf(", %d left to expire", p.Expired)
	}
	return s + ".*"
}

func statusLabel(q *Quest, now time.Time) string {
	switch q.Status {
	case StatusCompleted:
		return "✅ completed"
	case StatusCancelled:
		if q.Expired {
			return "⌛ expired"
		}
		return "✖ cancelled"
	}
	if now.Before(q.Deadline) {
		return "🟢 open"
	}
	return "⏳ awaiting award"
}

func deadlineLabel(q *Quest, now time.Time) string {
	d := q.Deadline.UTC().Format("2006-01-02 15:04 UTC")
	if q.Status == StatusOpen && now.Before(q.Deadline) {
		d += " (in " + humanDuration(q.Deadline.Sub(now)) + ")"
	}
	return d
}

// proofCell renders a hand-in: http(s) links become links, anything else is
// escaped text.
func proofCell(proof string) string {
	if strings.HasPrefix(proof, "https://") || strings.HasPrefix(proof, "http://") {
		if u := sanitize.URL(proof); u != "" && !strings.ContainsAny(proof, " \t\n") {
			label := proof
			if len(label) > 48 {
				label = label[:45] + "..."
			}
			return "[" + sanitize.TableCell(label) + "](" + u + ")"
		}
	}
	return sanitize.TableCell(proof)
}

func userLink(addr address) string {
	return "[" + shortAddr(addr) + "](" + boardURL() + ":u/" + addr.String() + ")"
}

func shortAddr(addr address) string {
	s := addr.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

var (
	pkgPath   string // gno.land/r/<addr>/questboard
	boardPath string // gnoweb path, e.g. /r/<addr>/questboard
)

func init(cur realm) {
	pkgPath = cur.PkgPath()
	boardPath = strings.TrimPrefix(pkgPath, runtime.ChainDomain())
}

// board returns a txlink builder for this realm, so links point here no
// matter which realm is rendering.
func board() txlink.Realm {
	return txlink.Realm(pkgPath)
}

// escapeHTML neutralises raw HTML in user text before it is rendered as
// markdown; gnoweb shows the entities as plain characters.
func escapeHTML(s string) string {
	s = strings.ReplaceAll(s, "<", "&lt;")
	return strings.ReplaceAll(s, ">", "&gt;")
}

func boardURL() string {
	return boardPath
}

func questURL(id int) string {
	return boardURL() + ":quest/" + strconv.Itoa(id)
}

// formatGNOT renders an ugnot amount as GNOT with up to six decimals.
func formatGNOT(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fs := strconv.FormatInt(frac, 10)
	for len(fs) < 6 {
		fs = "0" + fs
	}
	fs = strings.TrimRight(fs, "0")
	return strconv.FormatInt(whole, 10) + "." + fs + " GNOT"
}

// humanDuration renders a duration as its two largest units, e.g. "3d 4h".
func humanDuration(d time.Duration) string {
	if d < 0 {
		d = -d
	}
	day := 24 * time.Hour
	switch {
	case d >= day:
		return ufmt.Sprintf("%dd %dh", int(d/day), int((d%day)/time.Hour))
	case d >= time.Hour:
		return ufmt.Sprintf("%dh %dm", int(d/time.Hour), int((d%time.Hour)/time.Minute))
	case d >= time.Minute:
		return ufmt.Sprintf("%dm", int(d/time.Minute))
	}
	return "moments"
}

func days(d time.Duration) string {
	return strconv.Itoa(int(d/(24*time.Hour))) + " days"
}
