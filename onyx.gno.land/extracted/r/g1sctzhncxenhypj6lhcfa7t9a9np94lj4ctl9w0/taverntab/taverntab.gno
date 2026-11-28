// Package taverntab is Tavern Tab — on-chain group expense splitting
// with automatic debt simplification, built for the Gnome Tavern
// Hackathon on Gno.land (Onyx testnet).
//
// Model: expenses are recorded on-chain (paid off-chain, e.g. cash or
// card at the bar). The realm is the ledger. Debts are settled in real
// GNOT through Settle, which forwards the coins to the creditor in the
// same call. The realm never holds expense money.
//
// Money math (all integer ugnot, 1 GNOT = 1,000,000 ugnot):
//   - An expense of `amount` split among n participants has
//     share = amount / n and remainder = amount % n.
//   - The payer is credited amount - share - remainder (the others'
//     shares); every other participant is debited share. The remainder
//     stays with the payer. Nets always sum to zero.
//   - A settlement moves `amount` from a debtor to a creditor:
//     debtor net += amount, creditor net -= amount.
//
// API notes (verified against gnolang/gno v1.8.0 — there is no `std`
// package in this version; caller identity comes from the threaded
// `cur realm`):
//   - Caller: cur.Previous().Address() (see docs/resources/effective-gno.md
//     and the repo AGENTS.md security guide).
//   - Payment check: the documented pair cur.Previous().IsUserCall()
//     (direct EOA call only — IsUser() would also accept maketx-run
//     ephemeral realms that can pre-consume the envelope) plus
//     unsafe.OriginSend() amount check. Never one without the other.
//   - Coins move with banker.NewBanker(banker.BankerTypeRealmSend, cur);
//     SendCoins(from, to, coins) requires from == the realm's own address.
package taverntab

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const (
	ugnotDenom   = "ugnot"
	ugnotPerGNOT = int64(1000000)
	maxNameLen   = 100
	maxDescLen   = 200
	maxMembers   = 100
	maxPartExp   = 50
	maxTabs      = 1000
)

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Member struct {
	Addr address
	Name string
}

type Expense struct {
	ID           int64
	Payer        address
	Amount       int64 // total, ugnot
	Share        int64 // per-participant share, ugnot (floor)
	Remainder    int64 // Amount - Share*len(Participants), kept by payer
	Desc         string
	Participants []address
}

type Settlement struct {
	From   address
	To     address
	Amount int64 // ugnot
}

// Balance is one member's net position: positive = others owe them.
type Balance struct {
	Addr address
	Net  int64 // ugnot
}

