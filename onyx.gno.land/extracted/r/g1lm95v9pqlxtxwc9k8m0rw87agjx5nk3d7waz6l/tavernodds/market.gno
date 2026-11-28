// Package tavernodds is a binary prediction-market realm on Gno.land.
//
// Anyone can create a YES/NO market (question + close time) by seeding
// it with enough ugnot to cover the market maker's worst-case loss.
// Traders buy/sell YES/NO shares priced by an LMSR (lmsr.gno,
// fixed-point port of the Prophet formulas). A designated resolver resolves the outcome after the
// close time; after a 24h dispute window, winning shares redeem 1:1
// for ugnot and losing shares are worth 0.
//
// Design notes (mirrors the Solana Prophet program this was ported from):
//   - Solvency: the creator must seed at least ceil(b*ln(2)) ugnot
//     (lmsrMinSeed). Since C(q) >= max(qYes,qNo) always, the vault
//     always covers every outstanding winning share. Buys are charged
//     the raw LMSR delta + 1 ugnot (the fixed-point delta truncates,
//     so +1 keeps the strict solvency direction, as lmsr.gno documents);
//     sells pay the raw delta. Quotes (QuoteBuy/QuoteSell) use the same
//     values Buy/Sell charge, so a quoted cost is always exact.
//   - Clock: Gno has no wall-clock syscall; time.Now() returns the
//     block time (the chain sets it from the block header), and
//     runtime.ChainHeight() is the block height. Close/dispute times
//     are unix seconds of block time, matching Prophet's expiry_ts.
//   - Payments are push-only: there is no transferFrom in Gno. Buyers
//     and creators attach ugnot with `-send`; the realm verifies the
//     envelope with unsafe.OriginSend() AND requires a direct EOA
//     caller (cur.Previous().IsUserCall()) — the pair is required, see
//     docs/resources/effective-gno.md "Verifying inbound Coin payments".
//     Without the EOA guard an intermediate `maketx run` realm could
//     consume the envelope and leave OriginSend() describing a phantom
//     payment. Payouts (sell refunds, redemptions) use a RealmSend
//     banker constructed fresh in each call.
//   - Shares are GRC20 tokens: two per market (YES/NO), minted/burned
//     by this realm's PrivateLedger. They are NOT registered in
//     grc20reg (per-market symbols like YES1/NO1 would collide in the
//     registry's symbol-keyed index); balances are readable via
//     BalanceOf / the token's own Render. This keeps the realm small:
//     storage deposit is 100 ugnot/byte, so no registry, no fees, no
//     sweep — leftover vault funds after all redemptions stay locked
//     (a creator sweep is future work).
//   - Double-redeem is prevented twice: a redeemed flag per
//     (market, user) AND burning the winning shares on redeem, so a
//     second redeem finds a zero balance.
package tavernodds

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/seqid/v0"
)

// Module path of this realm (used to derive its on-chain address).
const pkgPath = "gno.land/r/g1lm95v9pqlxtxwc9k8m0rw87agjx5nk3d7waz6l/tavernodds"

// Outcomes.
const (
	OutcomeUnresolved = 0
	OutcomeYes        = 1
	OutcomeNo         = 2
)

// Bounds and windows.
const (
	MinB             int64 = 1000000     // 1 GNOT of liquidity parameter b
	MaxB             int64 = 10000000000 // 10_000 GNOT
	MaxQuestionLen         = 128
	DisputeWindow    int64 = 86400 // 24h of block time between resolve and redeem
	ugnotDenom             = "ugnot"
)

// Market is one binary prediction market. Token/ledger pointers live in
// realm state (same pattern as the GRC20 factory, which stores token +
// ledger pointers in an AVL tree); they are never returned to callers —
// see GetMarket, which returns a plain-data MarketView instead.
type Market struct {
	ID               uint64
	Question         string
	Creator          address
	Resolver         address
	CloseTime        int64 // unix seconds (block time)
	LiquidityB       int64
	QYes             int64
	QNo              int64
	Resolved         bool
	Outcome          int
	ResolveTime      int64
	DisputeEndTime   int64
	SeededCollateral int64
	YesToken         *grc20.Token
	YesLedger        *grc20.PrivateLedger
	NoToken          *grc20.Token
	NoLedger         *grc20.PrivateLedger
	Redeemed         map[address]bool
}

