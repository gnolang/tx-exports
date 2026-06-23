package nftmarket

import (
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// Render renders the realm as Markdown for the gno.land web UI.
//
//	""                     -> marketplace home (collections + recent listings)
//	"collection/<id>"      -> a single collection and its active listings
//	"listings"             -> every active listing
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case path == "listings":
		return renderAllListings()
	case path == "auctions":
		return "# Live auctions\n\n" + renderAuctionsTable()
	case strings.HasPrefix(path, "collection/"):
		return renderCollection(strings.TrimPrefix(path, "collection/"))
	default:
		return "## 404\nUnknown path: `" + path + "`\n"
	}
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 🖼️ NFT Marketplace\n\n")
	b.WriteString(ufmt.Sprintf("- **Collections**: %d\n", len(collOrder)))
	b.WriteString(ufmt.Sprintf("- **Active listings**: %d\n", listings.Size()))
	b.WriteString(ufmt.Sprintf("- **Active auctions**: %d\n", auctions.Size()))
	b.WriteString(ufmt.Sprintf("- **Platform fee**: %s%%\n\n", bpsToPct(feeBps)))

	b.WriteString("## Collections\n\n")
	if len(collOrder) == 0 {
		b.WriteString("_No collections yet. Be the first: call `CreateCollection`._\n\n")
	}
	for _, id := range collOrder {
		v, ok := collections.Get(id)
		if !ok {
			continue
		}
		c := v.(*Collection)
		b.WriteString(ufmt.Sprintf("- [%s (%s)](/r/demo/nftmarket:collection/%s) — minted %s",
			c.name, c.symbol, c.id, strconv.FormatInt(c.minted, 10)))
		if c.maxSupply > 0 {
			b.WriteString(ufmt.Sprintf("/%s", strconv.FormatInt(c.maxSupply, 10)))
		}
		b.WriteString(ufmt.Sprintf(", mint %s GNOT\n", ugnotToGnot(c.mintPrice)))
	}

	b.WriteString("\n## Recent listings\n\n")
	b.WriteString(renderListingsTable(10))
	b.WriteString("\n## Live auctions\n\n")
	b.WriteString(renderAuctionsTable())
	return b.String()
}

func renderCollection(id string) string {
	v, ok := collections.Get(id)
	if !ok {
		return "## 404\nNo such collection: `" + id + "`\n"
	}
	c := v.(*Collection)

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# %s (%s)\n\n", c.name, c.symbol))
	b.WriteString(ufmt.Sprintf("- **Creator**: %s\n", c.creator.String()))
	b.WriteString(ufmt.Sprintf("- **Mint price**: %s GNOT\n", ugnotToGnot(c.mintPrice)))
	if c.maxSupply > 0 {
		b.WriteString(ufmt.Sprintf("- **Supply**: %s / %s\n",
			strconv.FormatInt(c.minted, 10), strconv.FormatInt(c.maxSupply, 10)))
	} else {
		b.WriteString(ufmt.Sprintf("- **Supply**: %s (unlimited)\n", strconv.FormatInt(c.minted, 10)))
	}
	b.WriteString(ufmt.Sprintf("- **Royalty**: %s%%\n", bpsToPct(c.royaltyBps)))
	if c.baseURI != "" {
		b.WriteString(ufmt.Sprintf("- **Metadata base**: `%s`\n", c.baseURI))
	}

	b.WriteString("\n## Listings in this collection\n\n")
	header := false
	listings.Iterate("", "", func(key string, value any) bool {
		l := value.(*Listing)
		if l.collID != id {
			return false
		}
		if !header {
			b.WriteString("| Token | Price (GNOT) | Seller |\n|---|---|---|\n")
			header = true
		}
		b.WriteString(ufmt.Sprintf("| %s | %s | %s |\n",
			l.tokenID, ugnotToGnot(l.price), l.seller.String()))
		return false
	})
	if !header {
		b.WriteString("_No active listings._\n")
	}
	return b.String()
}

func renderAllListings() string {
	return "# All listings\n\n" + renderListingsTable(0)
}

// renderListingsTable renders up to limit listings (0 = no limit) as a table.
func renderListingsTable(limit int) string {
	if listings.Size() == 0 {
		return "_No active listings._\n"
	}
	var b strings.Builder
	b.WriteString("| Collection | Token | Price (GNOT) | Seller |\n|---|---|---|---|\n")
	n := 0
	listings.Iterate("", "", func(key string, value any) bool {
		l := value.(*Listing)
		b.WriteString(ufmt.Sprintf("| %s | %s | %s | %s |\n",
			l.collID, l.tokenID, ugnotToGnot(l.price), l.seller.String()))
		n++
		return limit > 0 && n >= limit
	})
	return b.String()
}

// renderAuctionsTable renders all live auctions as a Markdown table.
func renderAuctionsTable() string {
	if auctions.Size() == 0 {
		return "_No live auctions._\n"
	}
	var b strings.Builder
	b.WriteString("| Collection | Token | Min bid | Highest bid | Bidder |\n|---|---|---|---|---|\n")
	auctions.Iterate("", "", func(key string, value any) bool {
		a := value.(*Auction)
		hb, bidder := "—", "—"
		if a.highestBid > 0 {
			hb = ugnotToGnot(a.highestBid)
			bidder = a.highestBidder.String()
		}
		b.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s |\n",
			a.collID, a.tokenID, ugnotToGnot(a.minBid), hb, bidder))
		return false
	})
	return b.String()
}

// ugnotToGnot formats a ugnot amount as a GNOT decimal string (6 decimals).
func ugnotToGnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10)
	}
	// zero-pad the fractional part to 6 digits, then trim trailing zeros.
	fs := strconv.FormatInt(frac, 10)
	for len(fs) < 6 {
		fs = "0" + fs
	}
	fs = strings.TrimRight(fs, "0")
	return strconv.FormatInt(whole, 10) + "." + fs
}

// bpsToPct formats basis points as a percentage string (e.g. 250 -> "2.5").
func bpsToPct(bps int64) string {
	whole := bps / 100
	frac := bps % 100
	if frac == 0 {
		return strconv.FormatInt(whole, 10)
	}
	fs := strconv.FormatInt(frac, 10)
	if len(fs) < 2 {
		fs = "0" + fs
	}
	fs = strings.TrimRight(fs, "0")
	return strconv.FormatInt(whole, 10) + "." + fs
}
