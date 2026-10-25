// Package agentid binds one short name to one wallet.
//
// Claim writes the binding. Pay forwards the ugnot attached to that
// call to the bound wallet. A binding cannot be renamed, transferred,
// or deleted. The name does not grant a gno.land deploy namespace.
package agentbook

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	std "gno.land/p/g1y0n2geu0rmdrm9u30c5fmk3ykkl2enw9n9yr2k/agentid"
	"gno.land/p/nt/avl/v0"
)

const (
	maxRecent  = 20
	denomUgnot = "ugnot"
)

// record is the binding stored under both indexes.
type record struct {
	name  string
	owner address
}

var (
	byName avl.Tree // name -> *record
	byAddr avl.Tree // owner.String() -> *record
	recent []string // newest claim first, capped at maxRecent
)

// Claim binds name to the calling wallet. This is the registration call.
//
// The name follows gno.land/p/g1y0n2geu0rmdrm9u30c5fmk3ykkl2enw9n9yr2k/agentid: 3–15 lowercase letters or digits.
// One wallet can hold one name. Direct wallet calls only. Coins attached
// to Claim are rejected. A failed claim panics so the transaction reverts.
func Claim(cur realm, name string) {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("claim takes no payment")
	}
	if !std.Valid(name) {
		panic("invalid name")
	}
	if std.Reserved(name) {
		panic("reserved name")
	}
	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("invalid caller")
	}
	if byAddr.Has(caller.String()) {
		panic("already claimed")
	}
	if byName.Has(name) {
		panic("name taken")
	}

	rec := &record{name: name, owner: caller}
	byName.Set(name, rec)
	byAddr.Set(caller.String(), rec)
	pushRecent(name)
	chain.Emit("Claim", "name", name, "owner", caller.String())
}

// Resolve returns the wallet bound to name.
// The second result is false when no binding exists.
func Resolve(name string) (address, bool) {
	rec, ok := lookup(name)
	if !ok {
		return address(""), false
	}
	return rec.owner, true
}

// Reverse returns the name bound to addr.
// The second result is false when addr is not a valid address or has no name.
func Reverse(addr address) (string, bool) {
	if !addr.IsValid() {
		return "", false
	}
	raw := byAddr.Get(addr.String())
	if raw == nil {
		return "", false
	}
	return raw.(*record).name, true
}

// NameOf returns the name bound to addr, or "" when addr has none.
func NameOf(addr address) string {
	name, ok := Reverse(addr)
	if !ok {
		return ""
	}
	return name
}

// IsAvailable reports whether a wallet may claim name.
// Invalid, reserved, and taken names are false. The bare name is required.
func IsAvailable(name string) bool {
	if !std.Valid(name) || std.Reserved(name) {
		return false
	}
	return !byName.Has(name)
}

// Count returns the number of bindings.
func Count() int {
	return byName.Size()
}

// Pay forwards the ugnot attached to this call to the wallet bound to name.
//
// Direct wallet calls only. The call must attach ugnot and nothing else.
// An unknown name, a non-wallet caller, or a missing receipt aborts the
// transaction, so the coins do not stay on this realm.
func Pay(cur realm, name string) {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denomUgnot || sent[0].Amount <= 0 {
		panic("send ugnot")
	}
	amt := sent[0].Amount
	rec, ok := lookup(name)
	if !ok {
		panic("unknown name")
	}

	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	// IsUserCall means this amount landed here. Sending exactly that
	// amount leaves any earlier balance untouched.
	if banker_.GetCoins(realmAddr).AmountOf(denomUgnot) < amt {
		panic("ugnot not received")
	}
	banker_.SendCoins(realmAddr, rec.owner, chain.NewCoins(chain.NewCoin(denomUgnot, amt)))
	chain.Emit("Pay",
		"name", name,
		"to", rec.owner.String(),
		"ugnot", strconv.FormatInt(amt, 10),
	)
}

// Render shows the registry, one name, or the name bound to an address.
//
// path may be a bare name or the same name plus the .agent suffix.
// A valid address with no binding gets a static page. Any other path
// gets a static not-found page. Render does not write state and does
// not echo the raw path.
func Render(path string) string {
	key := renderKey(path)
	if key == "" {
		return renderHome()
	}
	if std.Valid(key) {
		rec, ok := lookup(key)
		if !ok {
			return notFound()
		}
		return renderCard(rec)
	}
	addr := address(key)
	if addr.IsValid() {
		name := NameOf(addr)
		rec, ok := lookup(name)
		if !ok {
			return "# Agent ID\n\nThis address has no Agent ID.\n"
		}
		return renderCard(rec)
	}
	return notFound()
}

func renderCard(rec *record) string {
	out := "# " + rec.name + std.Suffix + "\n\n"
	out += "Address: " + rec.owner.String() + "\n\n"
	out += "Pay forwards the ugnot attached to that call to this address. "
	out += "The call uses the bare name `" + rec.name + "`.\n\n"
	out += "This name is not an r/sys/namereg username and does not open a deploy namespace. "
	out += "It cannot be renamed, transferred, or deleted.\n"
	return out
}

func renderHome() string {
	out := "# Agent ID\n\n"
	out += "A short name for a gno.land address. "
	out += "Claim binds it to your wallet. Pay forwards ugnot to that wallet.\n\n"
	out += "Names are 3–15 lowercase letters or digits. "
	out += "One name per address. A claim cannot be renamed, transferred, or deleted.\n\n"
	out += "This book is not r/sys/namereg. A name here does not open a deploy namespace. "
	out += "Claim takes no payment.\n\n"
	out += "Registered: " + strconv.Itoa(byName.Size()) + "\n\n"
	out += "## Recent\n\n"
	if len(recent) == 0 {
		out += "No names yet.\n"
		return out
	}
	for _, name := range recent {
		rec, ok := lookup(name)
		if !ok {
			continue
		}
		out += "- [" + rec.name + std.Suffix + "](:" + rec.name + ")\n"
	}
	return out
}

func notFound() string {
	return "# Agent ID\n\nName not found.\n"
}

func renderKey(path string) string {
	for len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}
	if i := indexByte(path, '/'); i >= 0 {
		path = path[:i]
	}
	suffix := std.Suffix
	if len(path) > len(suffix) && path[len(path)-len(suffix):] == suffix {
		return path[:len(path)-len(suffix)]
	}
	return path
}

func lookup(name string) (*record, bool) {
	raw := byName.Get(name)
	if raw == nil {
		return nil, false
	}
	return raw.(*record), true
}

func pushRecent(name string) {
	next := make([]string, 0, maxRecent)
	next = append(next, name)
	for _, n := range recent {
		if len(next) == maxRecent {
			break
		}
		next = append(next, n)
	}
	recent = next
}

func indexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}