// MarketView is the read-only, pointer-free view of a Market.
type MarketView struct {
	ID               uint64
	Question         string
	Creator          address
	Resolver         address
	CloseTime        int64
	LiquidityB       int64
	QYes             int64
	QNo              int64
	Resolved         bool
	Outcome          int
	ResolveTime      int64
	DisputeEndTime   int64
	SeededCollateral int64
	YesPriceBps      int64
	NoPriceBps       int64
	YesSupply        int64
	NoSupply         int64
}

var (
	markets      []*Market
	nextMarketID uint64
	nextTokenID  seqid.ID
)

// nowUnix returns the current block time as unix seconds.
func nowUnix() int64 {
	return time.Now().Unix()
}

// realmAddr returns this realm's on-chain address.
func realmAddr() address {
	return chain.PackageAddress(pkgPath)
}

func mustMarket(marketID uint64) *Market {
	if marketID == 0 || marketID > uint64(len(markets)) {
		panic("market not found")
	}
	return markets[marketID-1]
}

// requireEOA panics unless the caller is a direct EOA call
// (gnokey maketx call). Must be paired with an OriginSend() amount
// check whenever the function accepts payment — see package docs.
func requireEOA(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by a user (maketx call)")
	}
}

func callerOf(cur realm) address {
	return cur.Previous().Address()
}

// payOut sends amount ugnot from this realm to `to`. No-op for 0.
func payOut(cur realm, to address, amount int64) {
	if amount == 0 {
		return
	}
	if amount < 0 {
		panic("payout must be >= 0")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{{Denom: ugnotDenom, Amount: amount}})
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}

// CreateMarket opens a new market. The creator attaches the seed
// collateral with `-send` (at least lmsrMinSeed(b) = ceil(b*ln2) ugnot);
// any excess stays in the vault as extra coverage. The resolver is
// the only address that may later call Resolve. Returns the market ID.
func CreateMarket(cur realm, question string, closeTime int64, liquidityB int64, resolver address) uint64 {
	requireEOA(cur)
	if len(question) == 0 || len(question) > MaxQuestionLen {
		panic("question must be 1..128 bytes")
	}
	if closeTime <= nowUnix() {
		panic("close time must be in the future")
	}
	if liquidityB < MinB || liquidityB > MaxB {
		panic("liquidity b out of range")
	}
	if !resolver.IsValid() {
		panic("resolver address invalid")
	}
	minSeed := lmsrMinSeed(liquidityB)
	if minSeed <= 0 {
		panic("invalid liquidity b")
	}
	paid := unsafe.OriginSend().AmountOf(ugnotDenom)
	if paid < minSeed {
		panic("seed below b*ln(2): vault could not cover winners")
	}

	creator := callerOf(cur)
	nextMarketID++
	id := nextMarketID

	yesToken, yesLedger := grc20.NewToken(
		"Tavern Odds YES #"+strconv.FormatUint(id, 10),
		"YES"+strconv.FormatUint(id, 10),
		0, nextTokenID.Next(), cur)
	noToken, noLedger := grc20.NewToken(
		"Tavern Odds NO #"+strconv.FormatUint(id, 10),
		"NO"+strconv.FormatUint(id, 10),
		0, nextTokenID.Next(), cur)

	markets = append(markets, &Market{
		ID:               id,
		Question:         question,
		Creator:          creator,
		Resolver:         resolver,
		CloseTime:        closeTime,
		LiquidityB:       liquidityB,
		QYes:             0,
		QNo:              0,
		Resolved:         false,
		Outcome:          OutcomeUnresolved,
		ResolveTime:      0,
		DisputeEndTime:   0,
		SeededCollateral: paid,
		YesToken:         yesToken,
		YesLedger:        yesLedger,
		NoToken:          noToken,
		NoLedger:         noLedger,
		Redeemed:         make(map[address]bool),
	})
	return id
}