type Tab struct {
	ID        int64
	Name      string
	Owner     address
	Closed    bool
	Members   []Member
	Expenses  []Expense
	Settled   []Settlement
	NextExpID int64
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

var tabs []Tab
var nextTabID int64 = 1

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

func findTabIndex(id int64) int {
	for i := range tabs {
		if tabs[i].ID == id {
			return i
		}
	}
	return -1
}

func memberIndex(tab Tab, addr address) int {
	for i := range tab.Members {
		if tab.Members[i].Addr == addr {
			return i
		}
	}
	return -1
}

func containsAddr(addrs []address, addr address) bool {
	for _, a := range addrs {
		if a == addr {
			return true
		}
	}
	return false
}

// parseParticipants splits a comma-separated list of g1 addresses.
// Returns an error string ("" = ok). Rejects empties, duplicates,
// non-g1 addresses, and lists longer than maxPartExp.
func parseParticipants(s string) ([]address, string) {
	if strings.TrimSpace(s) == "" {
		return nil, "participants must not be empty"
	}
	parts := strings.Split(s, ",")
	if len(parts) > maxPartExp {
		return nil, "too many participants (max 50)"
	}
	out := make([]address, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if len(p) < 10 || len(p) > 45 || !strings.HasPrefix(p, "g1") {
			return nil, "bad participant address: " + p
		}
		a := address(p)
		if containsAddr(out, a) {
			return nil, "duplicate participant: " + p
		}
		out = append(out, a)
	}
	return out, ""
}

// netBalance derives one member's net position from expenses minus
// settlements. Positive = others owe them.
func netBalance(tab Tab, addr address) int64 {
	net := int64(0)
	for _, e := range tab.Expenses {
		if e.Payer == addr {
			net += e.Amount - e.Share - e.Remainder
		} else if containsAddr(e.Participants, addr) {
			net -= e.Share
		}
	}
	for _, s := range tab.Settled {
		if s.From == addr {
			net += s.Amount
		}
		if s.To == addr {
			net -= s.Amount
		}
	}
	return net
}

func balancesOf(tab Tab) []Balance {
	out := make([]Balance, 0, len(tab.Members))
	for _, m := range tab.Members {
		out = append(out, Balance{Addr: m.Addr, Net: netBalance(tab, m.Addr)})
	}
	return out
}

// planSettlements returns the minimal settlement plan: greedy
// largest-debtor to largest-creditor matching. At most (members - 1)
// transfers. Pure function, no state.
func planSettlements(tab Tab) []Settlement {
	type entry struct {
		addr address
		amt  int64 // >0 creditor, <0 debtor
	}
	var entries []entry
	for _, m := range tab.Members {
		n := netBalance(tab, m.Addr)
		if n != 0 {
			entries = append(entries, entry{addr: m.Addr, amt: n})
		}
	}
	var plan []Settlement
	for {
		ci := -1
		di := -1
		for i, e := range entries {
			if e.amt > 0 && (ci == -1 || e.amt > entries[ci].amt) {
				ci = i
			}
			if e.amt < 0 && (di == -1 || e.amt < entries[di].amt) {
				di = i
			}
		}
		if ci == -1 || di == -1 {
			break
		}
		pay := entries[ci].amt
		owe := -entries[di].amt
		if owe < pay {
			pay = owe
		}
		plan = append(plan, Settlement{From: entries[di].addr, To: entries[ci].addr, Amount: pay})
		entries[ci].amt -= pay
		entries[di].amt += pay
	}
	return plan
}

func formatGNOT(amount int64) string {
	if amount == 0 {
		return "0 GNOT"
	}
	neg := amount < 0
	abs := amount
	if neg {
		abs = -amount
	}
	whole := abs / ugnotPerGNOT
	frac := abs % ugnotPerGNOT
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	for len(fracStr) > 0 && fracStr[len(fracStr)-1] == '0' {
		fracStr = fracStr[:len(fracStr)-1]
	}
	s := strconv.FormatInt(whole, 10)
	if fracStr != "" {
		s += "." + fracStr
	}
	if neg {
		s = "-" + s
	}
	return s + " GNOT"
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:10] + "..." + s[len(s)-4:]
}

// sanitizeInline neutralizes markdown-breaking characters in
// user-supplied strings before they reach Render output. Render input
// is attacker-controlled (repo AGENTS.md security guide), so tab names,
// member names and expense descriptions must never be written raw:
// a "|" would break tables, brackets/backticks would break links and
// code spans, newlines would break layout.
func sanitizeInline(s string) string {
	r := strings.NewReplacer(
		"|", "/",
		"`", "'",
		"[", "(",
		"]", ")",
		"\n", " ",
		"\r", " ",
	)
	return r.Replace(s)
}

// ---------------------------------------------------------------------------
// Core logic (plain functions taking an explicit caller — testable without
// a chain caller context). Crossing wrappers below are thin.
// Each returns "" on success, else an error message.
// ---------------------------------------------------------------------------

func createTab(caller address, name string) (int64, string) {
	name = strings.TrimSpace(name)
	if name == "" {
		return 0, "tab name must not be empty"
	}
	if len(name) > maxNameLen {
		return 0, "tab name too long (max 100)"
	}
	if len(tabs) >= maxTabs {
		return 0, "too many tabs"
	}
	id := nextTabID
	nextTabID++
	tabs = append(tabs, Tab{
		ID:        id,
		Name:      name,
		Owner:     caller,
		Members:   []Member{{Addr: caller, Name: ""}},
		NextExpID: 1,
	})
	return id, ""
}

