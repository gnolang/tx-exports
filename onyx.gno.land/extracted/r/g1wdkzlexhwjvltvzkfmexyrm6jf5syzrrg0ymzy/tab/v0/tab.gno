// Package tab is a bar tab priced in US dollars and paid in GNOT.
//
// A bartender opens a tab and adds items in dollars. The customer pays in
// GNOT at the live Tapster GNOT-USD price: the realm converts the bill at
// payment time, refuses stale prices, pays the bartender exactly the
// amount due and refunds any extra GNOT sent. It exists to show how any
// realm can use Tapster prices.
package tab

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapmath/v0"
	"gno.land/r/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapster/v0"
)

const (
	pricePair     = "GNOT-USD"
	maxPriceAge   = 600       // refuse prices older than 10 minutes
	maxItems      = 30        // per tab
	maxItemCents  = 1000000   // $10,000 per item
	maxTitleLen   = 48
	ugnot         = "ugnot"
	quoteBufferBp = 200 // pay links send 2% extra to absorb price moves; the rest is refunded
)

// Item is one line on a tab.
type Item struct {
	Name  string
	Cents int64
}

// Tab is a bill.
type Tab struct {
	ID        int
	Title     string
	Bartender address
	Items     []Item
	Created   int64

	Paid      bool
	Payer     address
	PaidUgnot int64
	PaidPrice int64 // GNOT-USD price used
	PaidAt    int64
}

var (
	tabs   = avl.NewTree() // zero-padded id -> *Tab
	nextID = 1
	paidTotalCents int64
)

func init(cur realm) {
	tapster.RegisterConsumer(cross(cur), "bar tabs priced in USD, paid in GNOT")
}

func key(id int) string { return ufmt.Sprintf("%08d", id) }

func mustTab(id int) *Tab {
	v := tabs.Get(key(id))
	if v == nil {
		panic("unknown tab")
	}
	return v.(*Tab)
}

func now() int64 { return time.Now().Unix() }

func assertCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
}

func cleanText(s string, max int) string {
	s = strings.TrimSpace(s)
	if s == "" {
		panic("text must not be empty")
	}
	if len(s) > max {
		panic(ufmt.Sprintf("text too long (max %d)", max))
	}
	for _, c := range s {
		if c == '|' || c == '[' || c == ']' || c == '(' || c == ')' || c == '<' || c == '>' || c == '`' || c == '\n' {
			panic("text contains characters that are not allowed")
		}
	}
	return s
}

// Open creates a tab owned by the caller and returns its id.
func Open(cur realm, title string) int {
	assertCurrent(cur)
	t := &Tab{
		ID:        nextID,
		Title:     cleanText(title, maxTitleLen),
		Bartender: cur.Previous().Address(),
		Created:   now(),
	}
	tabs.Set(key(t.ID), t)
	nextID++
	chain.Emit("Open", "id", strconv.Itoa(t.ID), "bartender", t.Bartender.String())
	return t.ID
}

// Add puts an item priced in US cents on an open tab. Bartender only.
func Add(cur realm, id int, name string, cents int64) {
	assertCurrent(cur)
	t := mustTab(id)
	if cur.Previous().Address() != t.Bartender {
		panic("only the bartender can add items")
	}
	if t.Paid {
		panic("tab already paid")
	}
	if cents <= 0 || cents > maxItemCents {
		panic("price must be between 1 cent and $10,000")
	}
	if len(t.Items) >= maxItems {
		panic("tab is full")
	}
	t.Items = append(t.Items, Item{Name: cleanText(name, 32), Cents: cents})
}

// Total returns a tab's total in cents.
func Total(id int) int64 {
	var sum int64
	for _, it := range mustTab(id).Items {
		sum += it.Cents
	}
	return sum
}

// Quote returns the ugnot due for a tab at the current Tapster price and
// whether that price is fresh enough to pay with.
func Quote(id int) (due int64, price int64, ok bool) {
	p, dec, fresh := tapster.PriceFresh(pricePair, maxPriceAge)
	if !fresh {
		return 0, 0, false
	}
	return tapmath.UsdCentsToUgnot(Total(id), p, dec), p, true
}

// Pay settles a tab with the GNOT sent with the call. The bill is
// converted at the live Tapster price; the bartender receives exactly the
// amount due and the payer gets the rest back.
func Pay(cur realm, id int) {
	assertCurrent(cur)
	// IsUserCall + OriginSend are a pair: only for a direct call from an
	// account are the -send coins guaranteed to have reached this realm.
	if !cur.Previous().IsUserCall() {
		panic("call Pay directly from an account")
	}
	sent := unsafe.OriginSend().AmountOf(ugnot)

	t := mustTab(id)
	if t.Paid {
		panic("tab already paid")
	}
	total := Total(id)
	if total == 0 {
		panic("tab is empty")
	}
	price, dec := tapster.MustPriceFresh(pricePair, maxPriceAge)
	due := tapmath.UsdCentsToUgnot(total, price, dec)
	if sent < due {
		panic(ufmt.Sprintf("not enough GNOT: due %d ugnot at $%s/GNOT, sent %d",
			due, tapmath.FormatFixed(price, dec), sent))
	}
	payer := cur.Previous().Address()
	t.Paid = true
	t.Payer = payer
	t.PaidUgnot = due
	t.PaidPrice = price
	t.PaidAt = now()
	paidTotalCents += total

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), t.Bartender, chain.Coins{{ugnot, due}})
	if sent > due {
		bk.SendCoins(cur.Address(), payer, chain.Coins{{ugnot, sent - due}})
	}
	chain.Emit("Pay", "id", strconv.Itoa(id), "cents", strconv.FormatInt(total, 10),
		"ugnot", strconv.FormatInt(due, 10), "price", strconv.FormatInt(price, 10))
}

