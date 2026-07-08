package memba_token_otc_v2

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/samcrew/memba_market_config"
	"gno.land/r/samcrew/tokenfactory_v2"
)

// AdminAddress is the same 2-of-2 multisig used by the market config.
const AdminAddress = "g10kw7e55e9wc8j8v6904ck29dqwr9fm9u280juh"

type Listing struct {
	Id        uint64
	Seller    address
	Symbol    string
	Amount    int64
	UnitPrice int64
	CreatedAt int64
}

var (
	admin         address
	paused        bool
	listings      avl.Tree // uint64 -> *Listing
	nextListingId uint64 = 1
)

func init() {
	admin = address(AdminAddress)
}

func caller() address { return unsafe.PreviousRealm().Address() }

// Pause acts as the kill switch for the engine (stops listing and filling).
func Pause(cur realm, state bool) {
	if caller() != admin {
		panic("unauthorized")
	}
	paused = state
}

// ListTokens creates a new OTC listing for a tokenfactory_v2 token.
func ListTokens(cur realm, symbol string, amount, unitPrice int64) uint64 {
	if paused {
		panic("engine is paused")
	}
	if amount <= 0 {
		panic("amount must be > 0")
	}
	if unitPrice <= 0 {
		panic("unitPrice must be > 0")
	}

	seller := caller()

	// SECURITY: Ensure the token was minted by tokenfactory_v2.
	// Bank will panic if the symbol is not registered in the factory.
	_ = tokenfactory_v2.Bank(symbol)

	// Verify the seller has enough balance and has approved this realm.
	bal := tokenfactory_v2.BalanceOf(symbol, seller)
	if bal < amount {
		panic("insufficient token balance")
	}
	allow := tokenfactory_v2.Allowance(symbol, seller, cur.Address())
	if allow < amount {
		panic("insufficient token allowance granted to OTC realm")
	}

	id := nextListingId
	nextListingId++

	listing := &Listing{
		Id:        id,
		Seller:    seller,
		Symbol:    symbol,
		Amount:    amount,
		UnitPrice: unitPrice,
		CreatedAt: runtime.ChainHeight(),
	}

	listings.Set(ufmt.Sprintf("%d", id), listing)

	chain.Emit("Listed",
		"id", ufmt.Sprintf("%d", id),
		"seller", string(seller),
		"symbol", symbol,
		"amount", ufmt.Sprintf("%d", amount),
		"unitPrice", ufmt.Sprintf("%d", unitPrice),
	)

	return id
}

// CancelListing removes an OTC listing. Only the seller can cancel.
func CancelListing(cur realm, listingId uint64) {
	seller := caller()
	listingRaw, exists := listings.Get(ufmt.Sprintf("%d", listingId))
	if !exists {
		panic("listing not found")
	}
	listing := listingRaw.(*Listing)

	if listing.Seller != seller {
		panic("unauthorized: not the seller")
	}

	listings.Remove(ufmt.Sprintf("%d", listingId))

	chain.Emit("Cancelled",
		"id", ufmt.Sprintf("%d", listingId),
	)
}

