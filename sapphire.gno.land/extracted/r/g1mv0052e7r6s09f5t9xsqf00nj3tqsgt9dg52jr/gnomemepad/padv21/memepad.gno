// Package pad is gnomemepad: a self-contained meme launchpad for gno.land.
//
//	Create (ugnot bond + GNS list-fee escrow) -> GRC20 + WUGNOT curve -> Graduate
//	  -> internal CPMM first; RetryListGnoswap when WUGNOT+escrowed GNS ready
//	  -> CreatePool fee paid from Create-time GNS escrow (no mid-tx WUGNOT->GNS)
//
// Production: Buy/Sell/Swap* use WUGNOT (push-pay + prepaid credits).
// Payment: user wugnot.Transfer(pad, amount) then Buy.
//   - Free float on pad is auto-locked into caller's prepaid credit.
//   - Buy may over-pay; unused WUGNOT stays as claimable credit (ClaimWugnot).
//   - Never Approve/TransferFrom (GRC20 spender bugs with Adena).
// Create: Transfer GNS (>= ListFeeGns free) then Create with ugnot bond.
// List: escrowed GNS + raised WUGNOT on pad; RetryListGnoswap (no user TransferFrom).
// Unit tests (testSkipBanker): still use OriginSend ugnot as collateral units.
// Tokens are real GRC20 (mint on buy, burn on sell). Hybrid of Pump.fun + permanent LP lock.
package padv21

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/demo/tokens/grc20"
	ammmath "gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gnomemepad/ammmathv2"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/demo/defi/grc20reg"
	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/gns"
	// bond: create-bond policy (promo / normal). Separate package - pad upgrades
	// do not replace bond schedule. Deploy prepare rewrites to personal path.
	createbond "gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gnomemepad/bond"
	// pointsv2: optional trade/create awards (off by default until SetPointsEnabled).
	// Deploy prepare rewrites this import to the Sapphire personal-namespace path.
	pointsv2 "gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gnomemepad/pointsv2"
)

var (
	launches     avl.Tree // id -> *Launch
	bySymbol     avl.Tree // symbol -> id string
	nextID       seqid.ID
	nextTokenID  seqid.ID // GRC20 identity sequence (shared for all launches)
	// padAddr: this realm's package address (set in init) - for inventory funding.
	padAddr address
	// protocolAddr: treasury set by Init (first EOA). Receives protocol fee share.
	protocolAddr address
	// protocolFees: ugnot still on pad, claimable / pushable to protocolAddr.
	protocolFees int64
	// protocolFeesPaid: lifetime ugnot already sent to protocolAddr (stats only).
	protocolFeesPaid int64
	inited           bool
	// testSkipBanker: when true, sendUgnot is a no-op (unit tests without funded realm bank).
	// Always false in production.
	testSkipBanker bool
	// testForceGnoswapList: unit tests only - stub tryListOnGnoswap succeeds without Sapphire deps.
	// Always false in production (gnoswap_list_full ignores it).
	testForceGnoswapList bool
	// pointsEnabled: when true, notify pointsv2 after Create / Buy / Sell / Swap*.
	// Admin must also AllowPad(this package) on pointsv2.
	pointsEnabled bool
	// wugnotCredit: EOA address string -> int64 prepaid WUGNOT claimable by user.
	// totalWugnotCredit: sum of all credits (included in reservedWugnot).
	// Flow: Transfer WUGNOT to pad (raises free) -> Buy auto-locks free into credit
	// and spends; overpay refund goes back to credit; ClaimWugnot withdraws credit.
	wugnotCredit      avl.Tree
	totalWugnotCredit int64
	// totalListFeeGns: sum of per-launch ListFeeGns escrow (reserved GNS on pad).
	// freeGns = gns.BalanceOf(pad) - totalListFeeGns.
	totalListFeeGns int64
)

func init(cur realm) {
	padAddr = cur.Address()
}

// Trade is one price sample for charts (capped history per launch).
type Trade struct {
	Height int64
	Side   int // TradeSideBuy | TradeSideSell | TradeSideOpen
	Ugnot  int64
	Tokens int64
	Price  int64 // ugnot per token * 1e6 after the trade
}

// Launch is one meme market: curve phase then locked pool phase.
// token/ledger are unexported so external packages cannot Mint/Burn via field access.
type Launch struct {
	ID      string
	Name    string
	Symbol  string
	URI     string
	Creator address
	Status  int
	Created int64 // block height

	// GRC20 (mint/burn only via pad-owned private ledger)
	token   *grc20.Token
	ledger  *grc20.PrivateLedger
	TokenID string // Token.ID() - registry / Gnoswap identity

	// Virtual curve reserves
	VirtualUgnot int64
	VirtualToken int64
	RealSold     int64 // tokens sold on curve (<= CurveSupply)
	RaisedUgnot  int64 // net ugnot collateral in curve (excl. fee vaults)

	// Real pool (post-grad); LP permanently locked - no remove path
	// PoolToken is pad-internal reserve (not the same as GRC20 total supply).
	PoolUgnot int64
	PoolToken int64

	CreatorFees  int64
	BondUgnot    int64
	BondRefunded bool
	UniqueBuyers avl.Tree // address -> true
	BuyerCount   int
	// snipeBought: address -> cumulative tokens bought during anti-snipe window
	snipeBought avl.Tree

	// Gnoswap listing state
	GnoswapReady      bool   // graduated; token is listable / listed
	GnoswapListed     bool   // true when CreatePool+Mint succeeded on Gnoswap
	GnoswapNote       string // human status / failure reason
	GnoswapPoolPath   string
	GnoswapPositionID uint64
	// FeeWugnotSpent / LiqWugnotUsed: inventory spent at graduate (1:1 vs raised ugnot notionally)
	FeeWugnotSpent int64
	LiqWugnotUsed  int64

	// ListFeeGns: Create-time GNS escrow for Gnoswap CreatePool fee (padv20+).
	// Consumed on successful list; ClaimListFee refunds creator if still unlisted.
	ListFeeGns       int64
	ListFeeConsumed  bool // true after list paid CreatePool fee from escrow

	// Chart history (ordered AVL keys)
	Trades    avl.Tree // tradeKey -> *Trade
	NextTrade int64
}

// Init sets the protocol treasury. First EOA caller becomes fee recipient
// (protocolAddr). Protocol trade fees accrue on-pad until ClaimProtocolFees
// (treasury only) or PushProtocolFees (anyone may push to treasury).
// Creator fees always need ClaimCreatorFees by the token creator.
//
// Deploy note: call Init with the wallet that should receive protocol fees
// (or TransferProtocol later). Gnoswap CreatePool GNS fee is paid to Gnoswap,
// not to this treasury.
func Init(cur realm) {
	if inited {
		panic("pad: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("pad: EOA only")
	}
	protocolAddr = cur.Previous().Address()
	inited = true
	chain.Emit("Init", "protocol", protocolAddr.String())
}

// creditProtocol accrues protocol ugnot liability on the pad realm.
// Cash stays in pad until ClaimProtocolFees / PushProtocolFees.
func creditProtocol(amt int64) {
	if amt <= 0 {
		return
	}
	protocolFees += amt
}

func requireInit() {
	if !inited {
		panic("pad: call Init first")
	}
}

// SetPointsEnabled toggles pointsv2 notifications (protocol admin only).
// pointsv2 must AllowPad(this package path) or OnTrade/OnCreate will panic and revert the trade.
func SetPointsEnabled(cur realm, on bool) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: EOA only")
	}
	if cur.Previous().Address() != protocolAddr {
		panic("pad: not protocol")
	}
	pointsEnabled = on
	chain.Emit("SetPointsEnabled", "on", strconv.FormatBool(on))
}