func joinTab(caller address, tabID int64, name string) string {
	idx := findTabIndex(tabID)
	if idx == -1 {
		return "tab not found"
	}
	if tabs[idx].Closed {
		return "tab is closed"
	}
	if memberIndex(tabs[idx], caller) != -1 {
		return "already a member"
	}
	if len(tabs[idx].Members) >= maxMembers {
		return "tab is full (max 100 members)"
	}
	name = strings.TrimSpace(name)
	if len(name) > maxNameLen {
		return "name too long (max 100)"
	}
	tabs[idx].Members = append(tabs[idx].Members, Member{Addr: caller, Name: name})
	return ""
}

func addMember(caller address, tabID int64, member address, name string) string {
	idx := findTabIndex(tabID)
	if idx == -1 {
		return "tab not found"
	}
	if tabs[idx].Closed {
		return "tab is closed"
	}
	if tabs[idx].Owner != caller {
		return "only the tab owner can add members"
	}
	if memberIndex(tabs[idx], member) != -1 {
		return "already a member"
	}
	if len(tabs[idx].Members) >= maxMembers {
		return "tab is full (max 100 members)"
	}
	name = strings.TrimSpace(name)
	if len(name) > maxNameLen {
		return "name too long (max 100)"
	}
	tabs[idx].Members = append(tabs[idx].Members, Member{Addr: member, Name: name})
	return ""
}

func addExpense(caller address, tabID int64, amount int64, desc string, participants string) (int64, string) {
	idx := findTabIndex(tabID)
	if idx == -1 {
		return 0, "tab not found"
	}
	if tabs[idx].Closed {
		return 0, "tab is closed"
	}
	if memberIndex(tabs[idx], caller) == -1 {
		return 0, "only members can add expenses"
	}
	if amount <= 0 {
		return 0, "amount must be positive"
	}
	desc = strings.TrimSpace(desc)
	if desc == "" {
		return 0, "description must not be empty"
	}
	if len(desc) > maxDescLen {
		return 0, "description too long (max 200)"
	}
	parts, err := parseParticipants(participants)
	if err != "" {
		return 0, err
	}
	if len(parts) < 2 {
		return 0, "need at least 2 participants"
	}
	for _, p := range parts {
		if memberIndex(tabs[idx], p) == -1 {
			return 0, "participant is not a member: " + p.String()
		}
	}
	if !containsAddr(parts, caller) {
		return 0, "payer must be one of the participants"
	}
	n := int64(len(parts))
	share := amount / n
	remainder := amount - share*n
	id := tabs[idx].NextExpID
	tabs[idx].NextExpID++
	tabs[idx].Expenses = append(tabs[idx].Expenses, Expense{
		ID:           id,
		Payer:        caller,
		Amount:       amount,
		Share:        share,
		Remainder:    remainder,
		Desc:         desc,
		Participants: parts,
	})
	return id, ""
}

func removeExpense(caller address, tabID int64, expenseID int64) string {
	idx := findTabIndex(tabID)
	if idx == -1 {
		return "tab not found"
	}
	if tabs[idx].Closed {
		return "tab is closed"
	}
	if len(tabs[idx].Settled) > 0 {
		return "cannot remove expenses after settlements have been recorded"
	}
	expIdx := -1
	for i := range tabs[idx].Expenses {
		if tabs[idx].Expenses[i].ID == expenseID {
			expIdx = i
			break
		}
	}
	if expIdx == -1 {
		return "expense not found"
	}
	if tabs[idx].Expenses[expIdx].Payer != caller {
		return "only the payer can remove this expense"
	}
	tabs[idx].Expenses = append(tabs[idx].Expenses[:expIdx], tabs[idx].Expenses[expIdx+1:]...)
	return ""
}