// Fill executes a partial or full fill of an OTC listing.
func Fill(cur realm, listingId uint64, qty, expectedUnitPrice int64) {
	if paused {
		panic("engine is paused")
	}

	// P0 fund-guard: a payable entrypoint MUST be a direct user call. unsafe.OriginSend()
	// reports the tx-level `--send`, credited to the DIRECT message target realm — not to
	// an inner realm reached via a cross-call. This realm forwards funds immediately and
	// holds no standing pool, so a routed fill self-reverts today (MED) — but the guard is
	// applied uniformly with the other payable entrypoints to close the residual-balance
	// edge (stranded/donated ugnot) and prevent regressions.
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("Fill must be a direct user call")
	}

	if qty <= 0 {
		panic("qty must be > 0")
	}

	buyer := caller()

	listingRaw, exists := listings.Get(ufmt.Sprintf("%d", listingId))
	if !exists {
		panic("listing not found")
	}
	listing := listingRaw.(*Listing)

	// Slippage & front-run protection
	if listing.UnitPrice != expectedUnitPrice {
		panic("price mismatch (front-run protection)")
	}

	if listing.Amount < qty {
		panic("requested qty exceeds available listing amount")
	}

	// Verify seller still has balance and allowance
	bal := tokenfactory_v2.BalanceOf(listing.Symbol, listing.Seller)
	if bal < qty {
		panic("seller has insufficient balance")
	}
	allow := tokenfactory_v2.Allowance(listing.Symbol, listing.Seller, cur.Address())
	if allow < qty {
		panic("seller has insufficient allowance")
	}

	// Calculate cost — guard the int64 multiplication against overflow. qty>0 (checked
	// above) and unitPrice>0 (checked at ListTokens), so a valid product is >0 and
	// cost/qty == unitPrice; a wrapped product fails one of those.
	cost := qty * listing.UnitPrice
	if cost <= 0 || cost/qty != listing.UnitPrice {
		panic("cost overflow")
	}

	// Dust-fill evasion protection (e.g., minimum notional > 0 if fee > 0)
	feeBps, treasury := memba_market_config.GetLaneConfig("token")
	if feeBps > int(memba_market_config.MaxFeeBPS) {
		feeBps = int(memba_market_config.DefaultFeeBPS) // safe fallback clamp
	}

	fee := (cost * int64(feeBps)) / 10000
	if feeBps > 0 && fee == 0 {
		panic("dust fill: notional too small to cover minimum fee")
	}

	// Require EXACT payment sent WITH this call. Read OriginSend (the coins attached to
	// the call) — NOT the caller's wallet balance — mirroring escrow_v2.FundMilestone.
	// Exact-coin closes both the overpay-trap (excess had no refund/sweep) and the
	// wallet-balance bypass (a funded caller could trigger a payout without paying).
	sent := unsafe.OriginSend()
	if sent.AmountOf("ugnot") != cost {
		panic(ufmt.Sprintf("must send exactly %d ugnot (sent %d)", cost, sent.AmountOf("ugnot")))
	}

	// CEI: Update state first
	listing.Amount -= qty
	if listing.Amount == 0 {
		listings.Remove(ufmt.Sprintf("%d", listingId))
	} else {
		listings.Set(ufmt.Sprintf("%d", listingId), listing)
	}

	// Route funds from the realm's own account (holding the exact ugnot just received).
	sellerProceeds := cost - fee
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := unsafe.CurrentRealm().Address()
	if fee > 0 {
		bnk.SendCoins(realmAddr, treasury, chain.Coins{chain.NewCoin("ugnot", fee)})
	}
	if sellerProceeds > 0 {
		bnk.SendCoins(realmAddr, listing.Seller, chain.Coins{chain.NewCoin("ugnot", sellerProceeds)})
	}

	// Transfer tokens and measure delta (fee-on-transfer protection)
	buyerBalBefore := tokenfactory_v2.BalanceOf(listing.Symbol, buyer)
	
	tokenfactory_v2.TransferFrom(cross(cur), listing.Symbol, listing.Seller, buyer, qty)
	
	buyerBalAfter := tokenfactory_v2.BalanceOf(listing.Symbol, buyer)
	delta := buyerBalAfter - buyerBalBefore
	if delta != qty {
		panic("token transfer delta mismatch (fee-on-transfer not supported)")
	}

	chain.Emit("Filled",
		"id", ufmt.Sprintf("%d", listingId),
		"buyer", string(buyer),
		"seller", string(listing.Seller),
		"symbol", listing.Symbol,
		"qty", ufmt.Sprintf("%d", qty),
		"unitPrice", ufmt.Sprintf("%d", listing.UnitPrice),
		"feeBps", ufmt.Sprintf("%d", feeBps),
		"fee", ufmt.Sprintf("%d", fee),
	)
}

// ── Read Getters ─────────────────────────────────────────────────────────────

// EngineAddress returns this realm's on-chain address — the account sellers approve to
// move their tokens and the settlement account. Exposed so the frontend/deploy ceremony
// can wire the engine without hardcoding the derived address (mirrors nft_market_v3
// MarketAddress()).
func EngineAddress() address {
	return unsafe.CurrentRealm().Address()
}

func GetListing(listingId uint64) *Listing {
	listingRaw, exists := listings.Get(ufmt.Sprintf("%d", listingId))
	if !exists {
		return nil
	}
	return listingRaw.(*Listing)
}

// Note: In production we'd want paginated getters here to prevent O(N) gas limits.
// For v1.1, we'll return all active listings or window them.
func GetListings() []*Listing {
	var result []*Listing
	listings.Iterate("", "", func(key string, value interface{}) bool {
		result = append(result, value.(*Listing))
		return false
	})
	return result
}

// GetListingsCSV returns listings formatted as "ID|Seller|Symbol|UnitPrice|Amount,ID|..."
// to avoid the frontend needing to parse raw Amino struct outputs.
func GetListingsCSV() string {
	out := ""
	listings.Iterate("", "", func(key string, value interface{}) bool {
		l := value.(*Listing)
		row := ufmt.Sprintf("%d|%s|%s|%d|%d", l.Id, string(l.Seller), l.Symbol, l.UnitPrice, l.Amount)
		if out == "" {
			out = row
		} else {
			out += "," + row
		}
		return false
	})
	return out
}
