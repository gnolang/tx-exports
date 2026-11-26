package bartab

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
)

var (
	selfPath string       // gno.land/r/<ns>/bartab, read at deploy
	selfURL  string       // /r/<ns>/bartab
	self     txlink.Realm // action links always point at this realm, whoever renders
)

func init() {
	selfPath = unsafe.CurrentRealm().PkgPath()
	selfURL = strings.TrimPrefix(selfPath, "gno.land")
	self = txlink.Realm(selfPath)
}

// Render: "" = the tavern front page; "tab/<id>" = one tab.
func Render(path string) string {
	if strings.HasPrefix(path, "tab/") {
		id, err := strconv.Atoi(strings.TrimPrefix(path, "tab/"))
		if err != nil || id < 1 || id > len(tabs) {
			return "# No such tab\n\n[Back to the bar](" + selfURL + ")\n"
		}
		return renderTab(tabs[id-1])
	}
	return renderHome()
}

func renderHome() string {
	var served, cut, held, open int
	var paid int64
	for _, t := range tabs {
		served += t.Served
		cut += t.CutOff
		held += t.Held
		paid += t.Paid
		if !t.Closed {
			open++
		}
	}
	var b strings.Builder
	b.WriteString("# Bar Tab\n\n")
	b.WriteString("**Give your AI agent a tab, not your wallet.**\n\n")
	b.WriteString("You open a tab with GNOT and name your agent's address. The agent orders payments. The barkeep (this realm) checks every order against your rules before a coin moves:\n\n")
	b.WriteString("- a cap per payment and a cap per day; over either, the order waits for you;\n")
	b.WriteString("- an allowlist of payees; anyone else is refused;\n")
	b.WriteString("- a hold on new or changed payee addresses, the classic invoice-fraud move;\n")
	b.WriteString("- an expiry, and the session key's own expiry;\n")
	b.WriteString("- **Freeze**: one call and the agent is cut off, pending orders cancelled.\n\n")
	b.WriteString("Every decision, refusals included, is written to the tab's ledger below.\n\n")
	b.WriteString("| Tabs open | Orders served | Orders held | Orders cut off | Paid out |\n|---:|---:|---:|---:|---:|\n")
	b.WriteString("| " + strconv.Itoa(open) + " | " + strconv.Itoa(served) + " | " + strconv.Itoa(held) + " | " + strconv.Itoa(cut) + " | " + gnot(paid) + " |\n\n")
	if len(tabs) > 0 {
		b.WriteString("## Tabs\n\n")
		for i := len(tabs) - 1; i >= 0 && i >= len(tabs)-20; i-- {
			t := tabs[i]
			b.WriteString("- [Tab " + strconv.Itoa(t.ID) + "](" + selfURL + ":tab/" + strconv.Itoa(t.ID) + "): " + status(t) + ", balance " + gnot(t.State.Balance) + "\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("## Open a tab\n\n[OpenTab](" + self.Call("OpenTab") + "): agent address, per-payment cap, daily cap, payee hold (seconds), expiry (unix, 0 = never); send the GNOT to put on the tab.\n")
	return b.String()
}

func renderTab(t *Tab) string {
	id := strconv.Itoa(t.ID)
	var b strings.Builder
	b.WriteString("# Tab " + id + ": " + status(t) + "\n\n")
	b.WriteString("[Back to the bar](" + selfURL + ")\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Owner | `" + t.Owner.String() + "` |\n")
	b.WriteString("| Agent | `" + t.Agent.String() + "` |\n")
	b.WriteString("| Balance | " + gnot(t.State.Balance) + " |\n")
	spent := int64(0)
	if t.State.SpentDay == time.Now().Unix()/86400 {
		spent = t.State.SpentToday
	}
	b.WriteString("| Spent today (UTC) | " + gnot(spent) + " of " + gnot(t.Policy.DailyCap) + " " + bar(spent, t.Policy.DailyCap) + " |\n")
	b.WriteString("| Per payment | up to " + gnot(t.Policy.PerPayment) + " without approval |\n")
	b.WriteString("| Payee hold | " + strconv.FormatInt(t.Policy.PayeeHoldSecs, 10) + " s |\n")
	exp := "never"
	if t.Policy.ExpiresAt > 0 {
		exp = when(t.Policy.ExpiresAt)
	}
	b.WriteString("| Expires | " + exp + " |\n\n")
	if !t.Closed {
		if t.State.Frozen {
			b.WriteString("**Frozen.** [Unfreeze](" + self.Call("Unfreeze", "tabID", id) + ")\n\n")
		} else {
			b.WriteString("[**Freeze this tab**](" + self.Call("Freeze", "tabID", id) + ") · ")
			b.WriteString("[Top up](" + self.Call("TopUp", "tabID", id) + ") · ")
			b.WriteString("[Add or change a payee](" + self.Call("SetPayee", "tabID", id) + ") · ")
			b.WriteString("[Close and refund](" + self.Call("CloseTab", "tabID", id) + ")\n\n")
		}
	}
	b.WriteString("## Payees\n\n")
	if len(t.Policy.Payees) == 0 {
		b.WriteString("None yet: every order is refused until you add one.\n\n")
	} else {
		b.WriteString("| Name | Address | Usable |\n|---|---|---|\n")
		n := time.Now().Unix()
		for _, p := range t.Policy.Payees {
			u := "now"
			if p.UsableAt > n {
				u = "on hold until " + when(p.UsableAt)
			}
			b.WriteString("| " + p.Name + " | `" + p.Addr.String() + "` | " + u + " |\n")
		}
		b.WriteString("\n")
	}
	pending := 0
	for _, h := range t.Holds {
		if h.Status == "pending" {
			pending++
		}
	}
	b.WriteString("## Waiting for you (" + strconv.Itoa(pending) + ")\n\n")
	if pending > 0 {
		b.WriteString("| # | To | Amount | Why held | |\n|---|---|---:|---|---|\n")
		for _, h := range t.Holds {
			if h.Status != "pending" {
				continue
			}
			hid := strconv.Itoa(h.ID)
			b.WriteString("| " + hid + " | " + who(h.Payee, h.To) + " | " + gnot(h.Amount) + " | " + strings.TrimPrefix(outcome("hold:"+h.Reason), "⏸ held: ") + " | [Approve](" +
				self.Call("Approve", "tabID", id, "holdID", hid) + ") · [Reject](" + self.Call("Reject", "tabID", id, "holdID", hid) + ") |\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("## Ledger (newest first)\n\n")
	for i := len(t.Ledger) - 1; i >= 0 && i >= len(t.Ledger)-20; i-- {
		e := t.Ledger[i]
		line := "- `" + clock(e.Time) + "` **" + e.Action + "**"
		if e.Amount != 0 {
			line += " " + gnot(e.Amount)
		}
		if e.To != "" {
			line += " → " + who(e.Payee, e.To)
		}
		line += ": " + outcome(e.Decision)
		if e.Note != "" {
			line += " · _" + esc(e.Note) + "_"
		}
		b.WriteString(line + "\n")
	}
	return b.String()
}

var reasonWords = map[string]string{
	"frozen": "tab frozen", "policy-expired": "tab expired", "session-expired": "session expired", "bad-amount": "bad amount",
	"unknown-payee": "not a payee", "insufficient-balance": "not enough on the tab", "overflow": "overflow",
	"payee-hold": "new payee address", "over-per-payment": "over the per-payment cap", "over-daily-cap": "over the daily cap",
	"closed": "tab closed",
}

// outcome turns a ledger decision into words: allow -> paid, hold:<r> -> held, deny:<r> -> refused.
func outcome(d string) string {
	kind, reason := d, ""
	if i := strings.Index(d, ":"); i > 0 {
		kind, reason = d[:i], d[i+1:]
	}
	if w, ok := reasonWords[reason]; ok {
		reason = w
	}
	switch kind {
	case "allow":
		return "✅ paid"
	case "hold":
		return "⏸ held: " + reason
	case "deny":
		return "⛔ refused: " + reason
	}
	return d
}

func clock(t int64) string { return time.Unix(t, 0).UTC().Format("01-02 15:04:05") }

func status(t *Tab) string {
	switch {
	case t.Closed:
		return "closed"
	case t.State.Frozen:
		return "frozen"
	}
	return "open"
}

func who(name string, a address) string {
	s := a.String()
	short := s
	if len(s) > 12 {
		short = s[:8] + "…" + s[len(s)-4:]
	}
	if name != "" {
		return name + " (`" + short + "`)"
	}
	return "`" + short + "`"
}

// gnot formats ugnot as GNOT with up to 6 decimals.
func gnot(u int64) string {
	whole := strconv.FormatInt(u/1_000_000, 10)
	frac := u % 1_000_000
	if frac == 0 {
		return whole + " GNOT"
	}
	f := strconv.FormatInt(frac+1_000_000, 10)[1:]
	return whole + "." + strings.TrimRight(f, "0") + " GNOT"
}

func bar(v, max int64) string {
	if max <= 0 {
		return ""
	}
	n := int(v * 10 / max)
	if n > 10 {
		n = 10
	}
	return "`" + strings.Repeat("█", n) + strings.Repeat("░", 10-n) + "`"
}

func when(t int64) string { return time.Unix(t, 0).UTC().Format("2006-01-02 15:04:05") }

func esc(s string) string {
	return strings.NewReplacer("|", "\\|", "\n", " ", "[", "\\[", "]", "\\]", "<", "&lt;").Replace(s)
}
