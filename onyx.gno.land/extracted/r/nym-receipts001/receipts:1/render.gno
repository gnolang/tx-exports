package receipts

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
)

// SealerURL is an offline page that computes a commitment in your browser.
const SealerURL = "https://666crypro.github.io/receipts/"

var router *mux.Router

func init() {
	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("call/{id}", renderCall)
	router.HandleFunc("u/{addr}", renderAuthor)
	router.HandleFunc("board", renderBoard)
	router.HandleFunc("how", renderHow)
	router.SetNotFoundHandler(func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write("# Not found\n\nNo page here. [Back to Receipts](" + homeLink + ")\n")
	})
}

const homeLink = "/r/nym-receipts001/receipts"

// Render serves the gnoweb pages.
func Render(path string) string {
	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	now := time.Now()
	var sealed, revealed, ducked int
	calls.Iterate("", "", func(_ string, v any) bool {
		switch v.(*Call).status(now) {
		case StatusSealed:
			sealed++
		case StatusDucked:
			ducked++
		default:
			revealed++
		}
		return false
	})

	var b strings.Builder
	b.WriteString("# Receipts\n\n")
	b.WriteString("**Call it now. Prove it later.** Seal a prediction as a hash today; reveal it when the time comes. ")
	b.WriteString("The chain stamps when you sealed it, so nobody can say you made it up afterwards. ")
	b.WriteString("Miss your own reveal deadline and the call is marked **ducked** on your record, so cherry-picking shows.\n\n")

	b.WriteString("| Sealed calls | Revealed | Ducked | Authors |\n|---:|---:|---:|---:|\n")
	b.WriteString("| " + strconv.Itoa(sealed) + " | " + strconv.Itoa(revealed) + " | " + strconv.Itoa(ducked) + " | " + strconv.Itoa(authors.Size()) + " |\n\n")

	b.WriteString("<gno-button href=\"" + SealerURL + "\" label=\"1. Make a commitment (offline)\" />")
	b.WriteString(" <gno-button href=\"" + homeLink + ":board\" label=\"Track records\" variant=\"outline\" />")
	b.WriteString(" <gno-button href=\"" + homeLink + ":how\" label=\"How it works\" variant=\"outline\" />\n\n")

	b.WriteString("## Seal a call\n\n")
	b.WriteString("Paste the commitment from the sealer (or run `printf '%s|%s' \"$SALT\" \"$CALL\" | sha256sum`). Your text never touches the chain until you reveal it.\n\n")
	b.WriteString("<gno-form exec=\"Seal\">\n")
	b.WriteString("<gno-input name=\"topic\" placeholder=\"Public topic, e.g. Who wins the Dec 31 vote\" required=\"true\" />\n")
	b.WriteString("<gno-input name=\"commitment\" placeholder=\"Commitment: 64 hex characters\" required=\"true\" />\n")
	b.WriteString("<gno-input name=\"revealByDays\" type=\"number\" placeholder=\"Reveal within (days)\" value=\"30\" required=\"true\" />\n")
	b.WriteString("</gno-form>\n\n")

	b.WriteString("## Latest calls\n\n")
	if calls.Size() == 0 {
		b.WriteString("_No calls yet. Be the first._\n")
	} else {
		b.WriteString(callTableHeader)
		calls.ReverseIterateByOffset(0, 15, func(_ string, v any) bool {
			b.WriteString(callRow(v.(*Call), now))
			return false
		})
	}
	res.Write(b.String())
}

const callTableHeader = "| # | Topic | Author | Status | Sealed at block |\n|---:|---|---|---|---:|\n"

func callRow(c *Call, now time.Time) string {
	return "| [" + strconv.Itoa(c.ID) + "](" + callLink(c.ID) + ") | " +
		"[" + escDollar(sanitize.TableCell(c.Topic)) + "](" + callLink(c.ID) + ") | " +
		shortAddr(c.Author) + " | " + badge(c, now) + " | " +
		strconv.FormatInt(c.SealedHeight, 10) + " |\n"
}

