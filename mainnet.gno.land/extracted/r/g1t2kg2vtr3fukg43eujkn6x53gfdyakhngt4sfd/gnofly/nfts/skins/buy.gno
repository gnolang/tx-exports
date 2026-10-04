package skins

import (
	"chain"
	"chain/banker"

	// Only for OriginSend, in Buy. Caller identity always comes from
	// cur.Previous(), never from this package.
	"chain/runtime/unsafe"

	"gno.land/p/nt/grc721/v0"
)

// Buy buys one token of a skin design for the caller and returns its id. The
// exact price must be attached to the transaction (-send "<price>ugnot") and
// is forwarded to the treasury of the game realm before the call returns.
//
// An address owns at most one token of a design: a skin cannot be given
// away, so a second copy would be of no use. It must be called directly by a
// user (maketx call): a call relayed by another realm or by a maketx run
// script is refused.
func Buy(cur realm, skinID string) int64 {
	buyer := callerOf(0, cur)

	// Paid-call guard: two checks that are only correct together.
	//
	// (a) The caller is a plain user account. Only then is the -send
	//     envelope guaranteed to have landed at this realm's address.
	if !cur.Previous().IsUserCall() {
		panic(errNotUserCall)
	}
	d := getDesign(skinID)
	if d == nil {
		panic(errUnknownSkin)
	}
	if !d.listed {
		panic(errSkinUnlisted)
	}
	if d.maxSupply > 0 && d.minted >= d.maxSupply {
		panic(errSoldOut)
	}
	key := ownedKey(buyer, skinID)
	if owned.Has(key) {
		panic(errAlreadyOwned)
	}

	// (b) The envelope is exactly the price: one coin, the right denom, the
	//     right amount.
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != payDenom || sent[0].Amount != d.price {
		panic("gnofly: wrong payment, send exactly " + itoa(d.price) + payDenom)
	}
	treasury := roles.Treasury()
	payment := chain.NewCoins(chain.NewCoin(payDenom, d.price))
	banker.NewBanker(banker.BankerTypeOriginSend, cur).SendCoins(cur.Address(), treasury, payment)

	id := nextID
	nextID++
	tid := grc721.TokenID(itoa(id))
	if err := ledger.Mint(buyer, tid); err != nil {
		panic(err)
	}
	tokenSkin.Set(string(tid), skinID)
	owned.Set(key, id)
	d.minted++

	chain.Emit("SkinBought",
		"id", itoa(id),
		"skin", skinID,
		"buyer", buyer.String(),
		"price", itoa(d.price),
		"treasury", treasury.String(),
	)
	return id
}

// Burn destroys a skin token. Only its owner can. The storage deposit paid at
// purchase comes back; the price does not. The owner can buy the design
// again, while it is listed.
func Burn(cur realm, id int64) {
	caller := callerOf(0, cur)
	skinID := skinOf(id)
	if skinID == "" {
		panic(errNotMinted)
	}
	if ownerOf(id) != caller {
		panic(errNotSkinOwner)
	}
	tid := grc721.TokenID(itoa(id))
	if err := ledger.Burn(tid); err != nil {
		panic(err)
	}
	tokenSkin.Remove(string(tid))
	owned.Remove(ownedKey(caller, skinID))
	chain.Emit("SkinBurned", "id", itoa(id), "skin", skinID, "owner", caller.String())
}

// ownedKey is the key of owned: the address, then the design.
func ownedKey(addr address, skinID string) string {
	return addr.String() + "/" + skinID
}

// skinOf returns the design of token id, "" when there is no such token.
func skinOf(id int64) string {
	v := tokenSkin.Get(itoa(id))
	if v == nil {
		return ""
	}
	return v.(string)
}

// ownerOf returns who owns token id, "" for none.
func ownerOf(id int64) address {
	owner, err := token.OwnerOf(grc721.TokenID(itoa(id)))
	if err != nil {
		return ""
	}
	return owner
}
