package sales

import (
	"strconv"

	"chain"
	"gno.land/p/samcrew/launchpad/fairmath/v1"
	"gno.land/p/samcrew/launchpad/meta/v1"
	"gno.land/r/samcrew/launchpad/config/v1"
	"gno.land/r/samcrew/launchpad/tokens/v1"
)

// Read views for launch clients. Every int64, base units and timestamps alike,
// is a decimal string so JavaScript keeps it exact; booleans stay booleans and
// counts that fit in an int are numbers. They change no state.

func jsonInt(v int64) string { return meta.JSONString(strconv.FormatInt(v, 10)) }

// fairRecordJSON reports a sale's terms and outcome. Once settled, the primary
// fee is what was raised minus the creator's share.
func fairRecordJSON(r FairSaleRecord) string {
	s := r.Schedule
	return "{" +
		`"creator":` + meta.JSONString(r.Creator.String()) +
		`,"quoteCurrency":` + meta.JSONString(r.QuoteCurrency) +
		`,"configVersion":` + jsonInt(r.ConfigVersion) +
		`,"primaryFeeBps":` + jsonInt(r.PrimaryFeeBPS) +
		`,"allocation":` + jsonInt(r.Allocation) +
		`,"lotSize":` + jsonInt(r.LotSize) +
		`,"walletCapLots":` + jsonInt(r.WalletCapLots) +
		`,"hardCapLots":` + jsonInt(r.Caps.HardLots) +
		`,"softCapQuote":` + jsonInt(r.Caps.SoftQuote) +
		`,"start":` + jsonInt(s.Start) +
		`,"end":` + jsonInt(s.End) +
		`,"startPrice":` + jsonInt(s.StartPrice) +
		`,"floorPrice":` + jsonInt(s.FloorPrice) +
		`,"decrement":` + jsonInt(s.Decrement) +
		`,"intervalSeconds":` + jsonInt(s.IntervalSeconds) +
		`,"allowlistRoot":` + meta.JSONString(r.AllowlistRoot) +
		`,"holdingGates":` + meta.JSONString(r.HoldingGates) +
		`,"totalLots":` + jsonInt(r.TotalLots) +
		`,"totalDeposits":` + jsonInt(r.TotalDeposits) +
		`,"hardClosedAt":` + jsonInt(r.HardClosedAt) +
		`,"cancelled":` + strconv.FormatBool(r.Cancelled) +
		`,"settled":` + strconv.FormatBool(r.Settled) +
		`,"succeeded":` + strconv.FormatBool(r.Succeeded) +
		`,"closeAt":` + jsonInt(r.CloseAt) +
		`,"closePrice":` + jsonInt(r.ClosePrice) +
		`,"soldTokens":` + jsonInt(r.SoldTokens) +
		`,"grossQuote":` + jsonInt(r.GrossQuote) +
		`,"primaryFeeQuote":` + jsonInt(r.GrossQuote-r.CreatorQuote) +
		`,"creatorQuote":` + jsonInt(r.CreatorQuote) +
		`,"proceedsReleased":` + strconv.FormatBool(r.ProceedsReleased) +
		`,"refundQuote":` + jsonInt(r.RefundQuote) +
		`,"unsoldTokens":` + jsonInt(r.UnsoldTokens) +
		`,"refundPaid":` + jsonInt(r.RefundPaid) +
		`,"tokensClaimed":` + jsonInt(r.TokensClaimed) + "}"
}

func airdropRecordJSON(r AirdropRecord) string {
	return "{" +
		`"root":` + meta.JSONString(r.Root) +
		`,"total":` + jsonInt(r.Total) +
		`,"claimed":` + jsonInt(r.Claimed) + "}"
}

// TermsJSON is what launching a token in a currency costs under the current
// config version: the fee a direct creation and a fair-sale creation attach,
// exactly; the most one fair sale may raise; and the primary fee a new sale
// pins. A fee of -1 means the currency has no terms. A creation names this
// version, so if the terms change before it lands it fails with "config
// changed" and takes nothing. Whether a lane takes new launches now is
// config's ActionStatusJSON.
func TermsJSON(currencyKey string) string {
	if currencyKey == "" || len(currencyKey) > 200 {
		panic("launchpad/sales: invalid currency")
	}
	version := config.GetCurrentVersion()
	p := config.GetVersion(version)
	direct, fair, raiseCap := int64(-1), int64(-1), int64(0)
	for _, c := range p.Currencies {
		if c.Key == currencyKey {
			direct, fair, raiseCap = c.DirectCreationFee, c.FairSaleCreationFee, c.FairSaleRaiseCap
		}
	}
	return "{" +
		`"schema":"launchpad-sales-terms-v1"` +
		`,"version":` + jsonInt(version) +
		`,"currency":` + meta.JSONString(currencyKey) +
		`,"directCreationFee":` + jsonInt(direct) +
		`,"fairSaleCreationFee":` + jsonInt(fair) +
		`,"fairSaleRaiseCap":` + jsonInt(raiseCap) +
		`,"primaryFeeBps":` + jsonInt(p.PrimaryFeeBPS) + "}"
}

