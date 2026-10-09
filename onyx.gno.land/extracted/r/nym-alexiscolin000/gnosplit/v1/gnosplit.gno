// Package gnosplit shares a group's expenses, like Tricount: who paid what,
// who owes whom, and the fewest transfers that settle everything.
//
// A group has members, each a name with or without a wallet. Members with a
// wallet linked are the group's editors: they record expenses, incomes and
// transfers, and get a gnotif notification when one concerns them. Members
// without one are just names: a friend with no wallet still has a balance.
//
// Amounts are cents of the group's currency, a label such as "€" or "CHF":
// no coin moves here, a transfer records a payment made elsewhere. Every
// balance is kept up to date on each write, so reading a group never adds
// up its history.
package gnosplit

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nym-alexiscolin000/gnosplit/ledger/v0"
	"gno.land/p/nt/avl/v0"
)

// Limits keep every page and every write small.
const (
	maxMembers  = 30
	maxEntries  = 5000 // per group
	maxName     = 24   // a member's name, in bytes
	maxGroup    = 40   // a group's name
	maxTitle    = 60   // an entry's title
	maxCurrency = 8
	remindEvery = 12 * 60 * 60 // seconds between two reminders to one member
)

// Kind is what an entry records.
type Kind uint8

const (
	KindExpense  Kind = iota // Payer paid Total for Who
	KindIncome               // Payer received Total that belongs to Who
	KindTransfer             // Payer paid Total to Who[0]
)

// Member is one person in a group. Bal is what they paid minus what they owe,
// in cents: > 0 the group owes them, < 0 they owe the group.
type Member struct {
	Name   string
	Addr   address // "" while no wallet is linked
	Bal    int64
	Paid   int64 // total of the expenses they paid, net of incomes received
	Share  int64 // total of their shares of expenses, net of incomes
	Nudged int64 // when they were last reminded, unix seconds
}

// Entry is one expense, income or transfer. Owe[i] is the part of Who[i]; the
// parts sum to Total. An income stores Total and Owe as negative amounts, so
// one rule applies every kind: Payer gains Total, each of Who loses its part.
type Entry struct {
	ID    int
	Kind  Kind
	Title string
	Cat   int
	Payer int
	Total int64
	Note  string // the foreign amount, "" if none
	Who   []int
	Owe   []int64
	At    int64
	By    address
}

// Group is one shared account.
type Group struct {
	ID       int
	Name     string
	Currency string
	Members  []Member
	Entries  avl.Tree // key(ID) → *Entry
	Next     int      // the next entry's ID
	Spent    int64    // expenses minus incomes, for the header
	ByCat    []int64  // expenses per category, incomes left out
	Created  int64
	Moved    bool // taken over by the successor realm: read-only here
}

var (
	groups avl.Tree // key(ID) → *Group
	byAddr avl.Tree // addr + "/" + key(ID) → true, the groups a wallet belongs to
	nextID = 1
)

// self is this realm's pkgpath and hub its gnoweb path, read at init while
// this realm is current: every link follows from them.
var (
	self = unsafe.CurrentRealm().PkgPath()
	hub  = strings.TrimPrefix(self, "gno.land")
)

func init(cur realm) {
	setUp(unsafe.OriginCaller(), runtime.ChainID())
	declareTriggers(cur)
}

// CreateGroup opens a group named name, counting in currency, with the
// caller as member you (wallet linked) and others, comma-separated names,
// without wallets. It returns the group's ID.
func CreateGroup(cur realm, name, currency, you, others string) int {
	caller := cur.Previous().Address()
	name, currency = strings.TrimSpace(name), strings.TrimSpace(currency)
	if !validText(name, maxGroup) {
		panic("gnosplit: a group name is 1 to 40 bytes on one line")
	}
	if !validText(currency, maxCurrency) || strings.ContainsAny(currency, " ,<>[]()|*_`\\&\"'") {
		panic("gnosplit: a currency is 1 to 8 bytes with no space, like € or CHF")
	}
	g := &Group{ID: nextID, Name: name, Currency: currency, Created: time.Now().Unix(), ByCat: make([]int64, len(categories))}
	g.addMember(you, caller)
	for _, n := range splitList(others) {
		g.addMember(n, "")
	}
	nextID++
	groups.Set(key(g.ID), g)
	chain.Emit(EventGroupCreated, "group", itoa(g.ID), "by", caller.String())
	return g.ID
}

