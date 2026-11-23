package questboard

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Render serves the board in gnoweb:
//
//	""            home: totals, open quests, recently closed
//	"quest/<id>"  one quest with its submissions and action links
//	"u/<addr>"    an address's public track record
func Render(path string) string {
	path = strings.Trim(path, "/")
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "quest/"):
		id, err := strconv.Atoi(strings.TrimPrefix(path, "quest/"))
		if err != nil {
			return "# 404\n\nBad quest id. [Back to the board](" + homeURL() + ")"
		}
		return renderQuest(id)
	case strings.HasPrefix(path, "u/"):
		return renderProfile(address(strings.TrimPrefix(path, "u/")))
	}
	return "# 404\n\n[Back to the board](" + homeURL() + ")"
}

const maxHomeRows = 30

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Quest Board\n\n")
	b.WriteString("Post a task, lock GNOT as the reward, and pay whoever delivers. ")
	b.WriteString("The reward sits in this realm's escrow until the poster awards it or it is refunded, ")
	b.WriteString("and every address builds a public record of what it paid and what it earned.\n\n")
	b.WriteString(ufmt.Sprintf("**%d** open quests · **%s** in escrow · **%s** paid to hunters · **%d** quests completed\n\n",
		openCount, gnot(escrowed), gnot(paidOut), completed))
	b.WriteString("[**+ Post a quest**](" + txlink.NewLink("PostQuest").AddArgs("days", "7").SetSend("1000000ugnot").URL() + ")\n\n")

	b.WriteString("## Open quests\n\n")
	if open.Size() == 0 {
		b.WriteString("_No open quests yet. Be the first to post one._\n\n")
	} else {
		b.WriteString("| # | Quest | Reward | Due (UTC) | Submissions |\n|---|---|---|---|---|\n")
		shown := 0
		open.ReverseIterate("", "", func(_ string, v any) bool {
			if shown >= maxHomeRows {
				return true
			}
			shown++
			q := v.(*Quest)
			b.WriteString(ufmt.Sprintf("| %d | [%s](%s) | %s | %s | %d |\n",
				q.ID, sanitize.TableCell(q.Title), questURL(q.ID), gnot(q.Reward), dueLabel(q), len(q.Subs)))
			return false
		})
		b.WriteString("\n")
		if open.Size() > maxHomeRows {
			b.WriteString(ufmt.Sprintf("_Showing the newest %d of %d open quests._\n\n", maxHomeRows, open.Size()))
		}
	}

	if len(closed) > 0 {
		b.WriteString("## Recently closed\n\n")
		for i := len(closed) - 1; i >= 0; i-- {
			q := getQuest(closed[i])
			if q == nil {
				continue
			}
			line := ufmt.Sprintf("- [#%d %s](%s): %s, %s", q.ID, sanitize.InlineText(q.Title), questURL(q.ID), q.Status.String(), gnot(q.Reward))
			if q.Status == StatusAwarded {
				line += " to " + addrLink(q.Winner)
			}
			b.WriteString(line + "\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## How it works\n\n")
	b.WriteString("1. **Post** a quest with `PostQuest` and send the reward (at least " + gnot(MinReward) + "). Optionally name an arbiter.\n")
	b.WriteString("2. **Fund**: anyone can add to the reward with `Fund`. Funders are refunded if the quest does not pay out.\n")
	b.WriteString("3. **Submit**: hunters post a link to their work with `Submit` before the deadline.\n")
	b.WriteString("4. **Award**: the poster (or arbiter) pays the whole escrow to one hunter with `Award`, or turns a submission down with `Reject`.\n")
	b.WriteString("5. **Refund**: `Cancel` refunds everyone. If nobody decides within " + days(GracePeriod) + " after the deadline, anyone can call `Expire` to refund.\n\n")
	b.WriteString("Cancelling after work was submitted, or letting a quest expire with hunters waiting, shows up on the poster's profile at `:u/<address>`.\n")
	return b.String()
}

func renderQuest(id int) string {
	q := getQuest(id)
	if q == nil {
		return "# 404\n\nQuest not found. [Back to the board](" + homeURL() + ")"
	}
	now := time.Now()
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# #%d %s\n\n", q.ID, sanitize.InlineText(q.Title)))
	b.WriteString("[← Board](" + homeURL() + ")\n\n")
	b.WriteString(ufmt.Sprintf("- **Status:** %s\n", statusLabel(q, now)))
	b.WriteString(ufmt.Sprintf("- **Reward:** %s\n", gnot(q.Reward)))
	b.WriteString(ufmt.Sprintf("- **Poster:** %s\n", addrLink(q.Poster)+posterSummary(q.Poster)))
	if q.Arbiter != "" {
		b.WriteString(ufmt.Sprintf("- **Arbiter:** %s\n", addrLink(q.Arbiter)))
	}
	b.WriteString(ufmt.Sprintf("- **Posted:** %s\n", fmtTime(q.CreatedAt)))
	b.WriteString(ufmt.Sprintf("- **Deadline:** %s\n", fmtTime(q.Deadline)))
	if q.Status == StatusAwarded {
		b.WriteString(ufmt.Sprintf("- **Winner:** %s\n", addrLink(q.Winner)))
	}
	b.WriteString("\n")

	if q.Body != "" {
		b.WriteString("## Details\n")
		b.WriteString(sanitize.Block(q.Body))
		b.WriteString("\n")
	}

	if q.Status == StatusOpen {
		ids := strconv.Itoa(q.ID)
		b.WriteString("## Actions\n\n")
		if !q.pastDeadline(now) {
			b.WriteString("- [Submit your work](" + txlink.NewLink("Submit").AddArgs("id", ids).URL() + ")\n")
			b.WriteString("- [Add to the reward](" + txlink.NewLink("Fund").AddArgs("id", ids).SetSend("100000ugnot").URL() + ")\n")
		}
		b.WriteString("- Poster / arbiter: [Award](" + txlink.NewLink("Award").AddArgs("id", ids).URL() + ") · [Reject a submission](" +
			txlink.NewLink("Reject").AddArgs("id", ids).URL() + ") · [Cancel and refund](" + txlink.NewLink("Cancel").AddArgs("id", ids).URL() + ")\n")
		if q.expirable(now) {
			b.WriteString("- Anyone: [Expire and refund](" + txlink.NewLink("Expire").AddArgs("id", ids).URL() + ")\n")
		}
		b.WriteString("\n")
	}

	b.WriteString(ufmt.Sprintf("## Submissions (%d)\n\n", len(q.Subs)))
	if len(q.Subs) == 0 {
		b.WriteString("_None yet._\n\n")
	} else {
		b.WriteString("| Hunter | Work | Note | When (UTC) | State |\n|---|---|---|---|---|\n")
		for _, s := range q.Subs {
			state := "pending"
			if q.Status == StatusAwarded && s.Hunter == q.Winner {
				state = "**winner**"
			} else if s.Rejected {
				state = "rejected"
				if s.Reason != "" {
					state += ": " + sanitize.TableCell(s.Reason)
				}
			} else if q.Status != StatusOpen {
				state = "-"
			}
			work := "-"
			if u := sanitize.URL(s.Link); u != "" {
				work = "[link](" + u + ")"
			}
			b.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s |\n",
				addrLink(s.Hunter), work, sanitize.TableCell(s.Note), fmtTime(s.At), state))
		}
		b.WriteString("\n")
	}

	b.WriteString(ufmt.Sprintf("## Funders (%d)\n\n", len(q.Contribs)))
	for _, c := range q.Contribs {
		b.WriteString(ufmt.Sprintf("- %s: %s\n", addrLink(c.From), gnot(c.Amount)))
	}
	return b.String()
}