// ----------------------------------------------------------------------
// Render

func usd(cents int64) string { return "$" + tapmath.FormatFixed(cents, 2) }

func gnot(u int64) string { return tapmath.FormatRounded(u, 6, 4) + " GNOT" }

func short(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func realmPath() string {
	l := txlink.Call("Open")
	if i := strings.Index(l, "$"); i >= 0 {
		return l[:i]
	}
	return l
}

// Render shows open and paid tabs; "tab/<id>" shows one tab.
func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if path == "json" {
		return renderJSON()
	}
	if len(parts) == 2 && parts[0] == "tab" {
		id, err := strconv.Atoi(parts[1])
		if err != nil || !tabs.Has(key(id)) {
			return "# Unknown tab\n\n[Back](" + realmPath() + ")"
		}
		return renderTab(mustTab(id))
	}
	return renderHome()
}

func priceLine() string {
	p, dec, at, _, ok := tapster.Latest(pricePair)
	if !ok {
		return "⏳ Waiting for the first Tapster GNOT-USD price."
	}
	fresh := now()-at <= maxPriceAge
	s := "Live price from [Tapster](/" + tapsterPath() + "): **1 GNOT = $" + tapmath.FormatFixed(p, dec) + "**"
	if !fresh {
		s += " ⚠️ stale, payments are paused until it updates"
	}
	return s
}

func tapsterPath() string {
	// Same namespace as this realm.
	p := strings.TrimPrefix(realmPath(), "/")
	return strings.Replace(p, "/tab/v0", "/tapster/v0", 1)
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 🍻 Tab\n\n")
	b.WriteString("Bar tabs priced in dollars, paid in GNOT at the live price. Built on Tapster price feeds.\n\n")
	b.WriteString(priceLine() + "\n\n")
	b.WriteString("[Open a tab](" + txlink.NewLink("Open").AddArgs("title", "").URL() + ")")
	b.WriteString(ufmt.Sprintf(" · %s settled so far\n\n", usd(paidTotalCents)))
	b.WriteString("| Tab | Bartender | Items | Total | Status |\n|---|---|---|---|---|\n")
	n := 0
	tabs.ReverseIterate("", "", func(_ string, v any) bool {
		t := v.(*Tab)
		status := "open"
		if t.Paid {
			status = "✅ paid " + gnot(t.PaidUgnot)
		}
		b.WriteString(ufmt.Sprintf("| [#%d %s](%s:tab/%d) | `%s` | %d | %s | %s |\n",
			t.ID, t.Title, realmPath(), t.ID, short(t.Bartender), len(t.Items), usd(Total(t.ID)), status))
		n++
		return n >= 50
	})
	if n == 0 {
		b.WriteString("| No tabs yet | | | | |\n")
	}
	return b.String()
}

func renderTab(t *Tab) string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Tab #%d: %s\n\n", t.ID, t.Title))
	b.WriteString(ufmt.Sprintf("Bartender `%s` · [All tabs](%s)\n\n", short(t.Bartender), realmPath()))
	b.WriteString("| Item | Price |\n|---|---|\n")
	for _, it := range t.Items {
		b.WriteString("| " + it.Name + " | " + usd(it.Cents) + " |\n")
	}
	total := Total(t.ID)
	b.WriteString("| **Total** | **" + usd(total) + "** |\n\n")

	if t.Paid {
		b.WriteString(ufmt.Sprintf("✅ Paid %s by `%s` at $%s/GNOT.\n",
			gnot(t.PaidUgnot), short(t.Payer), tapmath.FormatFixed(t.PaidPrice, 6)))
		return b.String()
	}
	b.WriteString(priceLine() + "\n\n")
	if total == 0 {
		b.WriteString("Empty tab. The bartender adds items with [Add](" + txlink.NewLink("Add").AddArgs("id", strconv.Itoa(t.ID)).URL() + ").\n")
		return b.String()
	}
	due, _, ok := Quote(t.ID)
	if !ok {
		b.WriteString("Payment is paused until Tapster has a fresh GNOT-USD price.\n")
		return b.String()
	}
	send := due + tapmath.ApplyBps(due, quoteBufferBp)
	b.WriteString(ufmt.Sprintf("**Due now: %s**\n\n", gnot(due)))
	b.WriteString("[Pay this tab](" + txlink.NewLink("Pay").AddArgs("id", strconv.Itoa(t.ID)).SetSend(strconv.FormatInt(send, 10)+"ugnot").URL() + ")")
	b.WriteString(" (sends 2% extra in case the price moves; the change is refunded) · ")
	b.WriteString("[Add item](" + txlink.NewLink("Add").AddArgs("id", strconv.Itoa(t.ID)).URL() + ")\n")
	return b.String()
}

func renderJSON() string {
	var items []string
	n := 0
	tabs.ReverseIterate("", "", func(_ string, v any) bool {
		t := v.(*Tab)
		var its []string
		for _, it := range t.Items {
			its = append(its, ufmt.Sprintf("{\"name\":\"%s\",\"cents\":%d}", it.Name, it.Cents))
		}
		items = append(items, ufmt.Sprintf("{\"id\":%d,\"title\":\"%s\",\"bartender\":\"%s\",\"total\":%d,\"paid\":%t,\"payer\":\"%s\",\"paidUgnot\":%d,\"paidPrice\":%d,\"items\":[%s]}",
			t.ID, t.Title, t.Bartender.String(), Total(t.ID), t.Paid, t.Payer.String(), t.PaidUgnot, t.PaidPrice, strings.Join(its, ",")))
		n++
		return n >= 100
	})
	return ufmt.Sprintf("{\"settledCents\":%d,\"tabs\":[%s]}", paidTotalCents, strings.Join(items, ","))
}
