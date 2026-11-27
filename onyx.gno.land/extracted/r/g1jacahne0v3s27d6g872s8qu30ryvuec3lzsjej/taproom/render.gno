package taproom

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

const stamp = "2006-01-02 15:04 UTC"

// Render serves the board in gnoweb.
//
//	""                 the board
//	"quest/<id>"       one quest with its submissions
//	"hunter/<address>" a reputation card
//	"about"            how it works
//	"json"             the latest quests as JSON, for the web front end
func Render(path string) string {
	switch {
	case path == "":
		return renderBoard()
	case path == "json":
		return renderJSON()
	case path == "about":
		return renderAbout()
	case strings.HasPrefix(path, "quest/"):
		id, err := strconv.Atoi(strings.TrimPrefix(path, "quest/"))
		if err != nil || id < 1 || id > nextID {
			return "# Not found\n\nThere is no such quest. [Back to the board](" + self() + ")\n"
		}
		return renderQuest(mustQuest(id))
	case strings.HasPrefix(path, "hunter/"):
		a := address(strings.TrimPrefix(path, "hunter/"))
		if !a.IsValid() {
			return "# Not found\n\nThat is not a valid address. [Back to the board](" + self() + ")\n"
		}
		return renderPerson(a)
	}
	return "# Not found\n\n[Back to the board](" + self() + ")\n"
}

