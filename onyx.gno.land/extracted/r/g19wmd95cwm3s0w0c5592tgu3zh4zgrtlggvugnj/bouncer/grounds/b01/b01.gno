// Package b01 is a Bouncer Training Ground: a vault with the B01 bug on
// purpose (security guide §5.1). Ledger hands out a live pointer to the
// balances tree, and avl.Tree has exported mutating methods.
//
// Break it: get the ledger to credit your address with more than you paid,
// then call Claim from that same address to join the hunters board.
//
// The ground keeps a second, private record of what each address really
// paid. That record is never handed out, so Claim can tell an exploit from
// an honest deposit. This is a practice target: deposits are not meant to
// be withdrawn, and there is no Withdraw.
package b01

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

var (
	ledger  = avl.NewTree() // address -> int64 ugnot credited: the leaked state
	paid    = avl.NewTree() // address -> int64 ugnot really paid: private
	hunters = avl.NewTree() // address -> Hunter
	order   []string        // hunter addresses, first claim first
)

// Hunter is one address that broke this ground.
type Hunter struct {
	Addr     address
	Credited int64 // ledger balance at the claim
	Paid     int64 // what the address really paid
	Height   int64
}

// Deposit credits the caller with the ugnot sent with the call.
func Deposit(cur realm) {
	if !cur.IsCurrent() {
		panic("not current")
	}
	if !cur.Previous().IsUserCall() {
		panic("deposit with maketx call -send")
	}
	amount := unsafe.OriginSend().AmountOf("ugnot")
	if amount <= 0 {
		panic("send ugnot to deposit")
	}
	caller := string(cur.Previous().Address())
	ledger.Set(caller, creditedOf(caller)+amount)
	paid.Set(caller, get(paid, caller)+amount)
	chain.Emit("Deposit", "from", caller, "amount", strconv.FormatInt(amount, 10))
}

// Ledger returns the balances, for frontends that list depositors.
// This is the bug: it returns the tree itself, not a copy.
func Ledger() *avl.Tree {
	return ledger
}

// BalanceOf returns addr's ledger balance in ugnot.
func BalanceOf(addr address) int64 {
	return creditedOf(string(addr))
}

// Claim records the caller as a hunter if the ledger credits them with
// more than they paid.
func Claim(cur realm) {
	if !cur.IsCurrent() {
		panic("not current")
	}
	caller := cur.Previous().Address()
	key := string(caller)
	if hunters.Has(key) {
		panic("already on the hunters board")
	}
	credited, p := creditedOf(key), get(paid, key)
	if credited <= p {
		panic("not broken for your address: the ledger credits you " + strconv.FormatInt(credited, 10) +
			" ugnot and you paid " + strconv.FormatInt(p, 10))
	}
	hunters.Set(key, Hunter{Addr: caller, Credited: credited, Paid: p, Height: runtime.ChainHeight()})
	order = append(order, key)
	chain.Emit("Claimed", "hunter", key, "ground", "B01")
}

// Hunters returns everyone who broke this ground, first claim first.
func Hunters() []Hunter {
	out := make([]Hunter, 0, len(order))
	for _, k := range order {
		out = append(out, hunters.Get(k).(Hunter))
	}
	return out
}

// Broken reports whether someone has claimed, or one of the first
// maxScan ledger entries credits more than was paid. (Anyone can add
// entries through the leak, so the scan is capped to keep Render cheap.)
func Broken() bool {
	if len(order) > 0 {
		return true
	}
	broken, n := false, 0
	ledger.Iterate("", "", func(k string, _ any) bool {
		n++
		if creditedOf(k) > get(paid, k) {
			broken = true
		}
		return broken || n >= maxScan
	})
	return broken
}

const maxScan = 500

// creditedOf reads a ledger entry defensively: a hunter may have stored
// any value, so anything that is not an int64 counts as 1 ugnot credited.
func creditedOf(key string) int64 {
	v := ledger.Get(key)
	if v == nil {
		return 0
	}
	if n, ok := v.(int64); ok {
		return n
	}
	return 1
}

func get(t *avl.Tree, key string) int64 {
	if v := t.Get(key); v != nil {
		return v.(int64)
	}
	return 0
}

func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Training Ground B01: the leaky ledger\n\n")
	b.WriteString("A practice target with Bouncer's rule **B01** on purpose: `Ledger()` returns the live `*avl.Tree` that holds every balance (security guide §5.1).\n\n")
	b.WriteString("**Goal:** make the ledger credit your address with more than you paid, then call `Claim` from the same address.\n\n")
	if Broken() {
		b.WriteString("**Invariant:** every balance equals what was paid. 🔴 Broken.\n\n")
	} else {
		b.WriteString("**Invariant:** every balance equals what was paid. 🟢 Holds.\n\n")
	}
	b.WriteString("<gno-form exec=\"Claim\">\n</gno-form>\n\n")
	b.WriteString("## Hunters\n\n")
	hs := Hunters()
	if len(hs) == 0 {
		b.WriteString("Nobody has broken this ground yet.\n")
		return b.String()
	}
	b.WriteString("| # | Hunter | Credited (ugnot) | Paid (ugnot) | Block |\n| --- | --- | --- | --- | --- |\n")
	for i, h := range hs {
		b.WriteString("| " + strconv.Itoa(i+1) + " | `" + h.Addr.String() + "` | " + strconv.FormatInt(h.Credited, 10) + " | " +
			strconv.FormatInt(h.Paid, 10) + " | " + strconv.FormatInt(h.Height, 10) + " |\n")
	}
	return b.String()
}