// SolvencyJSON is the realm's books in one currency: the balance it holds and
// what it owes, in total and by liability. fees is what SweepFees would pay
// now. Every movement of quote ends with balance >= owed, so a watcher that
// sees otherwise has found a fault; what the balance holds above owed was
// sent outside the entry points and is owed to no one. An empty key or one
// over 200 bytes panics "invalid currency"; a key that is neither ugnot nor a
// registered GRC20 aborts in the registry ("unknown token").
func SolvencyJSON(currencyKey string) string {
	if currencyKey == "" || len(currencyKey) > 200 {
		panic("launchpad/sales: invalid currency")
	}
	return "{" +
		`"schema":"launchpad-sales-solvency-v1"` +
		`,"currency":` + meta.JSONString(currencyKey) +
		`,"balance":` + jsonInt(quoteBalance(chain.PackageAddress(salesPath), currencyKey)) +
		`,"owed":` + jsonInt(owedIn(currencyKey)) +
		`,"fees":` + jsonInt(feeLiability[currencyKey]) +
		`,"escrow":` + jsonInt(fairEscrowLiability[currencyKey]) +
		`,"refunds":` + jsonInt(fairRefundLiability[currencyKey]) +
		`,"proceeds":` + jsonInt(fairProceedsLiability[currencyKey]) + "}"
}

// LaunchJSON is a token's launch state: the ledger's record of the token, what
// sales still owes in it, how many vesting records it has, and its fair sale
// and airdrop campaign, each null when the token has none.
func LaunchJSON(id string) string {
	token := tokens.TokenJSON(id)
	fair := "null"
	if r, ok := fairSales.Get(id).(FairSaleRecord); ok {
		fair = fairRecordJSON(r)
	}
	airdrop := "null"
	if r, ok := airdrops.Get(id).(AirdropRecord); ok {
		airdrop = airdropRecordJSON(r)
	}
	return "{" +
		`"schema":"launchpad-sales-v1"` +
		`,"token":` + token +
		`,"tokenLiability":` + jsonInt(tokenOwed(id)) +
		`,"vestingCount":` + strconv.Itoa(vestingCount(id)) +
		`,"fairSale":` + fair +
		`,"airdrop":` + airdrop + "}"
}

// FairBuyerJSON is one buyer's record in a sale and, once the sale is settled
// and until the buyer is paid, what ClaimFair would send them. Before
// settlement both amounts are 0 and settled is false: settle first.
func FairBuyerJSON(id string, buyer address) string {
	r := GetFairSale(id)
	b := GetFairBuyer(id, buyer)
	claimTokens, claimRefund := int64(0), int64(0)
	if r.Settled && b.Lots > 0 && !b.Claimed {
		c := fairmath.Claim(r.Succeeded, b.Lots, b.Deposit, r.LotSize, r.ClosePrice)
		claimTokens, claimRefund = c.Tokens, c.RefundQuote
	}
	return "{" +
		`"buyer":` + meta.JSONString(buyer.String()) +
		`,"lots":` + jsonInt(b.Lots) +
		`,"deposit":` + jsonInt(b.Deposit) +
		`,"claimableTokens":` + jsonInt(claimTokens) +
		`,"claimableRefund":` + jsonInt(claimRefund) +
		`,"settled":` + strconv.FormatBool(r.Settled) +
		`,"claimed":` + strconv.FormatBool(b.Claimed) + "}"
}

// VestingJSON is one vesting record: its schedule, who holds the claim right
// and who has been proposed to take it.
func VestingJSON(id string, index int) string {
	r := GetVesting(id, index)
	return "{" +
		`"index":` + strconv.Itoa(index) +
		`,"beneficiary":` + meta.JSONString(r.Beneficiary.String()) +
		`,"pendingBeneficiary":` + meta.JSONString(r.PendingBeneficiary.String()) +
		`,"total":` + jsonInt(r.Total) +
		`,"claimed":` + jsonInt(r.Claimed) +
		`,"start":` + jsonInt(r.Start) +
		`,"cliff":` + jsonInt(r.Cliff) +
		`,"duration":` + jsonInt(r.Duration) +
		`,"revocable":` + strconv.FormatBool(r.Revocable) +
		`,"revoked":` + strconv.FormatBool(r.Revoked) +
		`,"revokedVested":` + jsonInt(r.RevokedVested) + "}"
}