// AddMember adds name to the group, with a wallet if addr is set: that member
// becomes an editor and is told by gnotif.
func AddMember(cur realm, group, name, addr string) {
	g, by := editable(cur, group)
	a := parseAddr(addr)
	i := g.addMember(name, a)
	chain.Emit(EventMemberAdded, "group", itoa(g.ID), "member", g.Members[i].Name)
	if a != "" {
		notifyJoined(g, a, g.Members[by].Name)
	}
}

// LinkMember links a wallet to a member who has none yet, making them an
// editor. A linked wallet is never replaced, so no editor can take over
// another's place.
func LinkMember(cur realm, group, name, addr string) {
	g, by := editable(cur, group)
	i := g.member(name)
	if g.Members[i].Addr != "" {
		panic("gnosplit: " + g.Members[i].Name + " already has a wallet")
	}
	a := parseAddr(addr)
	if a == "" {
		panic("gnosplit: an address is required")
	}
	g.link(i, a)
	chain.Emit(EventMemberLinked, "group", itoa(g.ID), "member", g.Members[i].Name, "addr", a.String())
	notifyJoined(g, a, g.Members[by].Name)
}

// AddExpense records that paidBy paid amount for forWhom (comma-separated
// names, "" for everyone), split equally. amount is "42.50", or a foreign
// amount with its rate, "50 USD x0.92". It returns the entry's ID.
func AddExpense(cur realm, group, title, amount, paidBy, forWhom, category string) int {
	g, by := editable(cur, group)
	total, note := mustAmount(amount)
	who := g.members(forWhom)
	return g.record(by, KindExpense, title, category, g.member(paidBy), total, note, who, ledger.Equal(total, len(who)))
}

// AddByShares records an expense split by shares: shares is "Alice:2, Bob:1",
// so Alice owes two thirds.
func AddByShares(cur realm, group, title, amount, paidBy, shares, category string) int {
	g, by := editable(cur, group)
	total, note := mustAmount(amount)
	who, w := g.pairs(shares, func(s string) (int64, bool) {
		n, err := strconv.Atoi(s)
		return int64(n), err == nil && n > 0 && n <= 1000
	}, "a share is a whole number from 1 to 1000")
	return g.record(by, KindExpense, title, category, g.member(paidBy), total, note, who, ledger.Weighted(total, w))
}

// AddByAmounts records an expense split by exact amounts: amounts is
// "Alice:12.50, Bob:7.50", and the expense is their sum.
func AddByAmounts(cur realm, group, title, paidBy, amounts, category string) int {
	g, by := editable(cur, group)
	who, owe := g.pairs(amounts, ledger.ParseCents, "an amount is like 12.50")
	var total int64
	for _, o := range owe {
		total += o
	}
	if total > ledger.MaxCents {
		panic("gnosplit: the amounts add up to too much")
	}
	return g.record(by, KindExpense, title, category, g.member(paidBy), total, "", who, owe)
}

// AddIncome records money receivedBy got on behalf of forWhom (a refund, a
// deposit returned), split equally: it lowers what each of them paid.
func AddIncome(cur realm, group, title, amount, receivedBy, forWhom string) int {
	g, by := editable(cur, group)
	total, note := mustAmount(amount)
	who := g.members(forWhom)
	return g.record(by, KindIncome, title, "", g.member(receivedBy), -total, note, who, ledger.Equal(-total, len(who)))
}

// AddTransfer records that from paid amount to to, outside the chain.
func AddTransfer(cur realm, group, from, to, amount string) int {
	g, by := editable(cur, group)
	total, note := mustAmount(amount)
	f, t := g.member(from), g.member(to)
	if f == t {
		panic("gnosplit: a transfer goes to someone else")
	}
	title := g.Members[f].Name + " → " + g.Members[t].Name
	return g.record(by, KindTransfer, title, "", f, total, note, []int{t}, []int64{total})
}

