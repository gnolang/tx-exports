// Package pad is gnomemepad: a self-contained meme launchpad for gno.land.
//
// Direction A â€” factory IS the market (no external AMM required for MVP):
//
//	Create â†’ GRC20 token + bonding curve â†’ Graduate (atomic locked CPMM)
//	â†’ GRC20 is listable on Gnoswap (external DEX); pad keeps locked pool too
//
// Tokens are real GRC20 (mint on buy, burn on sell) so holders can transfer and
// later provide liquidity on Gnoswap. Hybrid of Pump.fun + permanent LP lock.
package padv7

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gnomemepad/ammmath"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/demo/defi/grc20reg"
	// pointsv2: optional trade/create awards (off by default until SetPointsEnabled).
	// Deploy prepare rewrites this import to the Sapphire personal-namespace path.
	pointsv2 "gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gnomemepad/pointsv2"
)

var (
	launches     avl.Tree // id -> *Launch
	bySymbol     avl.Tree // symbol -> id string
	nextID       seqid.ID
	nextTokenID  seqid.ID // GRC20 identity sequence (shared for all launches)
	protocolAddr address
	protocolFees int64
	inited       bool
	// testSkipBanker: when true, sendUgnot is a no-op (unit tests without funded realm bank).
	// Always false in production.
	testSkipBanker bool
	// pointsEnabled: when true, notify pointsv2 after Create / Buy / Sell / Swap*.
	// Admin must also AllowPad(this package) on pointsv2.
	pointsEnabled bool
)

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
	TokenID string // Token.ID() â€” registry / Gnoswap identity

	// Virtual curve reserves
	VirtualUgnot int64
	VirtualToken int64
	RealSold     int64 // tokens sold on curve (â‰¤ CurveSupply)
	RaisedUgnot  int64 // net ugnot collateral in curve (excl. fee vaults)

	// Real pool (post-grad); LP permanently locked â€” no remove path
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

	// Gnoswap listing readiness (GRC20 exists from Create; pool on Gnoswap is external)
	GnoswapReady bool // true after graduate â€” token may be paired on Gnoswap
	GnoswapNote  string

	// Chart history (ordered AVL keys)
	Trades    avl.Tree // tradeKey -> *Trade
	NextTrade int64
}

// Init sets the protocol treasury. First EOA caller becomes fee recipient.
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

// Create deploys a fair-launch meme. Requires CreateBondUgnot via -send.
// No pre-mint; all tradeable float starts on the bonding curve.
func Create(cur realm, name, symbol, uri string) string {
	requireInit()
	sent := requireUserPayment(cur)
	if sent < CreateBondUgnot {
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
	extra := sent - CreateBondUgnot
	if extra > 0 {
		protocolFees += extra
	}

	creator := cur.Previous().Address()
	id := nextID.Next().String()

	// Real GRC20 bound to this pad realm (mint/burn only via pad ledger).
	// Decimals=0: whole-token units (matches existing trade amounts).
	token, ledger := grc20.NewToken(name, symbol, 0, nextTokenID.Next(), cur)

	// Adena (and Gnoswap registries) resolve tokens ONLY via grc20reg under key
	// packagePath.SYMBOL â€” Token.ID() itself is packagePath.SYMBOL.seq and is
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
		BondUgnot:    CreateBondUgnot,
		Trades:       avl.Tree{},
	}
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
	)
	notifyCreate(cur, creator, id)
	return id
}

// AdenaPathOf returns the grc20reg / Adena token key: packagePath.SYMBOL
// (Token.ID is packagePath.SYMBOL.seq â€” Adena rejects that form).
func AdenaPathOf(id string) string {
	l := mustLaunch(id)
	return adenaKeyFromTokenID(l.TokenID, l.Symbol)
}

