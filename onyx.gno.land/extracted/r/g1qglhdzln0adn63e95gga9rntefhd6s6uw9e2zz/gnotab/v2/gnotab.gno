// Package gnotab implements GnoTab ("Tavern Tab"): a group expense
// ledger on Gno.land, Splitwise-style.
//
// A group of members records shared expenses in ugnot. The realm keeps
// a running net balance per member and can reduce those balances to a
// short list of "who pays whom" transfers (netting). Members record a
// Settlement once they have paid a debt off (e.g. with a real GNOT
// transfer), which zeroes the corresponding balances.
package gnotab

import (
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// Types & state
// ---------------------------------------------------------------------------

// Expense is one shared expense recorded in a group.
type Expense struct {
	ID           int
	Payer        address
	Amount       int64 // total amount paid, in ugnot
	Participants []address
	Memo         string
}

// Settlement records that From has paid Amount ugnot of debt to To.
type Settlement struct {
	From   address
	To     address
	Amount int64 // ugnot
}

// Transfer is one netted payment suggestion: From should pay Amount to To.
type Transfer struct {
	From   address
	To     address
	Amount int64 // ugnot
}

// Group is a single tab shared by its members.
type Group struct {
	ID          int
	Name        string
	Creator     address
	Members     []address // join order; Creator is Members[0]
	Expenses    []Expense
	Settlements []Settlement
	Balances    map[address]int64 // net balance in ugnot: >0 is owed money, <0 owes money
}

var (
	groups     = map[int]*Group{}
	groupCount int
)

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

func getGroup(groupID int) *Group {
	g, ok := groups[groupID]
	if !ok {
		panic("gnotab: group not found")
	}
	return g
}

func isMember(g *Group, addr address) bool {
	for _, m := range g.Members {
		if m == addr {
			return true
		}
	}
	return false
}

// dedupeAddresses returns the input with duplicates and empty addresses
// removed, preserving first-seen order.
func dedupeAddresses(in []address) []address {
	seen := map[address]bool{}
	out := []address{}
	for _, a := range in {
		if a.String() == "" || seen[a] {
			continue
		}
		seen[a] = true
		out = append(out, a)
	}
	return out
}

// parseAddressList parses a comma-separated list of g1 addresses.
// Public realm functions take address lists in this form because MsgCall
// arguments cannot carry []address values on-chain (the VM's argument
// converter only supports primitives and []byte).
func parseAddressList(s string) []address {
	out := []address{}
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		out = append(out, address(part))
	}
	return out
}

// computeTransfers reduces the group's net balances to a list of payments
// that settles everyone. Debtors and creditors are matched greedily in
// member order, so the result is deterministic.
func computeTransfers(g *Group) []Transfer {
	bal := make(map[address]int64, len(g.Members))
	for _, m := range g.Members {
		bal[m] = g.Balances[m]
	}
	transfers := []Transfer{}
	for _, from := range g.Members {
		for bal[from] < 0 {
			// Find the first creditor (in member order) still owed money.
			var to address
			found := false
			for _, cand := range g.Members {
				if bal[cand] > 0 {
					to = cand
					found = true
					break
				}
			}
			if !found {
				break
			}
			amt := -bal[from]
			if bal[to] < amt {
				amt = bal[to]
			}
			transfers = append(transfers, Transfer{From: from, To: to, Amount: amt})
			bal[from] += amt
			bal[to] -= amt
		}
	}
	return transfers
}

// ---------------------------------------------------------------------------
// Public functions (callable via MsgCall)
// ---------------------------------------------------------------------------

// CreateGroup creates a new tab. The caller becomes the creator and first
// member; members lists the other members' addresses, comma-separated.
// Returns the group ID.
func CreateGroup(cur realm, name string, members string) int {
	if strings.TrimSpace(name) == "" {
		panic("gnotab: group name must not be empty")
	}
	creator := cur.Previous().Address()
	all := dedupeAddresses(append([]address{creator}, parseAddressList(members)...))
	if len(all) < 2 {
		panic("gnotab: a group needs at least 2 members")
	}
	groupCount++
	g := &Group{
		ID:       groupCount,
		Name:     name,
		Creator:  creator,
		Members:  all,
		Balances: map[address]int64{},
	}
	for _, m := range all {
		g.Balances[m] = 0
	}
	groups[g.ID] = g
	return g.ID
}

