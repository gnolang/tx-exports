package memba_nft_v2

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/demo/tokens/grc721"
)

// ── Group 3: approvals + read-only queries ────────────────────────────────────

func Approve(cur realm, id string, operator address, tid grc721.TokenID) {
	c := mustGet(id)
	if err := c.nft.Approve(unsafe.PreviousRealm().Address(), operator, tid); err != nil {
		panic(err.Error())
	}
}

func SetApprovalForAll(cur realm, id string, operator address, approved bool) {
	c := mustGet(id)
	if err := c.nft.SetApprovalForAll(unsafe.PreviousRealm().Address(), operator, approved); err != nil {
		panic(err.Error())
	}
}

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

// ── Group 5: MarketTransfer ────────────────────────────────────────────────────

func MarketTransfer(cur realm, id string, from, to address, tid grc721.TokenID) {
	market := unsafe.PreviousRealm().Address()
	if !isRegisteredMarket(market) {
		panic("unauthorized market")
	}
	c := mustGet(id)
	assertNotPaused(c)
	if err := c.nft.TransferFrom(market, from, to, tid); err != nil {
		panic(err.Error())
	}
	chain.Emit("MarketTransfer",
		"collection", id,
		"from", from.String(),
		"to", to.String(),
		"tokenId", string(tid),
	)
}
