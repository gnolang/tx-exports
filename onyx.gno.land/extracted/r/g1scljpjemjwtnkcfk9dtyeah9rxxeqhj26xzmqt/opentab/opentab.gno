package opentab

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const (
	ugnotDenom   = "ugnot"
	ugnotPerGnot = int64(1_000_000)
	realmPkgPath = "gno.land/r/g1scljpjemjwtnkcfk9dtyeah9rxxeqhj26xzmqt/opentab"
	maxAmount    = int64(1_000_000_000_000_000) // 1e9 GNOT, guards overflow
)

// Tab is one shared bill ("one table").
type Tab struct {
	ID        uint64
	Title     string
	Creator   address
	CreatedAt int64 // block height
	Closed    bool
	Members   []Member
	Items     []Item
}

// Member tracks one participant's share, off-chain fronted amount,
// on-chain deposit, and settlement progress.
type Member struct {
	Addr     address
	Share    int64 // total this member should bear, in ugnot
	Paid     int64 // total this member fronted as item payer, in ugnot (off-chain)
	Deposit  int64 // ugnot currently held in the tab for this member
	Received int64 // ugnot already paid out to this member by Settle
	Settled  int64 // ugnot already taken from this member's deposit toward debts
}

// Item is one expense line on a tab.
type Item struct {
	ID      uint64
	Amount  int64
	Payer   address
	Members []address
	Shares  []int64 // parallel to Members; sums to Amount
}

var (
	nextTabID  uint64
	nextItemID uint64
	tabs       map[uint64]*Tab = map[uint64]*Tab{}
	tabOrder   []uint64
)

// CreateTab opens a new tab. The caller becomes the creator and first member.
func CreateTab(cur realm, title string) uint64 {
	assertUserCall(cur)
	title = strings.TrimSpace(title)
	if title == "" {
		panic("opentab: title is required")
	}
	caller := cur.Previous().Address()
	nextTabID++
	tab := &Tab{
		ID:        nextTabID,
		Title:     title,
		Creator:   caller,
		CreatedAt: runtime.ChainHeight(),
		Members:   []Member{{Addr: caller}},
	}
	tabs[nextTabID] = tab
	tabOrder = append(tabOrder, nextTabID)
	chain.Emit("CreateTab", "id", strconv.FormatUint(nextTabID, 10), "creator", caller.String(), "title", title)
	return nextTabID
}

// AddMember adds a Gno address to an open tab. The caller must already be a member
// (the creator is added automatically at CreateTab).
func AddMember(cur realm, tabID uint64, member address) {
	assertUserCall(cur)
	tab := mustOpenTab(tabID)
	caller := cur.Previous().Address()
	if !isMember(tab, caller) {
		panic("opentab: only a member can add members")
	}
	if !member.IsValid() {
		panic("opentab: invalid member address")
	}
	if isMember(tab, member) {
		panic("opentab: already a member")
	}
	tab.Members = append(tab.Members, Member{Addr: member})
	chain.Emit("AddMember", "id", strconv.FormatUint(tabID, 10), "member", member.String())
}

// AddItem records an expense. amount is in ugnot. payer must be a member.
// splitMembers is a comma-separated list of member addresses who share the bill
// equally. Any leftover ugnot after integer division goes to the first names
// in the list, one ugnot each, so the shares always sum to amount.
func AddItem(cur realm, tabID uint64, amount int64, payer address, splitMembers string) uint64 {
	assertUserCall(cur)
	tab := mustOpenTab(tabID)
	caller := cur.Previous().Address()
	if !isMember(tab, caller) {
		panic("opentab: only a member can add items")
	}
	if amount <= 0 {
		panic("opentab: amount must be positive")
	}
	if amount > maxAmount {
		panic("opentab: amount is too large")
	}
	if !isMember(tab, payer) {
		panic("opentab: payer must be a member")
	}
	split := parseAddresses(splitMembers)
	if len(split) == 0 {
		panic("opentab: at least one member must split the item")
	}
	seen := map[address]bool{}
	for _, addr := range split {
		if !isMember(tab, addr) {
			panic("opentab: split member is not on this tab: " + addr.String())
		}
		if seen[addr] {
			panic("opentab: duplicate split member: " + addr.String())
		}
		seen[addr] = true
	}

	n := int64(len(split))
	base := amount / n
	rem := amount % n
	shares := make([]int64, len(split))
	for i := range split {
		shares[i] = base
		if int64(i) < rem {
			shares[i]++
		}
	}

	nextItemID++
	tab.Items = append(tab.Items, Item{
		ID:      nextItemID,
		Amount:  amount,
		Payer:   payer,
		Members: append([]address(nil), split...),
		Shares:  shares,
	})

	payerMember := memberOf(tab, payer)
	payerMember.Paid += amount
	for i, addr := range split {
		m := memberOf(tab, addr)
		m.Share += shares[i]
	}

	chain.Emit("AddItem", "tab", strconv.FormatUint(tabID, 10), "item", strconv.FormatUint(nextItemID, 10), "amount", strconv.FormatInt(amount, 10))
	return nextItemID
}

