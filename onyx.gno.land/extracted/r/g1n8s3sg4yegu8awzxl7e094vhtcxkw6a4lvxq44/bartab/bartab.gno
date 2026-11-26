// Package bartab gives an AI agent a tab instead of a wallet.
//
// The owner opens a tab with ugnot and names the agent's address. The agent orders payments; every order runs through
// gno.land/p/g1n8s3sg4yegu8awzxl7e094vhtcxkw6a4lvxq44/spendpolicy and is allowed (paid at once), held for the owner, or refused. Every decision, refusals
// included, is written to the tab's on-chain ledger and shown on the realm's Render page. The owner can approve or reject
// holds, add payees (a new or changed payee address waits out a hold period first) and freeze the tab in one call.
//
// Banker discipline (see SECURITY.md): the realm mints a RealmSend banker only inside the function that pays, keeps it
// in a local variable, and never stores or passes it anywhere. A stored banker would bypass every check here.
package bartab

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	sp "gno.land/p/g1n8s3sg4yegu8awzxl7e094vhtcxkw6a4lvxq44/spendpolicy"
)

const (
	denom      = "ugnot"
	maxMemo    = 64
	maxIdemKey = 64
	maxTabs    = 1000
)

type Hold struct {
	ID      int
	To      address
	Payee   string
	Amount  int64
	Memo    string
	Reason  string
	Created int64
	Status  string // pending, paid, rejected, cancelled, refused:<reason>
}

type Entry struct {
	Seq      int
	Time     int64
	Height   int64
	Actor    address
	Payee    string // payee name at the time, if To was a payee
	Action   string // open, topup, order, approve, reject, payee, caps, freeze, close
	Amount   int64
	To       address
	Decision string
	Note     string
}

type Tab struct {
	ID     int
	Owner  address
	Agent  address
	Policy sp.Policy
	State  sp.State
	Holds  []*Hold
	Ledger []Entry
	Idem   map[string]string
	Closed bool
	Paid   int64 // total paid out to payees
	Served int   // orders paid
	CutOff int   // orders refused
	Held   int   // orders held
}

var (
	tabs []*Tab
)

// ---------- helpers

func now() int64 { return time.Now().Unix() }

func getTab(id int) *Tab {
	if id < 1 || id > len(tabs) {
		panic("no such tab")
	}
	return tabs[id-1]
}

func ownerTab(cur realm, id int) *Tab {
	t := getTab(id)
	if cur.Previous().Address() != t.Owner {
		panic("only the tab's owner can do this")
	}
	if t.Closed {
		panic("tab is closed")
	}
	return t
}

func (t *Tab) log(actor address, action string, amount int64, to address, decision, note string) {
	e := Entry{
		Seq: len(t.Ledger) + 1, Time: now(), Height: runtime.ChainHeight(), Actor: actor, Payee: payeeName(t, to),
		Action: action, Amount: amount, To: to, Decision: decision, Note: note,
	}
	t.Ledger = append(t.Ledger, e)
	chain.Emit("BarTab",
		"tab", strconv.Itoa(t.ID), "seq", strconv.Itoa(e.Seq), "action", action,
		"amount", strconv.FormatInt(amount, 10), "to", to.String(), "decision", decision, "note", note)
}

// received returns the ugnot the caller sent with this call. Only a direct user call (maketx call) is accepted, so the
// send envelope is the caller's own coins and not a balance some intermediate realm already held.
func received(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("call this directly with gnokey maketx call")
	}
	return unsafe.OriginSend().AmountOf(denom)
}

// pay is the only place coins leave the realm. The banker lives in this frame only.
func pay(cur realm, to address, amount int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(denom, amount)))
}

func payeeName(t *Tab, to address) string {
	if p, ok := sp.FindPayee(t.Policy, to); ok {
		return p.Name
	}
	return ""
}

// ---------- owner functions

// OpenTab opens a tab funded with the ugnot sent along (-send). The caller becomes the owner; agent is the only address
// that may order from it. Caps are in ugnot; payeeHoldSecs is the wait before a new or changed payee address is usable;
// expiresUnix 0 means the tab never expires. Returns the tab id.
func OpenTab(cur realm, agent address, perPayment, dailyCap, payeeHoldSecs, expiresUnix int64) int {
	amount := received(cur)
	if amount <= 0 {
		panic("send ugnot to fund the tab")
	}
	if !agent.IsValid() {
		panic("invalid agent address")
	}
	owner := cur.Previous().Address()
	if agent == owner {
		panic("the agent must be a different address from the owner")
	}
	if len(tabs) >= maxTabs {
		panic("too many tabs")
	}
	p := sp.Policy{PerPayment: perPayment, DailyCap: dailyCap, PayeeHoldSecs: payeeHoldSecs, ExpiresAt: expiresUnix}
	if e := sp.Validate(p); e != "" {
		panic(e)
	}
	t := &Tab{ID: len(tabs) + 1, Owner: owner, Agent: agent, Policy: p, State: sp.State{Balance: amount}, Idem: map[string]string{}}
	tabs = append(tabs, t)
	t.log(owner, "open", amount, agent, "ok", "")
	return t.ID
}

