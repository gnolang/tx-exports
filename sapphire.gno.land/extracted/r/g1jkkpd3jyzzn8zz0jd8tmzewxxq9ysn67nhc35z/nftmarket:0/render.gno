package nftmarket

import (
	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	out := "# gnomarket\n\n"
	out += "A fixed-price, non-custodial NFT marketplace for any registered GRC721 collection.\n\n"
	out += ufmt.Sprintf("Registered collections: %d\n\n", collections.Size())
	out += ufmt.Sprintf("Active listings: %d\n\n", len(listingOrder))
	if feeMode == FeeModePercent {
		out += ufmt.Sprintf("Platform fee: %d bps (%d%%)\n\n", feeValue, feeValue/100)
	} else {
		out += ufmt.Sprintf("Platform fee: %d ugnot flat\n\n", feeValue)
	}

	if len(listingOrder) == 0 {
		out += "_No active listings._\n"
		return out
	}

	out += "| Collection | Token | Seller | Price (ugnot) |\n"
	out += "|---|---|---|---|\n"
	for _, key := range listingOrder {
		l, ok := getListing(key)
		if !ok {
			continue
		}
		out += ufmt.Sprintf("| %s | %s | %s | %d |\n", l.CollectionID, l.TokenID, l.Seller, l.Price)
	}
	return out
}