func renderProfile(addr address) string {
	if !addr.IsValid() {
		return "# 404\n\nInvalid address. [Back to the board](" + homeURL() + ")"
	}
	var b strings.Builder
	b.WriteString("# Track record\n\n")
	b.WriteString("`" + addr.String() + "`\n\n[← Board](" + homeURL() + ")\n\n")
	p := peekProfile(addr)
	if p == nil {
		b.WriteString("_No activity on this board yet._\n")
		return b.String()
	}
	b.WriteString("## As a poster\n\n")
	b.WriteString(ufmt.Sprintf("- Quests posted: **%d**\n", p.Posted))
	b.WriteString(ufmt.Sprintf("- Paid out: **%d** quests, **%s**\n", p.Completed, gnot(p.Paid)))
	b.WriteString(ufmt.Sprintf("- Cancelled after work was submitted: **%d**\n", p.Cancelled))
	b.WriteString(ufmt.Sprintf("- Expired with hunters waiting (ghosted): **%d**\n", p.Ghosted))
	b.WriteString(ufmt.Sprintf("- Added to others' rewards: **%s**\n\n", gnot(p.Funded)))
	b.WriteString("## As a hunter\n\n")
	b.WriteString(ufmt.Sprintf("- Submissions: **%d**\n", p.Submitted))
	b.WriteString(ufmt.Sprintf("- Quests won: **%d**, earned **%s**\n\n", p.Won, gnot(p.Earned)))
	if len(p.Recent) > 0 {
		b.WriteString("## Recent quests posted\n\n")
		for i := len(p.Recent) - 1; i >= 0; i-- {
			q := getQuest(p.Recent[i])
			if q == nil {
				continue
			}
			b.WriteString(ufmt.Sprintf("- [#%d %s](%s): %s, %s\n", q.ID, sanitize.InlineText(q.Title), questURL(q.ID), q.Status.String(), gnot(q.Reward)))
		}
	}
	return b.String()
}

