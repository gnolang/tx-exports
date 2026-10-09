package gnosplit

import (
	"encoding/base64"
	"html"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nym-alexiscolin000/gnosplit/ledger/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// categories are an expense's kinds, in the order ByCat counts them. The last
// one is the default. A form sends the name.
var categories = []struct{ Name, Icon, Color string }{
	{"Food", "🍽", "#4e79a7"},
	{"Groceries", "🛒", "#f28e2b"},
	{"Transport", "🚗", "#59a14f"},
	{"Lodging", "🏠", "#e15759"},
	{"Activities", "🎟", "#76b7b2"},
	{"Shopping", "🛍", "#edc948"},
	{"Bills", "🧾", "#b07aa1"},
	{"Other", "📦", "#9c755f"},
}

func categoryOf(name string) int {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "" {
		return len(categories) - 1
	}
	for i, c := range categories {
		if strings.ToLower(c.Name) == name {
			return i
		}
	}
	panic("gnosplit: no category " + name)
}

const (
	pageSize = 25 // entries per history page
	latest   = 8  // entries on a group's page
)

// Render serves "" (home), "u/<address>" (a wallet's groups) and a group's
// pages: "<id>", then "/add", "/settle", "/settle/<from>/<to>/<cents>",
// "/members", "/stats", "/history[/<page>]", "/e/<entry>" and "/csv".
func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "u/") {
		return renderWallet(address(strings.TrimPrefix(path, "u/")))
	}
	parts := strings.Split(path, "/")
	g := getGroup(parts[0])
	if g == nil {
		return "# Not found\n\nNo group " + sanitize.InlineText(parts[0]) + ". [Back home](" + hub + ")\n"
	}
	page := ""
	if len(parts) > 1 {
		page = parts[1]
	}
	switch {
	case page == "" && len(parts) == 1:
		return renderGroup(g)
	case page == "add" && len(parts) == 2:
		return renderAdd(g)
	case page == "settle" && len(parts) == 2:
		return renderSettle(g, -1, -1, 0)
	case page == "settle" && len(parts) == 5:
		f, t, c := atoi(parts[2]), atoi(parts[3]), atoi(parts[4])
		if f >= 0 && t >= 0 && f < len(g.Members) && t < len(g.Members) && c > 0 {
			return renderSettle(g, f, t, int64(c))
		}
	case page == "members" && len(parts) == 2:
		return renderMembers(g)
	case page == "stats" && len(parts) == 2:
		return renderStats(g)
	case page == "history" && len(parts) <= 3:
		n := 1
		if len(parts) == 3 {
			n = atoi(parts[2])
		}
		if n >= 1 {
			return renderHistory(g, n)
		}
	case page == "e" && len(parts) == 3:
		if v := g.Entries.Get(key(atoi(parts[2]))); v != nil {
			return renderEntry(g, v.(*Entry))
		}
	case page == "csv" && len(parts) == 2:
		return header(g, "Export") + "Every member and entry, as CSV.\n\n" + sanitize.CodeBlock(Export(parts[0]))
	}
	return "# Not found\n\n[Back to the group](" + link(g, "") + ")\n"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# gnosplit\n\n")
	b.WriteString("**Share expenses with friends, then settle up in as few transfers as possible.** ")
	b.WriteString("Trips, flatshares, dinners: like Tricount, on gno.land, with no account and no ads.\n\n")
	b.WriteString("<gno-columns>\n### 1. Create a group\nName it, pick a currency, list your friends. They don't need a wallet.\n")
	b.WriteString("<gno-columns-sep />\n### 2. Add expenses\nWho paid, for whom: split equally, by shares or by exact amounts. Foreign currencies too.\n")
	b.WriteString("<gno-columns-sep />\n### 3. Settle up\ngnosplit works out who pays whom, in the fewest transfers. Friends with a wallet get notified.\n")
	b.WriteString("</gno-columns>\n\n")
	b.WriteString("## Create a group\n\n")
	b.WriteString("<gno-form exec=\"CreateGroup\">\n")
	b.WriteString(input("name", "Group name, like Ski trip", "", true))
	b.WriteString(input("currency", "Currency, like € or CHF", "€", true))
	b.WriteString(input("you", "Your name in the group", "", true))
	b.WriteString(input("others", "Your friends, comma-separated: Alice, Bob", "", false))
	b.WriteString("</gno-form>\n\n")
	b.WriteString("> [!NOTE] Everything is public\n> A group lives on gno.land: anyone with its link can read it. ")
	b.WriteString("Use first names, and keep private details out of titles.\n\n")
	b.WriteString("## Your groups\n\nOpen `" + hub + ":u/<your address>` to list the groups your wallet is in. ")
	b.WriteString(plural(groups.Size(), "group") + " so far.\n")
	return b.String()
}

