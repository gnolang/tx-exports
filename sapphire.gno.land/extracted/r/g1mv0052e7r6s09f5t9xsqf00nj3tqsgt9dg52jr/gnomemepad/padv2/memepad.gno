// Package pad is gnomemepad: a self-contained meme launchpad for gno.land.
//
// Direction A â€” factory IS the market (no external AMM required for MVP):
//
//	Create â†’ GRC20 token + bonding curve â†’ Graduate (atomic locked CPMM)
//	â†’ GRC20 is listable on Gnoswap (external DEX); pad keeps locked pool too
//
// Tokens are real GRC20 (mint on buy, burn on sell) so holders can transfer and
// later provide liquidity on Gnoswap. Hybrid of Pump.fun + permanent LP lock.
package padv2

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gnomemepad/ammmath"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
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
type Launch struct {
	ID      string
	Name    string
	Symbol  string
	URI     string
	Creator address
	Status  int
	Created int64 // block height

	// GRC20 (mint/burn via pad; transferable off-pad after buy)
	Token   *grc20.Token
	Ledger  *grc20.PrivateLedger
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
	UniqueBuyers avl.Tree
	BuyerCount   int

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

func mustLaunch(id string) *Launch {
	// Sapphire avl.Tree.Get returns a single any (nil if missing).
	l, ok := launches.Get(id).(*Launch)
	if !ok {
		panic("pad: unknown launch")
	}
	return l
}

func balOf(l *Launch, addr address) int64 {
	if l == nil || l.Token == nil {
		return 0
	}
	return l.Token.BalanceOf(addr)
}

// addBal mints (delta>0) or burns (delta<0) GRC20 via pad-owned PrivateLedger.
func addBal(l *Launch, addr address, delta int64) {
	if l == nil || l.Ledger == nil {
		panic("pad: missing GRC20 ledger")
	}
	if delta == 0 {
		return
	}
	if delta > 0 {
		if err := l.Ledger.Mint(addr, delta); err != nil {
			panic("pad: mint: " + err.Error())
		}
		return
	}
	if err := l.Ledger.Burn(addr, -delta); err != nil {
		panic("pad: burn: " + err.Error())
	}
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

	l := &Launch{
		ID:           id,
		Name:         name,
		Symbol:       symbol,
		URI:          uri,
		Creator:      creator,
		Status:       StatusCurve,
		Created:      runtime.ChainHeight(),
		Token:        token,
		Ledger:       ledger,
		TokenID:      token.ID(),
		VirtualUgnot: VirtualUgnot0,
		VirtualToken: VirtualToken0,
		UniqueBuyers: avl.Tree{},
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
	)
	return id
}

// Buy spends -send ugnot on the bonding curve; credits tokens to the caller.
// Auto-graduates when RaisedUgnot >= GraduationThreshold.
func Buy(cur realm, id string) int64 {
	requireInit()
	sent := requireUserPayment(cur)
	l := mustLaunch(id)
	if l.Status != StatusCurve {
		panic("pad: not on curve (use SwapBuy)")
	}
	buyer := cur.Previous().Address()
	height := runtime.ChainHeight()

	remaining := CurveSupply - l.RealSold
	if remaining <= 0 {
		panic("pad: curve sold out â€” call Graduate")
	}

	fee := ammmath.ApplyFee(sent, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	// Net enters curve; remainder boosts virtual ugnot (stays as collateral).
	netIn := fee.Net + fee.Remainder

	tokensOut, newVU, newVT := ammmath.BuyTokens(l.VirtualUgnot, l.VirtualToken, netIn)
	// Cap at remaining curve float (large buys can outrun CurveSupply on virtual CPMM).
	if tokensOut > remaining {
		lo, hi := int64(1), netIn
		bestTok, bestVU, bestVT, bestNet := int64(0), l.VirtualUgnot, l.VirtualToken, int64(0)
		for lo <= hi {
			mid := (lo + hi) / 2
			tok, vu, vt := ammmath.BuyTokens(l.VirtualUgnot, l.VirtualToken, mid)
			if tok <= remaining {
				bestTok, bestVU, bestVT, bestNet = tok, vu, vt, mid
				lo = mid + 1
			} else {
				hi = mid - 1
			}
		}
		if bestTok <= 0 {
			panic("pad: buy too large for remaining curve supply")
		}
		tokensOut, newVU, newVT, netIn = bestTok, bestVU, bestVT, bestNet
		// MVP: full `sent` still paid; excess stays in realm as protocol dust.
		_ = sent
	}
	if height-l.Created < AntiSnipeHeights {
		maxTok := TotalSupply * AntiSnipeMaxBuyBPS / 10000
		if tokensOut > maxTok {
			panic("pad: anti-snipe max buy exceeded")
		}
	}

	// Mutate only after all checks pass.
	l.CreatorFees += fee.Creator
	protocolFees += fee.Protocol
	l.VirtualUgnot = newVU
	l.VirtualToken = newVT
	l.RealSold += tokensOut
	raisedAdd := netIn
	if raisedAdd > fee.Net+fee.Remainder {
		raisedAdd = fee.Net + fee.Remainder
	}
	l.RaisedUgnot += raisedAdd

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

	if ammmath.CanGraduate(l.RaisedUgnot, GraduationThreshold) || l.RealSold >= CurveSupply {
		if l.RaisedUgnot >= GraduationThreshold {
			graduate(cur, l)
		}
	}
	return tokensOut
}

// Sell burns curve tokens and pays ugnot (fee on output).
func Sell(cur realm, id string, tokensIn int64) int64 {
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
	// remainder stays inside Raised/virtual (already in fee.Fee re-add portion for remainder+vaults)
	// Raised should still include remainder: payOut excludes remainder âœ“
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
func GRC20Bank(id string) *grc20.Token {
	l := mustLaunch(id)
	if l.Token == nil {
		panic("pad: no token")
	}
	return l.Token
}

// SwapBuy buys tokens from the graduated pool with -send ugnot.
func SwapBuy(cur realm, id string) int64 {
	requireInit()
	sent := requireUserPayment(cur)
	l := mustLaunch(id)
	if l.Status != StatusGraduated {
		panic("pad: not graduated (use Buy)")
	}
	buyer := cur.Previous().Address()

	fee := ammmath.ApplyFee(sent, FeeBPS, CreatorFeeShareBPS, ProtocolFeeShareBPS)
	l.CreatorFees += fee.Creator
	protocolFees += fee.Protocol

	tokensOut, newPU, newPT := ammmath.PoolSwapUgnotForToken(
		l.PoolUgnot, l.PoolToken, fee.Net, fee.Remainder,
	)
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
	return tokensOut
}

// SwapSell sells tokens into the graduated pool for ugnot.
func SwapSell(cur realm, id string, tokensIn int64) int64 {
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
	if l.Ledger == nil {
		panic("pad: no GRC20 ledger")
	}
	// Proper GRC20 transfer (not mint/burn).
	if err := l.Ledger.Transfer(from, to, amount); err != nil {
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
	if l.Ledger == nil {
		panic("pad: no GRC20 ledger")
	}
	owner := cur.Previous().Address()
	if err := l.Ledger.Approve(owner, spender, amount); err != nil {
		panic("pad: approve: " + err.Error())
	}
	chain.Emit("Approval", "id", id, "owner", owner.String(), "spender", spender.String(),
		"amount", strconv.FormatInt(amount, 10))
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

// --- read helpers (non-crossing) ---

func BalanceOf(id string, owner address) int64 {
	return balOf(mustLaunch(id), owner)
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
	var zero address
	protocolAddr = zero
	protocolFees = 0
	inited = false
	testSkipBanker = true // unit tests skip banker; integration/chain tests leave false
}