// PointsEnabled reports whether pad notifies pointsv2 after trades/creates.
func PointsEnabled() bool {
	return pointsEnabled
}

func notifyTrade(cur realm, trader address, id string, side int64, volumeUgnot int64) {
	if !pointsEnabled || testSkipBanker {
		return
	}
	_ = pointsv2.OnTrade(cross(cur), trader, id, side, volumeUgnot)
}

func notifyCreate(cur realm, creator address, id string) {
	if !pointsEnabled || testSkipBanker {
		return
	}
	_ = pointsv2.OnCreate(cross(cur), creator, id)
}

func mustLaunch(id string) *Launch {
	// Sapphire avl.Tree.Get returns a single any (nil if missing).
	l, ok := launches.Get(id).(*Launch)
	if !ok {
		panic("pad: unknown launch")
	}
	return l
}

func balOf(l *Launch, addr address) int64 {
	if l == nil || l.token == nil {
		return 0
	}
	return l.token.BalanceOf(addr)
}

// addBal mints (delta>0) or burns (delta<0) GRC20 via pad-owned PrivateLedger.
func addBal(l *Launch, addr address, delta int64) {
	if l == nil || l.ledger == nil {
		panic("pad: missing GRC20 ledger")
	}
	if delta == 0 {
		return
	}
	if delta > 0 {
		if err := l.ledger.Mint(addr, delta); err != nil {
			panic("pad: mint: " + err.Error())
		}
		return
	}
	if err := l.ledger.Burn(addr, -delta); err != nil {
		panic("pad: burn: " + err.Error())
	}
}

func requireMinOut(got, minOut int64, what string) {
	if minOut < 0 {
		panic("pad: minOut must be non-negative")
	}
	if minOut > 0 && got < minOut {
		panic("pad: " + what + " below minOut (slippage)")
	}
}