func renderWallet(a address) string {
	if !a.IsValid() {
		return "# Not found\n\nNot an address. [Back home](" + hub + ")\n"
	}
	var b strings.Builder
	b.WriteString("# Your groups\n\n" + a.String() + "\n\n")
	n := 0
	byAddr.Iterate(a.String()+"/", a.String()+"0", func(k string, _ any) bool {
		g := groups.Get(k[strings.LastIndex(k, "/")+1:]).(*Group)
		m := g.Members[g.editor(a)]
		if n == 0 {
			b.WriteString("| Group | You | Your balance |\n|---|---|---:|\n")
		}
		b.WriteString("| [" + cellText(g.Name) + "](" + link(g, "") + ") | " + sanitize.TableCell(m.Name) +
			" | " + ledger.Signed(m.Bal) + " " + g.Currency + " |\n")
		n++
		return false
	})
	if n == 0 {
		b.WriteString("This wallet is in no group yet. [Create one](" + hub + ")\n")
	}
	return b.String()
}

func renderGroup(g *Group) string {
	var b strings.Builder
	b.WriteString(header(g, ""))
	b.WriteString("<gno-columns>\n## Balances\n\n| Member | | Balance |\n|---|---|---:|\n")
	var max int64
	for _, m := range g.Members {
		if abs(m.Bal) > max {
			max = abs(m.Bal)
		}
	}
	for _, m := range g.Members {
		b.WriteString("| " + sanitize.TableCell(m.Name) + " | " + balanceBar(m.Bal, max) + " | **" + g.money(m.Bal) + "** |\n")
	}
	b.WriteString("\n<gno-columns-sep />\n## Settle up\n\n")
	b.WriteString(transfers(g, true))
	b.WriteString("</gno-columns>\n\n## Latest\n\n")
	if g.Entries.Size() == 0 {
		b.WriteString("No expense yet. [Add the first one](" + link(g, "/add") + ")\n")
		return b.String()
	}
	b.WriteString(entryTable(g, 0, latest))
	if g.Entries.Size() > latest {
		b.WriteString("\n[All " + plural(g.Entries.Size(), "entry") + " →](" + link(g, "/history") + ")\n")
	}
	return b.String()
}

// transfers lists the payments that settle the group, each with a link that
// fills in the form to record it.
func transfers(g *Group, short bool) string {
	bal := make([]int64, len(g.Members))
	for i, m := range g.Members {
		bal[i] = m.Bal
	}
	ts := ledger.Settle(bal)
	if len(ts) == 0 {
		return "> [!SUCCESS] All settled up\n> Nobody owes anything.\n\n"
	}
	var b strings.Builder
	b.WriteString("| Who | Pays | Amount | |\n|---|---|---:|---|\n")
	for _, t := range ts {
		b.WriteString("| " + sanitize.TableCell(g.Members[t.From].Name) + " | " + sanitize.TableCell(g.Members[t.To].Name) +
			" | " + g.money(t.Amount) + " | [Record](" + link(g, "/settle/"+itoa(t.From)+"/"+itoa(t.To)+"/"+strconv.FormatInt(t.Amount, 10)) + ") |\n")
	}
	if short {
		b.WriteString("\n" + plural(len(ts), "transfer") + " settle everything. [Settle up →](" + link(g, "/settle") + ")\n")
	}
	return b.String()
}

