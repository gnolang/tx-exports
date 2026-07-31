package memba_collections

import (
	"chain"

	"gno.land/p/samcrew/grc721"
)

// ── Owner approvals ─────────────────────────────────────────────────────────

// Approve grants single-token transfer approval. Caller must own/operate.
func Approve(cur realm, id string, operator address, tid grc721.TokenID) {
	c := mustGet(id)
	if err := c.nft.Approve(caller(), operator, tid); err != nil {
		panic(err.Error())
	}
}

// SetApprovalForAll grants/revokes operator approval for all the caller's
// tokens in the collection (this is how a seller authorizes a marketplace).
func SetApprovalForAll(cur realm, id string, operator address, approved bool) {
	c := mustGet(id)
	if err := c.nft.SetApprovalForAll(caller(), operator, approved); err != nil {
		panic(err.Error())
	}
}

// ── Burn ─────────────────────────────────────────────────────────────────────

// Burn destroys a token the caller owns and clears any per-token royalty.
// Burning never reopens a supply slot (nextAutoTokenID only increments, S-2).
func Burn(cur realm, id string, tid grc721.TokenID) {
	c := mustGet(id)
	owner, err := c.nft.OwnerOf(tid)
	if err != nil {
		panic(err.Error())
	}
	if caller() != owner {
		panic("caller is not owner")
	}
	if err := c.nft.Burn(tid); err != nil {
		panic(err.Error())
	}
	c.tokenRoyalty.Remove(string(tid))
	chain.Emit("Burned", "collectionID", id, "tokenId", string(tid), "owner", owner.String())
}

// ── Settlement (registered markets only) ─────────────────────────────────────

func isRegisteredMarket(a address) bool {
	v, ok := registeredMarkets.Get(a.String())
	return ok && v.(bool)
}

// MarketTransfer is the ONLY token-movement path. Only a registered market
// realm may call it; it moves the token via the realm's internal ledger with
// the market as the grc721 caller (the seller must have approved the market).
func MarketTransfer(cur realm, id string, from, to address, tid grc721.TokenID) {
	market := caller()
	if !isRegisteredMarket(market) {
		panic("unauthorized market")
	}
	c := mustGet(id)
	assertNotPaused(c)
	if err := c.nft.TransferFrom(market, from, to, tid); err != nil {
		panic(err.Error())
	}
	chain.Emit("MarketTransfer",
		"collectionID", id,
		"from", from.String(),
		"to", to.String(),
		"tokenId", string(tid),
	)
}

// ── Reads (IGRC721Reader surface + URI) ──────────────────────────────────────

func OwnerOf(id string, tid grc721.TokenID) address {
	o, err := mustGet(id).nft.OwnerOf(tid)
	if err != nil {
		panic(err.Error())
	}
	return o
}

func BalanceOf(id string, owner address) int64 {
	b, err := mustGet(id).nft.BalanceOf(owner)
	if err != nil {
		panic(err.Error())
	}
	return b
}

func GetApproved(id string, tid grc721.TokenID) address {
	a, err := mustGet(id).nft.GetApproved(tid)
	if err != nil {
		return ""
	}
	return a
}

func IsApprovedForAll(id string, owner, operator address) bool {
	return mustGet(id).nft.IsApprovedForAll(owner, operator)
}

func TokenURI(id string, tid grc721.TokenID) string {
	u, err := mustGet(id).nft.TokenURI(tid)
	if err != nil {
		return ""
	}
	return u
}

func TokenCount(id string) int64 { return mustGet(id).nft.TokenCount() }

func IsRegisteredMarket(a address) bool { return isRegisteredMarket(a) }
