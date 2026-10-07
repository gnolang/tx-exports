package sales

import (
	"strconv"
	"strings"
	"time"

	"chain"
	"gno.land/p/samcrew/launchpad/currency/v1"
	"gno.land/p/samcrew/launchpad/fairmath/v1"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/samcrew/launchpad/config/v1"
	"gno.land/r/samcrew/launchpad/tokens/v1"
)

// FairSaleRecord fixes the sale terms and records funded whole-lot orders.
// Settlement splits GrossQuote into the primary fee, owed to the protocol, and
// CreatorQuote, owed to the creator: the fee is GrossQuote minus CreatorQuote.
// RefundPaid and TokensClaimed count what buyer claims have taken out of this
// sale, so no claim can pay more than the sale itself owes.
type FairSaleRecord struct {
	Creator          address
	QuoteCurrency    string
	ConfigVersion    int64
	PrimaryFeeBPS    int64
	Allocation       int64
	LotSize          int64
	WalletCapLots    int64
	Caps             fairmath.Caps
	Schedule         fairmath.Schedule
	AllowlistRoot    string
	HoldingGates     string
	TotalLots        int64
	TotalDeposits    int64
	HardClosedAt     int64
	Cancelled        bool
	Settled          bool
	Succeeded        bool
	CloseAt          int64
	ClosePrice       int64
	SoldTokens       int64
	GrossQuote       int64
	CreatorQuote     int64
	ProceedsReleased bool
	RefundQuote      int64
	UnsoldTokens     int64
	RefundPaid       int64
	TokensClaimed    int64
}

type FairBuyerRecord struct {
	Lots    int64
	Deposit int64
	Claimed bool
}

var (
	fairEscrowLiability   = map[string]int64{}
	fairRefundLiability   = map[string]int64{}
	fairProceedsLiability = map[string]int64{}
)

// openFairSale gates a new sale on the live config, pins its primary fee,
// bounds the most quote it can ever hold in escrow, and collects its creation
// fee, which it returns.
func openFairSale(cur realm, r *FairSaleRecord) int64 {
	config.AssertNewAction(config.LaneFairSale, r.QuoteCurrency, r.ConfigVersion)
	p := config.GetVersion(r.ConfigVersion)
	for _, c := range p.Currencies {
		if c.Key == r.QuoteCurrency {
			if sm.Mul(r.Caps.HardLots, r.Schedule.StartPrice) > c.FairSaleRaiseCap {
				panic("launchpad/sales: fair sale exceeds raise cap")
			}
			r.PrimaryFeeBPS = p.PrimaryFeeBPS
			collectCreationFee(cur, r.QuoteCurrency, c.FairSaleCreationFee)
			return c.FairSaleCreationFee
		}
	}
	panic("launchpad/sales: currency has no fair-sale terms")
}

func fairTerms(creator address, saleAllocation, lotSize, hardLots,
	walletCapLots, softQuote int64, quoteCurrency string, expectedVersion int64,
	start, end, startPrice, floorPrice, decrement, intervalSeconds int64) FairSaleRecord {
	if strings.HasPrefix(quoteCurrency, launchpadTokenRegistryPrefix) {
		panic("launchpad/sales: launchpad token cannot be quote currency")
	}
	schedule := fairmath.Schedule{
		Start: start, End: end, StartPrice: startPrice,
		FloorPrice: floorPrice, Decrement: decrement,
		IntervalSeconds: intervalSeconds,
	}
	schedule.Validate()
	if start <= time.Now().Unix() {
		panic("launchpad/sales: fair sale must start in the future")
	}
	caps := fairmath.Caps{HardLots: hardLots, SoftQuote: softQuote}
	caps.Validate(saleAllocation, lotSize, startPrice)
	if walletCapLots <= 0 || walletCapLots > hardLots {
		panic("launchpad/sales: invalid fair wallet cap")
	}
	return FairSaleRecord{
		Creator: creator, QuoteCurrency: quoteCurrency,
		ConfigVersion: expectedVersion, Allocation: saleAllocation,
		LotSize: lotSize, WalletCapLots: walletCapLots,
		Caps: caps, Schedule: schedule,
	}
}