func renderCall(res *mux.ResponseWriter, req *mux.Request) {
	id, err := strconv.Atoi(req.GetVar("id"))
	c := getCall(id)
	if err != nil || c == nil {
		res.Write("# Call not found\n\n[Back to Receipts](" + homeLink + ")\n")
		return
	}
	now := time.Now()
	var b strings.Builder
	b.WriteString("[Receipts](" + homeLink + ") / Call #" + strconv.Itoa(c.ID) + "\n\n")
	b.WriteString("# " + escDollar(sanitize.InlineText(c.Topic)) + "\n\n")
	b.WriteString("**" + badge(c, now) + "** · by [" + c.Author.String() + "](" + homeLink + ":u/" + c.Author.String() + ")\n\n")

	b.WriteString("| Receipt | |\n|---|---|\n")
	b.WriteString("| Sealed | block " + strconv.FormatInt(c.SealedHeight, 10) + " · " + fmtTime(c.SealedAt) + " |\n")
	b.WriteString("| Reveal by | " + fmtTime(c.RevealBy) + dueIn(c, now) + " |\n")
	if c.Revealed {
		b.WriteString("| Revealed | block " + strconv.FormatInt(c.RevealedHeight, 10) + " · " + fmtTime(c.RevealedAt) + " |\n")
	}
	b.WriteString("| Commitment | `" + c.Commitment + "` |\n\n")

	if c.Revealed {
		b.WriteString("## The call\n\n")
		b.WriteString(escDollar(sanitize.Blockquote(c.Prediction)) + "\n\n")
		b.WriteString("> [!SUCCESS] Verified on-chain\n")
		b.WriteString("> `sha256(salt + \"|\" + call)` equals the commitment sealed at block " +
			strconv.FormatInt(c.SealedHeight, 10) + ", " + blocksBetween(c) + " before the reveal. Salt: " +
			escDollar(sanitize.InlineCode(c.Salt)) + "\n\n")

		b.WriteString("## Did it hold?\n\n")
		b.WriteString("Held **" + strconv.Itoa(c.Held) + "** · Missed **" + strconv.Itoa(c.Missed) + "**")
		if o := c.outcome(); o != "" {
			b.WriteString(" · crowd says **" + o + "**")
		}
		b.WriteString("\n\nAnyone except the author can give one verdict (and change it later).\n\n")
		b.WriteString("<gno-form exec=\"Verdict\">\n")
		b.WriteString("<gno-input name=\"id\" type=\"number\" value=\"" + strconv.Itoa(c.ID) + "\" placeholder=\"Call ID\" readonly=\"true\" />\n")
		b.WriteString("<gno-input name=\"verdict\" type=\"radio\" value=\"held\" placeholder=\"it came true\" />\n")
		b.WriteString("<gno-input name=\"verdict\" type=\"radio\" value=\"missed\" placeholder=\"it did not\" />\n")
		b.WriteString("</gno-form>\n")
	} else {
		if c.status(now) == StatusDucked {
			b.WriteString("> [!WARNING] Ducked\n> The author promised to reveal this call by " + fmtTime(c.RevealBy) +
				" and has not. It counts against their track record until revealed, and a late reveal stays marked late.\n\n")
		} else {
			b.WriteString("> [!NOTE] Still sealed\n> Only the hash is public. The author reveals the exact text and salt; the realm checks the hash.\n\n")
		}
		b.WriteString("## Reveal (author only)\n\n")
		b.WriteString("<gno-form exec=\"Reveal\">\n")
		b.WriteString("<gno-input name=\"id\" type=\"number\" value=\"" + strconv.Itoa(c.ID) + "\" placeholder=\"Call ID\" readonly=\"true\" />\n")
		b.WriteString("<gno-textarea name=\"prediction\" rows=\"3\" placeholder=\"The exact call text you sealed\" />\n")
		b.WriteString("<gno-input name=\"salt\" placeholder=\"The exact salt you sealed with\" />\n")
		b.WriteString("</gno-form>\n")
	}
	res.Write(b.String())
}