func snipeBoughtOf(l *Launch, buyer address) int64 {
	v := l.snipeBought.Get(buyer.String())
	if v == nil {
		return 0
	}
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

func checkAndAddSnipe(l *Launch, buyer address, tokensOut int64) {
	height := runtime.ChainHeight()
	if height-l.Created >= AntiSnipeHeights {
		return
	}
	maxTok := TotalSupply * AntiSnipeMaxBuyBPS / 10000
	prev := snipeBoughtOf(l, buyer)
	if prev+tokensOut > maxTok {
		panic("pad: anti-snipe cumulative max buy exceeded")
	}
	l.snipeBought.Set(buyer.String(), prev+tokensOut)
}

func sendUgnot(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	if testSkipBanker {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.Coins{{Denom: DenomUgnot, Amount: amount}})
}

func requireUserPayment(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	sent := unsafe.OriginSend().AmountOf(DenomUgnot)
	if sent <= 0 {
		panic("pad: need ugnot -send")
	}
	return sent
}

// --- WUGNOT collateral (production curve / internal CPMM) ---

// reservedWugnot is WUGNOT already committed (markets/fees/user prepaid credits).
// Excludes bank-only liabilities (create bond ugnot).
func reservedWugnot() int64 {
	reserved := protocolFees + totalWugnotCredit
	launches.Iterate("", "", func(_ string, value any) bool {
		l := value.(*Launch)
		reserved += l.CreatorFees
		if l.Status == StatusCurve {
			reserved += l.RaisedUgnot
		}
		// Internal CPMM holds WUGNOT when not listed on Gnoswap.
		if l.Status == StatusGraduated && !l.GnoswapListed {
			reserved += l.PoolUgnot
		}
		return false
	})
	return reserved
}

// freeWugnotOnPad is WUGNOT on pad above reserved commitments.
// After user wugnot.Transfer(pad, amt), free rises; Buy locks free into caller credit.
func freeWugnotOnPad() int64 {
	have := wugnot.BalanceOf(padAddr)
	free := have - reservedWugnot()
	if free < 0 {
		return 0
	}
	return free
}

// FreeWugnot is free|have|reserved|totalCredit for UI preflight.
func FreeWugnot() string {
	have := wugnot.BalanceOf(padAddr)
	res := reservedWugnot()
	free := have - res
	if free < 0 {
		free = 0
	}
	return strconv.FormatInt(free, 10) + "|" +
		strconv.FormatInt(have, 10) + "|" +
		strconv.FormatInt(res, 10) + "|" +
		strconv.FormatInt(totalWugnotCredit, 10)
}

func prepaidOf(addr address) int64 {
	if !addr.IsValid() {
		return 0
	}
	v := wugnotCredit.Get(addr.String())
	if v == nil {
		return 0
	}
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

func addPrepaid(addr address, amount int64) {
	if amount <= 0 || !addr.IsValid() {
		return
	}
	next := prepaidOf(addr) + amount
	wugnotCredit.Set(addr.String(), next)
	totalWugnotCredit += amount
}

func subPrepaid(addr address, amount int64) {
	if amount <= 0 {
		return
	}
	have := prepaidOf(addr)
	if have < amount {
		panic("pad: prepaid WUGNOT underfunded")
	}
	next := have - amount
	if next == 0 {
		wugnotCredit.Remove(addr.String())
	} else {
		wugnotCredit.Set(addr.String(), next)
	}
	totalWugnotCredit -= amount
}

// PrepaidBalance returns caller's claimable WUGNOT credit on this pad.
func PrepaidBalance(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	return prepaidOf(cur.Previous().Address())
}

// PrepaidOf returns claimable credit for an address (read helper).
func PrepaidOf(addr string) int64 {
	return prepaidOf(address(addr))
}

// ClaimWugnot withdraws all of the caller's prepaid WUGNOT credit to their wallet.
// Safe after Buy overpay or after graduate/list - excess stays claimable until claimed.
func ClaimWugnot(cur realm) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	user := cur.Previous().Address()
	amt := prepaidOf(user)
	if amt <= 0 {
		return 0
	}
	subPrepaid(user, amt)
	payWugnotOut(cur, user, amt)
	chain.Emit("ClaimWugnot",
		"user", user.String(),
		"amount", strconv.FormatInt(amt, 10),
	)
	return amt
}

// takeWugnotIn collects amount WUGNOT as payment for Buy/SwapBuy.
//
// 1) Auto-lock free float into caller's prepaid (user must Transfer to pad first).
// 2) Spend amount from prepaid (overpay stays as credit via creditRefund).
// No TransferFrom.
//
// Tests (testSkipBanker): OriginSend ugnot as synthetic collateral units.
func takeWugnotIn(cur realm, amount int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if testSkipBanker {
		// Local tests: OriginSend ugnot stands in for WUGNOT units.
		return requireUserPayment(cur)
	}
	if amount <= 0 {
		panic("pad: amountWugnot must be positive")
	}
	user := cur.Previous().Address()
	have := prepaidOf(user)
	if have < amount {
		need := amount - have
		free := freeWugnotOnPad()
		if free < need {
			havePad := wugnot.BalanceOf(padAddr)
			res := reservedWugnot()
			panic("pad: Transfer " + strconv.FormatInt(need, 10) +
				" more WUGNOT to pad then Buy (free=" + strconv.FormatInt(free, 10) +
				" prepaid=" + strconv.FormatInt(have, 10) +
				" have=" + strconv.FormatInt(havePad, 10) +
				" reserved=" + strconv.FormatInt(res, 10) +
				" needTotal=" + strconv.FormatInt(amount, 10) + ")")
		}
		// Lock free into this caller's prepaid (raises reserved, lowers free).
		addPrepaid(user, need)
	}
	subPrepaid(user, amount)
	return amount
}

// creditRefund keeps unused Buy WUGNOT as claimable prepaid (not instant wallet refund).
// User calls ClaimWugnot after buy / after list when convenient.
func creditRefund(buyer address, amount int64) {
	if testSkipBanker || amount <= 0 {
		return
	}
	addPrepaid(buyer, amount)
}

// payWugnotOut sends WUGNOT from pad to user (production).
// Tests: pay ugnot via banker when testSkipBanker.
func payWugnotOut(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	if testSkipBanker {
		sendUgnot(cur, to, amount)
		return
	}
	have := wugnot.BalanceOf(cur.Address())
	if have < amount {
		amount = have
	}
	if amount > 0 {
		wugnot.Transfer(cross(cur), to, amount)
	}
}

func noteBuyer(l *Launch, buyer address) {
	k := buyer.String()
	if l.UniqueBuyers.Has(k) {
		return
	}
	l.UniqueBuyers.Set(k, true)
	l.BuyerCount++
}

func tradeKey(n int64) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

// spotPriceScaled returns ugnot/token * 1e6 from current curve or pool reserves.
func spotPriceScaled(l *Launch) int64 {
	if l.Status == StatusGraduated {
		if l.PoolToken <= 0 {
			return 0
		}
		return l.PoolUgnot * 1000000 / l.PoolToken
	}
	if l.VirtualToken <= 0 {
		return 0
	}
	return l.VirtualUgnot * 1000000 / l.VirtualToken
}

func recordTrade(l *Launch, side int, ugnot, tokens int64) {
	l.NextTrade++
	t := &Trade{
		Height: runtime.ChainHeight(),
		Side:   side,
		Ugnot:  ugnot,
		Tokens: tokens,
		Price:  spotPriceScaled(l),
	}
	l.Trades.Set(tradeKey(l.NextTrade), t)
	// Ring buffer: drop oldest while over cap.
	for l.Trades.Size() > MaxTradeHistory {
		oldest := ""
		l.Trades.Iterate("", "", func(k string, _ any) bool {
			oldest = k
			return true // stop
		})
		if oldest == "" {
			break
		}
		l.Trades.Remove(oldest)
	}
}

func maybeRefundBond(cur realm, l *Launch) {
	if l.BondRefunded || l.BondUgnot <= 0 {
		return
	}
	if l.BuyerCount < BondRefundBuyers {
		return
	}
	// Quality gate: pure sybil micro-buys cannot refund bond.
	if l.RaisedUgnot < BondRefundMinRaised {
		return
	}
	if runtime.ChainHeight()-l.Created > BondRefundMaxHeights {
		return
	}
	amt := l.BondUgnot
	l.BondUgnot = 0
	l.BondRefunded = true
	sendUgnot(cur, l.Creator, amt)
	chain.Emit("BondRefund", "id", l.ID, "amount", strconv.FormatInt(amt, 10))
}

// requiredCreateBond returns ugnot the creator must send.
// Production: createbond.CurrentBondUgnot() (promo or normal).
// Unit tests (testSkipBanker): local CreateBondUgnot constant.
func requiredCreateBond() int64 {
	if testSkipBanker {
		return CreateBondUgnot
	}
	return createbond.CurrentBondUgnot()
}

// CreateBondRequired is a public alias for UIs / qeval (same as requiredCreateBond).
func CreateBondRequired() int64 {
	return requiredCreateBond()
}

// requiredListFeeGns returns GNS base units the creator must pre-fund (free on pad).
// Production uses ListFeeGns const (matches Gnoswap CreatePool fee).
func requiredListFeeGns() int64 {
	if ListFeeGns <= 0 {
		return 100_000_000
	}
	return ListFeeGns
}

// ListFeeRequired is a public alias for UIs / qeval.
func ListFeeRequired() int64 {
	return requiredListFeeGns()
}

// freeGnsOnPad is GNS on pad above per-launch list-fee escrow.
func freeGnsOnPad() int64 {
	if testSkipBanker {
		// Tests skip GNS inventory checks.
		return requiredListFeeGns()
	}
	have := gns.BalanceOf(padAddr)
	free := have - totalListFeeGns
	if free < 0 {
		return 0
	}
	return free
}

// FreeGns returns free|have|reserved for UI preflight (GNS list fee).
func FreeGns() string {
	have := int64(0)
	if !testSkipBanker {
		have = gns.BalanceOf(padAddr)
	}
	free := freeGnsOnPad()
	return strconv.FormatInt(free, 10) + "|" +
		strconv.FormatInt(have, 10) + "|" +
		strconv.FormatInt(totalListFeeGns, 10)
}

// lockListFeeEscrow earmarks free GNS for this launch's CreatePool fee.
func lockListFeeEscrow(l *Launch, amt int64) {
	if l == nil || amt <= 0 {
		return
	}
	if freeGnsOnPad() < amt {
		have := int64(0)
		if !testSkipBanker {
			have = gns.BalanceOf(padAddr)
		}
		panic("pad: Transfer " + strconv.FormatInt(amt, 10) +
			" GNS to pad then Create (free=" + strconv.FormatInt(freeGnsOnPad(), 10) +
			" have=" + strconv.FormatInt(have, 10) +
			" reserved=" + strconv.FormatInt(totalListFeeGns, 10) + ")")
	}
	totalListFeeGns += amt
	l.ListFeeGns = amt
	l.ListFeeConsumed = false
}

// consumeListFeeEscrow clears launch escrow after successful Gnoswap list
// (CreatePool spent feeNeed GNS from pad balance).
func consumeListFeeEscrow(l *Launch) {
	if l == nil || l.ListFeeGns <= 0 {
		return
	}
	amt := l.ListFeeGns
	totalListFeeGns -= amt
	if totalListFeeGns < 0 {
		totalListFeeGns = 0
	}
	l.ListFeeGns = 0
	l.ListFeeConsumed = true
	chain.Emit("ListFeeConsumed", "id", l.ID, "amount", strconv.FormatInt(amt, 10))
}

// ClaimListFee refunds Create-time GNS escrow to the token creator if still unlisted.
// Use when graduate/list will not complete or creator abandons listing.
func ClaimListFee(cur realm, id string) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	l := mustLaunch(id)
	caller := cur.Previous().Address()
	if caller != l.Creator {
		panic("pad: only creator may claim list fee")
	}
	if l.GnoswapListed {
		panic("pad: already listed - list fee spent")
	}
	if l.ListFeeConsumed {
		panic("pad: list fee already consumed")
	}
	amt := l.ListFeeGns
	if amt <= 0 {
		return 0
	}
	l.ListFeeGns = 0
	totalListFeeGns -= amt
	if totalListFeeGns < 0 {
		totalListFeeGns = 0
	}
	if !testSkipBanker && amt > 0 {
		have := gns.BalanceOf(padAddr)
		if have < amt {
			amt = have
		}
		if amt > 0 {
			gns.Transfer(cross(cur), l.Creator, amt)
		}
	}
	chain.Emit("ClaimListFee",
		"id", id,
		"creator", l.Creator.String(),
		"amount", strconv.FormatInt(amt, 10),
	)
	return amt
}