func emitFairCreated(id, funding string, r FairSaleRecord, fee int64) {
	chain.Emit("LaunchpadFairSaleCreated", "id", id,
		"creator", r.Creator.String(), "currency", r.QuoteCurrency,
		"allocation", strconv.FormatInt(r.Allocation, 10),
		"lot_size", strconv.FormatInt(r.LotSize, 10),
		"hard_lots", strconv.FormatInt(r.Caps.HardLots, 10),
		"wallet_cap_lots", strconv.FormatInt(r.WalletCapLots, 10),
		"soft_quote", strconv.FormatInt(r.Caps.SoftQuote, 10),
		"allowlist_root", r.AllowlistRoot,
		"holding_gates", r.HoldingGates,
		"primary_fee_bps", strconv.FormatInt(r.PrimaryFeeBPS, 10),
		"funding", funding, "fee", strconv.FormatInt(fee, 10))
}

// CreateFairSale mints a fixed-supply fair-sale token and encumbers its whole-
// lot allocation in sales custody. The creator receives the initial supply
// remainder.
func CreateFairSale(cur realm, name, ticker string, decimals int,
	initialSupply, saleAllocation, lotSize, hardLots, walletCapLots, softQuote int64,
	quoteCurrency string, expectedVersion int64,
	start, end, startPrice, floorPrice, decrement, intervalSeconds int64,
	description, image, website, xHandle, telegram string) string {
	return createFairSale(cur, name, ticker, decimals,
		initialSupply, saleAllocation, lotSize, hardLots, walletCapLots, softQuote,
		quoteCurrency, expectedVersion,
		start, end, startPrice, floorPrice, decrement, intervalSeconds,
		description, image, website, xHandle, telegram, "", "", "")
}

// CreateGatedFairSale binds a precomputed token ID to a Merkle root and/or
// token-holding gates. The expected ID prevents an intervening creation from
// silently attaching the root to a different token.
func CreateGatedFairSale(cur realm, name, ticker string, decimals int,
	initialSupply, saleAllocation, lotSize, hardLots, walletCapLots, softQuote int64,
	quoteCurrency string, expectedVersion int64,
	start, end, startPrice, floorPrice, decrement, intervalSeconds int64,
	description, image, website, xHandle, telegram,
	expectedID, allowlistRoot, holdingGates string) string {
	return createFairSale(cur, name, ticker, decimals,
		initialSupply, saleAllocation, lotSize, hardLots, walletCapLots, softQuote,
		quoteCurrency, expectedVersion,
		start, end, startPrice, floorPrice, decrement, intervalSeconds,
		description, image, website, xHandle, telegram,
		expectedID, allowlistRoot, holdingGates)
}

func createFairSale(cur realm, name, ticker string, decimals int,
	initialSupply, saleAllocation, lotSize, hardLots, walletCapLots, softQuote int64,
	quoteCurrency string, expectedVersion int64,
	start, end, startPrice, floorPrice, decrement, intervalSeconds int64,
	description, image, website, xHandle, telegram,
	expectedID, allowlistRoot, holdingGates string) string {
	creator := directCaller(cur)
	r := fairTerms(creator, saleAllocation, lotSize, hardLots,
		walletCapLots, softQuote, quoteCurrency, expectedVersion,
		start, end, startPrice, floorPrice, decrement, intervalSeconds)
	validateFairEligibility(allowlistRoot, holdingGates)
	if allowlistRoot != "" && expectedID == "" {
		panic("launchpad/sales: fair allowlist token ID required")
	}
	if expectedID != "" && expectedID != "T"+strconv.FormatInt(sm.Add(tokens.Count(), 1), 10) {
		panic("launchpad/sales: fair token ID changed")
	}
	r.AllowlistRoot = allowlistRoot
	r.HoldingGates = holdingGates
	if initialSupply <= 0 || saleAllocation > initialSupply {
		panic("launchpad/sales: fair allocation exceeds supply")
	}
	fee := openFairSale(cur, &r)
	id := tokens.Create(cross(cur), creator, tokens.ModeFairSale, name, ticker,
		decimals, initialSupply, initialSupply, quoteCurrency, expectedVersion,
		description, image, website, xHandle, telegram)
	if expectedID != "" && id != expectedID {
		panic("launchpad/sales: fair token ID changed")
	}
	remainder := sm.Sub(initialSupply, saleAllocation)
	if remainder > 0 {
		tokens.Transfer(cross(cur), id, creator, remainder)
	}
	fairSales.Set(id, r)
	setTokenOwed(id, sm.Add(tokenOwed(id), saleAllocation))
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) != tokenOwed(id) {
		panic("launchpad/sales: token custody mismatch")
	}
	emitFairCreated(id, "minted", r, fee)
	return id
}