// Buy mints `shares` YES/NO shares to the caller. The exact LMSR cost
// in ugnot must be attached with `-send`; cost must not exceed maxCost.
// The cost is the raw LMSR delta + 1 ugnot (see package docs for why).
// Returns the cost paid.
func Buy(cur realm, marketID uint64, outcome int, shares int64, maxCost int64) int64 {
	requireEOA(cur)
	m := mustMarket(marketID)
	if m.Resolved {
		panic("market already resolved")
	}
	if nowUnix() >= m.CloseTime {
		panic("market closed")
	}
	if outcome != OutcomeYes && outcome != OutcomeNo {
		panic("outcome must be YES (1) or NO (2)")
	}
	if shares <= 0 {
		panic("shares must be > 0")
	}
	dYes, dNo := shares, int64(0)
	if outcome == OutcomeNo {
		dYes, dNo = int64(0), shares
	}
	// Reject quantities outside the LMSR domain before pricing: the
	// pricing returns 0 out of domain, which must never be mistaken
	// for a real (free) price.
	if outcome == OutcomeYes && shares > LMSRMaxQ-m.QYes {
		panic("shares exceed LMSR quantity domain")
	}
	if outcome == OutcomeNo && shares > LMSRMaxQ-m.QNo {
		panic("shares exceed LMSR quantity domain")
	}
	cost := lmsrCostDelta(m.QYes, m.QNo, m.LiquidityB, dYes, dNo) + 1
	if cost > maxCost {
		panic("cost exceeds maxCost")
	}
	paid := unsafe.OriginSend().AmountOf(ugnotDenom)
	if paid != cost {
		panic("must send exactly the cost in ugnot")
	}

	buyer := callerOf(cur)
	if outcome == OutcomeYes {
		checkErr(m.YesLedger.Mint(buyer, shares))
		m.QYes += shares
	} else {
		checkErr(m.NoLedger.Mint(buyer, shares))
		m.QNo += shares
	}
	return cost
}

// Sell burns `shares` YES/NO shares and refunds the LMSR value in
// ugnot; the refund must be at least minOut. Returns the refund.
func Sell(cur realm, marketID uint64, outcome int, shares int64, minOut int64) int64 {
	m := mustMarket(marketID)
	if m.Resolved {
		panic("market already resolved")
	}
	if nowUnix() >= m.CloseTime {
		panic("market closed")
	}
	if outcome != OutcomeYes && outcome != OutcomeNo {
		panic("outcome must be YES (1) or NO (2)")
	}
	if shares <= 0 {
		panic("shares must be > 0")
	}
	seller := callerOf(cur)
	dYes, dNo := shares, int64(0)
	if outcome == OutcomeNo {
		dYes, dNo = int64(0), shares
	}
	// Balances are read from the token (read API); mint/burn go
	// through the ledger (write API).
	var balance int64
	if outcome == OutcomeYes {
		balance = m.YesToken.BalanceOf(seller)
	} else {
		balance = m.NoToken.BalanceOf(seller)
	}
	if balance < shares {
		panic("not enough shares")
	}
	// Refund is C(old) - C(new): pass negative deltas.
	refund := -lmsrCostDelta(m.QYes, m.QNo, m.LiquidityB, -dYes, -dNo)
	if refund <= 0 {
		panic("refund must be > 0")
	}
	if refund < minOut {
		panic("refund below minOut")
	}

	if outcome == OutcomeYes {
		checkErr(m.YesLedger.Burn(seller, shares))
		m.QYes -= shares
	} else {
		checkErr(m.NoLedger.Burn(seller, shares))
		m.QNo -= shares
	}
	payOut(cur, seller, refund)
	return refund
}

// Resolve sets the outcome. Only the designated resolver may call it,
// only after the close time. Redemption unlocks after the dispute
// window (DisputeWindow seconds) so a wrong resolution can be
// challenged off-chain before funds move.
func Resolve(cur realm, marketID uint64, outcome int) {
	m := mustMarket(marketID)
	if m.Resolved {
		panic("market already resolved")
	}
	if callerOf(cur) != m.Resolver {
		panic("only the designated resolver can resolve")
	}
	if nowUnix() < m.CloseTime {
		panic("market not closed yet")
	}
	if outcome != OutcomeYes && outcome != OutcomeNo {
		panic("outcome must be YES (1) or NO (2)")
	}
	m.Resolved = true
	m.Outcome = outcome
	m.ResolveTime = nowUnix()
	m.DisputeEndTime = m.ResolveTime + DisputeWindow
}

