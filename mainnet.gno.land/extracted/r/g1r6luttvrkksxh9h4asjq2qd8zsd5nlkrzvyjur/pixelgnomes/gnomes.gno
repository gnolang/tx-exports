// Package gnomes — Pixel Gnomes, one hundred of them.
//
// Every gnome is drawn by this realm from its row in traitTable (traits.gno):
// no image files, nothing hosted. The table was picked off-chain, once, with
// a fixed seed (tools/gen-gnome-traits.py), so rarity is deliberate and no
// two gnomes share all nine traits.
//
// ANYONE MAY CALL Mint, once. Every gnome goes to `owner`, fixed in the
// source, so it does not matter who sends the transaction.
//
// OWNERSHIP IS LAZY: all hundred belong to `owner` from the mint without a
// hundred writes. A gnome is written down individually only the first time
// it moves.
//
// ROYALTY is 5% to `royaltyReceiver`, reported by RoyaltyInfo in the EIP-2981 shape.
// It is advisory, as on every chain: a marketplace has to choose to pay it,
// and a direct wallet-to-wallet transfer does not.
package pixelgnomes

import (
	"chain"
	"chain/runtime"
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	collectionName   = "Pixel Gnomes"
	collectionSymbol = "GNOME"
	supply           = 100
	royaltyBps       = int64(500) // 5%

	owner           = address("g1fjr5eezf73tmqzh0ml9qkhj7t8dkn4cgmxgp5f") // receives all 100 at mint
	royaltyReceiver = address("g1d57q42jcymc7qvcea9de6kvadz7pfrvdg7zrgz") // receives the 5% royalty
)

var (
	mintHeight int64

	owners    avl.Tree // token id -> address, only tokens that have moved
	balances  avl.Tree // address -> int64
	approvals avl.Tree // token id -> address
	operators avl.Tree // owner + "/" + operator -> true
)

// Mint brings all hundred into existence, once.
func Mint(cur realm) {
	if mintHeight != 0 {
		panic(ufmt.Sprintf("gnomes: already minted, in block %d", mintHeight))
	}
	if len(traitTable) != supply*traitCount {
		panic("gnomes: trait table does not match the supply")
	}
	mintHeight = runtime.ChainHeight()
	balances.Set(owner.String(), int64(supply))
	for i := 1; i <= supply; i++ {
		chain.Emit("Transfer", "from", "", "to", owner.String(), "tid", strconv.Itoa(i))
	}
	chain.Emit("Minted", "height", strconv.FormatInt(mintHeight, 10), "supply", strconv.Itoa(supply), "to", owner.String())
}

// -- GRC-721 surface --

func Name() string         { return collectionName }
func Symbol() string       { return collectionSymbol }
func Owner() address       { return owner }
func RoyaltyReceiver() address { return royaltyReceiver }
func MintHeight() int64    { return mintHeight }
func TotalSupply() int64 {
	if mintHeight == 0 {
		return 0
	}
	return supply
}

