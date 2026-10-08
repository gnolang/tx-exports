package nft

import (
	"chain"
	"strings"

	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/samcrew/launchpad/config/v1"
)

// Hard limits, fixed for the life of this realm.
const (
	maxRoyaltyReceivers = 10
	maxRoyaltyBPS       = 1000 // 10% of a sale, across all receivers
	maxMarkets          = 5
)

// royalty is one receiver's share of every sale, in basis points.
type royalty struct {
	Account address
	BPS     int64
}

type RoyaltyPayout struct {
	Account address
	Amount  int64
}

// parseBPS reads a positive decimal with no sign, space or leading zero.
func parseBPS(s string) int64 {
	if s == "" || len(s) > 4 || s[0] == '0' {
		panic("launchpad/nft: invalid royalty share")
	}
	var n int64
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			panic("launchpad/nft: invalid royalty share")
		}
		n = n*10 + int64(s[i]-'0')
	}
	return n
}

// parseRoyalties reads "address:bps;address:bps". Strictly ascending addresses
// give every split exactly one encoding and rule out duplicates.
func parseRoyalties(encoded, mode string) ([]royalty, int64) {
	if encoded == "" {
		if mode == ModeRoyaltyProtected {
			panic("launchpad/nft: a royalty-protected collection needs royalties")
		}
		return nil, 0
	}
	if mode == ModeSoulbound {
		panic("launchpad/nft: soulbound tokens are never sold")
	}
	records := strings.Split(encoded, ";")
	if len(records) > maxRoyaltyReceivers {
		panic("launchpad/nft: too many royalty receivers")
	}
	out := make([]royalty, 0, len(records))
	previous := ""
	var total int64
	for _, record := range records {
		fields := strings.Split(record, ":")
		if len(fields) != 2 || fields[0] <= previous {
			panic("launchpad/nft: invalid royalty list")
		}
		who := address(fields[0])
		// Unspendable covers every text but the chain's spelling of an account.
		if config.IsUnspendable(who) {
			panic("launchpad/nft: invalid royalty receiver")
		}
		bps := parseBPS(fields[1])
		if total = sm.Add(total, bps); total > maxRoyaltyBPS {
			panic("launchpad/nft: royalties exceed 10%")
		}
		out = append(out, royalty{Account: who, BPS: bps})
		previous = fields[0]
	}
	return out, total
}

// validName is the chain's rule for one segment of a package path: a letter
// first, then letters and digits, joined by single "_" or "-".
func validName(s string) bool {
	if s == "" || s[0] < 'a' || s[0] > 'z' {
		return false
	}
	joined := false // the previous character joins two runs
	for i := 1; i < len(s); i++ {
		switch c := s[i]; {
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'):
			joined = false
		case (c == '_' || c == '-') && !joined:
			joined = true
		default:
			return false
		}
	}
	return !joined
}

// A market may be any realm the chain can host, a third party's included, so
// its path follows the chain's own rule for a realm path: "gno.land/r/", then
// names separated by "/", none ending in "_test", in at most 200 bytes. A slot
// is permanent: none is given to a path no realm can have. The rule for
// issuers is config's and is narrower (plain segments in our own namespace):
// an issuer is one of ours, a market need not be.
func validMarketPath(path string) bool {
	if len(path) > 200 || !strings.HasPrefix(path, "gno.land/r/") || strings.HasSuffix(path, "_test") {
		return false
	}
	for _, name := range strings.Split(path[len("gno.land/r/"):], "/") {
		if !validName(name) {
			return false
		}
	}
	return true
}

func RoyaltyBPS(id string) int64 { return mustCollection(id).royaltyBPS }

// RoyaltyQuote floors each receiver's share of price. The seller keeps the
// rounding remainder.
func RoyaltyQuote(id string, price int64) []RoyaltyPayout {
	royalties := mustCollection(id).royalties
	out := make([]RoyaltyPayout, len(royalties))
	for i, r := range royalties {
		out[i] = RoyaltyPayout{Account: r.Account, Amount: sm.BPS(price, r.BPS)}
	}
	return out
}

// AllowMarket adds a realm through which a royalty-protected collection's
// tokens may be sold. The list starts with the Launchpad market and only
// grows: a holder's way out can be widened, never taken away. The ledger
// cannot make a realm pay: the creator vouches that the market it lists pays
// this collection's royalties, and every holder can read the list.
func AllowMarket(cur realm, id, pkgPath string) {
	c := creatorOf(cur, id)
	if c.info.Mode != ModeRoyaltyProtected || !validMarketPath(pkgPath) ||
		len(c.markets) >= maxMarkets ||
		operator(c, chain.PackageAddress(pkgPath)) {
		panic("launchpad/nft: market cannot be added")
	}
	market := chain.PackageAddress(pkgPath)
	c.markets = append(c.markets, market)
	chain.Emit("MarketAllowed", "collection", id, "market", pkgPath,
		"address", market.String())
}