// Delete removes an entry and undoes its effect on every balance.
func Delete(cur realm, group, entry string) {
	g, _ := editable(cur, group)
	id, err := strconv.Atoi(strings.TrimSpace(entry))
	if err != nil {
		panic("gnosplit: no entry " + entry)
	}
	v, ok := g.Entries.Remove(key(id))
	if !ok {
		panic("gnosplit: no entry " + entry)
	}
	g.apply(v.(*Entry), -1)
	chain.Emit(EventEntryDeleted, "group", itoa(g.ID), "entry", itoa(id), "by", cur.Previous().Address().String())
}

// Remind sends member, who owes the group, a gnotif reminder: at most one
// every 12 hours, and only to a member with a wallet.
func Remind(cur realm, group, member string) {
	g, by := editable(cur, group)
	i := g.member(member)
	m := &g.Members[i]
	now := time.Now().Unix()
	switch {
	case m.Bal >= 0:
		panic("gnosplit: " + m.Name + " owes nothing")
	case m.Addr == "":
		panic("gnosplit: " + m.Name + " has no wallet to remind")
	case i == by:
		panic("gnosplit: you cannot remind yourself")
	case now-m.Nudged < remindEvery:
		panic("gnosplit: " + m.Name + " was reminded less than 12 hours ago")
	}
	m.Nudged = now
	notifyReminder(g, m, g.Members[by].Name)
}

// record validates and stores an entry, then applies it to the balances.
func (g *Group) record(by int, kind Kind, title, category string, payer int, total int64, note string, who []int, owe []int64) int {
	title = strings.TrimSpace(title)
	if !validText(title, maxTitle) {
		panic("gnosplit: a title is 1 to 60 bytes on one line")
	}
	if g.Entries.Size() >= maxEntries {
		panic("gnosplit: this group is full (5000 entries)")
	}
	e := &Entry{
		ID: g.Next, Kind: kind, Title: title, Cat: categoryOf(category), Payer: payer,
		Total: total, Note: note, Who: who, Owe: owe,
		At: time.Now().Unix(), By: g.Members[by].Addr,
	}
	g.Next++
	g.Entries.Set(key(e.ID), e)
	g.apply(e, 1)
	chain.Emit(EventEntryAdded, "group", itoa(g.ID), "entry", itoa(e.ID), "by", e.By.String())
	notifyEntry(g, e, by)
	return e.ID
}

// apply adds an entry to the balances (sign 1) or takes it back out (-1).
func (g *Group) apply(e *Entry, sign int64) {
	g.Members[e.Payer].Bal += sign * e.Total
	for i, m := range e.Who {
		g.Members[m].Bal -= sign * e.Owe[i]
	}
	if e.Kind == KindTransfer {
		return
	}
	g.Spent += sign * e.Total
	if e.Kind == KindExpense {
		g.ByCat[e.Cat] += sign * e.Total
	}
	g.Members[e.Payer].Paid += sign * e.Total
	for i, m := range e.Who {
		g.Members[m].Share += sign * e.Owe[i]
	}
}

// addMember appends a member and returns its index.
func (g *Group) addMember(name string, a address) int {
	name = strings.TrimSpace(name)
	if !validName(name) {
		panic("gnosplit: a name is 1 to 24 bytes, without , : ; or =")
	}
	if g.find(name) >= 0 {
		panic("gnosplit: there is already a " + name)
	}
	if len(g.Members) >= maxMembers {
		panic("gnosplit: a group has at most 30 members")
	}
	g.Members = append(g.Members, Member{Name: name})
	i := len(g.Members) - 1
	if a != "" {
		g.link(i, a)
	}
	return i
}

func (g *Group) link(i int, a address) {
	if g.editor(a) >= 0 {
		panic("gnosplit: this wallet is already in the group")
	}
	g.Members[i].Addr = a
	byAddr.Set(a.String()+"/"+key(g.ID), true)
}

