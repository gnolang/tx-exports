// Package grc1155 is an edition ledger. One id has a balance per address.
// The realm that calls New owns every later Mint and Move. A caller address
// is not an argument: the home check is the realm value itself.
package grc1155

import (
	"chain"
	"math/overflow"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// Ledger is stored by the creating realm. Do not export it from that realm.
type Ledger struct {
	home   string
	bal    avl.Tree // id|address -> int64
	supply avl.Tree // id -> int64
}

// New binds the ledger to rlm. The realm is not the first argument, so this
// stays a normal call and home stays the creating realm. rlm must be current.
func New(_ int, rlm realm) *Ledger {
	if !rlm.IsCurrent() {
		panic("grc1155: spoofed realm")
	}
	home := rlm.PkgPath()
	if home == "" {
		panic("grc1155: home")
	}
	return &Ledger{home: home}
}

// Mint adds amount of id to to. from is empty in the event.
func (led *Ledger) Mint(_ int, rlm realm, to address, id string, amount int64) {
	led.guard(0, rlm)
	if !to.IsValid() {
		panic("grc1155: address")
	}
	if !validID(id) || amount <= 0 {
		panic("grc1155: amount")
	}
	next := overflow.Add64p(led.Supply(id), amount)
	led.supply.Set(id, next)
	key := balKey(id, to)
	led.bal.Set(key, overflow.Add64p(led.Balance(to, id), amount))
	emit(address(""), to, id, amount)
}

// Move sends amount of id from from to to. Both addresses must already be valid.
func (led *Ledger) Move(_ int, rlm realm, from, to address, id string, amount int64) {
	led.guard(0, rlm)
	if !from.IsValid() || !to.IsValid() || from == to {
		panic("grc1155: address")
	}
	if !validID(id) || amount <= 0 {
		panic("grc1155: amount")
	}
	if led.supply.Get(id) == nil {
		panic("grc1155: unknown id")
	}
	have := led.Balance(from, id)
	if have < amount {
		panic("grc1155: balance")
	}
	left := overflow.Sub64p(have, amount)
	if left == 0 {
		led.bal.Remove(balKey(id, from))
	} else {
		led.bal.Set(balKey(id, from), left)
	}
	led.bal.Set(balKey(id, to), overflow.Add64p(led.Balance(to, id), amount))
	emit(from, to, id, amount)
}

// Balance is the free or escrowed amount of id held by addr. Unknown pairs are 0.
func (led *Ledger) Balance(addr address, id string) int64 {
	if led == nil || !addr.IsValid() || !validID(id) {
		return 0
	}
	v := led.bal.Get(balKey(id, addr))
	if v == nil {
		return 0
	}
	return v.(int64)
}

// Supply is the minted amount of id. An unknown id is 0.
func (led *Ledger) Supply(id string) int64 {
	if led == nil || !validID(id) {
		return 0
	}
	v := led.supply.Get(id)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func (led *Ledger) guard(_ int, rlm realm) {
	if led == nil || !rlm.IsCurrent() || rlm.PkgPath() != led.home {
		panic("grc1155: home")
	}
}

func balKey(id string, addr address) string {
	return id + "|" + addr.String()
}

func validID(id string) bool {
	if len(id) < 1 || len(id) > 16 {
		return false
	}
	if id[0] < 'a' || id[0] > 'z' {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

func emit(from, to address, id string, amount int64) {
	chain.Emit(
		"EditionTransfer",
		"from", from.String(),
		"to", to.String(),
		"id", id,
		"amount", strconv.FormatInt(amount, 10),
	)
}