func BalanceOf(addr address) int64 {
	v := balances.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

func OwnerOf(tid string) address { return ownerOf(mustID(tid)) }

func GetApproved(tid string) address {
	mustID(tid)
	v := approvals.Get(tid)
	if v == nil {
		return ""
	}
	return v.(address)
}

func IsApprovedForAll(holder, operator address) bool {
	return operators.Get(holder.String()+"/"+operator.String()) != nil
}

func Approve(cur realm, to address, tid string) {
	caller := cur.Previous().Address()
	holder := ownerOf(mustID(tid))
	if caller != holder && !IsApprovedForAll(holder, caller) {
		panic("gnomes: only the holder or an operator may approve")
	}
	if to == holder {
		panic("gnomes: the holder does not need approving")
	}
	if to == "" {
		approvals.Remove(tid)
	} else {
		approvals.Set(tid, to)
	}
	chain.Emit("Approval", "owner", holder.String(), "approved", to.String(), "tid", tid)
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	caller := cur.Previous().Address()
	if operator == caller {
		panic("gnomes: you cannot make yourself your own operator")
	}
	key := caller.String() + "/" + operator.String()
	if approved {
		operators.Set(key, true)
	} else {
		operators.Remove(key)
	}
	chain.Emit("ApprovalForAll", "owner", caller.String(), "operator", operator.String(), "approved", strconv.FormatBool(approved))
}

func TransferFrom(cur realm, from, to address, tid string) {
	caller := cur.Previous().Address()
	id := mustID(tid)
	holder := ownerOf(id)
	if holder != from {
		panic("gnomes: `from` does not hold this gnome")
	}
	if !to.IsValid() {
		panic("gnomes: that is not a valid address")
	}
	if caller != holder && GetApproved(tid) != caller && !IsApprovedForAll(holder, caller) {
		panic("gnomes: not the holder, not approved, not an operator")
	}
	approvals.Remove(tid)
	owners.Set(tid, to)
	addBalance(from, -1)
	addBalance(to, 1)
	chain.Emit("Transfer", "from", from.String(), "to", to.String(), "tid", tid)
}

// SafeTransferFrom is TransferFrom: there is no receiver hook on gno.land.
func SafeTransferFrom(cur realm, from, to address, tid string) {
	TransferFrom(cross(cur), from, to, tid)
}

// RoyaltyInfo answers the EIP-2981 question: for a sale at salePrice, who
// should receive a royalty, and how much.
func RoyaltyInfo(tid string, salePrice int64) (address, int64) {
	mustID(tid)
	if salePrice < 0 || salePrice > (int64(1)<<62)/royaltyBps {
		panic("gnomes: sale price out of range")
	}
	return royaltyReceiver, salePrice * royaltyBps / 10000
}

func RoyaltyBps() int64 { return royaltyBps }

// TokenURI is the artwork itself, as a data URI.
func TokenURI(tid string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(Art(tid)))
}

// Traits lists one gnome's traits as "trait:option" pairs.
func Traits(tid string) string {
	t := traitsOf(mustID(tid))
	parts := make([]string, traitCount)
	for i := 0; i < traitCount; i++ {
		parts[i] = traitNames[i] + ":" + optionName(i, t[i])
	}
	return strings.Join(parts, ",")
}

// -- helpers --

func mustID(tid string) int {
	n, err := strconv.Atoi(tid)
	if err != nil || n < 1 || n > supply || strconv.Itoa(n) != tid {
		panic("gnomes: gnome ids are 1 to 100")
	}
	return n
}

func ownerOf(id int) address {
	if mintHeight == 0 {
		panic("gnomes: not minted yet")
	}
	if v := owners.Get(strconv.Itoa(id)); v != nil {
		return v.(address)
	}
	return owner
}

func addBalance(a address, d int64) {
	b := BalanceOf(a) + d
	if b == 0 {
		balances.Remove(a.String())
		return
	}
	balances.Set(a.String(), b)
}

// Render: "" is the collection, "N" is gnome N.
func Render(path string) string {
	if path == "" {
		var b strings.Builder
		b.WriteString("# " + collectionName + "\n\n")
		if mintHeight == 0 {
			b.WriteString("100 pixel gnomes. Not minted yet.\n")
			return b.String()
		}
		b.WriteString(ufmt.Sprintf("100 pixel gnomes, minted in block %d. Royalty 5%%.\n\n", mintHeight))
		for i := 1; i <= supply; i++ {
			b.WriteString(ufmt.Sprintf("[#%d](:%d) ", i, i))
		}
		b.WriteString("\n")
		return b.String()
	}
	id := mustID(path)
	tid := strconv.Itoa(id)
	return ufmt.Sprintf("# %s #%d\n\n![Gnome #%d](%s)\n\n%s\n\nHolder: %s\n",
		collectionName, id, id, TokenURI(tid), strings.ReplaceAll(Traits(tid), ",", " · "), ownerOf(id).String())
}
