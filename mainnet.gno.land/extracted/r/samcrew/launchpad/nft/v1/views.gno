package nft

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/samcrew/launchpad/meta/v1"
)

// Lists are paged: a zero-based page of 1 to maxPage entries.
const maxPage = 50

// int64 values are decimal strings so a JSON client cannot round them.
func num(n int64) string { return meta.JSONString(strconv.FormatInt(n, 10)) }

// listJSON renders one page of a tree in key order. The tree seeks the first
// entry by subtree sizes, so a deep page costs what the first one does.
func listJSON(tree *avl.Tree, page, size int64, render func(key string, value any) string) string {
	if page < 0 || size < 1 || size > maxPage {
		panic("launchpad/nft: invalid page")
	}
	var b strings.Builder
	b.WriteByte('[')
	// A page past the end cannot overflow: nothing is multiplied before this.
	if tree != nil && page <= int64(tree.Size())/size {
		tree.IterateByOffset(int(page*size), int(size), func(key string, value any) bool {
			if b.Len() > 1 {
				b.WriteByte(',')
			}
			b.WriteString(render(key, value))
			return false
		})
	}
	b.WriteByte(']')
	return b.String()
}

func CollectionJSON(id string) string {
	c := mustCollection(id)
	i := c.info
	return "{" +
		`"id":` + meta.JSONString(i.ID) +
		`,"grc721Id":` + meta.JSONString(i.GRC721ID) +
		`,"issuer":` + meta.JSONString(i.Issuer.String()) +
		`,"creator":` + meta.JSONString(i.Creator.String()) +
		`,"originator":` + meta.JSONString(i.Originator.String()) +
		`,"pendingCreator":` + meta.JSONString(i.PendingCreator.String()) +
		`,"name":` + meta.JSONString(i.Name) +
		`,"symbol":` + meta.JSONString(i.Symbol) +
		`,"description":` + meta.JSONString(i.Description) +
		`,"image":` + meta.JSONString(i.Image) +
		`,"banner":` + meta.JSONString(i.Banner) +
		`,"website":` + meta.JSONString(i.Website) +
		`,"mode":` + meta.JSONString(i.Mode) +
		`,"revocable":` + strconv.FormatBool(i.Revocable) +
		`,"maxSupply":` + num(i.MaxSupply) +
		`,"sealed":` + strconv.FormatBool(i.Sealed) +
		`,"minted":` + num(i.Minted) +
		`,"totalSupply":` + num(c.token.TotalSupply()) +
		`,"profileFrozen":` + strconv.FormatBool(i.ProfileFrozen) +
		`,"metadataMode":` + meta.JSONString(c.metadata.mode) +
		`,"metadataFrozen":` + strconv.FormatBool(c.metadata.frozen) +
		`,"metadataRevision":` + num(c.metadata.revision) +
		`,"baseURI":` + meta.JSONString(c.metadata.baseURI) +
		`,"placeholderURI":` + meta.JSONString(c.metadata.placeholderURI) +
		`,"baseURICommitment":` + meta.JSONString(c.metadata.commitment) +
		`,"committer":` + meta.JSONString(c.metadata.committer.String()) +
		`,"provenanceHash":` + meta.JSONString(c.metadata.provenance) +
		`,"traitsRoot":` + meta.JSONString(c.traitsRoot) +
		`,"royaltyBPS":` + num(c.royaltyBPS) +
		`,"royalties":` + royaltiesJSON(c.royalties) +
		`,"markets":` + addressesJSON(c.markets) + "}"
}