func renderAdd(g *Group) string {
	var b strings.Builder
	b.WriteString(header(g, "Add"))
	if g.Moved {
		return b.String()
	}
	b.WriteString("Amounts are like `42.50`. Paid in another currency? Write `50 USD x0.92`: 50 dollars at 0.92 " +
		g.Currency + " each.\n\n")

	b.WriteString("## Split equally\n\n<gno-form exec=\"AddExpense\">\n")
	b.WriteString(groupField(g) + input("title", "What, like Groceries", "", true) + input("amount", "Amount", "", true))
	b.WriteString(memberSelect(g, "paidBy", "Paid by", -1))
	b.WriteString(memberChecks(g, "forWhom", "For whom"))
	b.WriteString(categorySelect())
	b.WriteString("</gno-form>\n\n")

	var shares, amounts []string
	for _, m := range g.Members {
		shares = append(shares, m.Name+":1")
		amounts = append(amounts, m.Name+":")
	}
	b.WriteString("## Split by shares\n\nGive each a number of shares: `Alice:2, Bob:1` makes Alice pay two thirds. Leave out who is not in.\n\n")
	b.WriteString("<gno-form exec=\"AddByShares\">\n")
	b.WriteString(groupField(g) + input("title", "What", "", true) + input("amount", "Amount", "", true))
	b.WriteString(memberSelect(g, "paidBy", "Paid by", -1))
	b.WriteString(input("shares", "Shares", strings.Join(shares, ", "), true))
	b.WriteString(categorySelect())
	b.WriteString("</gno-form>\n\n")

	b.WriteString("## Split by amounts\n\nWrite each one's exact part: `Alice:12.50, Bob:7.50`. The expense is their sum.\n\n")
	b.WriteString("<gno-form exec=\"AddByAmounts\">\n")
	b.WriteString(groupField(g) + input("title", "What", "", true))
	b.WriteString(memberSelect(g, "paidBy", "Paid by", -1))
	b.WriteString(input("amounts", "Amounts, like "+strings.Join(amounts, "12.50, ")+"12.50", "", true))
	b.WriteString(categorySelect())
	b.WriteString("</gno-form>\n\n")

	b.WriteString("## Money received\n\nA refund, a deposit returned: who received it, and for whom.\n\n")
	b.WriteString("<gno-form exec=\"AddIncome\">\n")
	b.WriteString(groupField(g) + input("title", "What, like Deposit back", "", true) + input("amount", "Amount", "", true))
	b.WriteString(memberSelect(g, "receivedBy", "Received by", -1))
	b.WriteString(memberChecks(g, "forWhom", "For whom"))
	b.WriteString("</gno-form>\n")
	return b.String()
}

func renderSettle(g *Group, from, to int, amount int64) string {
	var b strings.Builder
	b.WriteString(header(g, "Settle up"))
	if from < 0 {
		b.WriteString(transfers(g, false) + "\n")
	}
	if g.Moved {
		return b.String()
	}
	b.WriteString("## Record a payment\n\nA payment made outside gnosplit, by bank transfer or in cash.\n\n")
	b.WriteString("<gno-form exec=\"AddTransfer\">\n" + groupField(g))
	if to < 0 && len(g.Members) > 1 {
		to = 1 // a blank form starts on two different members
	}
	b.WriteString(memberSelect(g, "from", "From", from))
	b.WriteString(memberSelect(g, "to", "To", to))
	amt := ""
	if amount > 0 {
		amt = cents(amount)
	}
	b.WriteString(input("amount", "Amount", amt, true))
	b.WriteString("</gno-form>\n\n")
	if from >= 0 {
		return b.String()
	}
	var debtors []int
	for i, m := range g.Members {
		if m.Bal < 0 && m.Addr != "" {
			debtors = append(debtors, i)
		}
	}
	if len(debtors) > 0 {
		b.WriteString("## Send a reminder\n\nA notification to a member who owes, at most one every 12 hours.\n\n")
		b.WriteString("<gno-form exec=\"Remind\">\n" + groupField(g))
		for k, i := range debtors {
			b.WriteString(selectOpt("member", g.Members[i].Name, first(k, "Who"), k == 0))
		}
		b.WriteString("</gno-form>\n")
	}
	return b.String()
}

func renderMembers(g *Group) string {
	var b strings.Builder
	b.WriteString(header(g, "Members"))
	b.WriteString("| Member | Wallet | Paid | Share | Balance |\n|---|---|---:|---:|---:|\n")
	var free []int
	for i, m := range g.Members {
		w := "—"
		if m.Addr != "" {
			w = "[" + short(m.Addr) + "](" + hub + ":u/" + m.Addr.String() + ")"
		} else {
			free = append(free, i)
		}
		b.WriteString("| " + sanitize.TableCell(m.Name) + " | " + w + " | " + g.money(m.Paid) + " | " +
			g.money(m.Share) + " | **" + g.money(m.Bal) + "** |\n")
	}
	b.WriteString("\nMembers with a wallet can add and change entries, and get notified. ")
	b.WriteString("To turn notifications on, open [gnotif](https://gnotif.xyz) with your address.\n\n")
	if g.Moved {
		return b.String()
	}
	b.WriteString("## Add a member\n\n<gno-form exec=\"AddMember\">\n" + groupField(g))
	b.WriteString(input("name", "Name", "", true) + input("addr", "Their g1 address, if they have a wallet", "", false))
	b.WriteString("</gno-form>\n\n")
	if len(free) > 0 && len(g.Members) > 0 {
		b.WriteString("## Link a wallet\n\nA friend got a wallet: link it to their name. A linked wallet is never replaced.\n\n")
		b.WriteString("<gno-form exec=\"LinkMember\">\n" + groupField(g))
		for k, i := range free {
			b.WriteString(selectOpt("name", g.Members[i].Name, first(k, "Member"), k == 0))
		}
		b.WriteString(input("addr", "Their g1 address", "", true))
		b.WriteString("</gno-form>\n")
	}
	return b.String()
}