// CreateFairSaleFromToken locks an existing direct token's exact creator-funded
// allocation. Other token liabilities remain encumbered in the same custody
// balance. One token can have at most one fair sale.
func CreateFairSaleFromToken(cur realm, id string,
	saleAllocation, lotSize, hardLots, walletCapLots, softQuote int64,
	quoteCurrency string, expectedVersion int64,
	start, end, startPrice, floorPrice, decrement, intervalSeconds int64) {
	createFairSaleFromToken(cur, id,
		saleAllocation, lotSize, hardLots, walletCapLots, softQuote,
		quoteCurrency, expectedVersion,
		start, end, startPrice, floorPrice, decrement, intervalSeconds, "", "")
}

func CreateGatedFairSaleFromToken(cur realm, id string,
	saleAllocation, lotSize, hardLots, walletCapLots, softQuote int64,
	quoteCurrency string, expectedVersion int64,
	start, end, startPrice, floorPrice, decrement, intervalSeconds int64,
	allowlistRoot, holdingGates string) {
	createFairSaleFromToken(cur, id,
		saleAllocation, lotSize, hardLots, walletCapLots, softQuote,
		quoteCurrency, expectedVersion,
		start, end, startPrice, floorPrice, decrement, intervalSeconds,
		allowlistRoot, holdingGates)
}

func createFairSaleFromToken(cur realm, id string,
	saleAllocation, lotSize, hardLots, walletCapLots, softQuote int64,
	quoteCurrency string, expectedVersion int64,
	start, end, startPrice, floorPrice, decrement, intervalSeconds int64,
	allowlistRoot, holdingGates string) {
	creator := directCaller(cur)
	info := tokens.GetInfo(id)
	if info.Creator != creator ||
		(info.Mode != tokens.ModeDirectFixed && info.Mode != tokens.ModeDirectCap) ||
		fairSales.Has(id) {
		panic("launchpad/sales: existing fair token denied")
	}
	r := fairTerms(creator, saleAllocation, lotSize, hardLots,
		walletCapLots, softQuote, quoteCurrency, expectedVersion,
		start, end, startPrice, floorPrice, decrement, intervalSeconds)
	validateFairEligibility(allowlistRoot, holdingGates)
	r.AllowlistRoot = allowlistRoot
	r.HoldingGates = holdingGates
	fee := openFairSale(cur, &r)
	tokens.TransferFrom(cross(cur), id, creator,
		chain.PackageAddress(salesPath), saleAllocation)
	fairSales.Set(id, r)
	setTokenOwed(id, sm.Add(tokenOwed(id), saleAllocation))
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	emitFairCreated(id, "deposited", r, fee)
}

func GetFairSale(id string) FairSaleRecord {
	r, ok := fairSales.Get(id).(FairSaleRecord)
	if !ok {
		panic("launchpad/sales: fair sale not found")
	}
	return r
}

func GetFairBuyer(id string, buyer address) FairBuyerRecord {
	if !meta.ValidAddress(buyer) {
		panic("launchpad/sales: invalid address")
	}
	GetFairSale(id)
	b, _ := fairBuyers.Get(buyerKey(id, buyer)).(FairBuyerRecord)
	return b
}

