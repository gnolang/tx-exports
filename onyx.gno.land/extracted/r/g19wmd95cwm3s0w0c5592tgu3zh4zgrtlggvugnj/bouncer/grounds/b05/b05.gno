// Package b05 is a Bouncer Training Ground: a tip jar with the B05 bug on
// purpose (security guide §5.5). Tip guards its payment with IsUser(),
// which is also true for a MsgRun script. In a MsgRun the coins sent with
// the transaction stay with the sender, while OriginSend still reports
// them, so a script can be credited for coins this realm never received.
// The fix is cur.Previous().IsUserCall().
//
// Break it: get credited for more than you really sent, then call Claim
// from that same address to join the hunters board.
//
// The ground keeps a private record of the coins that really arrived with
// each tip (its own bank balance before and after), so Claim can tell an
// exploit from an honest tip. There is no withdrawal: tips stay here.
package b05

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

var (
	self     address
	credits  = avl.NewTree() // address -> int64 ugnot credited
	received = avl.NewTree() // address -> int64 ugnot that really arrived: private
	seen     int64           // this realm's ugnot balance after the last tip
	hunters  = avl.NewTree() // address -> Hunter
	order    []string        // hunter addresses, first claim first
)

func init(cur realm) {
	self = cur.Address()
	seen = balance()
}

// Hunter is one address that broke this ground.
type Hunter struct {
	Addr     address
	Credited int64
	Received int64
	Height   int64
}

// Tip credits the caller with the ugnot sent with the transaction.
func Tip(cur realm) {
	if !cur.IsCurrent() {
		panic("not current")
	}
	if !cur.Previous().IsUser() { // the bug: IsUser() is true in MsgRun too
		panic("tip from your wallet")
	}
	amount := unsafe.OriginSend().AmountOf("ugnot")
	if amount <= 0 {
		panic("send ugnot to tip")
	}
	caller := string(cur.Previous().Address())
	credits.Set(caller, get(credits, caller)+amount)

	// Bookkeeping for Claim, separate from the bug: what really arrived.
	// The balance never falls here (no withdrawals); clamp anyway, so
	// nobody is charged for coins that left some other way.
	now := balance()
	if delta := now - seen; delta > 0 {
		received.Set(caller, get(received, caller)+delta)
	}
	seen = now
	chain.Emit("Tip", "from", caller, "amount", strconv.FormatInt(amount, 10))
}

// CreditOf returns addr's credited tips in ugnot.
func CreditOf(addr address) int64 {
	return get(credits, string(addr))
}

// Claim records the caller as a hunter if they were credited for more
// than really arrived.
func Claim(cur realm) {
	if !cur.IsCurrent() {
		panic("not current")
	}
	caller := cur.Previous().Address()
	key := string(caller)
	if hunters.Has(key) {
		panic("already on the hunters board")
	}
	credited, got := get(credits, key), get(received, key)
	if credited <= got {
		panic("not broken for your address: you are credited " + strconv.FormatInt(credited, 10) +
			" ugnot and " + strconv.FormatInt(got, 10) + " ugnot arrived")
	}
	hunters.Set(key, Hunter{Addr: caller, Credited: credited, Received: got, Height: runtime.ChainHeight()})
	order = append(order, key)
	chain.Emit("Claimed", "hunter", key, "ground", "B05")
}

// Hunters returns everyone who broke this ground, first claim first.
func Hunters() []Hunter {
	out := make([]Hunter, 0, len(order))
	for _, k := range order {
		out = append(out, hunters.Get(k).(Hunter))
	}
	return out
}

// Broken reports whether anyone has been credited for coins that never
// arrived: total credits exceed what this realm really received.
func Broken() bool {
	return total(credits) > total(received)
}

func total(t *avl.Tree) int64 {
	var sum int64
	t.Iterate("", "", func(_ string, v any) bool {
		sum += v.(int64)
		return false
	})
	return sum
}

func balance() int64 {
	return banker.NewReadonlyBanker().GetCoins(self).AmountOf("ugnot")
}

func get(t *avl.Tree, key string) int64 {
	if v := t.Get(key); v != nil {
		return v.(int64)
	}
	return 0
}

func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Training Ground B05: the trusting tip jar\n\n")
	b.WriteString("A practice target with Bouncer's rule **B05** on purpose: `Tip` checks `IsUser()` before trusting `OriginSend`, and a MsgRun script passes that check (security guide §5.5).\n\n")
	b.WriteString("**Goal:** get credited for more than you really sent, then call `Claim` from the same address.\n\n")
	if Broken() {
		b.WriteString("**Invariant:** total credits equal the coins that arrived. 🔴 Broken.\n\n")
	} else {
		b.WriteString("**Invariant:** total credits equal the coins that arrived. 🟢 Holds.\n\n")
	}
	b.WriteString("Holds " + strconv.FormatInt(balance(), 10) + " ugnot; credited " + strconv.FormatInt(total(credits), 10) + " ugnot.\n\n")
	b.WriteString("<gno-form exec=\"Claim\">\n</gno-form>\n\n")
	b.WriteString("## Hunters\n\n")
	hs := Hunters()
	if len(hs) == 0 {
		b.WriteString("Nobody has broken this ground yet.\n")
		return b.String()
	}
	b.WriteString("| # | Hunter | Credited (ugnot) | Arrived (ugnot) | Block |\n| --- | --- | --- | --- | --- |\n")
	for i, h := range hs {
		b.WriteString("| " + strconv.Itoa(i+1) + " | `" + h.Addr.String() + "` | " + strconv.FormatInt(h.Credited, 10) + " | " +
			strconv.FormatInt(h.Received, 10) + " | " + strconv.FormatInt(h.Height, 10) + " |\n")
	}
	return b.String()
}