func renderStats(g *Group) string {
	var b strings.Builder
	b.WriteString(header(g, "Stats"))
	var total int64
	for _, c := range g.ByCat {
		total += c
	}
	if total <= 0 {
		b.WriteString("No expense yet.\n")
		return b.String()
	}
	b.WriteString("## By category\n\n" + categoryBar(g.ByCat, total) + "\n\n")
	b.WriteString("| | Category | Spent | Share |\n|---|---|---:|---:|\n")
	for i, c := range categories {
		if g.ByCat[i] == 0 {
			continue
		}
		b.WriteString("| " + swatch(c.Color) + " | " + c.Icon + " " + c.Name + " | " + g.money(g.ByCat[i]) +
			" | " + percent(g.ByCat[i], total) + " |\n")
	}
	b.WriteString("\n## By member\n\nWhat each one paid, and what their part of the expenses came to.\n\n")
	b.WriteString("| Member | Paid | Share | Of all paid |\n|---|---:|---:|---:|\n")
	for _, m := range g.Members {
		b.WriteString("| " + sanitize.TableCell(m.Name) + " | " + g.money(m.Paid) + " | " + g.money(m.Share) +
			" | " + percent(m.Paid, g.Spent) + " |\n")
	}
	return b.String()
}

func renderHistory(g *Group, page int) string {
	var b strings.Builder
	b.WriteString(header(g, "History"))
	n := g.Entries.Size()
	pages := (n + pageSize - 1) / pageSize
	if n == 0 || page > pages {
		b.WriteString("Nothing here.\n")
		return b.String()
	}
	b.WriteString(entryTable(g, (page-1)*pageSize, pageSize) + "\n")
	if page > 1 {
		b.WriteString("[← Newer](" + link(g, "/history/"+itoa(page-1)) + ") ")
	}
	if page < pages {
		b.WriteString("[Older →](" + link(g, "/history/"+itoa(page+1)) + ")")
	}
	b.WriteString("\n\nPage " + itoa(page) + " of " + itoa(pages) + " · [Export as CSV](" + link(g, "/csv") + ")\n")
	return b.String()
}

func renderEntry(g *Group, e *Entry) string {
	var b strings.Builder
	b.WriteString(header(g, "Entry"))
	b.WriteString("## " + entryIcon(e) + " " + sanitize.InlineText(e.Title) + "\n\n")
	total := abs(e.Total)
	b.WriteString("**" + g.money(total) + "**")
	if e.Note != "" {
		b.WriteString(" (" + e.Note + ")")
	}
	b.WriteString(" · " + verb(e) + " **" + sanitize.InlineText(g.Members[e.Payer].Name) + "** · " + date(e.At, "Mon Jan 2, 2006"))
	b.WriteString("\n\nRecorded by " + e.By.String() + "\n\n")
	if e.Kind != KindTransfer {
		b.WriteString("| Member | Part |\n|---|---:|\n")
		for i, m := range e.Who {
			b.WriteString("| " + sanitize.TableCell(g.Members[m].Name) + " | " + g.money(abs(e.Owe[i])) + " |\n")
		}
		b.WriteString("\n")
	}
	if g.Moved {
		return b.String()
	}
	b.WriteString("## Delete\n\nRemoves the entry and undoes it on every balance.\n\n")
	b.WriteString("<gno-form exec=\"Delete\">\n" + groupField(g) + readonly("entry", "Entry", itoa(e.ID)) + "</gno-form>\n")
	return b.String()
}