func royaltiesJSON(royalties []royalty) string {
	var b strings.Builder
	b.WriteByte('[')
	for i, r := range royalties {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"account":` + meta.JSONString(r.Account.String()) +
			`,"bps":` + num(r.BPS) + "}")
	}
	b.WriteByte(']')
	return b.String()
}

func addressesJSON(list []address) string {
	var b strings.Builder
	b.WriteByte('[')
	for i, a := range list {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(meta.JSONString(a.String()))
	}
	b.WriteByte(']')
	return b.String()
}

// CapabilitiesJSON tells a wallet or a market what a holder of this
// collection can do, without it knowing the modes. "markets" is empty when
// any operator may be approved. Royalties are paid by markets at sale.
// "royaltyEnforcement" is "none" without royalties; "market_sales" for an open
// collection, where the ledger enforces nothing: a market that honours
// royalties pays them at a sale, and a direct transfer or any other realm
// pays none; "listed_markets" when the ledger lets a token move only through
// the realms in "markets". Whether a listed realm pays is the word of the
// creator who listed it. "creatorRevoke" is the creator's right to revoke
// a token of a revocable soulbound collection.
func CapabilitiesJSON(id string) string {
	c := mustCollection(id)
	i := c.info
	enforcement := "none"
	if c.royaltyBPS > 0 {
		enforcement = "market_sales"
		if i.Mode == ModeRoyaltyProtected {
			enforcement = "listed_markets"
		}
	}
	return "{" +
		`"schema":"launchpad-nft-capabilities/v1"` +
		`,"collection":` + meta.JSONString(id) +
		`,"standard":"grc721"` +
		`,"mode":` + meta.JSONString(i.Mode) +
		`,"holderTransfer":` + strconv.FormatBool(i.Mode == ModeOpen) +
		`,"marketSale":` + strconv.FormatBool(i.Mode != ModeSoulbound) +
		`,"markets":` + addressesJSON(c.markets) +
		`,"holderBurn":true` +
		`,"creatorRevoke":` + strconv.FormatBool(i.Revocable) +
		`,"maxSupply":` + num(i.MaxSupply) +
		`,"metadataMode":` + meta.JSONString(c.metadata.mode) +
		`,"metadataFrozen":` + strconv.FormatBool(c.metadata.frozen) +
		`,"traitsCommitted":` + strconv.FormatBool(c.traitsRoot != "") +
		`,"royaltyBPS":` + num(c.royaltyBPS) +
		`,"royaltyEnforcement":` + meta.JSONString(enforcement) + "}"
}

// ListCollectionsJSON pages through a summary of every collection, in
// creation order. CollectionJSON has the full record.
func ListCollectionsJSON(page, size int64) string {
	return listJSON(&collections, page, size, func(_ string, value any) string {
		i := value.(*collection).info
		return "{" +
			`"id":` + meta.JSONString(i.ID) +
			`,"creator":` + meta.JSONString(i.Creator.String()) +
			`,"name":` + meta.JSONString(i.Name) +
			`,"symbol":` + meta.JSONString(i.Symbol) +
			`,"image":` + meta.JSONString(i.Image) +
			`,"mode":` + meta.JSONString(i.Mode) +
			`,"maxSupply":` + num(i.MaxSupply) +
			`,"sealed":` + strconv.FormatBool(i.Sealed) +
			`,"minted":` + num(i.Minted) + "}"
	})
}

func tokenJSON(c *collection, number int64) string {
	status := statusOf(c, number)
	var owner address
	if status == StatusActive {
		owner = ownerOf(c, number)
	}
	return "{" +
		`"collection":` + meta.JSONString(c.info.ID) +
		`,"number":` + num(number) +
		`,"owner":` + meta.JSONString(owner.String()) +
		`,"status":` + meta.JSONString(status) +
		`,"uri":` + meta.JSONString(c.metadata.tokenURI(number)) + "}"
}

// TokenJSON describes one minted number. A retired token has no owner.
func TokenJSON(id string, number int64) string { return tokenJSON(mustCollection(id), number) }

// ApprovalJSON answers, in one read, whether operator may move an active
// token: by a single-token approval or by the owner's collection-wide one.
func ApprovalJSON(id string, number int64, operator string) string {
	c := mustCollection(id)
	owner := ownerOf(c, number)
	who := address(operator)
	if !meta.ValidAddress(who) {
		panic("launchpad/nft: invalid operator")
	}
	return "{" +
		`"collection":` + meta.JSONString(id) +
		`,"number":` + num(number) +
		`,"owner":` + meta.JSONString(owner.String()) +
		`,"operator":` + meta.JSONString(operator) +
		`,"tokenApproved":` + strconv.FormatBool(GetApproved(id, number) == who) +
		`,"collectionApproved":` + strconv.FormatBool(c.token.IsApprovedForAll(owner, who)) + "}"
}

// TokensJSON pages through a collection's minted numbers in order, retired
// ones included.
func TokensJSON(id string, page, size int64) string {
	if page < 0 || size < 1 || size > maxPage {
		panic("launchpad/nft: invalid page")
	}
	c := mustCollection(id)
	var b strings.Builder
	b.WriteByte('[')
	if page <= c.info.Minted/size {
		for number := page*size + 1; number <= c.info.Minted && size > 0; number, size = number+1, size-1 {
			if b.Len() > 1 {
				b.WriteByte(',')
			}
			b.WriteString(tokenJSON(c, number))
		}
	}
	b.WriteByte(']')
	return b.String()
}

// HoldingsJSON pages through the tokens an account holds, across every
// collection, in collection then number order.
func HoldingsJSON(owner string, page, size int64) string {
	if !meta.ValidAddress(address(owner)) {
		panic("launchpad/nft: invalid owner")
	}
	mine, _ := holdings.Get(owner).(*avl.Tree)
	return listJSON(mine, page, size, func(key string, _ any) string {
		parts := strings.Split(key, "/")
		c := collections.Get(parts[0]).(*collection)
		number, _ := seqid.FromString(parts[1])
		return "{" +
			`"collection":` + meta.JSONString(c.info.ID) +
			`,"number":` + num(int64(number)) +
			`,"uri":` + meta.JSONString(c.metadata.tokenURI(int64(number))) + "}"
	})
}