// Create deploys a fair-launch meme. Bond amount from bond realm (or fallback const).
// Also locks ListFeeGns free GNS (creator must Transfer GNS to pad first).
// No pre-mint; all tradeable float starts on the bonding curve.
func Create(cur realm, name, symbol, uri string) string {
	requireInit()
	sent := requireUserPayment(cur)
	bondNeed := requiredCreateBond()
	if bondNeed <= 0 {
		panic("pad: create bond misconfigured")
	}
	if sent < bondNeed {
		panic("pad: create bond underpaid")
	}
	if name == "" || symbol == "" {
		panic("pad: name and symbol required")
	}
	if len(symbol) > 12 {
		panic("pad: symbol too long")
	}
	if bySymbol.Has(symbol) {
		panic("pad: symbol taken")
	}
	extra := sent - bondNeed
	if extra > 0 {
		creditProtocol(extra)
	}

	creator := cur.Previous().Address()
	id := nextID.Next().String()

	// Real GRC20 bound to this pad realm (mint/burn only via pad ledger).
	// Decimals=0: whole-token units (matches existing trade amounts).
	token, ledger := grc20.NewToken(name, symbol, 0, nextTokenID.Next(), cur)

	// Adena (and Gnoswap registries) resolve tokens ONLY via grc20reg under key
	// packagePath.SYMBOL - Token.ID() itself is packagePath.SYMBOL.seq and is
	// rejected as "Invalid path" if pasted into Adena without registration.
	// Skip in unit tests (testSkipBanker); production always registers.
	regKey := ""
	if !testSkipBanker {
		regKey = grc20reg.Register(cross(cur), token, symbol)
	}

	l := &Launch{
		ID:           id,
		Name:         name,
		Symbol:       symbol,
		URI:          uri,
		Creator:      creator,
		Status:       StatusCurve,
		Created:      runtime.ChainHeight(),
		token:        token,
		ledger:       ledger,
		TokenID:      token.ID(),
		VirtualUgnot: VirtualUgnot0,
		VirtualToken: VirtualToken0,
		UniqueBuyers: avl.Tree{},
		snipeBought:  avl.Tree{},
		BondUgnot:    bondNeed,
		Trades:       avl.Tree{},
	}
	// Lock free GNS for future CreatePool (UI: gns.Transfer then Create).
	lockListFeeEscrow(l, requiredListFeeGns())
	// Open mark for charts (initial virtual spot).
	recordTrade(l, TradeSideOpen, 0, 0)
	launches.Set(id, l)
	bySymbol.Set(symbol, id)

	chain.Emit("Created",
		"id", id,
		"symbol", symbol,
		"creator", creator.String(),
		"token", l.TokenID,
		"reg", regKey,
		"listFeeGns", strconv.FormatInt(l.ListFeeGns, 10),
	)
	notifyCreate(cur, creator, id)
	return id
}

// AdenaPathOf returns the grc20reg / Adena token key: packagePath.SYMBOL
// (Token.ID is packagePath.SYMBOL.seq - Adena rejects that form).
func AdenaPathOf(id string) string {
	l := mustLaunch(id)
	return adenaKeyFromTokenID(l.TokenID, l.Symbol)
}

// adenaKeyFromTokenID strips the trailing .seq from Token.ID when present.
func adenaKeyFromTokenID(tokenID, symbol string) string {
	if tokenID == "" {
		return ""
	}
	// Token.ID = packagePath.symbol.seq -> registry key = packagePath.symbol
	suffix := "." + symbol + "."
	if i := strings.LastIndex(tokenID, suffix); i >= 0 {
		// packagePath + "." + symbol
		return tokenID[:i] + "." + symbol
	}
	// Already packagePath.symbol or unknown layout
	if strings.HasSuffix(tokenID, "."+symbol) {
		return tokenID
	}
	return tokenID
}