// assertWithinSale runs on every exit of a settled sale. Quote and tokens sit
// in balances pooled across sales, and the custody checks compare a balance
// with totals only: an exit that overpaid one sale while lowering the totals
// by as much would pass them, paid with other sales' money. Settlement
// asserted GrossQuote + RefundQuote = TotalDeposits, so with these bounds a
// sale never pays out more quote than it took in, nor more tokens than it
// sold. Settlement also sets CreatorQuote to GrossQuote minus the fee, so the
// last bound cannot fail on a record settlement wrote; it stays as a defence
// should a later change break that.
func assertWithinSale(r FairSaleRecord) {
	if r.RefundPaid > r.RefundQuote || r.TokensClaimed > r.SoldTokens ||
		r.CreatorQuote > r.GrossQuote {
		panic("launchpad/sales: fair sale overpaid")
	}
}

// SettleFair closes a sale at its recorded hard-cap fill or scheduled end.
// It returns every unsold token to the creator and partitions deposits into
// buyer refunds, the creator's proceeds and the protocol's primary fee. The
// fee joins the bucket SweepFees pays; nothing is paid out here, so neither
// receiver can hold up settlement or buyer claims.
func SettleFair(cur realm, id string) {
	if !cur.IsCurrent() {
		panic("launchpad/sales: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	r := GetFairSale(id)
	if r.Cancelled {
		panic("launchpad/sales: fair settlement unavailable")
	}
	if r.Settled {
		return
	}
	if r.HardClosedAt == 0 && time.Now().Unix() < r.Schedule.End {
		panic("launchpad/sales: fair settlement unavailable")
	}
	closeAt := r.Schedule.End
	if r.HardClosedAt != 0 {
		closeAt = r.HardClosedAt
	}
	price := r.Schedule.PriceAt(closeAt)
	result := fairmath.Clear(r.Caps, r.Allocation, r.LotSize,
		r.TotalLots, r.TotalDeposits, price)
	if sm.Add(result.GrossQuote, result.RefundQuote) != r.TotalDeposits ||
		sm.Add(result.SoldTokens, result.UnsoldTokens) != r.Allocation {
		panic("launchpad/sales: fair settlement partition mismatch")
	}
	r.Settled = true
	r.Succeeded = result.Succeeded
	r.CloseAt = closeAt
	r.ClosePrice = price
	r.SoldTokens = result.SoldTokens
	r.GrossQuote = result.GrossQuote
	primaryFee := sm.BPS(result.GrossQuote, r.PrimaryFeeBPS)
	r.CreatorQuote = sm.Sub(result.GrossQuote, primaryFee)
	r.RefundQuote = result.RefundQuote
	r.UnsoldTokens = result.UnsoldTokens
	fairSales.Set(id, r)
	key := r.QuoteCurrency
	fairEscrowLiability[key] = sm.Sub(fairEscrowLiability[key], r.TotalDeposits)
	fairRefundLiability[key] = sm.Add(fairRefundLiability[key], result.RefundQuote)
	fairProceedsLiability[key] = sm.Add(fairProceedsLiability[key], r.CreatorQuote)
	feeLiability[key] = sm.Add(feeLiability[key], primaryFee)
	setTokenOwed(id, sm.Sub(tokenOwed(id), result.UnsoldTokens))
	if result.UnsoldTokens > 0 {
		tokens.Transfer(cross(cur), id, r.Creator, result.UnsoldTokens)
	}
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	assertQuoteCovered(cur, key)
	chain.Emit("LaunchpadFairSettled", "id", id, "currency", key,
		"succeeded", strconv.FormatBool(result.Succeeded),
		"close_price", strconv.FormatInt(price, 10),
		"gross_quote", strconv.FormatInt(result.GrossQuote, 10),
		"primary_fee_quote", strconv.FormatInt(primaryFee, 10),
		"creator_quote", strconv.FormatInt(r.CreatorQuote, 10),
		"refund_quote", strconv.FormatInt(result.RefundQuote, 10),
		"unsold_tokens", strconv.FormatInt(result.UnsoldTokens, 10))
}

// ClaimFair lets anyone release a buyer's recorded tokens and quote refund
// to that buyer. Claims never expire and ignore current pause/listing.
func ClaimFair(cur realm, id string, buyer address) {
	if !cur.IsCurrent() {
		panic("launchpad/sales: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	r := GetFairSale(id)
	b := GetFairBuyer(id, buyer)
	if !r.Settled || b.Lots <= 0 || b.Claimed {
		panic("launchpad/sales: fair claim unavailable")
	}
	claim := fairmath.Claim(r.Succeeded, b.Lots, b.Deposit,
		r.LotSize, r.ClosePrice)
	r.RefundPaid = sm.Add(r.RefundPaid, claim.RefundQuote)
	r.TokensClaimed = sm.Add(r.TokensClaimed, claim.Tokens)
	assertWithinSale(r)
	fairSales.Set(id, r)
	b.Claimed = true
	fairBuyers.Set(buyerKey(id, buyer), b)
	key := r.QuoteCurrency
	fairRefundLiability[key] = sm.Sub(fairRefundLiability[key], claim.RefundQuote)
	setTokenOwed(id, sm.Sub(tokenOwed(id), claim.Tokens))
	if claim.Tokens > 0 {
		tokens.Transfer(cross(cur), id, buyer, claim.Tokens)
	}
	if claim.RefundQuote > 0 {
		payQuote(cur, key, buyer, claim.RefundQuote)
	}
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	assertQuoteCovered(cur, key)
	chain.Emit("LaunchpadFairClaimed", "id", id, "buyer", buyer.String(),
		"tokens", strconv.FormatInt(claim.Tokens, 10),
		"refund_quote", strconv.FormatInt(claim.RefundQuote, 10))
}

// ReleaseFairProceeds pays a succeeded sale's creator what settlement
// recorded for them, once, and returns the amount. Anyone can call it; the
// receiver is always the recorded creator. It stays open while the lane is
// paused or the currency delisted.
func ReleaseFairProceeds(cur realm, id string) int64 {
	if !cur.IsCurrent() {
		panic("launchpad/sales: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	r := GetFairSale(id)
	if !r.Settled || !r.Succeeded || r.ProceedsReleased {
		panic("launchpad/sales: fair proceeds unavailable")
	}
	r.ProceedsReleased = true
	assertWithinSale(r)
	fairSales.Set(id, r)
	key := r.QuoteCurrency
	fairProceedsLiability[key] = sm.Sub(fairProceedsLiability[key], r.CreatorQuote)
	// A succeeded sale raised at least its soft cap and the fee is at most 5%,
	// so there is always something to pay.
	payQuote(cur, key, r.Creator, r.CreatorQuote)
	assertQuoteCovered(cur, key)
	chain.Emit("LaunchpadFairProceedsReleased", "id", id,
		"creator", r.Creator.String(), "currency", key,
		"creator_quote", strconv.FormatInt(r.CreatorQuote, 10),
		"actor", cur.Previous().Address().String())
	return r.CreatorQuote
}

// ContributeFair escrows exact quote atoms for whole token lots at this
// transaction's schedule price. The direct caller is both payer and buyer,
// and maxDeposit is the most the order may cost. A native order attaches
// exactly maxDeposit and gets maxDeposit minus the cost back in the same
// transaction; a token order pulls only the cost from the buyer's allowance.
func ContributeFair(cur realm, id string, lots, maxDeposit int64) {
	contributeFair(cur, id, lots, maxDeposit, "")
}

// ContributeFairWithProof verifies the recorded allowlist and holding gates
// against the direct buyer's live address and balances before collecting quote.
func ContributeFairWithProof(cur realm, id string, lots, maxDeposit int64, proof string) {
	contributeFair(cur, id, lots, maxDeposit, proof)
}

func contributeFair(cur realm, id string, lots, maxDeposit int64, proof string) {
	buyer := directCaller(cur)
	r := GetFairSale(id)
	now := time.Now().Unix()
	if r.Cancelled || r.Settled || r.HardClosedAt != 0 || now < r.Schedule.Start || now >= r.Schedule.End {
		panic("launchpad/sales: fair sale closed")
	}
	// The sale's own terms are pinned in its record and the buyer bounds the
	// price with maxDeposit, so no config version is involved here.
	config.AssertLaneOpen(config.LaneFairSale, r.QuoteCurrency)
	if lots <= 0 || maxDeposit <= 0 {
		panic("launchpad/sales: invalid fair order")
	}
	b := GetFairBuyer(id, buyer)
	nextBuyerLots := sm.Add(b.Lots, lots)
	if nextBuyerLots > r.WalletCapLots {
		panic("launchpad/sales: fair wallet cap exceeded")
	}
	requireFairEligibility(id, r, buyer, proof)
	nextTotalLots, hardClosed := r.Caps.AddLots(r.TotalLots, lots)
	order := fairmath.QuoteOrder(lots, r.LotSize, r.Schedule.PriceAt(now))
	if order.Deposit > maxDeposit {
		panic("launchpad/sales: fair quote exceeds buyer bound")
	}
	if r.QuoteCurrency == config.NativeCurrency {
		// Coins are attached when the buyer signs, and a falling price can step
		// down before the block: the buyer attaches its bound, exactly, and gets
		// back at once what the order does not cost.
		currency.CollectNative(0, cur, maxDeposit)
		if change := maxDeposit - order.Deposit; change > 0 {
			currency.PayNative(0, cur, buyer, change)
		}
	} else {
		collectQuote(cur, r.QuoteCurrency, order.Deposit)
	}
	b.Lots = nextBuyerLots
	b.Deposit = sm.Add(b.Deposit, order.Deposit)
	fairBuyers.Set(buyerKey(id, buyer), b)
	r.TotalLots = nextTotalLots
	r.TotalDeposits = sm.Add(r.TotalDeposits, order.Deposit)
	if hardClosed {
		r.HardClosedAt = now
	}
	fairSales.Set(id, r)
	fairEscrowLiability[r.QuoteCurrency] = sm.Add(fairEscrowLiability[r.QuoteCurrency], order.Deposit)
	// The admin's brake on what the realm may hold in a currency. Only an
	// inflow reads it; exits never do.
	if owedIn(r.QuoteCurrency) > config.GetSalesOwedCeiling(r.QuoteCurrency) {
		panic("launchpad/sales: sales owed ceiling reached")
	}
	assertQuoteCovered(cur, r.QuoteCurrency)
	chain.Emit("LaunchpadFairContribution", "id", id, "buyer", buyer.String(),
		"lots", strconv.FormatInt(lots, 10),
		"price", strconv.FormatInt(order.Deposit/lots, 10),
		"deposit", strconv.FormatInt(order.Deposit, 10),
		"total_lots", strconv.FormatInt(r.TotalLots, 10))
	if hardClosed {
		chain.Emit("LaunchpadFairHardClosed", "id", id,
			"closed_at", strconv.FormatInt(now, 10))
	}
}

// CancelFairSale returns the entire unsold allocation to its creator while
// there are no contributions. It remains callable if the new-sale lane is
// paused or the quote currency has since been delisted. The creation fee is
// not returned.
func CancelFairSale(cur realm, id string) {
	creator := directCaller(cur)
	currency.AssertNoCoins(0, cur)
	r := GetFairSale(id)
	if r.Creator != creator || r.Cancelled || r.Settled || r.TotalLots != 0 || r.TotalDeposits != 0 {
		panic("launchpad/sales: fair cancellation denied")
	}
	r.Cancelled = true
	fairSales.Set(id, r)
	setTokenOwed(id, sm.Sub(tokenOwed(id), r.Allocation))
	tokens.Transfer(cross(cur), id, creator, r.Allocation)
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	chain.Emit("LaunchpadFairSaleCancelled", "id", id,
		"creator", creator.String(),
		"returned", strconv.FormatInt(r.Allocation, 10))
}
