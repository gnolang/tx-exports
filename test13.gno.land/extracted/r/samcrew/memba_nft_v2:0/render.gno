package memba_nft_v2

import (
	"strings"

	"gno.land/p/samcrew/grc721"
	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf("# Memba NFT Collections\n\nTotal collections: %d\n", collections.Size())
	}
	parts := strings.SplitN(path, "/", 2)
	id := parts[0]
	cv, ok := collections.Get(id)
	if !ok {
		return "# 404\n\nCollection not found: " + id
	}
	col := cv.(*collection)
	if len(parts) == 1 {
		return ufmt.Sprintf("# %s\n\nSymbol: %s\nSupply: %d\nRoyalty BPS: %d\nRoyalty Recipient: %s\n",
			col.nft.Name(), col.nft.Symbol(), col.nft.TokenCount(), col.royaltyBPS, col.royaltyRecip.String())
	}
	tid := grc721.TokenID(parts[1])
	owner, err := col.nft.OwnerOf(tid)
	if err != nil {
		return "# 404\n\nToken not found: " + string(tid)
	}
	uri, _ := col.nft.TokenURI(tid)
	return ufmt.Sprintf("# Token %s\n\nOwner: %s\nURI: %s\n", string(tid), owner.String(), uri)
}