// Record is an author's track record.
type Record struct {
	Author                             address
	Sealed, Open, OnTime, Late, Ducked int
	Held, Missed                       int
}

// KeptWord is the share of due calls revealed on time, in percent, or -1
// when nothing is due yet.
func (r Record) KeptWord() int {
	due := r.OnTime + r.Late + r.Ducked
	if due == 0 {
		return -1
	}
	return r.OnTime * 100 / due
}

func recordOf(a address, now time.Time) Record {
	r := Record{Author: a}
	au := getAuthor(a)
	if au == nil {
		return r
	}
	for _, id := range au.calls {
		c := getCall(id)
		r.Sealed++
		switch c.status(now) {
		case StatusSealed:
			r.Open++
		case StatusDucked:
			r.Ducked++
		case StatusLate:
			r.Late++
		case StatusRevealed:
			r.OnTime++
		}
		switch c.outcome() {
		case "held":
			r.Held++
		case "missed":
			r.Missed++
		}
	}
	return r
}

// TrackRecord returns an author's record, for clients (vm/qeval).
func TrackRecord(a address) Record { return recordOf(a, time.Now()) }

func renderAuthor(res *mux.ResponseWriter, req *mux.Request) {
	raw := req.GetVar("addr")
	a := address(raw)
	if !a.IsValid() {
		res.Write("# Unknown author\n\nThat is not a valid address. [Back](" + homeLink + ")\n")
		return
	}
	now := time.Now()
	r := recordOf(a, now)
	var b strings.Builder
	b.WriteString("[Receipts](" + homeLink + ") / Track record\n\n")
	b.WriteString("# " + a.String() + "\n\n")
	b.WriteString(recordHeader)
	b.WriteString(recordRow(r, false))
	b.WriteString("\n")
	au := getAuthor(a)
	if au == nil {
		b.WriteString("_No calls sealed by this address yet._\n")
		res.Write(b.String())
		return
	}
	b.WriteString("## Calls\n\n" + callTableHeader)
	for i := len(au.calls) - 1; i >= 0; i-- {
		b.WriteString(callRow(getCall(au.calls[i]), now))
	}
	res.Write(b.String())
}

const recordHeader = "| Author | Sealed | Open | On time | Late | Ducked | Kept word | Held | Missed |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|\n"

func recordRow(r Record, link bool) string {
	who := shortAddr(r.Author)
	if !link {
		who = "this address"
	}
	kw := "n/a"
	if k := r.KeptWord(); k >= 0 {
		kw = strconv.Itoa(k) + "%"
	}
	return "| " + who + " | " + strconv.Itoa(r.Sealed) + " | " + strconv.Itoa(r.Open) + " | " +
		strconv.Itoa(r.OnTime) + " | " + strconv.Itoa(r.Late) + " | " + strconv.Itoa(r.Ducked) + " | " +
		kw + " | " + strconv.Itoa(r.Held) + " | " + strconv.Itoa(r.Missed) + " |\n"
}

// better reports whether record x ranks above y: more held calls first,
// then a higher kept-word rate, then fewer ducked calls, then more sealed.
func better(x, y Record) bool {
	if x.Held != y.Held {
		return x.Held > y.Held
	}
	if x.KeptWord() != y.KeptWord() {
		return x.KeptWord() > y.KeptWord()
	}
	if x.Ducked != y.Ducked {
		return x.Ducked < y.Ducked
	}
	return x.Sealed > y.Sealed
}