// settleRecord validates and records a settlement. It does NOT move
// coins — the Settle wrapper forwards them after this returns.
// Returns "" on success.
func settleRecord(caller address, tabID int64, to address, amount int64) string {
	idx := findTabIndex(tabID)
	if idx == -1 {
		return "tab not found"
	}
	if tabs[idx].Closed {
		return "tab is closed"
	}
	if memberIndex(tabs[idx], caller) == -1 {
		return "only members can settle"
	}
	if memberIndex(tabs[idx], to) == -1 {
		return "recipient is not a member"
	}
	if caller == to {
		return "cannot settle to yourself"
	}
	if amount <= 0 {
		return "amount must be positive"
	}
	callerNet := netBalance(tabs[idx], caller)
	if callerNet >= 0 {
		return "you owe nothing on this tab"
	}
	toNet := netBalance(tabs[idx], to)
	if toNet <= 0 {
		return "recipient is not owed anything on this tab"
	}
	if amount > -callerNet {
		return "amount exceeds what you owe"
	}
	if amount > toNet {
		return "amount exceeds what the recipient is owed"
	}
	tabs[idx].Settled = append(tabs[idx].Settled, Settlement{From: caller, To: to, Amount: amount})
	return ""
}

func closeTab(caller address, tabID int64) string {
	idx := findTabIndex(tabID)
	if idx == -1 {
		return "tab not found"
	}
	if tabs[idx].Closed {
		return "tab is already closed"
	}
	if tabs[idx].Owner != caller {
		return "only the tab owner can close it"
	}
	for _, m := range tabs[idx].Members {
		if netBalance(tabs[idx], m.Addr) != 0 {
			return "cannot close: balances are not all zero"
		}
	}
	tabs[idx].Closed = true
	return ""
}

// ---------------------------------------------------------------------------
// Crossing functions (on-chain entry points). Caller identity comes from
// the threaded cur realm: cur.Previous().Address().
// ---------------------------------------------------------------------------

func CreateTab(cur realm, name string) int64 {
	id, err := createTab(cur.Previous().Address(), name)
	if err != "" {
		panic(err)
	}
	return id
}

func JoinTab(cur realm, tabID int64, name string) {
	if err := joinTab(cur.Previous().Address(), tabID, name); err != "" {
		panic(err)
	}
}

func AddMember(cur realm, tabID int64, member address, name string) {
	if err := addMember(cur.Previous().Address(), tabID, member, name); err != "" {
		panic(err)
	}
}

func AddExpense(cur realm, tabID int64, amount int64, desc string, participants string) int64 {
	id, err := addExpense(cur.Previous().Address(), tabID, amount, desc, participants)
	if err != "" {
		panic(err)
	}
	return id
}

func RemoveExpense(cur realm, tabID int64, expenseID int64) {
	if err := removeExpense(cur.Previous().Address(), tabID, expenseID); err != "" {
		panic(err)
	}
}