// TopUp adds the ugnot sent along to a tab.
func TopUp(cur realm, tabID int) {
	t := ownerTab(cur, tabID)
	amount := received(cur)
	if amount <= 0 {
		panic("send ugnot to top up")
	}
	t.State.Balance += amount
	t.log(t.Owner, "topup", amount, "", "ok", "")
}

// SetPayee adds a payee or changes a payee's address. Either way the address is usable without a hold only after the
// tab's payee hold period. Setting the same address again keeps its current hold time.
func SetPayee(cur realm, tabID int, name string, to address) {
	t := ownerTab(cur, tabID)
	if e := sp.ValidName(name); e != "" {
		panic(e)
	}
	if !to.IsValid() {
		panic("invalid payee address")
	}
	usable := now() + t.Policy.PayeeHoldSecs
	for i, p := range t.Policy.Payees {
		if p.Name == name {
			if p.Addr == to {
				return
			}
			if _, taken := sp.FindPayee(t.Policy, to); taken {
				panic("address already belongs to another payee")
			}
			t.Policy.Payees[i] = sp.Payee{Name: name, Addr: to, UsableAt: usable}
			t.log(t.Owner, "payee", 0, to, "changed", name+" usable from "+when(usable))
			return
		}
	}
	next := t.Policy
	next.Payees = append(append([]sp.Payee{}, t.Policy.Payees...), sp.Payee{Name: name, Addr: to, UsableAt: usable})
	if e := sp.Validate(next); e != "" {
		panic(e)
	}
	t.Policy = next
	t.log(t.Owner, "payee", 0, to, "added", name+" usable from "+when(usable))
}

// RemovePayee removes a payee. Pending holds to that address are refused when approved.
func RemovePayee(cur realm, tabID int, name string) {
	t := ownerTab(cur, tabID)
	for i, p := range t.Policy.Payees {
		if p.Name == name {
			t.Policy.Payees = append(t.Policy.Payees[:i:i], t.Policy.Payees[i+1:]...)
			t.log(t.Owner, "payee", 0, p.Addr, "removed", name)
			return
		}
	}
	panic("no such payee")
}

// SetCaps changes the per-payment and daily caps.
func SetCaps(cur realm, tabID int, perPayment, dailyCap int64) {
	t := ownerTab(cur, tabID)
	next := t.Policy
	next.PerPayment, next.DailyCap = perPayment, dailyCap
	if e := sp.Validate(next); e != "" {
		panic(e)
	}
	t.Policy = next
	t.log(t.Owner, "caps", 0, "", "ok", strconv.FormatInt(perPayment, 10)+"/"+strconv.FormatInt(dailyCap, 10))
}

// Approve pays a held order. It re-checks the order against the tab as it is now: an approval lifts the soft limits
// (caps, payee hold) but never a hard one (frozen, expired, unknown payee, not enough balance).
func Approve(cur realm, tabID, holdID int) string {
	t := ownerTab(cur, tabID)
	h := pendingHold(t, holdID)
	d := sp.Check(t.Policy, t.State, sp.Request{To: h.To, Amount: h.Amount, Now: now(), OwnerApproved: true})
	if d.Kind != sp.Allow {
		h.Status = "refused:" + d.Reason
		t.log(t.Owner, "approve", h.Amount, h.To, d.String(), "hold "+strconv.Itoa(h.ID))
		return d.String()
	}
	t.State = sp.Record(t.State, h.Amount, now())
	h.Status = "paid"
	t.Paid += h.Amount
	t.Served++
	pay(cur, h.To, h.Amount)
	t.log(t.Owner, "approve", h.Amount, h.To, "allow", "hold "+strconv.Itoa(h.ID))
	return "allow"
}

// Reject drops a held order.
func Reject(cur realm, tabID, holdID int) {
	t := ownerTab(cur, tabID)
	h := pendingHold(t, holdID)
	h.Status = "rejected"
	t.log(t.Owner, "reject", h.Amount, h.To, "rejected", "hold "+strconv.Itoa(h.ID))
}