// Deposit credits test-GNOT sent with the transaction to the caller's
// balance on an open tab. Only members can deposit.
func Deposit(cur realm, tabID uint64) int64 {
	assertUserCall(cur)
	tab := mustOpenTab(tabID)
	caller := cur.Previous().Address()
	if !isMember(tab, caller) {
		panic("opentab: only a member can deposit")
	}
	sent := unsafe.OriginSend().AmountOf(ugnotDenom)
	if sent <= 0 {
		panic("opentab: send ugnot with the transaction to deposit")
	}
	m := memberOf(tab, caller)
	m.Deposit += sent
	chain.Emit("Deposit", "tab", strconv.FormatUint(tabID, 10), "member", caller.String(), "amount", strconv.FormatInt(sent, 10))
	return sent
}

// Settle uses member deposits to pay outstanding debts, sending ugnot
// from the realm to members who are owed. Partial settlement is allowed
// when deposits do not yet cover every debit. Returns ugnot transferred.
func Settle(cur realm, tabID uint64) int64 {
	assertUserCall(cur)
	tab := mustTab(tabID)
	if tab.Closed {
		panic("opentab: tab is closed")
	}
	caller := cur.Previous().Address()
	if !isMember(tab, caller) {
		panic("opentab: only a member can settle")
	}

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	transferred := int64(0)

	for di := range tab.Members {
		debtor := &tab.Members[di]
		pay := min64(debtor.Deposit, remainingDebit(debtor))
		if pay <= 0 {
			continue
		}
		for ci := range tab.Members {
			if pay <= 0 {
				break
			}
			creditor := &tab.Members[ci]
			need := remainingCredit(creditor)
			if need <= 0 {
				continue
			}
			x := min64(pay, need)
			bk.SendCoins(realmAddr, creditor.Addr, chain.Coins{{Denom: ugnotDenom, Amount: x}})
			creditor.Received += x
			debtor.Deposit -= x
			debtor.Settled += x
			pay -= x
			transferred += x
		}
	}

	chain.Emit("Settle", "tab", strconv.FormatUint(tabID, 10), "transferred", strconv.FormatInt(transferred, 10))
	return transferred
}

// CloseTab closes a fully settled tab and refunds leftover deposits to
// their owners. Any member may close once every debit is paid.
func CloseTab(cur realm, tabID uint64) int64 {
	assertUserCall(cur)
	tab := mustTab(tabID)
	if tab.Closed {
		panic("opentab: tab is already closed")
	}
	caller := cur.Previous().Address()
	if !isMember(tab, caller) {
		panic("opentab: only a member can close the tab")
	}
	if !isFullySettled(tab) {
		panic("opentab: cannot close until every debit is settled")
	}

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	refunded := int64(0)
	for i := range tab.Members {
		m := &tab.Members[i]
		if m.Deposit > 0 {
			amt := m.Deposit
			bk.SendCoins(realmAddr, m.Addr, chain.Coins{{Denom: ugnotDenom, Amount: amt}})
			m.Deposit = 0
			refunded += amt
		}
	}
	tab.Closed = true
	chain.Emit("CloseTab", "tab", strconv.FormatUint(tabID, 10), "refunded", strconv.FormatInt(refunded, 10))
	return refunded
}