// Settle is payable: call it with -send <amount>ugnot. The realm
// forwards the coins to the creditor in the same call. State is
// recorded BEFORE the coin transfer (checks-effects-interactions).
//
// Payment verification follows the documented pair (effective-gno.md,
// "Verifying inbound Coin payments"): the IsUserCall guard FIRST —
// only a direct EOA call guarantees the -send coins actually landed
// at this realm (IsUser would also accept maketx-run ephemeral realms
// that can pre-consume the envelope) — then the OriginSend amount
// check. The envelope must be exactly one coin, exactly amount ugnot,
// so no stray denom can get stuck in the realm. Never one check
// without the other.
func Settle(cur realm, tabID int64, to address, amount int64) {
	if !cur.Previous().IsUserCall() {
		panic("Settle must be called directly by a user (maketx call)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != ugnotDenom || sent[0].Amount != amount {
		panic("sent amount must equal the settlement amount")
	}
	caller := cur.Previous().Address()
	if err := settleRecord(caller, tabID, to, amount); err != "" {
		panic(err)
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{{Denom: ugnotDenom, Amount: amount}})
}

func CloseTab(cur realm, tabID int64) {
	if err := closeTab(cur.Previous().Address(), tabID); err != "" {
		panic(err)
	}
}

// ---------------------------------------------------------------------------
// Views (no realm param — callable via qeval)
// ---------------------------------------------------------------------------

func TabCount() int64 {
	return int64(len(tabs))
}

func GetTab(tabID int64) Tab {
	idx := findTabIndex(tabID)
	if idx == -1 {
		panic("tab not found")
	}
	return tabs[idx]
}

func GetMembers(tabID int64) []Member {
	idx := findTabIndex(tabID)
	if idx == -1 {
		panic("tab not found")
	}
	return tabs[idx].Members
}

func GetExpenses(tabID int64) []Expense {
	idx := findTabIndex(tabID)
	if idx == -1 {
		panic("tab not found")
	}
	return tabs[idx].Expenses
}

func GetBalances(tabID int64) []Balance {
	idx := findTabIndex(tabID)
	if idx == -1 {
		panic("tab not found")
	}
	return balancesOf(tabs[idx])
}

func GetPlan(tabID int64) []Settlement {
	idx := findTabIndex(tabID)
	if idx == -1 {
		panic("tab not found")
	}
	return planSettlements(tabs[idx])
}

func GetSettlements(tabID int64) []Settlement {
	idx := findTabIndex(tabID)
	if idx == -1 {
		panic("tab not found")
	}
	return tabs[idx].Settled
}

// ---------------------------------------------------------------------------
// Render (gnoweb)
// ---------------------------------------------------------------------------

func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if path == "" || path == "/" {
		return renderIndex()
	}
	switch parts[0] {
	case "tab":
		if len(parts) < 2 {
			return "# Tavern Tab\n\nMissing tab id. See the [tab list](/)."
		}
		id, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			return "# Tavern Tab\n\nBad tab id."
		}
		return renderTab(id)
	case "stats":
		return renderStats()
	case "guide":
		return renderGuide()
	default:
		return "# Tavern Tab\n\nUnknown page. See the [tab list](/)."
	}
}

func renderIndex() string {
	s := "# 🍺 Tavern Tab\n\n"
	s += "Split the bill, settle on-chain. Open a tab for your table, log "
	s += "who paid what, and let the realm work out the fewest payments "
	s += "to settle up — in real GNOT.\n\n"
	s += "[How it works](/guide) · [Stats](/stats)\n\n"
	if len(tabs) == 0 {
		s += "_No tabs yet. Be the first to open one — see the guide._\n"
		return s
	}
	s += "## Tabs\n\n| # | Tab | Owner | Members | Expenses | Settled | Status |\n"
	s += "|---|-----|-------|---------|----------|---------|--------|\n"
	for _, t := range tabs {
		status := "open"
		if t.Closed {
			status = "closed"
		}
		s += "| " + strconv.FormatInt(t.ID, 10)
		s += " | [" + sanitizeInline(t.Name) + "](/tab/" + strconv.FormatInt(t.ID, 10) + ")"
		s += " | " + shortAddr(t.Owner)
		s += " | " + strconv.Itoa(len(t.Members))
		s += " | " + strconv.Itoa(len(t.Expenses))
		s += " | " + strconv.Itoa(len(t.Settled))
		s += " | " + status + " |\n"
	}
	return s
}