// Redeem pays the caller 1 ugnot per winning share (losing shares pay
// 0) and burns the winning shares. Only after the dispute window ends,
// and only once per user per market. Returns the payout in ugnot.
func Redeem(cur realm, marketID uint64) int64 {
	m := mustMarket(marketID)
	if !m.Resolved {
		panic("market not resolved yet")
	}
	if nowUnix() < m.DisputeEndTime {
		panic("dispute window still open")
	}
	caller := callerOf(cur)
	if m.Redeemed[caller] {
		panic("already redeemed")
	}
	m.Redeemed[caller] = true

	var winToken *grc20.Token
	var winLedger *grc20.PrivateLedger
	if m.Outcome == OutcomeYes {
		winToken, winLedger = m.YesToken, m.YesLedger
	} else {
		winToken, winLedger = m.NoToken, m.NoLedger
	}
	win := winToken.BalanceOf(caller)
	if win > 0 {
		checkErr(winLedger.Burn(caller, win))
		payOut(cur, caller, win)
	}
	return win
}

// ---- read-only views (no realm handle needed) ----

// MarketCount returns the number of markets created.
func MarketCount() int {
	return len(markets)
}

// GetMarket returns a pointer-free snapshot of a market.
func GetMarket(marketID uint64) MarketView {
	m := mustMarket(marketID)
	return MarketView{
		ID:               m.ID,
		Question:         m.Question,
		Creator:          m.Creator,
		Resolver:         m.Resolver,
		CloseTime:        m.CloseTime,
		LiquidityB:       m.LiquidityB,
		QYes:             m.QYes,
		QNo:              m.QNo,
		Resolved:         m.Resolved,
		Outcome:          m.Outcome,
		ResolveTime:      m.ResolveTime,
		DisputeEndTime:   m.DisputeEndTime,
		SeededCollateral: m.SeededCollateral,
		YesPriceBps:      lmsrPriceBps(m.QYes, m.QNo, m.LiquidityB, true),
		NoPriceBps:       lmsrPriceBps(m.QYes, m.QNo, m.LiquidityB, false),
		YesSupply:        m.YesToken.TotalSupply(),
		NoSupply:         m.NoToken.TotalSupply(),
	}
}

// PriceBps returns the current price of one side in basis points.
func PriceBps(marketID uint64, yes bool) int64 {
	m := mustMarket(marketID)
	return lmsrPriceBps(m.QYes, m.QNo, m.LiquidityB, yes)
}

// BalanceOf returns a user's YES (yes=true) or NO share balance.
func BalanceOf(marketID uint64, owner address, yes bool) int64 {
	m := mustMarket(marketID)
	if yes {
		return m.YesToken.BalanceOf(owner)
	}
	return m.NoToken.BalanceOf(owner)
}

// QuoteBuy returns the ugnot cost of buying `shares` of one side —
// exactly what Buy would charge (raw LMSR delta + 1 ugnot).
func QuoteBuy(marketID uint64, outcome int, shares int64) int64 {
	m := mustMarket(marketID)
	if outcome != OutcomeYes && outcome != OutcomeNo {
		panic("outcome must be YES (1) or NO (2)")
	}
	if shares <= 0 {
		panic("shares must be > 0")
	}
	dYes, dNo := shares, int64(0)
	if outcome == OutcomeNo {
		dYes, dNo = int64(0), shares
	}
	if outcome == OutcomeYes && shares > LMSRMaxQ-m.QYes {
		panic("shares exceed LMSR quantity domain")
	}
	if outcome == OutcomeNo && shares > LMSRMaxQ-m.QNo {
		panic("shares exceed LMSR quantity domain")
	}
	return lmsrCostDelta(m.QYes, m.QNo, m.LiquidityB, dYes, dNo) + 1
}

// QuoteSell returns the ugnot refund of selling `shares` of one side.
func QuoteSell(marketID uint64, outcome int, shares int64) int64 {
	m := mustMarket(marketID)
	if outcome != OutcomeYes && outcome != OutcomeNo {
		panic("outcome must be YES (1) or NO (2)")
	}
	if shares <= 0 {
		panic("shares must be > 0")
	}
	dYes, dNo := shares, int64(0)
	if outcome == OutcomeNo {
		dYes, dNo = int64(0), shares
	}
	return -lmsrCostDelta(m.QYes, m.QNo, m.LiquidityB, -dYes, -dNo)
}

// VaultBalance returns the realm's ugnot balance (seed + buys -
// refunds - redemptions). Read-only banker; cheap single-denom read.
func VaultBalance() int64 {
	return banker.NewReadonlyBanker().GetCoin(realmAddr(), ugnotDenom)
}