// AddExpense records an expense paid by the caller and split equally among
// participants (comma-separated addresses, all must be group members). The
// indivisible remainder of the split is assigned one ugnot at a time to the
// first participants. Returns the expense ID within the group.
func AddExpense(cur realm, groupID int, amount int64, participants string, memo string) int {
	g := getGroup(groupID)
	payer := cur.Previous().Address()
	if !isMember(g, payer) {
		panic("gnotab: payer is not a group member")
	}
	if amount <= 0 {
		panic("gnotab: amount must be positive")
	}
	parts := dedupeAddresses(parseAddressList(participants))
	if len(parts) == 0 {
		panic("gnotab: expense needs at least one participant")
	}
	for _, p := range parts {
		if !isMember(g, p) {
			panic("gnotab: participant is not a group member")
		}
	}

	n := int64(len(parts))
	share := amount / n
	remainder := amount - share*n
	for i, p := range parts {
		s := share
		if int64(i) < remainder {
			s++
		}
		g.Balances[p] -= s
	}
	g.Balances[payer] += amount

	exp := Expense{
		ID:           len(g.Expenses) + 1,
		Payer:        payer,
		Amount:       amount,
		Participants: parts,
		Memo:         memo,
	}
	g.Expenses = append(g.Expenses, exp)
	return exp.ID
}

// Settle records that the caller has paid amount ugnot of their debt to
// the member `to`, and adjusts both net balances accordingly.
func Settle(cur realm, groupID int, to address, amount int64) {
	g := getGroup(groupID)
	from := cur.Previous().Address()
	if !isMember(g, from) {
		panic("gnotab: settler is not a group member")
	}
	if !isMember(g, to) {
		panic("gnotab: settlement target is not a group member")
	}
	if from == to {
		panic("gnotab: cannot settle with yourself")
	}
	if amount <= 0 {
		panic("gnotab: amount must be positive")
	}
	if g.Balances[from] >= 0 {
		panic("gnotab: settler has no outstanding debt")
	}
	if g.Balances[to] <= 0 {
		panic("gnotab: settlement target is not owed anything")
	}
	if amount > -g.Balances[from] {
		panic("gnotab: amount exceeds settler's debt")
	}
	if amount > g.Balances[to] {
		panic("gnotab: amount exceeds what target is owed")
	}
	g.Balances[from] += amount
	g.Balances[to] -= amount
	g.Settlements = append(g.Settlements, Settlement{From: from, To: to, Amount: amount})
}

// GetBalance returns the net balance of a member in ugnot
// (>0: the group owes them, <0: they owe the group, 0: settled).
func GetBalance(groupID int, member address) int64 {
	g := getGroup(groupID)
	if !isMember(g, member) {
		panic("gnotab: not a group member")
	}
	return g.Balances[member]
}

// GroupCount returns how many groups have been created.
func GroupCount() int {
	return groupCount
}

// ---------------------------------------------------------------------------
// Rendering (gnoweb UI)
// ---------------------------------------------------------------------------

// fmtAmount formats an ugnot amount as a signed GNOT string,
// e.g. -1500000 -> "-1.500000 GNOT".
func fmtAmount(u int64) string {
	neg := u < 0
	if neg {
		u = -u
	}
	frac := strconv.FormatInt(u%1000000, 10)
	for len(frac) < 6 {
		frac = "0" + frac
	}
	s := strconv.FormatInt(u/1000000, 10) + "." + frac + " GNOT"
	if neg {
		return "-" + s
	}
	return s
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) > 14 {
		return s[:8] + "…" + s[len(s)-4:]
	}
	return s
}