// entryTable writes count entries, newest first, from offset.
func entryTable(g *Group, offset, count int) string {
	var b strings.Builder
	b.WriteString("| Date | What | Paid by | For | Amount |\n|---|---|---|---|---:|\n")
	g.Entries.ReverseIterateByOffset(offset, count, func(_ string, v any) bool {
		e := v.(*Entry)
		title := "[" + cellText(e.Title) + "](" + link(g, "/e/"+itoa(e.ID)) + ")"
		amount := g.money(abs(e.Total))
		if e.Kind == KindIncome {
			amount = "−" + amount
		}
		b.WriteString("| " + date(e.At, "Jan 2") + " | " + entryIcon(e) + " " + title + " | " +
			sanitize.TableCell(g.Members[e.Payer].Name) + " | " + forWhom(g, e) + " | " + amount + " |\n")
		return false
	})
	return b.String()
}

func header(g *Group, page string) string {
	var b strings.Builder
	if page == "" {
		b.WriteString("# " + sanitize.InlineText(g.Name) + "\n\n")
	} else {
		b.WriteString("# [" + sanitize.InlineText(g.Name) + "](" + link(g, "") + ") · " + page + "\n\n")
	}
	b.WriteString(plural(len(g.Members), "member") + " · **" + g.money(g.Spent) + "** spent · ")
	b.WriteString("[Add](" + link(g, "/add") + ") · [Settle up](" + link(g, "/settle") + ") · [Members](" +
		link(g, "/members") + ") · [Stats](" + link(g, "/stats") + ") · [History](" + link(g, "/history") + ")\n\n")
	if g.Moved {
		b.WriteString("> [!WARNING] This group moved\n> It is kept read-only here. Its new home is [" + successor + "](" +
			strings.TrimPrefix(successor, "gno.land") + ":" + itoa(g.ID) + ").\n\n")
	}
	return b.String()
}

// Export writes a group as CSV: its members, then every entry, oldest first.
// MoveOut hands it to the successor, and the /csv page shows it.
func Export(group string) string {
	g := mustGroup(group)
	var b strings.Builder
	b.WriteString("member,address,balance,paid,share\n")
	for _, m := range g.Members {
		b.WriteString(csv(m.Name) + "," + m.Addr.String() + "," + cents(m.Bal) + "," + cents(m.Paid) + "," + cents(m.Share) + "\n")
	}
	b.WriteString("\nentry,kind,time,title,category,payer,total,note,split\n")
	g.Entries.Iterate("", "", func(_ string, v any) bool {
		e := v.(*Entry)
		split := make([]string, len(e.Who))
		for i, m := range e.Who {
			split[i] = g.Members[m].Name + ":" + cents(e.Owe[i])
		}
		b.WriteString(itoa(e.ID) + "," + [...]string{"expense", "income", "transfer"}[e.Kind] + "," +
			date(e.At, "2006-01-02T15:04:05Z") + "," + csv(e.Title) + "," + categories[e.Cat].Name + "," +
			csv(g.Members[e.Payer].Name) + "," + cents(e.Total) + "," + csv(e.Note) + "," + csv(strings.Join(split, ";")) + "\n")
		return false
	})
	return b.String()
}

// Form fields. Every value is escaped for the attribute it lands in; a form's
// fields are in the order of its function's parameters, since gnoweb passes
// them by position.

func input(name, placeholder, value string, required bool) string {
	s := `<gno-input name="` + name + `" placeholder="` + attr(placeholder) + `"`
	if value != "" {
		s += ` value="` + attr(value) + `"`
	}
	if required {
		s += ` required="true"`
	}
	return s + " />\n"
}

func readonly(name, placeholder, value string) string {
	return `<gno-input name="` + name + `" placeholder="` + placeholder + `" value="` + attr(value) + `" readonly="true" />` + "\n"
}

func groupField(g *Group) string { return readonly("group", "Group", itoa(g.ID)) }

// selectOpt is one option of a select; gnoweb reads the description off
// the first one, so only that one carries it.
func selectOpt(name, value, description string, selected bool) string {
	s := `<gno-select name="` + name + `" value="` + attr(value) + `"`
	if description != "" {
		s += ` description="` + attr(description) + `"`
	}
	if selected {
		s += ` selected="true"`
	}
	return s + " />\n"
}

func memberSelect(g *Group, name, description string, selected int) string {
	var b strings.Builder
	if selected < 0 {
		selected = 0
	}
	for i, m := range g.Members {
		b.WriteString(selectOpt(name, m.Name, first(i, description), i == selected))
	}
	return b.String()
}

// first is s for the first item of a list, "" after.
func first(i int, s string) string {
	if i == 0 {
		return s
	}
	return ""
}