// maxGrossForNetIn finds largest gross ugnot <= sentMax whose fee-split netIn <= maxNet.
func maxGrossForNetIn(maxNet, sentMax int64) int64 {
	if maxNet <= 0 || sentMax <= 0 {
		return 0
	}
	lo, hi := int64(0), sentMax
	for lo < hi {
		mid := (lo + hi + 1) / 2
		f := ammmath.ApplyFee(mid, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
		net := f.Net + f.Remainder
		if net <= maxNet {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// readyToGraduate is true when raise met the threshold, or the entire curve
// float is sold (sold-out escape: threshold may be unreachable with bad virtuals).
func readyToGraduate(l *Launch) bool {
	if l == nil || l.Status != StatusCurve {
		return false
	}
	if l.RaisedUgnot <= 0 {
		return false
	}
	if ammmath.CanGraduate(l.RaisedUgnot, GraduationThreshold) {
		return true
	}
	// Curve exhausted before threshold: still graduate with whatever was raised
	// so the market is never permanently stuck on Buy/Graduate.
	return l.RealSold >= CurveSupply
}

// Buy spends WUGNOT on the bonding curve; credits tokens.
// amountWugnot: max to spend (may overpay). UI: Deposit + Transfer(pad, amt) + Buy.
// Overpay stays as claimable prepaid - ClaimWugnot anytime (incl. after list).
// minTokensOut: slippage floor (0 = disabled). Auto-graduates at threshold or sold-out.
//
// Production: collateral is real WUGNOT on pad -> Graduate can auto-list Gnoswap.
// Tests (testSkipBanker): amountWugnot ignored; OriginSend ugnot is used as units.
//
// Last-fill (no overshoot):
//  1. Cap net so RaisedUgnot never exceeds GraduationThreshold (refund excess WUGNOT).
//  2. Cap by remaining curve tokens (CurveSupply - RealSold).
//
// If the curve is already sold out (or raise already filled), Buy refunds the full
// take and graduates when ready - no panic so users are not stuck mid-tx.
func Buy(cur realm, id string, amountWugnot, minTokensOut int64) int64 {
	requireInit()
	sent := takeWugnotIn(cur, amountWugnot)
	l := mustLaunch(id)
	if l.Status != StatusCurve {
		panic("pad: not on curve (use SwapBuy)")
	}
	buyer := cur.Previous().Address()

	remainingTok := CurveSupply - l.RealSold
	needRaise := GraduationThreshold - l.RaisedUgnot
	// Already complete: refund payment and graduate (sold-out or raise-filled).
	if remainingTok <= 0 || needRaise <= 0 {
		if !readyToGraduate(l) {
			// Edge: zero raise with empty float should not happen in production.
			if remainingTok <= 0 {
				panic("pad: curve sold out with no raise")
			}
			panic("pad: raise filled - call Graduate")
		}
		if sent > 0 {
			// Keep as claimable credit (ClaimWugnot) - safe after graduate/list too.
			creditRefund(buyer, sent)
			chain.Emit("BuyRefund",
				"id", id,
				"buyer", buyer.String(),
				"refund", strconv.FormatInt(sent, 10),
				"toCredit", "1",
			)
		}
		graduate(cur, l)
		return 0
	}

	usedGross := sent
	fee := ammmath.ApplyFee(usedGross, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	// Net enters curve; remainder boosts virtual ugnot (stays as collateral).
	netIn := fee.Net + fee.Remainder

	// Max net allowed: min(user net, remaining raise, remaining tokens).
	maxNet := netIn
	if maxNet > needRaise {
		maxNet = needRaise
	}
	maxNetTok := ammmath.MaxNetInForTokenOut(l.VirtualUgnot, l.VirtualToken, remainingTok)
	if maxNetTok > 0 && maxNet > maxNetTok {
		maxNet = maxNetTok
	}
	if maxNet <= 0 {
		panic("pad: no fill capacity remaining")
	}

	// Clamp gross + recompute fee when caps bind (last-fill refund path).
	if maxNet < netIn {
		usedGross = maxGrossForNetIn(maxNet, sent)
		if usedGross <= 0 {
			panic("pad: buy too small for remaining fill")
		}
		fee = ammmath.ApplyFee(usedGross, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
		netIn = fee.Net + fee.Remainder
		if netIn > maxNet {
			netIn = maxNet
		}
	}

	tokensOut, newVU, newVT := ammmath.BuyTokens(l.VirtualUgnot, l.VirtualToken, netIn)
	// Integer edge: step down net until tokens <= remaining curve supply.
	for tokensOut > remainingTok && netIn > 1 {
		netIn--
		tokensOut, newVU, newVT = ammmath.BuyTokens(l.VirtualUgnot, l.VirtualToken, netIn)
	}
	if tokensOut > remainingTok || tokensOut <= 0 {
		panic("pad: cannot fill remaining curve supply")
	}
	// If net was reduced further, shrink usedGross so refund is correct.
	if netIn < maxNet || usedGross < sent {
		// Re-derive gross that yields this netIn (<= sent).
		g2 := maxGrossForNetIn(netIn, sent)
		if g2 > 0 && g2 < usedGross {
			usedGross = g2
			fee = ammmath.ApplyFee(usedGross, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
			// Keep curve netIn as simulated (may be slightly below fee.Net+Rem).
		}
	}
	// Hard safety: never overshoot graduation raise after this buy.
	if l.RaisedUgnot+netIn > GraduationThreshold {
		netIn = GraduationThreshold - l.RaisedUgnot
		if netIn <= 0 {
			panic("pad: raise filled - call Graduate")
		}
		tokensOut, newVU, newVT = ammmath.BuyTokens(l.VirtualUgnot, l.VirtualToken, netIn)
		for tokensOut > remainingTok && netIn > 1 {
			netIn--
			tokensOut, newVU, newVT = ammmath.BuyTokens(l.VirtualUgnot, l.VirtualToken, netIn)
		}
		if tokensOut <= 0 {
			panic("pad: cannot fill remaining raise")
		}
		usedGross = maxGrossForNetIn(netIn, sent)
		if usedGross <= 0 {
			panic("pad: buy too small for remaining raise")
		}
		fee = ammmath.ApplyFee(usedGross, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	}

	refund := sent - usedGross
	if refund > 0 {
		// Overpay stays claimable - user ClaimWugnot anytime (incl. after list).
		creditRefund(buyer, refund)
	}

	requireMinOut(tokensOut, minTokensOut, "tokens out")
	checkAndAddSnipe(l, buyer, tokensOut)

	// Mutate only after all checks pass.
	// Fees stay as WUGNOT on pad (liabilities); netIn is raised collateral for LP.
	l.CreatorFees += fee.Creator
	creditProtocol(fee.Protocol)
	l.VirtualUgnot = newVU
	l.VirtualToken = newVT
	l.RealSold += tokensOut
	l.RaisedUgnot += netIn
	// Invariant: raise never exceeds threshold after Buy.
	if l.RaisedUgnot > GraduationThreshold {
		panic("pad: raise overshoot invariant")
	}

	addBal(l, buyer, tokensOut)
	noteBuyer(l, buyer)
	maybeRefundBond(cur, l)
	recordTrade(l, TradeSideBuy, usedGross, tokensOut)

	chain.Emit("Buy",
		"id", id,
		"buyer", buyer.String(),
		"ugnot", strconv.FormatInt(usedGross, 10),
		"wugnot", strconv.FormatInt(usedGross, 10),
		"tokens", strconv.FormatInt(tokensOut, 10),
	)
	if refund > 0 {
		chain.Emit("BuyRefund",
			"id", id,
			"buyer", buyer.String(),
			"refund", strconv.FormatInt(refund, 10),
		)
	}
	notifyTrade(cur, buyer, id, 0, usedGross)

	if readyToGraduate(l) {
		graduate(cur, l)
	}
	return tokensOut
}

// RemainingRaiseUgnot is net ugnot still needed to hit GraduationThreshold (0 if met/over).
func RemainingRaiseUgnot(id string) int64 {
	l := mustLaunch(id)
	if l.Status != StatusCurve {
		return 0
	}
	if l.RaisedUgnot >= GraduationThreshold {
		return 0
	}
	return GraduationThreshold - l.RaisedUgnot
}

// Sell burns curve tokens and pays WUGNOT (fee on output).
// minWugnotOut: slippage floor (0 = disabled). User may wugnot.Withdraw to ugnot.
func Sell(cur realm, id string, tokensIn, minWugnotOut int64) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if tokensIn <= 0 {
		panic("pad: tokensIn must be positive")
	}
	l := mustLaunch(id)
	if l.Status != StatusCurve {
		panic("pad: not on curve (use SwapSell)")
	}
	seller := cur.Previous().Address()
	if balOf(l, seller) < tokensIn {
		panic("pad: insufficient token balance")
	}

	gross, newVU, newVT := ammmath.SellTokens(l.VirtualUgnot, l.VirtualToken, tokensIn)
	fee := ammmath.ApplyFeeOnOutput(gross, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	requireMinOut(fee.Net, minWugnotOut, "wugnot out")

	// Full gross left virtual reserves; retain fee in virtual ugnot (cash stays in realm).
	l.VirtualUgnot = newVU + fee.Fee
	l.VirtualToken = newVT
	l.RealSold -= tokensIn
	if l.RealSold < 0 {
		l.RealSold = 0
	}

	// User receives net; creator+protocol become fee liabilities (leave Raised).
	payOut := fee.Net + fee.Creator + fee.Protocol
	if l.RaisedUgnot >= payOut {
		l.RaisedUgnot -= payOut
	} else {
		l.RaisedUgnot = 0
	}
	l.CreatorFees += fee.Creator
	creditProtocol(fee.Protocol)

	addBal(l, seller, -tokensIn)
	payWugnotOut(cur, seller, fee.Net)
	recordTrade(l, TradeSideSell, fee.Net, tokensIn)

	chain.Emit("Sell",
		"id", id,
		"seller", seller.String(),
		"tokens", strconv.FormatInt(tokensIn, 10),
		"ugnot", strconv.FormatInt(fee.Net, 10),
		"wugnot", strconv.FormatInt(fee.Net, 10),
	)
	notifyTrade(cur, seller, id, 1, fee.Net)
	return fee.Net
}

// Graduate permissionlessly moves a ready curve into a permanently locked CPMM.
// Ready when RaisedUgnot >= GraduationThreshold, or when RealSold >= CurveSupply
// with RaisedUgnot > 0 (sold-out before threshold - escape hatch for unreachable raise).
func Graduate(cur realm, id string) {
	requireInit()
	l := mustLaunch(id)
	if l.Status != StatusCurve {
		panic("pad: already graduated")
	}
	if !readyToGraduate(l) {
		panic("pad: not ready to graduate (need raise threshold or curve sold out)")
	}
	graduate(cur, l)
}

func graduate(cur realm, l *Launch) {
	if l.Status != StatusCurve {
		return
	}
	// Liquidity capital = all raised GNOT + every token not already sold to buyers.
	// (Formerly only PoolSeed tokens entered the pool; unsold curve supply was dead.)
	poolU := l.RaisedUgnot
	if poolU <= 0 {
		panic("pad: empty pool ugnot")
	}
	remaining := TotalSupply - l.RealSold
	if remaining <= 0 {
		panic("pad: no remaining tokens for liquidity")
	}
	poolT := remaining

	l.PoolUgnot = poolU
	l.PoolToken = poolT
	l.RaisedUgnot = 0
	l.VirtualUgnot = 0
	l.VirtualToken = 0
	l.Status = StatusGraduated

	// Forfeit unrefunded bond to protocol at graduation if still locked.
	if !l.BondRefunded && l.BondUgnot > 0 {
		creditProtocol(l.BondUgnot)
		l.BondUgnot = 0
		l.BondRefunded = true
	}

	// Mark graduation on chart at pool spot.
	recordTrade(l, TradeSideOpen, poolU, poolT)

	// NEVER auto-list inside Buy/Graduate.
	// Gnoswap CreatePool/Mint does WUGNOT Approve+TransferFrom; realm spender
	// frame often panics "insufficient allowance" and REVERTS the entire Buy
	// (including the curve fill that triggered graduation). List is a separate
	// EOA call: pre-fund pad WUGNOT/GNS then RetryListGnoswap.
	// Unit tests may still force list via testForceGnoswapList.
	l.GnoswapReady = true
	listed := false
	if testForceGnoswapList {
		listed = listOnGnoswapWithFunding(cur, l, poolU, poolT)
	}
	if !listed {
		// Internal CPMM: PoolToken is pad-accounting reserve (not minted GRC20).
		// Circulating = user balances; pool side is virtual reserve PoolToken.
		// Ops/UI: Transfer WUGNOT/GNS to pad then RetryListGnoswap (no user TF).
		if l.GnoswapNote == "" {
			l.GnoswapNote = "internal CPMM; Transfer WUGNOT+GNS to pad then RetryListGnoswap"
		}
		chain.Emit("Graduated",
			"id", l.ID,
			"poolUgnot", strconv.FormatInt(poolU, 10),
			"poolToken", strconv.FormatInt(poolT, 10),
			"token", l.TokenID,
			"gnoswap_listed", "0",
		)
		return
	}
	// Listed on Gnoswap (test-only path): capital is in the CL position (NFT owned by pad).
	// Internal SwapBuy/Sell disabled (PoolUgnot/PoolToken kept as listing record).
	chain.Emit("Graduated",
		"id", l.ID,
		"poolUgnot", strconv.FormatInt(poolU, 10),
		"poolToken", strconv.FormatInt(poolT, 10),
		"token", l.TokenID,
		"gnoswap_listed", "1",
		"poolPath", l.GnoswapPoolPath,
		"positionId", strconv.FormatUint(l.GnoswapPositionID, 10),
	)
}

// RetryListGnoswap re-attempts Gnoswap CreatePool + full-range Mint for a
// graduated launch that fell back to the internal CPMM.
// Permissionless EOA MsgCall.
//
// Auto-funding (padv13+): if pad WUGNOT/GNS inventory is short, pulls shortfall from
// the caller via TransferFrom (caller must wugnot.Deposit + Approve(pad) first, and
// preferably hold/Approve GNS for CreatePool fee). On success, LP WUGNOT pulled from
// the caller is reimbursed in ugnot from pad bank (raised capital). Fee is not reimbursed.
//
// Uses current PoolUgnot / PoolToken as LP sizes. Returns true if listed this call.
func RetryListGnoswap(cur realm, id string) bool {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	l := mustLaunch(id)
	if l.Status != StatusGraduated {
		panic("pad: not graduated")
	}
	if l.GnoswapListed {
		panic("pad: already listed on Gnoswap")
	}
	poolU := l.PoolUgnot
	poolT := l.PoolToken
	if poolU <= 0 || poolT <= 0 {
		panic("pad: empty internal pool")
	}
	ok := listOnGnoswapWithFunding(cur, l, poolU, poolT)
	if ok {
		chain.Emit("GnoswapListedRetry",
			"id", l.ID,
			"poolPath", l.GnoswapPoolPath,
			"positionId", strconv.FormatUint(l.GnoswapPositionID, 10),
			"poolUgnot", strconv.FormatInt(poolU, 10),
			"poolToken", strconv.FormatInt(poolT, 10),
		)
	} else if l.GnoswapNote == "" {
		l.GnoswapNote = "retry list failed - check ListNeed(id): wrap WUGNOT, Approve pad, prefer GNS fee"
	}
	return ok
}

// TokenIDOf returns the GRC20 Token.ID() for a launch.
func TokenIDOf(id string) string {
	return mustLaunch(id).TokenID
}

// GRC20Bank returns the underlying *grc20.Token for interop (metadata / external DEX).
// Does not expose PrivateLedger - mint/burn stay pad-only.
func GRC20Bank(id string) *grc20.Token {
	l := mustLaunch(id)
	if l.token == nil {
		panic("pad: no token")
	}
	return l.token
}

// SwapBuy buys tokens from the graduated internal pool with WUGNOT.
// amountWugnot: max to spend (Approve pad). minTokensOut: slippage (0 = off).
// Disabled when listed on Gnoswap (trade via router).
func SwapBuy(cur realm, id string, amountWugnot, minTokensOut int64) int64 {
	requireInit()
	sent := takeWugnotIn(cur, amountWugnot)
	l := mustLaunch(id)
	if l.Status != StatusGraduated {
		panic("pad: not graduated (use Buy)")
	}
	if l.GnoswapListed {
		panic("pad: listed on Gnoswap - trade via router, not pad SwapBuy")
	}
	buyer := cur.Previous().Address()

	fee := ammmath.ApplyFee(sent, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	tokensOut, newPU, newPT := ammmath.PoolSwapUgnotForToken(
		l.PoolUgnot, l.PoolToken, fee.Net, fee.Remainder,
	)
	requireMinOut(tokensOut, minTokensOut, "tokens out")

	// Refund unused gross if pool math used less (rare); fees from sent.
	// Pool swap uses fee.Net into pool; full sent stays as fee+pool contribution.
	l.CreatorFees += fee.Creator
	creditProtocol(fee.Protocol)
	l.PoolUgnot = newPU
	l.PoolToken = newPT
	addBal(l, buyer, tokensOut)
	noteBuyer(l, buyer)
	recordTrade(l, TradeSideBuy, sent, tokensOut)

	chain.Emit("SwapBuy",
		"id", id,
		"buyer", buyer.String(),
		"ugnot", strconv.FormatInt(sent, 10),
		"wugnot", strconv.FormatInt(sent, 10),
		"tokens", strconv.FormatInt(tokensOut, 10),
	)
	notifyTrade(cur, buyer, id, 0, sent)
	return tokensOut
}

// SwapSell sells tokens into the graduated pool for WUGNOT.
// minWugnotOut: slippage floor (0 = disabled).
func SwapSell(cur realm, id string, tokensIn, minWugnotOut int64) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if tokensIn <= 0 {
		panic("pad: tokensIn must be positive")
	}
	l := mustLaunch(id)
	if l.Status != StatusGraduated {
		panic("pad: not graduated (use Sell)")
	}
	if l.GnoswapListed {
		panic("pad: listed on Gnoswap - trade via router, not pad SwapSell")
	}
	seller := cur.Previous().Address()
	if balOf(l, seller) < tokensIn {
		panic("pad: insufficient token balance")
	}

	gross, newPU, newPT := ammmath.PoolSwapTokenForUgnot(l.PoolUgnot, l.PoolToken, tokensIn)
	fee := ammmath.ApplyFeeOnOutput(gross, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	requireMinOut(fee.Net, minWugnotOut, "wugnot out")

	// Retain fee in pool ugnot (cash stays); user gets net WUGNOT.
	l.PoolUgnot = newPU + fee.Fee
	l.PoolToken = newPT
	l.CreatorFees += fee.Creator
	creditProtocol(fee.Protocol)

	addBal(l, seller, -tokensIn)
	payWugnotOut(cur, seller, fee.Net)
	recordTrade(l, TradeSideSell, fee.Net, tokensIn)

	chain.Emit("SwapSell",
		"id", id,
		"seller", seller.String(),
		"tokens", strconv.FormatInt(tokensIn, 10),
		"ugnot", strconv.FormatInt(fee.Net, 10),
		"wugnot", strconv.FormatInt(fee.Net, 10),
	)
	notifyTrade(cur, seller, id, 1, fee.Net)
	return fee.Net
}

// Transfer moves GRC20 tokens between addresses (user-initiated).
func Transfer(cur realm, id string, to address, amount int64) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if amount <= 0 {
		panic("pad: amount must be positive")
	}
	if !to.IsValid() {
		panic("pad: invalid to")
	}
	l := mustLaunch(id)
	from := cur.Previous().Address()
	if from == to {
		panic("pad: self transfer")
	}
	if l.ledger == nil {
		panic("pad: no GRC20 ledger")
	}
	if err := l.ledger.Transfer(from, to, amount); err != nil {
		panic("pad: transfer: " + err.Error())
	}
	chain.Emit("Transfer", "id", id, "from", from.String(), "to", to.String(),
		"amount", strconv.FormatInt(amount, 10))
}

// Approve sets GRC20 allowance so DEX/contracts can TransferFrom.
func Approve(cur realm, id string, spender address, amount int64) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if !spender.IsValid() {
		panic("pad: invalid spender")
	}
	l := mustLaunch(id)
	if l.ledger == nil {
		panic("pad: no GRC20 ledger")
	}
	owner := cur.Previous().Address()
	if err := l.ledger.Approve(owner, spender, amount); err != nil {
		panic("pad: approve: " + err.Error())
	}
	chain.Emit("Approval", "id", id, "owner", owner.String(), "spender", spender.String(),
		"amount", strconv.FormatInt(amount, 10))
}

// TransferFrom spends allowance: spender = MsgCall EOA caller.
// Enables DEX / routers that hold allowance from Approve.
func TransferFrom(cur realm, id string, from, to address, amount int64) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if amount <= 0 {
		panic("pad: amount must be positive")
	}
	if !from.IsValid() || !to.IsValid() {
		panic("pad: invalid address")
	}
	if from == to {
		panic("pad: self transfer")
	}
	l := mustLaunch(id)
	if l.ledger == nil {
		panic("pad: no GRC20 ledger")
	}
	spender := cur.Previous().Address()
	if err := l.ledger.TransferFrom(from, spender, to, amount); err != nil {
		panic("pad: transferFrom: " + err.Error())
	}
	chain.Emit("TransferFrom", "id", id, "from", from.String(), "to", to.String(),
		"spender", spender.String(), "amount", strconv.FormatInt(amount, 10))
}

// ClaimCreatorFees withdraws accrued creator fees for a launch.
// Only the token creator may claim. Fees stay on pad until claimed.
func ClaimCreatorFees(cur realm, id string) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	l := mustLaunch(id)
	caller := cur.Previous().Address()
	if caller != l.Creator {
		panic("pad: not creator")
	}
	amt := l.CreatorFees
	if amt <= 0 {
		return 0
	}
	l.CreatorFees = 0
	// Production: fees accrue as WUGNOT on pad. Tests pay ugnot via payWugnotOut.
	payWugnotOut(cur, caller, amt)
	chain.Emit("ClaimCreator", "id", id, "amount", strconv.FormatInt(amt, 10))
	return amt
}

// payoutProtocolFees sends all pending protocolFees to protocolAddr.
// Shared by ClaimProtocolFees and PushProtocolFees.
func payoutProtocolFees(cur realm) int64 {
	amt := protocolFees
	if amt <= 0 {
		return 0
	}
	if !protocolAddr.IsValid() {
		panic("pad: protocol address unset")
	}
	protocolFees = 0
	protocolFeesPaid += amt
	payWugnotOut(cur, protocolAddr, amt)
	chain.Emit("ClaimProtocol",
		"to", protocolAddr.String(),
		"amount", strconv.FormatInt(amt, 10),
	)
	return amt
}

// ClaimProtocolFees withdraws pending protocol fees to protocolAddr.
// Only the current protocol treasury key may call (same wallet that Init'd,
// unless TransferProtocol was used).
func ClaimProtocolFees(cur realm) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if cur.Previous().Address() != protocolAddr {
		panic("pad: not protocol")
	}
	return payoutProtocolFees(cur)
}

// PushProtocolFees sends pending protocol fees to protocolAddr.
// Permissionless: anyone may call so treasury can be paid without the protocol
// key signing (still only pays the configured protocolAddr).
func PushProtocolFees(cur realm) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	return payoutProtocolFees(cur)
}

// TransferProtocol rotates the protocol fee recipient (current protocol only).
// Pending protocolFees stay on pad until claimed/pushed to the *new* address.
func TransferProtocol(cur realm, newAddr address) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if cur.Previous().Address() != protocolAddr {
		panic("pad: not protocol")
	}
	if !newAddr.IsValid() {
		panic("pad: invalid new protocol address")
	}
	if newAddr == protocolAddr {
		panic("pad: same protocol address")
	}
	old := protocolAddr
	protocolAddr = newAddr
	chain.Emit("TransferProtocol", "from", old.String(), "to", newAddr.String())
}

// ProtocolAddress returns the current protocol treasury address (bech32).
func ProtocolAddress() string {
	return protocolAddr.String()
}

// ProtocolFeesPaid returns lifetime ugnot already paid out to the treasury.
func ProtocolFeesPaid() int64 {
	return protocolFeesPaid
}

// FeeInfo returns protocolAddr|pendingUgnot|paidUgnot for UIs.
func FeeInfo() string {
	return protocolAddr.String() + "|" +
		strconv.FormatInt(protocolFees, 10) + "|" +
		strconv.FormatInt(protocolFeesPaid, 10)
}

// PadAddress returns this pad realm's bech32 package address (fund WUGNOT here).
func PadAddress() string {
	return padAddr.String()
}

// AdminInfo is a single-line dashboard snapshot for the ops UI:
//
//	protocolAddr|pendingFees|paidFees|reservedUgnot|launchCount|pointsOn|inited|padAddr
//
// pointsOn/inited are 0|1.
func AdminInfo() string {
	pts := "0"
	if pointsEnabled {
		pts = "1"
	}
	ini := "0"
	if inited {
		ini = "1"
	}
	return protocolAddr.String() + "|" +
		strconv.FormatInt(protocolFees, 10) + "|" +
		strconv.FormatInt(protocolFeesPaid, 10) + "|" +
		strconv.FormatInt(reservedUgnot(), 10) + "|" +
		strconv.Itoa(launches.Size()) + "|" +
		pts + "|" +
		ini + "|" +
		padAddr.String()
}

// IsProtocol reports whether addr is the current treasury (for UI gating).
func IsProtocol(addr string) bool {
	if !inited || !protocolAddr.IsValid() {
		return false
	}
	return protocolAddr.String() == addr
}

// reservedUgnot is ugnot the pad must keep to honor user/creator liabilities
// and active markets (curve raised, internal CPMM, bonds, pending fees).
func reservedUgnot() int64 {
	reserved := protocolFees
	launches.Iterate("", "", func(_ string, value any) bool {
		l := value.(*Launch)
		reserved += l.CreatorFees
		if !l.BondRefunded {
			reserved += l.BondUgnot
		}
		if l.Status == StatusCurve {
			reserved += l.RaisedUgnot
		}
		// Internal CPMM (fallback when not Gnoswap-listed) holds real ugnot.
		if l.Status == StatusGraduated && !l.GnoswapListed {
			reserved += l.PoolUgnot
		}
		return false
	})
	return reserved
}

// ReservedUgnot is ugnot the pad must keep for markets + pending claims.
func ReservedUgnot() int64 {
	return reservedUgnot()
}

// freeUgnot reports bank ugnot above reserved liabilities (0 if short/test).
func freeUgnot(cur realm) int64 {
	if testSkipBanker {
		return 0
	}
	bk := banker.NewBanker(banker.BankerTypeReadonly, cur)
	bal := bk.GetCoins(cur.Address()).AmountOf(DenomUgnot)
	free := bal - reservedUgnot()
	if free < 0 {
		return 0
	}
	return free
}

// WithdrawProtocolUgnot lets the treasury pull free ugnot from the pad bank
// (e.g. raised backlog after Gnoswap list, to re-wrap as WUGNOT inventory).
// Capped by free balance; panics if amount > free.
func WithdrawProtocolUgnot(cur realm, amount int64) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	if cur.Previous().Address() != protocolAddr {
		panic("pad: not protocol")
	}
	if amount <= 0 {
		panic("pad: amount must be positive")
	}
	free := freeUgnot(cur)
	if amount > free {
		panic("pad: amount exceeds free ugnot (reserved for markets/fees)")
	}
	sendUgnot(cur, protocolAddr, amount)
	chain.Emit("WithdrawProtocolUgnot",
		"to", protocolAddr.String(),
		"amount", strconv.FormatInt(amount, 10),
		"freeLeft", strconv.FormatInt(free-amount, 10),
	)
	return amount
}

// --- read helpers (non-crossing) ---

func BalanceOf(id string, owner address) int64 {
	return balOf(mustLaunch(id), owner)
}

// ListBuyers returns unique buyer addresses (one per line), capped for query size.
// Only addresses that bought at least once on this pad (UniqueBuyers). Not full GRC20 holders
// who received tokens via transfer.
func ListBuyers(id string) string {
	l := mustLaunch(id)
	const maxN = 100
	out := ""
	n := 0
	l.UniqueBuyers.Iterate("", "", func(key string, _ any) bool {
		if n >= maxN {
			return true
		}
		if out != "" {
			out += "\n"
		}
		out += key
		n++
		return false
	})
	return out
}

func GetStatus(id string) int {
	return mustLaunch(id).Status
}

func GetRaised(id string) int64 {
	return mustLaunch(id).RaisedUgnot
}

func GetPool(id string) (ugnot, token int64) {
	l := mustLaunch(id)
	return l.PoolUgnot, l.PoolToken
}

func GetCreatorFees(id string) int64 {
	return mustLaunch(id).CreatorFees
}

func ProtocolFees() int64 {
	return protocolFees
}

func LaunchCount() int {
	return launches.Size()
}

func ResolveSymbol(symbol string) string {
	s, ok := bySymbol.Get(symbol).(string)
	if !ok {
		return ""
	}
	return s
}

// ListIDs returns newline-separated launch IDs (sorted by AVL key / creation order).
func ListIDs() string {
	out := ""
	launches.Iterate("", "", func(key string, _ any) bool {
		if out != "" {
			out += "\n"
		}
		out += key
		return false
	})
	return out
}

// LaunchInfo returns a single-line pipe-delimited summary for UIs/indexers:
//
//	id|name|symbol|status|raised|sold|buyers|creatorFees|poolUgnot|poolToken|uri|creator|virtualUgnot|virtualToken|created|tokenID|gnoswapReady|gnoswapListed|gnoswapPoolPath|gnoswapNote
//
// status: 0=curve 1=graduated; gnoswapReady/listed: 0|1
// gnoswapNote: optional (padv12+); pipes stripped for delimiter safety.
func LaunchInfo(id string) string {
	l := mustLaunch(id)
	gs := "0"
	if l.GnoswapReady {
		gs = "1"
	}
	gl := "0"
	if l.GnoswapListed {
		gl = "1"
	}
	note := strings.ReplaceAll(l.GnoswapNote, "|", "/")
	return l.ID + "|" +
		l.Name + "|" +
		l.Symbol + "|" +
		strconv.Itoa(l.Status) + "|" +
		strconv.FormatInt(l.RaisedUgnot, 10) + "|" +
		strconv.FormatInt(l.RealSold, 10) + "|" +
		strconv.Itoa(l.BuyerCount) + "|" +
		strconv.FormatInt(l.CreatorFees, 10) + "|" +
		strconv.FormatInt(l.PoolUgnot, 10) + "|" +
		strconv.FormatInt(l.PoolToken, 10) + "|" +
		l.URI + "|" +
		l.Creator.String() + "|" +
		strconv.FormatInt(l.VirtualUgnot, 10) + "|" +
		strconv.FormatInt(l.VirtualToken, 10) + "|" +
		strconv.FormatInt(l.Created, 10) + "|" +
		l.TokenID + "|" +
		gs + "|" +
		gl + "|" +
		l.GnoswapPoolPath + "|" +
		note
}

// ParamsInfo returns parameters for UI display.
// total|curve|poolSeed|gradThreshold|feeBps|createBond|listFeeGns
// createBond is live from bond realm when not in unit-test mode.
// listFeeGns: Create-time GNS escrow required (padv20+).
func ParamsInfo() string {
	return strconv.FormatInt(TotalSupply, 10) + "|" +
		strconv.FormatInt(CurveSupply, 10) + "|" +
		strconv.FormatInt(PoolSeed, 10) + "|" +
		strconv.FormatInt(GraduationThreshold, 10) + "|" +
		strconv.FormatInt(FeeBPS, 10) + "|" +
		strconv.FormatInt(requiredCreateBond(), 10) + "|" +
		strconv.FormatInt(requiredListFeeGns(), 10)
}

// TradeHistory returns newline-separated chart points:
//
//	height|side|ugnot|tokens|priceScaled
//
// side: 0=buy 1=sell 2=open/graduate. Ordered oldest -> newest.
func TradeHistory(id string) string {
	l := mustLaunch(id)
	out := ""
	l.Trades.Iterate("", "", func(_ string, value any) bool {
		t := value.(*Trade)
		line := strconv.FormatInt(t.Height, 10) + "|" +
			strconv.Itoa(t.Side) + "|" +
			strconv.FormatInt(t.Ugnot, 10) + "|" +
			strconv.FormatInt(t.Tokens, 10) + "|" +
			strconv.FormatInt(t.Price, 10)
		if out != "" {
			out += "\n"
		}
		out += line
		return false
	})
	return out
}

// TradeCount returns number of stored chart samples for a launch.
func TradeCount(id string) int {
	return mustLaunch(id).Trades.Size()
}

// resetForTest clears package state between unit tests.
func resetForTest() {
	launches = avl.Tree{}
	bySymbol = avl.Tree{}
	nextID = 0
	nextTokenID = 0
	var zero address
	protocolAddr = zero
	// padAddr is set in package init - do not clear (realm address is fixed).
	protocolFees = 0
	protocolFeesPaid = 0
	inited = false
	pointsEnabled = false
	testSkipBanker = true // unit tests skip banker; integration/chain tests leave false
	testForceGnoswapList = false
}