// Render is the gnoweb entry point.
// Paths:
//
//	""        — intro and list of tabs
//	"tab/<id>" — tab detail: members, items, owed / paid / deposit / net
func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderIndex()
	}
	if strings.HasPrefix(path, "tab/") {
		idStr := strings.TrimPrefix(path, "tab/")
		id, err := strconv.ParseUint(idStr, 10, 64)
		if err != nil {
			return "# OpenTab\n\nInvalid tab id.\n"
		}
		tab, ok := tabs[id]
		if !ok {
			return "# OpenTab\n\nTab not found.\n"
		}
		return renderTab(tab)
	}
	return "# OpenTab\n\nUnknown path. Try the [home page](" + realmLink("") + ").\n"
}

func renderIndex() string {
	var b strings.Builder
	b.WriteString("# OpenTab\n\n")
	b.WriteString("A one-table shared bill on the Gno.land testnet. Create a tab, add members and expenses, deposit test-GNOT, settle what is owed, and close the tab when everyone is even.\n\n")
	b.WriteString("Use the **Actions** tab in gnoweb (or `gnokey maketx call`) to run `CreateTab`, `AddMember`, `AddItem`, `Deposit`, `Settle`, and `CloseTab`. Amounts are in **ugnot** (1 GNOT = 1,000,000 ugnot). Send test-GNOT with `Deposit` using the transaction `-send` flag or the wallet send field.\n\n")
	if len(tabOrder) == 0 {
		b.WriteString("_No tabs yet. Call `CreateTab` to open the first one._\n")
		return b.String()
	}
	b.WriteString("## Tabs\n\n")
	b.WriteString("| ID | Title | Members | Status | Link |\n")
	b.WriteString("| --- | --- | ---: | --- | --- |\n")
	for i := len(tabOrder) - 1; i >= 0; i-- {
		tab := tabs[tabOrder[i]]
		status := "open"
		if tab.Closed {
			status = "closed"
		} else if isFullySettled(tab) && len(tab.Items) > 0 {
			status = "settled"
		}
		b.WriteString("| ")
		b.WriteString(strconv.FormatUint(tab.ID, 10))
		b.WriteString(" | ")
		b.WriteString(escapeCell(tab.Title))
		b.WriteString(" | ")
		b.WriteString(strconv.Itoa(len(tab.Members)))
		b.WriteString(" | ")
		b.WriteString(status)
		b.WriteString(" | [view](")
		b.WriteString(realmLink("tab/" + strconv.FormatUint(tab.ID, 10)))
		b.WriteString(") |\n")
	}
	return b.String()
}

