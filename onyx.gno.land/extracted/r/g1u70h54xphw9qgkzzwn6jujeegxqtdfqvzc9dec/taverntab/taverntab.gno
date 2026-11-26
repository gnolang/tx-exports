// Package taverntab is the TavernTab realm: a tavern tab (escrow) for the
// Gnome Tavern. At the tavern you don't pay per drink — you open a tab.
// The realm holds your GNOT, and the tab is later settled (the payee gets
// paid) or cancelled (you get refunded), always by the payer, always on
// the record.
//
// Flow:
//
//	id := OpenTab(payee, "two ales and a stew") // -send 5000000ugnot
//	SettleTab(id) // payer only: realm pays the payee
//	// or
//	CancelTab(id) // payer only: realm refunds the payer in full
//
// Render("") draws the public board on gnoweb: every tab, its status,
// and how much the tavern is holding right now, so anyone can verify
// the state in a browser without a wallet.
package taverntab

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// tabStatus is the lifecycle state of a tab.
type tabStatus uint8

const (
	statusOpen tabStatus = iota
	statusSettled
	statusCancelled
)

func (s tabStatus) String() string {
	switch s {
	case statusOpen:
		return "open"
	case statusSettled:
		return "settled"
	case statusCancelled:
		return "cancelled"
	}
	return "unknown"
}

// tab is a single escrow record. The coins themselves sit in the realm's
// bank account; the tab records who they belong to and where they may go.
type tab struct {
	id     uint64
	payer  address
	payee  address
	amount int64 // ugnot held for this tab
	memo   string
	status tabStatus
}

var (
	tabs      = map[uint64]*tab{}
	nextID    uint64 = 1
	heldTotal int64 // ugnot currently held across all open tabs
)

// OpenTab opens a tab: the caller deposits GNOT (sent with the call),
// recorded against a payee. Only a direct user call is accepted, so the
// origin-send envelope really is the caller's deposit. Returns the tab id.
func OpenTab(cur realm, payee address, memo string) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("OpenTab: only direct user calls can open a tab")
	}
	payer := cur.Previous().Address()
	if payee == payer {
		panic("OpenTab: payee must differ from payer")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("OpenTab: send a single positive ugnot amount with the call")
	}

	id := nextID
	nextID++
	tabs[id] = &tab{
		id:     id,
		payer:  payer,
		payee:  payee,
		amount: sent[0].Amount,
		memo:   memo,
		status: statusOpen,
	}
	heldTotal += sent[0].Amount
	return id
}

// SettleTab settles an open tab: the held amount goes to the payee.
// Only the tab's payer can settle, and only once.
func SettleTab(cur realm, id uint64) {
	t := mustTab(id)
	if cur.Previous().Address() != t.payer {
		panic("SettleTab: only the payer can settle this tab")
	}
	if t.status != statusOpen {
		panic("SettleTab: tab is not open")
	}
	t.status = statusSettled
	heldTotal -= t.amount
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), t.payee, chain.Coins{{Denom: "ugnot", Amount: t.amount}})
}

// CancelTab cancels an open tab: the held amount is refunded in full to
// the payer. Only the tab's payer can cancel, and only once.
func CancelTab(cur realm, id uint64) {
	t := mustTab(id)
	if cur.Previous().Address() != t.payer {
		panic("CancelTab: only the payer can cancel this tab")
	}
	if t.status != statusOpen {
		panic("CancelTab: tab is not open")
	}
	t.status = statusCancelled
	heldTotal -= t.amount
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), t.payer, chain.Coins{{Denom: "ugnot", Amount: t.amount}})
}

// GetTab returns a read-only snapshot of one tab.
func GetTab(id uint64) (payer, payee address, amount int64, memo, status string, found bool) {
	t, ok := tabs[id]
	if !ok {
		return "", "", 0, "", "", false
	}
	return t.payer, t.payee, t.amount, t.memo, t.status.String(), true
}

// HeldTotal returns the ugnot the tavern is currently holding.
func HeldTotal() int64 {
	return heldTotal
}

// Render draws the public board. Render("") lists every tab grouped by
// status plus the held total; Render("<id>") shows a single tab.
func Render(path string) string {
	if path != "" {
		id, err := strconv.ParseUint(path, 10, 64)
		if err != nil {
			return "404: unknown tab"
		}
		t, ok := tabs[id]
		if !ok {
			return "404: unknown tab"
		}
		return renderTab(t)
	}

	out := "# TavernTab — the Gnome Tavern tab board\n\n"
	out += ufmt.Sprintf("The tavern is holding **%dugnot** across open tabs.\n\n", heldTotal)
	for _, s := range []tabStatus{statusOpen, statusSettled, statusCancelled} {
		out += ufmt.Sprintf("## %s tabs\n\n", title(s.String()))
		found := false
		for id := uint64(1); id < nextID; id++ {
			t := tabs[id]
			if t.status != s {
				continue
			}
			found = true
			out += ufmt.Sprintf("- [tab %d](%s): %s owes %s %dugnot — %s\n",
				t.id, strconv.FormatUint(t.id, 10), t.payer, t.payee, t.amount, sanitize.InlineText(t.memo))
		}
		if !found {
			out += "- none\n"
		}
		out += "\n"
	}
	return out
}

func renderTab(t *tab) string {
	return ufmt.Sprintf("# Tab %d\n\n- payer: %s\n- payee: %s\n- amount: %dugnot\n- memo: %s\n- status: %s\n",
		t.id, t.payer, t.payee, t.amount, sanitize.InlineText(t.memo), t.status.String())
}

func mustTab(id uint64) *tab {
	t, ok := tabs[id]
	if !ok {
		panic("unknown tab ID")
	}
	return t
}

func title(s string) string {
	if s == "" {
		return s
	}
	return string(s[0]-'a'+'A') + s[1:]
}