// ---- formatting helpers ----

// homeURL is this realm's gnoweb path, e.g. /r/<addr>/questboard.
func homeURL() string {
	return strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), runtime.ChainDomain())
}

func questURL(id int) string { return homeURL() + ":quest/" + strconv.Itoa(id) }
func addrLink(a address) string {
	s := a.String()
	short := s
	if len(s) > 14 {
		short = s[:8] + "…" + s[len(s)-4:]
	}
	return "[" + short + "](" + homeURL() + ":u/" + s + ")"
}

func posterSummary(a address) string {
	p := peekProfile(a)
	if p == nil {
		return ""
	}
	return ufmt.Sprintf(" (paid %d of %d quests, %s total)", p.Completed, p.Posted, gnot(p.Paid))
}

func statusLabel(q *Quest, now time.Time) string {
	if q.Status != StatusOpen {
		return q.Status.String() + " on " + fmtTime(q.ClosedAt)
	}
	if !q.pastDeadline(now) {
		return "open, " + remaining(q.Deadline.Sub(now)) + " left to submit"
	}
	if q.expirable(now) {
		return "awaiting decision (grace period over: anyone can Expire)"
	}
	return "awaiting decision, " + remaining(q.Deadline.Add(GracePeriod).Sub(now)) + " until refundable"
}

func dueLabel(q *Quest) string {
	now := time.Now()
	if q.pastDeadline(now) {
		return "closed for submissions"
	}
	return q.Deadline.UTC().Format("2006-01-02") + " (" + remaining(q.Deadline.Sub(now)) + ")"
}

func remaining(d time.Duration) string {
	if d <= 0 {
		return "0h"
	}
	h := int(d / time.Hour)
	if h >= 48 {
		return strconv.Itoa(h/24) + "d"
	}
	if h >= 1 {
		return strconv.Itoa(h) + "h"
	}
	return strconv.Itoa(int(d/time.Minute)) + "m"
}

func days(d time.Duration) string { return strconv.Itoa(int(d/(24*time.Hour))) + " days" }

func fmtTime(t time.Time) string { return t.UTC().Format("2006-01-02 15:04") }

// gnot formats an ugnot amount as GNOT, e.g. 1500000 -> "1.5 GNOT".
func gnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fs := strconv.FormatInt(frac+1_000_000, 10)[1:]
	fs = strings.TrimRight(fs, "0")
	return strconv.FormatInt(whole, 10) + "." + fs + " GNOT"
}