func pendingHold(t *Tab, holdID int) *Hold {
	if holdID < 1 || holdID > len(t.Holds) {
		panic("no such hold")
	}
	h := t.Holds[holdID-1]
	if h.Status != "pending" {
		panic("hold is " + h.Status)
	}
	return h
}

// Freeze is the kill switch: every later order is refused and every pending hold is cancelled, in this one call.
// Unfreeze lifts it.
func Freeze(cur realm, tabID int) {
	t := ownerTab(cur, tabID)
	if t.State.Frozen {
		return
	}
	t.State.Frozen = true
	n := 0
	for _, h := range t.Holds {
		if h.Status == "pending" {
			h.Status = "cancelled"
			n++
		}
	}
	t.log(t.Owner, "freeze", 0, "", "frozen", plural(n, "pending order")+" cancelled")
}

func Unfreeze(cur realm, tabID int) {
	t := ownerTab(cur, tabID)
	if !t.State.Frozen {
		return
	}
	t.State.Frozen = false
	t.log(t.Owner, "unfreeze", 0, "", "ok", "")
}

// CloseTab refunds what is left to the owner and closes the tab for good.
func CloseTab(cur realm, tabID int) {
	t := ownerTab(cur, tabID)
	left := t.State.Balance
	t.State.Balance = 0
	t.State.Frozen = true
	t.Closed = true
	for _, h := range t.Holds {
		if h.Status == "pending" {
			h.Status = "cancelled"
		}
	}
	if left > 0 {
		pay(cur, t.Owner, left)
	}
	t.log(t.Owner, "close", left, t.Owner, "closed", "refund")
}

// ---------- agent function

// Order asks the tab to pay `amount` ugnot to `to`. Only the tab's agent may call it. It never panics on a policy
// outcome, so refusals are recorded on-chain too. idemKey (optional) makes retries safe: the same key on the same tab
// returns the first answer and never pays twice. Returns "allow", "hold:<id>:<reason>" or "deny:<reason>".
func Order(cur realm, tabID int, to address, amount int64, memo, idemKey string) string {
	t := getTab(tabID)
	caller := cur.Previous().Address()
	if caller != t.Agent {
		panic("only the tab's agent can order")
	}
	if len(memo) > maxMemo || len(idemKey) > maxIdemKey {
		panic("memo or idemKey too long")
	}
	if idemKey != "" {
		if prev, ok := t.Idem[idemKey]; ok {
			return prev
		}
	}
	if t.Closed {
		return t.remember(idemKey, "deny:closed")
	}
	sessAddr, sessExp, _, isSession := runtime.GetSessionInfo()
	note := memo
	if isSession {
		note = memo + " [session " + sessAddr.String() + "]"
	}
	r := sp.Request{To: to, Amount: amount, Now: now(), SessionExpiresAt: sessExp}
	d := sp.Check(t.Policy, t.State, r)
	switch d.Kind {
	case sp.Allow:
		t.State = sp.Record(t.State, amount, r.Now)
		t.Paid += amount
		t.Served++
		pay(cur, to, amount)
		t.log(caller, "order", amount, to, "allow", note)
		return t.remember(idemKey, "allow")
	case sp.Hold:
		h := &Hold{ID: len(t.Holds) + 1, To: to, Payee: payeeName(t, to), Amount: amount, Memo: memo, Reason: d.Reason, Created: r.Now, Status: "pending"}
		t.Holds = append(t.Holds, h)
		t.Held++
		t.log(caller, "order", amount, to, d.String(), note)
		return t.remember(idemKey, "hold:"+strconv.Itoa(h.ID)+":"+d.Reason)
	}
	t.CutOff++
	t.log(caller, "order", amount, to, d.String(), note)
	return t.remember(idemKey, d.String())
}

func (t *Tab) remember(idemKey, answer string) string {
	if idemKey != "" {
		t.Idem[idemKey] = answer
	}
	return answer
}

// ---------- reads

// TabCount returns the number of tabs opened.
func TabCount() int { return len(tabs) }

// Balance returns a tab's balance in ugnot.
func Balance(tabID int) int64 { return getTab(tabID).State.Balance }

// LastDecision returns the newest ledger line of a tab as "action decision amount".
func LastDecision(tabID int) string {
	t := getTab(tabID)
	if len(t.Ledger) == 0 {
		return ""
	}
	e := t.Ledger[len(t.Ledger)-1]
	return e.Action + " " + e.Decision + " " + strconv.FormatInt(e.Amount, 10)
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return strconv.Itoa(n) + " " + word + "s"
}