func self() string { return strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land") }

func renderBoard() string {
	var b strings.Builder
	b.WriteString("# Taproom\n\n")
	b.WriteString("*An escrowed bounty board. Pin a quest, lock the reward, pay the best answer.*\n\n")

	open := 0
	quests.Iterate("", "", func(_ string, v any) bool {
		if v.(*quest).status == StatusOpen {
			open++
		}
		return false
	})
	b.WriteString("| Open quests | Locked in escrow | Paid to hunters | Quests pinned |\n")
	b.WriteString("| --- | --- | --- | --- |\n")
	b.WriteString("| " + strconv.Itoa(open) + " | " + gnot(totalEscrow) + " | " + gnot(totalPaid) + " | " + strconv.Itoa(nextID) + " |\n\n")

	b.WriteString("## Open quests\n\n")
	if open == 0 {
		b.WriteString("The board is empty. [Pin the first quest](" + self() + "$help&func=PostQuest).\n\n")
	} else {
		b.WriteString("| Quest | Reward | Closes | Answers |\n| --- | --- | --- | --- |\n")
		shown := 0
		quests.ReverseIterate("", "", func(_ string, v any) bool {
			q := v.(*quest)
			if q.status != StatusOpen {
				return false
			}
			b.WriteString("| [" + esc(q.title) + "](" + self() + ":quest/" + strconv.Itoa(q.id) + ") | " +
				gnot(q.reward) + " | " + q.deadline.UTC().Format(stamp) + " | " + strconv.Itoa(len(q.subs)) + " |\n")
			shown++
			return shown >= 25
		})
		b.WriteString("\n")
	}

	// recently settled
	settled := 0
	quests.Iterate("", "", func(_ string, v any) bool {
		if v.(*quest).status != StatusOpen {
			settled++
		}
		return false
	})
	if settled > 0 {
		b.WriteString("## Recently settled\n\n| Quest | Reward | Result |\n| --- | --- | --- |\n")
		shown := 0
		quests.ReverseIterate("", "", func(_ string, v any) bool {
			q := v.(*quest)
			if q.status == StatusOpen {
				return false
			}
			result := "reclaimed by poster"
			if q.status == StatusAwarded {
				result = "won by [" + short(q.winner) + "](" + self() + ":hunter/" + q.winner.String() + ")"
			}
			b.WriteString("| [" + esc(q.title) + "](" + self() + ":quest/" + strconv.Itoa(q.id) + ") | " + gnot(q.reward) + " | " + result + " |\n")
			shown++
			return shown >= 10
		})
		b.WriteString("\n")
	}

	b.WriteString("---\n\n[How it works](" + self() + ":about) · [Pin a quest](" + self() + "$help&func=PostQuest)\n")
	return b.String()
}

func renderQuest(q *quest) string {
	var b strings.Builder
	id := strconv.Itoa(q.id)
	b.WriteString("# " + esc(q.title) + "\n\n")
	b.WriteString("| Reward | Status | Closes | Posted by |\n| --- | --- | --- | --- |\n")
	b.WriteString("| **" + gnot(q.reward) + "** | " + q.status.String() + " | " + q.deadline.UTC().Format(stamp) +
		" | [" + short(q.poster) + "](" + self() + ":hunter/" + q.poster.String() + ") |\n\n")
	b.WriteString("> " + esc(q.details) + "\n\n")

	switch q.status {
	case StatusOpen:
		b.WriteString("[Submit an answer](" + self() + "$help&func=Submit&id=" + id + ")")
		b.WriteString(" · [Award (poster)](" + self() + "$help&func=Award&id=" + id + ")")
		b.WriteString(" · [Reclaim (poster)](" + self() + "$help&func=Reclaim&id=" + id + ")\n\n")
	case StatusAwarded:
		b.WriteString("**Winner:** [" + short(q.winner) + "](" + self() + ":hunter/" + q.winner.String() + ")\n\n")
	case StatusReclaimed:
		b.WriteString("The poster reclaimed the escrow.\n\n")
	}

	b.WriteString("## Answers (" + strconv.Itoa(len(q.subs)) + ")\n\n")
	if len(q.subs) == 0 {
		b.WriteString("No answers yet.\n\n")
	}
	for i, s := range q.subs {
		b.WriteString(strconv.Itoa(i+1) + ". [" + short(s.hunter) + "](" + self() + ":hunter/" + s.hunter.String() + ") · " +
			s.at.UTC().Format(stamp) + "\n   > " + esc(s.note))
		if s.link != "" {
			b.WriteString("\n   > <" + s.link + ">")
		}
		b.WriteString("\n")
	}
	b.WriteString("\n[Back to the board](" + self() + ")\n")
	return b.String()
}

func renderPerson(a address) string {
	var b strings.Builder
	b.WriteString("# " + short(a) + "\n\n`" + a.String() + "`\n\n")
	v := people.Get(a.String())
	if v == nil {
		b.WriteString("This address has not touched the board yet.\n\n[Back to the board](" + self() + ")\n")
		return b.String()
	}
	s := v.(*stats)
	b.WriteString("| Quests pinned | Paid as poster | Answers sent | Quests won | Earned as hunter |\n| --- | --- | --- | --- | --- |\n")
	b.WriteString("| " + strconv.Itoa(s.posted) + " | " + gnot(s.paidOut) + " | " + strconv.Itoa(s.submitted) +
		" | " + strconv.Itoa(s.won) + " | " + gnot(s.earned) + " |\n\n[Back to the board](" + self() + ")\n")
	return b.String()
}

func renderAbout() string {
	return `# How Taproom works

1. **Pin.** A poster calls ` + "`PostQuest`" + ` with a title, details, a window in days and at least 1 GNOT attached. The reward is locked in the realm.
2. **Answer.** Each hunter sends one answer with a note and an optional https link, until the window closes.
3. **Award.** The poster picks a winner. The escrow is paid in the same transaction.
4. **Reclaim.** With no answers the poster can withdraw any time. Once answers exist, the poster must wait for the window plus a 7-day review period, so a silent poster cannot starve hunters who delivered.

Only ugnot is accepted, only from a direct user call, and every payout is checked against the realm balance.

[Back to the board](` + self() + `)
`
}

// short renders an address as g1abcd…wxyz.
func short(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "…" + s[len(s)-4:]
}

// esc neutralises user text so it cannot inject markdown, HTML or table breaks.
func esc(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '\n', '\r', '\t':
			b.WriteRune(' ')
		case '\\', '`', '*', '_', '[', ']', '<', '>', '|', '#', '!', '(', ')', '~', '&':
			b.WriteRune('\\')
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

const jsonLimit = 50

// renderJSON returns the newest quests (with their answers) as one JSON
// document. Times are unix seconds, amounts are ugnot, ids are numbers.
func renderJSON() string {
	var b strings.Builder
	b.WriteString(`{"realm":` + jstr(unsafe.CurrentRealm().PkgPath()))
	b.WriteString(`,"now":` + strconv.FormatInt(time.Now().Unix(), 10))
	b.WriteString(`,"count":` + strconv.Itoa(nextID))
	b.WriteString(`,"escrow":` + strconv.FormatInt(totalEscrow, 10))
	b.WriteString(`,"paid":` + strconv.FormatInt(totalPaid, 10))
	b.WriteString(`,"minReward":` + strconv.FormatInt(MinReward, 10))
	b.WriteString(`,"quests":[`)
	n := 0
	quests.ReverseIterate("", "", func(_ string, v any) bool {
		q := v.(*quest)
		if n > 0 {
			b.WriteString(",")
		}
		n++
		b.WriteString(`{"id":` + strconv.Itoa(q.id))
		b.WriteString(`,"poster":` + jstr(q.poster.String()))
		b.WriteString(`,"title":` + jstr(q.title))
		b.WriteString(`,"details":` + jstr(q.details))
		b.WriteString(`,"reward":` + strconv.FormatInt(q.reward, 10))
		b.WriteString(`,"created":` + strconv.FormatInt(q.created.Unix(), 10))
		b.WriteString(`,"deadline":` + strconv.FormatInt(q.deadline.Unix(), 10))
		b.WriteString(`,"status":` + jstr(q.status.String()))
		b.WriteString(`,"winner":` + jstr(q.winner.String()))
		b.WriteString(`,"answers":[`)
		for i, s := range q.subs {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(`{"hunter":` + jstr(s.hunter.String()) + `,"note":` + jstr(s.note) +
				`,"link":` + jstr(s.link) + `,"at":` + strconv.FormatInt(s.at.Unix(), 10) + `}`)
		}
		b.WriteString("]}")
		return n >= jsonLimit
	})
	b.WriteString("]}")
	return b.String()
}

// jstr quotes s as a JSON string.
func jstr(s string) string {
	const hex = "0123456789abcdef"
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&15])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