// find is the index of the member called name, any case, or -1.
func (g *Group) find(name string) int {
	name = strings.ToLower(strings.TrimSpace(name))
	for i, m := range g.Members {
		if strings.ToLower(m.Name) == name {
			return i
		}
	}
	return -1
}

func (g *Group) member(name string) int {
	i := g.find(name)
	if i < 0 {
		panic("gnosplit: no member called " + strings.TrimSpace(name))
	}
	return i
}

// members reads a comma-separated list of names, "" for everyone.
func (g *Group) members(list string) []int {
	names := splitList(list)
	if len(names) == 0 {
		all := make([]int, len(g.Members))
		for i := range all {
			all[i] = i
		}
		return all
	}
	var out []int
	seen := make([]bool, len(g.Members))
	for _, n := range names {
		i := g.member(n)
		if seen[i] {
			panic("gnosplit: " + g.Members[i].Name + " is listed twice")
		}
		seen[i] = true
		out = append(out, i)
	}
	return out
}

// pairs reads "Name:value, Name:value" with parse checking each value.
func (g *Group) pairs(list string, parse func(string) (int64, bool), hint string) ([]int, []int64) {
	var who []int
	var vals []int64
	seen := make([]bool, len(g.Members))
	for _, p := range splitList(list) {
		name, val, ok := strings.Cut(p, ":")
		if !ok {
			panic("gnosplit: write each one as Name:value, like Alice:2")
		}
		i := g.member(name)
		v, ok := parse(strings.TrimSpace(val))
		if !ok {
			panic("gnosplit: " + hint)
		}
		if seen[i] {
			panic("gnosplit: " + g.Members[i].Name + " is listed twice")
		}
		seen[i] = true
		who, vals = append(who, i), append(vals, v)
	}
	if len(who) == 0 {
		panic("gnosplit: name at least one member")
	}
	return who, vals
}

// editor is the index of the member whose wallet is a, or -1.
func (g *Group) editor(a address) int {
	for i, m := range g.Members {
		if m.Addr == a {
			return i
		}
	}
	return -1
}

// editable is the one write check: the group exists, is still kept here, and
// the immediate caller is one of its members with a wallet.
func editable(cur realm, group string) (*Group, int) {
	g := mustGroup(group)
	if g.Moved {
		panic("gnosplit: this group moved to " + successor)
	}
	by := g.editor(cur.Previous().Address())
	if by < 0 {
		panic("gnosplit: only a member with a linked wallet can change this group")
	}
	return g, by
}

func getGroup(group string) *Group {
	id, err := strconv.Atoi(strings.TrimSpace(group))
	if err != nil {
		return nil
	}
	v := groups.Get(key(id))
	if v == nil {
		return nil
	}
	return v.(*Group)
}

func mustGroup(group string) *Group {
	g := getGroup(group)
	if g == nil {
		panic("gnosplit: no group " + group)
	}
	return g
}

func mustAmount(s string) (int64, string) {
	total, note, ok := ledger.ParseAmount(s)
	if !ok {
		panic("gnosplit: an amount is like 42.50, or 50 USD x0.92 for a foreign one")
	}
	return total, note
}

func parseAddr(s string) address {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	a := address(s)
	if !a.IsValid() {
		panic("gnosplit: not an address: " + s)
	}
	return a
}

// splitList cuts a comma-separated list, dropping blanks.
func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// validText is 1 to max bytes with no control character.
func validText(s string, max int) bool {
	if len(s) == 0 || len(s) > max {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return false
		}
	}
	return true
}

// validName also refuses the separators the forms use.
func validName(s string) bool {
	return validText(s, maxName) && !strings.ContainsAny(s, ",:;=")
}

// key pads an ID so the trees keep numeric order.
func key(id int) string {
	s := strconv.Itoa(id)
	return strings.Repeat("0", 10-len(s)) + s
}

func itoa(n int) string { return strconv.Itoa(n) }