// Render is the realm's UI on gnoweb.
//
//	""       -> index of all groups
//	"g/<id>" -> one group's live balance sheet
func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderHome()
	}
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "g" {
		id, err := strconv.Atoi(parts[1])
		if err == nil {
			if g, ok := groups[id]; ok {
				return renderGroup(g)
			}
		}
	}
	return "# GnoTab\n\nPage not found. [Back to all tabs](/r/g1qglhdzln0adn63e95gga9rntefhd6s6uw9e2zz/gnotab/v2)"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 🍻 GnoTab — Tavern Tab on Gno\n\n")
	b.WriteString("Group expense tabs, settled on-chain. Create a tab, record who paid, ")
	b.WriteString("and GnoTab nets the debts down to the shortest list of payments.\n\n")
	if groupCount == 0 {
		b.WriteString("No tabs yet. Create the first one with `CreateGroup`.\n")
		return b.String()
	}
	b.WriteString("## Open tabs\n\n")
	for id := 1; id <= groupCount; id++ {
		g := groups[id]
		total := int64(0)
		for _, e := range g.Expenses {
			total += e.Amount
		}
		b.WriteString("- [")
		b.WriteString(g.Name)
		b.WriteString("](/r/g1qglhdzln0adn63e95gga9rntefhd6s6uw9e2zz/gnotab/v2:g/")
		b.WriteString(strconv.Itoa(id))
		b.WriteString(") — ")
		b.WriteString(strconv.Itoa(len(g.Members)))
		b.WriteString(" members, ")
		b.WriteString(strconv.Itoa(len(g.Expenses)))
		b.WriteString(" expenses, ")
		b.WriteString(fmtAmount(total))
		b.WriteString(" recorded\n")
	}
	return b.String()
}

func renderGroup(g *Group) string {
	var b strings.Builder
	b.WriteString("# 🍻 ")
	b.WriteString(g.Name)
	b.WriteString("\n\n")

	b.WriteString("## Balances\n\n")
	for _, m := range g.Members {
		b.WriteString("- `")
		b.WriteString(m.String())
		b.WriteString("`: ")
		b.WriteString(fmtAmount(g.Balances[m]))
		b.WriteString("\n")
	}

	b.WriteString("\n## Who pays whom (netted)\n\n")
	transfers := computeTransfers(g)
	if len(transfers) == 0 {
		b.WriteString("All settled up. 🎉\n")
	} else {
		for _, t := range transfers {
			b.WriteString("- `")
			b.WriteString(shortAddr(t.From))
			b.WriteString("` pays `")
			b.WriteString(shortAddr(t.To))
			b.WriteString("` **")
			b.WriteString(fmtAmount(t.Amount))
			b.WriteString("**\n")
		}
	}

	if len(g.Expenses) > 0 {
		b.WriteString("\n## Expenses\n\n")
		for _, e := range g.Expenses {
			b.WriteString("- #")
			b.WriteString(strconv.Itoa(e.ID))
			b.WriteString(" `")
			b.WriteString(shortAddr(e.Payer))
			b.WriteString("` paid **")
			b.WriteString(fmtAmount(e.Amount))
			b.WriteString("** split ")
			b.WriteString(strconv.Itoa(len(e.Participants)))
			b.WriteString(" ways")
			if e.Memo != "" {
				b.WriteString(" — ")
				b.WriteString(e.Memo)
			}
			b.WriteString("\n")
		}
	}

	if len(g.Settlements) > 0 {
		b.WriteString("\n## Settlements\n\n")
		for _, s := range g.Settlements {
			b.WriteString("- `")
			b.WriteString(shortAddr(s.From))
			b.WriteString("` settled **")
			b.WriteString(fmtAmount(s.Amount))
			b.WriteString("** with `")
			b.WriteString(shortAddr(s.To))
			b.WriteString("`\n")
		}
	}

	b.WriteString("\n[← All tabs](/r/g1qglhdzln0adn63e95gga9rntefhd6s6uw9e2zz/gnotab/v2)\n")
	return b.String()
}