func memberChecks(g *Group, name, description string) string {
	var b strings.Builder
	for i, m := range g.Members {
		s := `<gno-input type="checkbox" name="` + name + `" value="` + attr(m.Name) + `" checked="true"`
		if i == 0 {
			s += ` description="` + description + `"`
		}
		b.WriteString(s + " />\n")
	}
	return b.String()
}

func categorySelect() string {
	var b strings.Builder
	for i, c := range categories {
		b.WriteString(selectOpt("category", c.Name, first(i, "Category"), i == len(categories)-1))
	}
	return b.String()
}

// Pictures: small SVGs as data URIs, the one image source gnoweb always shows.

// balanceBar draws a balance against the largest one: right and teal when the
// group owes the member, left and orange when they owe.
func balanceBar(v, max int64) string {
	w := 0
	if max > 0 {
		w = int(abs(v) * 56 / max)
		if w == 0 && v != 0 {
			w = 1
		}
	}
	x, color := 60, "#1a9e8f"
	if v < 0 {
		x, color = 60-w, "#e07b39"
	}
	return svg(120, 14, `<rect x="59.5" y="0" width="1" height="14" fill="#8b8f98"/><rect x="`+itoa(x)+
		`" y="2" width="`+itoa(w)+`" height="10" rx="2" fill="`+color+`"/>`)
}

// categoryBar is one bar split by category, in the table's order.
func categoryBar(byCat []int64, total int64) string {
	const w = 600
	var s strings.Builder
	x := 0
	for i, c := range byCat {
		if c <= 0 {
			continue
		}
		cw := int(c * w / total)
		if x+cw > w {
			cw = w - x
		}
		s.WriteString(`<rect x="` + itoa(x) + `" y="0" width="` + itoa(cw) + `" height="24" fill="` + categories[i].Color + `"/>`)
		x += cw
	}
	return svg(w, 24, s.String())
}

func swatch(color string) string {
	return svg(12, 12, `<rect width="12" height="12" rx="3" fill="`+color+`"/>`)
}

func svg(w, h int, body string) string {
	doc := `<svg xmlns="http://www.w3.org/2000/svg" width="` + itoa(w) + `" height="` + itoa(h) +
		`" viewBox="0 0 ` + itoa(w) + ` ` + itoa(h) + `">` + body + `</svg>`
	return "![](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(doc)) + ")"
}

// Small helpers.

func link(g *Group, page string) string { return hub + ":" + itoa(g.ID) + page }

func entryIcon(e *Entry) string {
	switch e.Kind {
	case KindIncome:
		return "↩"
	case KindTransfer:
		return "⇄"
	}
	return categories[e.Cat].Icon
}

func verb(e *Entry) string {
	if e.Kind == KindIncome {
		return "received by"
	}
	return "paid by"
}

func forWhom(g *Group, e *Entry) string {
	if e.Kind == KindTransfer {
		return sanitize.TableCell(g.Members[e.Who[0]].Name)
	}
	if len(e.Who) == len(g.Members) {
		return "everyone"
	}
	var names []string
	for i, m := range e.Who {
		if i == 3 {
			return sanitize.TableCell(strings.Join(names, ", ")) + " +" + itoa(len(e.Who)-3)
		}
		names = append(names, g.Members[m].Name)
	}
	return sanitize.TableCell(strings.Join(names, ", "))
}

func date(unix int64, layout string) string { return time.Unix(unix, 0).UTC().Format(layout) }

func short(a address) string {
	s := a.String()
	if len(s) < 12 {
		return s
	}
	return s[:6] + "…" + s[len(s)-4:]
}

func percent(part, whole int64) string {
	if whole <= 0 {
		return "—"
	}
	return strconv.FormatInt((part*100+whole/2)/whole, 10) + "%"
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	if strings.HasSuffix(word, "y") {
		return itoa(n) + " " + word[:len(word)-1] + "ies"
	}
	return itoa(n) + " " + word + "s"
}

// cents writes an amount for CSV: "42.50", no thousands separator.
func cents(c int64) string { return strings.ReplaceAll(ledger.Format(c), ",", "") }

func csv(s string) string {
	if !strings.ContainsAny(s, ",\"\n;") {
		return s
	}
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}

func attr(s string) string { return html.EscapeString(s) }

// cellText is link text inside a table cell: InlineText leaves "|" alone,
// and a bare one would end the cell.
func cellText(s string) string { return strings.ReplaceAll(sanitize.InlineText(s), "|", `\|`) }

func abs(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

// atoi is a non-negative number, -1 for anything else.
func atoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return -1
	}
	return n
}