func renderTab(tab *Tab) string {
	var b strings.Builder
	b.WriteString("# Tab #")
	b.WriteString(strconv.FormatUint(tab.ID, 10))
	b.WriteString(": ")
	b.WriteString(tab.Title)
	b.WriteString("\n\n")
	b.WriteString("[← all tabs](")
	b.WriteString(realmLink(""))
	b.WriteString(")\n\n")
	status := "open"
	if tab.Closed {
		status = "closed"
	} else if isFullySettled(tab) && len(tab.Items) > 0 {
		status = "settled, ready to close"
	}
	b.WriteString("- Status: **")
	b.WriteString(status)
	b.WriteString("**\n")
	b.WriteString("- Creator: `")
	b.WriteString(tab.Creator.String())
	b.WriteString("`\n")
	b.WriteString("- Created at height: ")
	b.WriteString(strconv.FormatInt(tab.CreatedAt, 10))
	b.WriteString("\n\n")

	b.WriteString("## Members\n\n")
	b.WriteString("| Address | Share (owed) | Fronted (paid) | Deposit | Received | Still owes | Still due |\n")
	b.WriteString("| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n")
	for i := range tab.Members {
		m := &tab.Members[i]
		b.WriteString("| `")
		b.WriteString(m.Addr.String())
		b.WriteString("` | ")
		b.WriteString(formatUgnot(m.Share))
		b.WriteString(" | ")
		b.WriteString(formatUgnot(m.Paid))
		b.WriteString(" | ")
		b.WriteString(formatUgnot(m.Deposit))
		b.WriteString(" | ")
		b.WriteString(formatUgnot(m.Received))
		b.WriteString(" | ")
		b.WriteString(formatUgnot(remainingDebit(m)))
		b.WriteString(" | ")
		b.WriteString(formatUgnot(remainingCredit(m)))
		b.WriteString(" |\n")
	}
	b.WriteString("\n")
	b.WriteString("_Share_ is this member's portion of recorded items. _Fronted_ is the amount they paid as an item payer (off-chain). _Deposit_ is test-GNOT currently held in the tab. _Still owes_ / _Still due_ are the remaining on-chain settlement amounts.\n\n")

	b.WriteString("## Items\n\n")
	if len(tab.Items) == 0 {
		b.WriteString("_No items yet._\n")
		return b.String()
	}
	b.WriteString("| ID | Amount | Payer | Split |\n")
	b.WriteString("| --- | ---: | --- | --- |\n")
	for _, item := range tab.Items {
		b.WriteString("| ")
		b.WriteString(strconv.FormatUint(item.ID, 10))
		b.WriteString(" | ")
		b.WriteString(formatUgnot(item.Amount))
		b.WriteString(" | `")
		b.WriteString(item.Payer.String())
		b.WriteString("` | ")
		parts := make([]string, len(item.Members))
		for j, addr := range item.Members {
			parts[j] = "`" + addr.String() + "` " + formatUgnot(item.Shares[j])
		}
		b.WriteString(strings.Join(parts, ", "))
		b.WriteString(" |\n")
	}
	return b.String()
}

func realmLink(sub string) string {
	// gnoweb path: /r/<addr>/opentab or /r/<addr>/opentab:tab/1
	base := "/r/g1scljpjemjwtnkcfk9dtyeah9rxxeqhj26xzmqt/opentab"
	if sub == "" {
		return base
	}
	return base + ":" + sub
}

func assertUserCall(cur realm) {
	// IsUserCall is true only for a direct EOA `maketx call`.
	// It rejects other realms and `maketx run` ephemeral callers,
	// which is the same pattern used by official examples such as
	// r/demo/disperse.
	if !cur.Previous().IsUserCall() {
		panic("opentab: only a direct user call is allowed")
	}
}

func mustTab(id uint64) *Tab {
	tab, ok := tabs[id]
	if !ok {
		panic("opentab: tab not found")
	}
	return tab
}

func mustOpenTab(id uint64) *Tab {
	tab := mustTab(id)
	if tab.Closed {
		panic("opentab: tab is closed")
	}
	return tab
}

func isMember(tab *Tab, addr address) bool {
	for i := range tab.Members {
		if tab.Members[i].Addr == addr {
			return true
		}
	}
	return false
}

func memberOf(tab *Tab, addr address) *Member {
	for i := range tab.Members {
		if tab.Members[i].Addr == addr {
			return &tab.Members[i]
		}
	}
	panic("opentab: not a member")
}

func remainingDebit(m *Member) int64 {
	d := m.Share - m.Paid - m.Settled
	if d < 0 {
		return 0
	}
	return d
}

func remainingCredit(m *Member) int64 {
	c := m.Paid - m.Share - m.Received
	if c < 0 {
		return 0
	}
	return c
}

func isFullySettled(tab *Tab) bool {
	for i := range tab.Members {
		if remainingDebit(&tab.Members[i]) > 0 {
			return false
		}
	}
	return true
}

func parseAddresses(s string) []address {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]address, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		addr := address(p)
		if !addr.IsValid() {
			panic("opentab: invalid address: " + p)
		}
		out = append(out, addr)
	}
	return out
}

func formatUgnot(amount int64) string {
	sign := ""
	v := amount
	if v < 0 {
		sign = "-"
		v = -v
	}
	whole := v / ugnotPerGnot
	frac := v % ugnotPerGnot
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	return sign + strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

func escapeCell(s string) string {
	s = strings.ReplaceAll(s, "|", "/")
	s = strings.ReplaceAll(s, "\n", " ")
	return s
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
