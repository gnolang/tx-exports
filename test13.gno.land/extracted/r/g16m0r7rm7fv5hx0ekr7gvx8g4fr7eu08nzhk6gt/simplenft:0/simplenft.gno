package simplenft

import (
	"strconv"

	"gno.land/p/nt/avl/v0"

	"chain/runtime/unsafe"
)

var (
	owners    avl.Tree
	tokenURIs avl.Tree
	balances  avl.Tree
	nextID    int
	admin     address
)

func init() {
	admin = unsafe.OriginCaller()
	nextID = 1
}

func Mint(cur realm, to address, uri string) int {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("only admin can mint")
	}
	id := nextID
	nextID++
	idStr := strconv.Itoa(id)
	owners.Set(idStr, to.String())
	tokenURIs.Set(idStr, uri)

	balRaw, exists := balances.Get(to.String())
	bal := 0
	if exists {
		bal = balRaw.(int)
	}
	balances.Set(to.String(), bal+1)
	return id
}

func Transfer(cur realm, to address, tokenID int) {
	caller := cur.Previous().Address()
	idStr := strconv.Itoa(tokenID)
	ownerRaw, exists := owners.Get(idStr)
	if !exists {
		panic("token does not exist")
	}
	owner := ownerRaw.(string)
	if owner != caller.String() {
		panic("not token owner")
	}
	owners.Set(idStr, to.String())

	fromBalRaw, _ := balances.Get(owner)
	fromBal := fromBalRaw.(int)
	balances.Set(owner, fromBal-1)

	toBalRaw, exists := balances.Get(to.String())
	toBal := 0
	if exists {
		toBal = toBalRaw.(int)
	}
	balances.Set(to.String(), toBal+1)
}

func OwnerOf(tokenID int) string {
	raw, exists := owners.Get(strconv.Itoa(tokenID))
	if !exists {
		panic("token does not exist")
	}
	return raw.(string)
}

func TokenURI(tokenID int) string {
	raw, exists := tokenURIs.Get(strconv.Itoa(tokenID))
	if !exists {
		panic("token does not exist")
	}
	return raw.(string)
}

func BalanceOf(addr address) int {
	raw, exists := balances.Get(addr.String())
	if !exists {
		return 0
	}
	return raw.(int)
}

func Render(path string) string {
	return "Simple NFT collection\nAdmin: " + admin.String() +
		"\nTotal minted: " + strconv.Itoa(nextID-1)
}
