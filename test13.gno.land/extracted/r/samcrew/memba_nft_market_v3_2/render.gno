package memba_nft_market_v3_2

// Render — public read-only views.
//
// Routes:
//   ""       — home: active listings count + volume
//   "stats"  — platform fee, totals
//   "sales"  — recent sales (up to 20)
//   *        — 404

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	switch path {
	case "":
		return renderHome()
	case "stats":
		return renderStats()
	case "sales":
		return renderSales()
	default:
		return "# 404\nNot found: " + path
	}
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# NFT Marketplace\n\n")
	sb.WriteString(ufmt.Sprintf("**Active Listings:** %d\n", listings.Size()))
	volGnot := ufmt.Sprintf("%d.%06d", totalVolume/1_000_000, totalVolume%1_000_000)
	sb.WriteString(ufmt.Sprintf("**Total Volume:** %s GNOT\n", volGnot))

	if len(listingOrder) == 0 {
		sb.WriteString("\n*No active listings.*\n")
		return sb.String()
	}

	const homePageCap = 50

	sb.WriteString("\n| # | Collection | Token | Price | Seller |\n")
	sb.WriteString("|---|-----------|-------|-------|--------|\n")
	shown := 0
	for i, key := range listingOrder {
		if shown >= homePageCap {
			break
		}
		val, exists := listings.Get(key)
		if !exists {
			continue
		}
		l := val.(*Listing)
		priceGnot := ufmt.Sprintf("%d.%06d", l.Price/1_000_000, l.Price%1_000_000)
		sb.WriteString(ufmt.Sprintf("| %d | %s | %s | %s GNOT | %s |\n",
			i+1, truncPath(l.CollectionID), l.TokenID, priceGnot, truncAddr(l.Seller)))
		shown++
	}
	if len(listingOrder) > homePageCap {
		sb.WriteString(ufmt.Sprintf("\n*… showing first %d of %d listings.*\n", homePageCap, len(listingOrder)))
	}
	return sb.String()
}

// feePctString renders FeeBPS as a percent with two decimals (e.g. 200 bps -> "2.00").
// gno's ufmt parses width digits but drops the zero-pad flag, so "%02d" does NOT
// zero-pad — pad the fractional bps explicitly.
func feePctString() string {
	whole := FeeBPS / 100
	frac := FeeBPS % 100
	if frac < 10 {
		return ufmt.Sprintf("%d.0%d", whole, frac)
	}
	return ufmt.Sprintf("%d.%d", whole, frac)
}

func renderStats() string {
	var sb strings.Builder
	sb.WriteString("# Marketplace Stats\n\n")
	sb.WriteString(ufmt.Sprintf("**Active Listings:** %d\n", listings.Size()))
	sb.WriteString(ufmt.Sprintf("**Total Sales:** %d\n", salesLog.Size()))
	volGnot := ufmt.Sprintf("%d.%06d", totalVolume/1_000_000, totalVolume%1_000_000)
	sb.WriteString(ufmt.Sprintf("**Total Volume:** %s GNOT\n", volGnot))
	sb.WriteString(ufmt.Sprintf("**Active Offers:** %d\n", offers.Size()))
	sb.WriteString(ufmt.Sprintf("**Platform Fee:** %s%%\n", feePctString()))
	sb.WriteString(ufmt.Sprintf("**Max Royalty:** %d%%\n", MaxRoyaltyBPS/100))
	return sb.String()
}

func renderSales() string {
	var sb strings.Builder
	sb.WriteString("# Recent Sales\n\n")
	if salesLog.Size() == 0 {
		sb.WriteString("*No sales yet.*\n")
		return sb.String()
	}

	sb.WriteString("| Sale | Collection | Token | Price | Seller | Buyer |\n")
	sb.WriteString("|------|-----------|-------|-------|--------|-------|\n")

	count := 0
	salesLog.ReverseIterate("", "", func(key string, val interface{}) bool {
		s := val.(*Sale)
		priceGnot := ufmt.Sprintf("%d.%06d", s.Price/1_000_000, s.Price%1_000_000)
		sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s GNOT | %s | %s |\n",
			key, truncPath(s.CollectionID), s.TokenID, priceGnot,
			truncAddr(s.Seller), truncAddr(s.Buyer)))
		count++
		return count >= 20
	})
	return sb.String()
}