// adenaKeyFromTokenID strips the trailing .seq from Token.ID when present.
func adenaKeyFromTokenID(tokenID, symbol string) string {
	if tokenID == "" {
		return ""
	}
	// Token.ID = packagePath.symbol.seq â†’ registry key = packagePath.symbol
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

// Buy spends -send ugnot on the bonding curve; credits tokens to the caller.
// minTokensOut: slippage floor (0 = disabled). Auto-graduates at threshold.
// Oversized buys that would exceed remaining curve supply panic (no silent dust).
func Buy(cur realm, id string, minTokensOut int64) int64 {
	requireInit()
	sent := requireUserPayment(cur)
	l := mustLaunch(id)
	if l.Status != StatusCurve {
		panic("pad: not on curve (use SwapBuy)")
	}
	buyer := cur.Previous().Address()

	remaining := CurveSupply - l.RealSold
	if remaining <= 0 {
		panic("pad: curve sold out â€” call Graduate")
	}

	fee := ammmath.ApplyFee(sent, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	// Net enters curve; remainder boosts virtual ugnot (stays as collateral).
	netIn := fee.Net + fee.Remainder

	tokensOut, newVU, newVT := ammmath.BuyTokens(l.VirtualUgnot, l.VirtualToken, netIn)
	// Hard fail instead of partial fill + dust (audit Y2).
	if tokensOut > remaining {
		panic("pad: buy exceeds remaining curve supply â€” reduce amount")
	}
	requireMinOut(tokensOut, minTokensOut, "tokens out")
	checkAndAddSnipe(l, buyer, tokensOut)

	// Mutate only after all checks pass.
	l.CreatorFees += fee.Creator
	protocolFees += fee.Protocol
	l.VirtualUgnot = newVU
	l.VirtualToken = newVT
	l.RealSold += tokensOut
	l.RaisedUgnot += netIn

	addBal(l, buyer, tokensOut)
	noteBuyer(l, buyer)
	maybeRefundBond(cur, l)
	recordTrade(l, TradeSideBuy, sent, tokensOut)

	chain.Emit("Buy",
		"id", id,
		"buyer", buyer.String(),
		"ugnot", strconv.FormatInt(sent, 10),
		"tokens", strconv.FormatInt(tokensOut, 10),
	)
	notifyTrade(cur, buyer, id, 0, sent)

	if ammmath.CanGraduate(l.RaisedUgnot, GraduationThreshold) || l.RealSold >= CurveSupply {
		if l.RaisedUgnot >= GraduationThreshold {
			graduate(cur, l)
		}
	}
	return tokensOut
}

// Sell burns curve tokens and pays ugnot (fee on output).
// minUgnotOut: slippage floor (0 = disabled).
func Sell(cur realm, id string, tokensIn, minUgnotOut int64) int64 {
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
	requireMinOut(fee.Net, minUgnotOut, "ugnot out")

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
	protocolFees += fee.Protocol

	addBal(l, seller, -tokensIn)
	sendUgnot(cur, seller, fee.Net)
	recordTrade(l, TradeSideSell, fee.Net, tokensIn)

	chain.Emit("Sell",
		"id", id,
		"seller", seller.String(),
		"tokens", strconv.FormatInt(tokensIn, 10),
		"ugnot", strconv.FormatInt(fee.Net, 10),
	)
	notifyTrade(cur, seller, id, 1, fee.Net)
	return fee.Net
}

// Graduate permissionlessly moves a ready curve into a permanently locked CPMM.
func Graduate(cur realm, id string) {
	requireInit()
	l := mustLaunch(id)
	if l.Status != StatusCurve {
		panic("pad: already graduated")
	}
	if !ammmath.CanGraduate(l.RaisedUgnot, GraduationThreshold) {
		panic("pad: threshold not met")
	}
	graduate(cur, l)
}

func graduate(cur realm, l *Launch) {
	if l.Status != StatusCurve {
		return
	}
	// Seed pool: all curve collateral + remaining pool seed tokens.
	// Curve unsold tokens are not minted; only PoolSeed enters the pool.
	// Raised ugnot becomes pool ugnot (fee vaults stay separate liabilities).
	poolU := l.RaisedUgnot
	if poolU <= 0 {
		panic("pad: empty pool ugnot")
	}
	poolT := PoolSeed
	// Optional: if curve sold less than CurveSupply, unsold is never minted (dead supply).
	// Real circulating = RealSold + PoolSeed after minting pool to realm accounting.

	l.PoolUgnot = poolU
	l.PoolToken = poolT
	l.RaisedUgnot = 0
	l.VirtualUgnot = 0
	l.VirtualToken = 0
	l.Status = StatusGraduated

	// Pool tokens are held by the launch (not an address) â€” PoolToken reserve.
	// Circulating user balances remain; total effective supply = sum(balances)+PoolToken.

	// Forfeit unrefunded bond to protocol at graduation if still locked.
	if !l.BondRefunded && l.BondUgnot > 0 {
		protocolFees += l.BondUgnot
		l.BondUgnot = 0
		l.BondRefunded = true
	}

	// Mark graduation on chart at pool spot.
	recordTrade(l, TradeSideOpen, poolU, poolT)

	// GRC20 already exists and is transferable. Mark ready for external Gnoswap pool.
	// Pad keeps a locked internal CPMM; Gnoswap listing is a separate permissionless pool
	// seeded with GNOT + this GRC20 by the community/creator (see Guide).
	l.GnoswapReady = true
	l.GnoswapNote = "create GNOT/" + l.Symbol + " pool on Gnoswap with Token.ID=" + l.TokenID

	chain.Emit("Graduated",
		"id", l.ID,
		"poolUgnot", strconv.FormatInt(poolU, 10),
		"poolToken", strconv.FormatInt(poolT, 10),
		"token", l.TokenID,
		"gnoswap_ready", "1",
	)
	_ = cur // banker not needed; ugnot already on realm
}

// TokenIDOf returns the GRC20 Token.ID() for a launch.
func TokenIDOf(id string) string {
	return mustLaunch(id).TokenID
}

// GRC20Bank returns the underlying *grc20.Token for interop (metadata / external DEX).
// Does not expose PrivateLedger â€” mint/burn stay pad-only.
func GRC20Bank(id string) *grc20.Token {
	l := mustLaunch(id)
	if l.token == nil {
		panic("pad: no token")
	}
	return l.token
}

// SwapBuy buys tokens from the graduated pool with -send ugnot.
// minTokensOut: slippage floor (0 = disabled).
func SwapBuy(cur realm, id string, minTokensOut int64) int64 {
	requireInit()
	sent := requireUserPayment(cur)
	l := mustLaunch(id)
	if l.Status != StatusGraduated {
		panic("pad: not graduated (use Buy)")
	}
	buyer := cur.Previous().Address()

	fee := ammmath.ApplyFee(sent, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	tokensOut, newPU, newPT := ammmath.PoolSwapUgnotForToken(
		l.PoolUgnot, l.PoolToken, fee.Net, fee.Remainder,
	)
	requireMinOut(tokensOut, minTokensOut, "tokens out")

	l.CreatorFees += fee.Creator
	protocolFees += fee.Protocol
	l.PoolUgnot = newPU
	l.PoolToken = newPT
	addBal(l, buyer, tokensOut)
	noteBuyer(l, buyer)
	recordTrade(l, TradeSideBuy, sent, tokensOut)

	chain.Emit("SwapBuy",
		"id", id,
		"buyer", buyer.String(),
		"ugnot", strconv.FormatInt(sent, 10),
		"tokens", strconv.FormatInt(tokensOut, 10),
	)
	notifyTrade(cur, buyer, id, 0, sent)
	return tokensOut
}

// SwapSell sells tokens into the graduated pool for ugnot.
// minUgnotOut: slippage floor (0 = disabled).
func SwapSell(cur realm, id string, tokensIn, minUgnotOut int64) int64 {
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
	seller := cur.Previous().Address()
	if balOf(l, seller) < tokensIn {
		panic("pad: insufficient token balance")
	}

	gross, newPU, newPT := ammmath.PoolSwapTokenForUgnot(l.PoolUgnot, l.PoolToken, tokensIn)
	fee := ammmath.ApplyFeeOnOutput(gross, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	requireMinOut(fee.Net, minUgnotOut, "ugnot out")

	// Retain fee in pool ugnot (cash stays); user gets net.
	l.PoolUgnot = newPU + fee.Fee
	l.PoolToken = newPT
	l.CreatorFees += fee.Creator
	protocolFees += fee.Protocol

	addBal(l, seller, -tokensIn)
	sendUgnot(cur, seller, fee.Net)
	recordTrade(l, TradeSideSell, fee.Net, tokensIn)

	chain.Emit("SwapSell",
		"id", id,
		"seller", seller.String(),
		"tokens", strconv.FormatInt(tokensIn, 10),
		"ugnot", strconv.FormatInt(fee.Net, 10),
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
	sendUgnot(cur, caller, amt)
	chain.Emit("ClaimCreator", "id", id, "amount", strconv.FormatInt(amt, 10))
	return amt
}

// ClaimProtocolFees withdraws protocol treasury fees.
func ClaimProtocolFees(cur realm) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pad: must be EOA MsgCall")
	}
	caller := cur.Previous().Address()
	if caller != protocolAddr {
		panic("pad: not protocol")
	}
	amt := protocolFees
	if amt <= 0 {
		return 0
	}
	protocolFees = 0
	sendUgnot(cur, caller, amt)
	chain.Emit("ClaimProtocol", "amount", strconv.FormatInt(amt, 10))
	return amt
}

// TransferProtocol rotates the protocol fee recipient (current protocol only).
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

// ProtocolAddress returns the current protocol treasury address.
func ProtocolAddress() string {
	return protocolAddr.String()
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
//	id|name|symbol|status|raised|sold|buyers|creatorFees|poolUgnot|poolToken|uri|creator|virtualUgnot|virtualToken|created|tokenID|gnoswapReady
//
// status: 0=curve 1=graduated; gnoswapReady: 0|1
func LaunchInfo(id string) string {
	l := mustLaunch(id)
	gs := "0"
	if l.GnoswapReady {
		gs = "1"
	}
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
		gs
}

// ParamsInfo returns fixed MVP parameters for UI display.
// total|curve|poolSeed|gradThreshold|feeBps|createBond
func ParamsInfo() string {
	return strconv.FormatInt(TotalSupply, 10) + "|" +
		strconv.FormatInt(CurveSupply, 10) + "|" +
		strconv.FormatInt(PoolSeed, 10) + "|" +
		strconv.FormatInt(GraduationThreshold, 10) + "|" +
		strconv.FormatInt(FeeBPS, 10) + "|" +
		strconv.FormatInt(CreateBondUgnot, 10)
}

// TradeHistory returns newline-separated chart points:
//
//	height|side|ugnot|tokens|priceScaled
//
// side: 0=buy 1=sell 2=open/graduate. Ordered oldest â†’ newest.
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
	protocolFees = 0
	inited = false
	pointsEnabled = false
	testSkipBanker = true // unit tests skip banker; integration/chain tests leave false
}