func renderTab(id int64) string {
	idx := findTabIndex(id)
	if idx == -1 {
		return "# Tavern Tab\n\nTab not found."
	}
	t := tabs[idx]
	s := "# 🍺 " + sanitizeInline(t.Name) + "\n\n"
	if t.Closed {
		s += "**Status: CLOSED** — all settled up. 🎉\n\n"
	} else {
		s += "**Status: open** · Owner: `" + t.Owner.String() + "`\n\n"
	}
	s += "## Balances\n\n"
	s += "| Member | Net |\n|--------|-----|\n"
	for _, m := range t.Members {
		n := netBalance(t, m.Addr)
		name := m.Name
		if name == "" {
			name = shortAddr(m.Addr)
		} else {
			name = sanitizeInline(name) + " (" + shortAddr(m.Addr) + ")"
		}
		s += "| " + name + " | " + formatGNOT(n) + " |\n"
	}
	s += "\n_Positive = others owe them. Negative = they owe._\n\n"
	plan := planSettlements(t)
	s += "## Settle up — fewest payments\n\n"
	if len(plan) == 0 {
		s += "_All settled up._\n\n"
	} else {
		for _, p := range plan {
			s += "- `" + shortAddr(p.From) + "` → `" + shortAddr(p.To) + "`: **" + formatGNOT(p.Amount) + "**\n"
		}
		s += "\n"
	}
	s += "## Expenses\n\n"
	if len(t.Expenses) == 0 {
		s += "_No expenses yet._\n"
	} else {
		s += "| # | What | Paid by | Amount | Share each |\n"
		s += "|---|------|---------|--------|------------|\n"
		for _, e := range t.Expenses {
			s += "| " + strconv.FormatInt(e.ID, 10)
			s += " | " + sanitizeInline(e.Desc)
			s += " | " + shortAddr(e.Payer)
			s += " | " + formatGNOT(e.Amount)
			s += " | " + formatGNOT(e.Share) + " |\n"
		}
	}
	if len(t.Settled) > 0 {
		s += "\n## Settlements recorded\n\n"
		for _, st := range t.Settled {
			s += "- `" + shortAddr(st.From) + "` → `" + shortAddr(st.To) + "`: " + formatGNOT(st.Amount) + "\n"
		}
	}
	s += "\n[← All tabs](/)\n"
	return s
}

func renderStats() string {
	totalTabs := len(tabs)
	totalExp := 0
	totalVol := int64(0)
	totalSettled := int64(0)
	openTabs := 0
	for _, t := range tabs {
		totalExp += len(t.Expenses)
		if !t.Closed {
			openTabs++
		}
		for _, e := range t.Expenses {
			totalVol += e.Amount
		}
		for _, st := range t.Settled {
			totalSettled += st.Amount
		}
	}
	s := "# 📊 Tavern Tab — Stats\n\n"
	s += "- Tabs: " + strconv.Itoa(totalTabs) + " (" + strconv.Itoa(openTabs) + " open)\n"
	s += "- Expenses logged: " + strconv.Itoa(totalExp) + "\n"
	s += "- Volume logged: " + formatGNOT(totalVol) + "\n"
	s += "- Settled on-chain: " + formatGNOT(totalSettled) + "\n\n"
	s += "[← All tabs](/)\n"
	return s
}

func renderGuide() string {
	s := "# 🍺 Tavern Tab — How it works\n\n"
	s += "1. **CreateTab(name)** — open a tab for your table. You become the owner (and first member).\n"
	s += "2. **JoinTab(tabID, name)** — friends join with their own wallets. The owner can also **AddMember** someone.\n"
	s += "3. **AddExpense(tabID, amount, desc, participants)** — log who paid what. `amount` is in ugnot (1 GNOT = 1,000,000 ugnot), `participants` is a comma-separated list of `g1...` addresses. The cost splits equally; any leftover ugnot stays with the payer.\n"
	s += "4. Check **Balances** on the tab page, and the **Settle up** plan — the fewest payments that clear every debt.\n"
	s += "5. **Settle(tabID, to, amount)** with `-send <amount>ugnot` — the realm forwards your GNOT to the creditor immediately and records it.\n"
	s += "6. **CloseTab(tabID)** — the owner closes the tab once every balance is zero.\n\n"
	s += "The realm never holds your money: expenses are just a ledger, and settlements move coins straight to the person owed.\n\n"
	s += "[← All tabs](/)\n"
	return s
}