// Leaderboard returns up to n records, best first.
func Leaderboard(n int) []Record {
	now := time.Now()
	var rs []Record
	authors.Iterate("", "", func(k string, _ any) bool {
		r := recordOf(address(k), now)
		// insertion sort: the author set is small and this is a read path
		i := len(rs)
		rs = append(rs, r)
		for i > 0 && better(rs[i], rs[i-1]) {
			rs[i], rs[i-1] = rs[i-1], rs[i]
			i--
		}
		return false
	})
	if n >= 0 && len(rs) > n {
		rs = rs[:n]
	}
	return rs
}

func renderBoard(res *mux.ResponseWriter, req *mux.Request) {
	var b strings.Builder
	b.WriteString("[Receipts](" + homeLink + ") / Track records\n\n# Track records\n\n")
	b.WriteString("Ranked by calls the crowd says **held**, then **kept word** (share of due calls revealed on time), then fewest **ducked**.\n\n")
	rs := Leaderboard(50)
	if len(rs) == 0 {
		b.WriteString("_Nobody has sealed a call yet._\n")
		res.Write(b.String())
		return
	}
	b.WriteString(recordHeader)
	for _, r := range rs {
		row := recordRow(r, true)
		row = strings.Replace(row, shortAddr(r.Author), "["+shortAddr(r.Author)+"]("+homeLink+":u/"+r.Author.String()+")", 1)
		b.WriteString(row)
	}
	res.Write(b.String())
}

func renderHow(res *mux.ResponseWriter, req *mux.Request) {
	res.Write(`[Receipts](` + homeLink + `) / How it works

# How it works

1. **Write your call** and pick a random **salt** (8 to 64 characters). The salt stops anyone from guessing short calls like "yes" by brute force.
2. **Compute the commitment** off-chain: lowercase hex of ` + "`sha256(salt + \"|\" + call)`" + `. Use the [offline sealer](` + SealerURL + `) or:
   ` + "`printf '%s|%s' \"$SALT\" \"$CALL\" | sha256sum`" + `
3. **Seal** it with a public topic and a reveal deadline in days. The chain records the block height and time.
4. **Reveal** any time before the deadline by sending the exact call and salt. The realm re-hashes them and only accepts an exact match.
5. **Verdicts.** Once revealed, other accounts mark it **held** or **missed**. One verdict per account, changeable.

## Statuses

| Status | Meaning |
|---|---|
| sealed | hash public, call hidden, deadline not passed |
| revealed | opened on or before the deadline and verified |
| revealed late | opened after the deadline: verified, but it does not count as kept word |
| ducked | deadline passed, still not revealed: counts against the author |

## For developers

Read-only helpers for clients via ` + "`vm/qeval`" + `: ` + "`Commit(call, salt)`, `GetCall(id)`, `StatusOf(id)`, `TrackRecord(addr)`, `Leaderboard(n)`, `Count()`" + `. Events: ` + "`Sealed`, `Revealed`, `Verdict`" + `.
`)
}

func badge(c *Call, now time.Time) string {
	switch c.status(now) {
	case StatusSealed:
		return "🔒 sealed"
	case StatusDucked:
		return "🫥 ducked"
	case StatusLate:
		s := "⏰ revealed late"
		if o := c.outcome(); o != "" {
			s += ", " + o
		}
		return s
	}
	s := "✅ revealed"
	if o := c.outcome(); o != "" {
		s += ", " + o
	}
	return s
}

func dueIn(c *Call, now time.Time) string {
	if c.Revealed || now.After(c.RevealBy) {
		return ""
	}
	d := c.RevealBy.Sub(now)
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	return " (in " + strconv.Itoa(days) + "d " + strconv.Itoa(hours) + "h)"
}

func blocksBetween(c *Call) string {
	n := c.RevealedHeight - c.SealedHeight
	if n == 1 {
		return "1 block"
	}
	return strconv.FormatInt(n, 10) + " blocks"
}

func callLink(id int) string { return homeLink + ":call/" + strconv.Itoa(id) }

func fmtTime(t time.Time) string { return t.UTC().Format("2006-01-02 15:04 UTC") }

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func escDollar(s string) string { return strings.ReplaceAll(s, "$", "\\$") }
