// Package pado is a launchpad template with no trade tax.
//
// One deployment is one realm and one WUGNOT purse. A creator copies this
// package into their own namespace with MsgAddPackage (gno.land/r/<creator>/pado).
// That purse is not padv3 and not any other creator's pad. This package cannot
// spawn those realms itself.
//
// Inside one realm, each token has its own raise target and its own quote
// reserve. Sell and SwapSell pay only from that token's reserve. The bank
// balance is still a single number; the books are what keep launches apart.
//
// Create locks raiseUgnot. Buy and Sell take no fee. At the target, Graduate
// moves that token's quote into an internal pool in this same realm. There is
// no Gnoswap list and no zDex list, and the owner cannot withdraw the raise.
//
// Payment: the user wugnot.Transfer's to this realm, then calls Buy or SwapBuy
// with the same amount. A partial fill leaves the rest as that caller's prepaid
// credit (ClaimWugnot). Pass the amount you transferred. Coins that sit here
// without a Buy can be locked by the next Buy caller, same as padv3.
package pado

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/pado/ammmath"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/gnoland/wugnot"
)

var (
	launches    avl.Tree // id -> *launch
	bySymbol    avl.Tree // symbol -> id
	nextID      seqid.ID
	nextTokenID seqid.ID

	padAddr address
	owner   address

	prepaid      avl.Tree // caller -> int64 claimable WUGNOT
	totalPrepaid int64

	// testSkipBanker is set only by resetState in tests. Production stays false.
	testSkipBanker bool
	testBank       int64
)

func init(cur realm) {
	padAddr = cur.Address()
	caller := unsafe.OriginCaller()
	if caller.IsValid() {
		owner = caller
	}
}

// Init sets the owner when deploy did not capture one. One shot.
func Init(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("pado: must be EOA MsgCall")
	}
	if owner.IsValid() {
		panic("pado: owner already set")
	}
	owner = cur.Previous().Address()
	chain.Emit("Owner", "owner", owner.String())
}

// TransferAdmin rotates the launchpad owner. The raise stays in the realm.
func TransferAdmin(cur realm, next address) {
	requireOwner(cur)
	if !next.IsValid() {
		panic("pado: bad owner")
	}
	owner = next
	chain.Emit("Owner", "owner", owner.String())
}

// Create opens one token. raiseUgnot is the quote this curve locks before
// graduate, in ugnot. Only the realm owner may call. The value is fixed here.
func Create(cur realm, name, symbol, uri string, raiseUgnot int64) string {
	requireOwner(cur)
	name = strings.TrimSpace(name)
	symbol = strings.TrimSpace(symbol)
	if len(uri) > MaxURILen {
		panic("pado: uri too long")
	}
	if strings.Contains(uri, "\n") || strings.Contains(uri, "\r") {
		panic("pado: bad uri")
	}
	if bySymbol.Has(symbol) {
		panic("pado: symbol taken")
	}
	vu0, target := seedForRaise(raiseUgnot)
	id := formatID(nextID.Next())
	token, ledger := grc20.NewToken(name, symbol, 0, nextTokenID.Next(), cur)
	l := &launch{
		id:             id,
		name:           name,
		symbol:         symbol,
		uri:            uri,
		creator:        cur.Previous().Address(),
		status:         StatusCurve,
		created:        runtime.ChainHeight(),
		requestedRaise: raiseUgnot,
		raiseUgnot:     target,
		virtualUgnot0:  vu0,
		virtualUgnot:   vu0,
		virtualToken:   VirtualToken0,
		token:          token,
		ledger:         ledger,
	}
	launches.Set(id, l)
	bySymbol.Set(symbol, id)
	chain.Emit("Create",
		"id", id,
		"symbol", symbol,
		"creator", l.creator.String(),
		"requested", strconv.FormatInt(raiseUgnot, 10),
		"raise", strconv.FormatInt(target, 10),
		"virtualUgnot0", strconv.FormatInt(vu0, 10),
	)
	return id
}

// Buy spends up to amount WUGNOT on the curve and mints tokens to the caller.
// No fee. A fill that reaches the raise graduates inside this call.
func Buy(cur realm, id string, amount, minTokensOut int64) int64 {
	payer := requireEOA(cur)
	l := mustLaunch(id)
	if amount <= 0 {
		panic("pado: amount must be positive")
	}
	if minTokensOut < 0 {
		panic("pado: minOut negative")
	}
	creditOrigin(cur)
	lockPrepaid(payer, amount)

	if l.status != StatusCurve {
		panic("pado: not on curve (use SwapBuy)")
	}
	need := l.raiseUgnot - l.raisedUgnot
	left := CurveSupply - l.realSold
	if need <= 0 || left <= 0 {
		if ready(l) {
			graduate(l)
		}
		return 0
	}

	used := amount
	if used > need {
		used = need
	}
	maxIn := ammmath.MaxNetInForTokenOut(l.virtualUgnot, l.virtualToken, left)
	if maxIn <= 0 {
		panic("pado: no curve capacity")
	}
	if used > maxIn {
		used = maxIn
	}
	tokens, _, newVT := ammmath.BuyTokens(l.virtualUgnot, l.virtualToken, used)
	for tokens > left && used > 1 {
		used--
		tokens, _, newVT = ammmath.BuyTokens(l.virtualUgnot, l.virtualToken, used)
	}
	if tokens <= 0 || tokens > left {
		panic("pado: cannot fill curve")
	}
	if minTokensOut > 0 && tokens < minTokensOut {
		panic("pado: tokens below minOut")
	}
	checkSnipe(l, payer, tokens)

	subPrepaid(payer, used)
	l.raisedUgnot += used
	l.virtualUgnot = l.virtualUgnot0 + l.raisedUgnot
	l.virtualToken = newVT
	l.realSold += tokens
	mint(l, payer, tokens)
	chain.Emit("Buy",
		"id", id,
		"buyer", payer.String(),
		"ugnot", strconv.FormatInt(used, 10),
		"tokens", strconv.FormatInt(tokens, 10),
	)
	if ready(l) {
		graduate(l)
	}
	return tokens
}

// Sell burns curve tokens and returns the quote this launch holds. No fee.
// Payout is capped at this launch's raised quote, so a rounding step cannot
// spend another launch's WUGNOT or the virtual seed.
func Sell(cur realm, id string, tokensIn, minUgnotOut int64) int64 {
	seller := requireEOA(cur)
	l := mustLaunch(id)
	if l.status != StatusCurve {
		panic("pado: not on curve (use SwapSell)")
	}
	if tokensIn <= 0 {
		panic("pado: tokensIn must be positive")
	}
	if minUgnotOut < 0 {
		panic("pado: minOut negative")
	}
	if bal(l, seller) < tokensIn {
		panic("pado: insufficient token balance")
	}
	quote, _, newVT := ammmath.SellTokens(l.virtualUgnot, l.virtualToken, tokensIn)
	if quote > l.raisedUgnot {
		quote = l.raisedUgnot
	}
	if quote <= 0 {
		panic("pado: no quote out")
	}
	if minUgnotOut > 0 && quote < minUgnotOut {
		panic("pado: ugnot below minOut")
	}
	l.raisedUgnot -= quote
	l.virtualUgnot = l.virtualUgnot0 + l.raisedUgnot
	l.virtualToken = newVT
	l.realSold -= tokensIn
	if l.realSold < 0 {
		l.realSold = 0
	}
	burn(l, seller, tokensIn)
	payOut(cur, seller, quote)
	chain.Emit("Sell",
		"id", id,
		"seller", seller.String(),
		"tokens", strconv.FormatInt(tokensIn, 10),
		"ugnot", strconv.FormatInt(quote, 10),
	)
	return quote
}

// Graduate moves a filled curve into this realm's internal pool.
// The quote stays on this token's books. Anyone may call it once ready.
func Graduate(cur realm, id string) {
	requireEOA(cur)
	l := mustLaunch(id)
	if l.status != StatusCurve {
		panic("pado: already graduated")
	}
	if !ready(l) {
		panic("pado: not ready to graduate")
	}
	graduate(l)
}

// SwapBuy buys from the post-graduate pool. No fee.
func SwapBuy(cur realm, id string, amount, minTokensOut int64) int64 {
	buyer := requireEOA(cur)
	l := mustLaunch(id)
	if l.status != StatusGraduated {
		panic("pado: not graduated")
	}
	if amount <= 0 {
		panic("pado: amount must be positive")
	}
	if minTokensOut < 0 {
		panic("pado: minOut negative")
	}
	creditOrigin(cur)
	lockPrepaid(buyer, amount)
	tokens, newU, newT := ammmath.PoolSwapUgnotForToken(l.poolUgnot, l.poolToken, amount, 0)
	if minTokensOut > 0 && tokens < minTokensOut {
		panic("pado: tokens below minOut")
	}
	subPrepaid(buyer, amount)
	l.poolUgnot = newU
	l.poolToken = newT
	mint(l, buyer, tokens)
	chain.Emit("SwapBuy",
		"id", id,
		"buyer", buyer.String(),
		"ugnot", strconv.FormatInt(amount, 10),
		"tokens", strconv.FormatInt(tokens, 10),
	)
	return tokens
}

// SwapSell sells into the post-graduate pool. No fee.
// Pays only from this launch's pool quote.
func SwapSell(cur realm, id string, tokensIn, minUgnotOut int64) int64 {
	seller := requireEOA(cur)
	l := mustLaunch(id)
	if l.status != StatusGraduated {
		panic("pado: not graduated")
	}
	if tokensIn <= 0 {
		panic("pado: tokensIn must be positive")
	}
	if minUgnotOut < 0 {
		panic("pado: minOut negative")
	}
	if bal(l, seller) < tokensIn {
		panic("pado: insufficient token balance")
	}
	quote, newU, newT := ammmath.PoolSwapTokenForUgnot(l.poolUgnot, l.poolToken, tokensIn)
	if quote > l.poolUgnot {
		panic("pado: pool quote")
	}
	if minUgnotOut > 0 && quote < minUgnotOut {
		panic("pado: ugnot below minOut")
	}
	l.poolUgnot = newU
	l.poolToken = newT
	burn(l, seller, tokensIn)
	payOut(cur, seller, quote)
	chain.Emit("SwapSell",
		"id", id,
		"seller", seller.String(),
		"tokens", strconv.FormatInt(tokensIn, 10),
		"ugnot", strconv.FormatInt(quote, 10),
	)
	return quote
}

// ClaimWugnot withdraws the caller's prepaid remainder. It does not withdraw
// a launch's raised quote or pool.
func ClaimWugnot(cur realm) int64 {
	user := requireEOA(cur)
	amt := prepaidOf(user)
	if amt <= 0 {
		return 0
	}
	subPrepaid(user, amt)
	payOut(cur, user, amt)
	chain.Emit("ClaimWugnot", "user", user.String(), "amount", strconv.FormatInt(amt, 10))
	return amt
}

// Transfer moves this realm's token. The quote reserve does not move.
func Transfer(cur realm, id string, to address, amount int64) {
	from := requireEOA(cur)
	l := mustLaunch(id)
	if err := l.ledger.Transfer(from, to, amount); err != nil {
		panic(err.Error())
	}
	chain.Emit("Transfer", "id", id, "from", from.String(), "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// Approve lets spender TransferFrom the caller's tokens.
func Approve(cur realm, id string, spender address, amount int64) {
	caller := requireEOA(cur)
	l := mustLaunch(id)
	if err := l.ledger.Approve(caller, spender, amount); err != nil {
		panic(err.Error())
	}
}

// TransferFrom spends the caller's allowance.
func TransferFrom(cur realm, id string, from, to address, amount int64) {
	spender := requireEOA(cur)
	l := mustLaunch(id)
	if err := l.ledger.TransferFrom(from, spender, to, amount); err != nil {
		panic(err.Error())
	}
	chain.Emit("TransferFrom", "id", id, "from", from.String(), "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

func Owner() address     { return owner }
func RealmAddr() address { return padAddr }
func RaiseOf(id string) int64 {
	return mustLaunch(id).raiseUgnot
}
func RequestedRaiseOf(id string) int64 {
	return mustLaunch(id).requestedRaise
}
func RaisedOf(id string) int64 { return mustLaunch(id).raisedUgnot }
func StatusOf(id string) int   { return mustLaunch(id).status }
func SoldOf(id string) int64   { return mustLaunch(id).realSold }
func VirtualOf(id string) (vu0, vu, vt int64) {
	l := mustLaunch(id)
	return l.virtualUgnot0, l.virtualUgnot, l.virtualToken
}
func PoolOf(id string) (ugnot, tokens int64) {
	l := mustLaunch(id)
	return l.poolUgnot, l.poolToken
}
func BalanceOf(id string, addr address) int64 {
	return bal(mustLaunch(id), addr)
}
func Allowance(id string, who, spender address) int64 {
	return mustLaunch(id).token.Allowance(who, spender)
}
func PrepaidOf(addr address) int64 { return prepaidOf(addr) }
func ResolveSymbol(symbol string) string {
	v := bySymbol.Get(symbol)
	if v == nil {
		return ""
	}
	id, ok := v.(string)
	if !ok {
		panic("pado: bad symbol index")
	}
	return id
}

// launch is one token book. token and ledger stay unexported so other
// packages cannot mint.
type launch struct {
	id             string
	name           string
	symbol         string
	uri            string
	creator        address
	status         int
	created        int64
	requestedRaise int64
	raiseUgnot     int64
	virtualUgnot0  int64
	virtualUgnot   int64
	virtualToken   int64
	raisedUgnot    int64
	realSold       int64
	poolUgnot      int64
	poolToken      int64
	leftover       int64
	token          *grc20.Token
	ledger         *grc20.PrivateLedger
	snipe          avl.Tree
}

func seedForRaise(raise int64) (vu0, target int64) {
	if raise < MinRaiseUgnot || raise > MaxRaiseUgnot {
		panic("pado: raise out of range")
	}
	span := VirtualToken0 - CurveSupply
	vu0 = ammmath.MulDiv(raise, span, CurveSupply)
	if vu0 <= 0 {
		panic("pado: raise too small for curve")
	}
	target = ammmath.MulDiv(vu0, CurveSupply, span)
	if target <= 0 || target > raise {
		panic("pado: raise not reachable")
	}
	return vu0, target
}

func ready(l *launch) bool {
	if l.raisedUgnot >= l.raiseUgnot && l.raiseUgnot > 0 {
		return true
	}
	return l.realSold >= CurveSupply && l.raisedUgnot > 0
}

func graduate(l *launch) {
	if l.status != StatusCurve {
		return
	}
	poolU := l.raisedUgnot
	if poolU <= 0 {
		panic("pado: empty pool quote")
	}
	remaining := TotalSupply - l.realSold
	if remaining <= 0 {
		panic("pado: no tokens for pool")
	}
	poolT := remaining
	if l.virtualUgnot > 0 && l.virtualToken > 0 {
		needed := ammmath.MulDiv(poolU, l.virtualToken, l.virtualUgnot)
		if needed > 0 && needed < remaining {
			poolT = needed
		}
	}
	l.poolUgnot = poolU
	l.poolToken = poolT
	l.leftover = remaining - poolT
	l.raisedUgnot = 0
	l.virtualUgnot = 0
	l.virtualToken = 0
	l.status = StatusGraduated
	chain.Emit("Graduated",
		"id", l.id,
		"poolUgnot", strconv.FormatInt(poolU, 10),
		"poolToken", strconv.FormatInt(poolT, 10),
		"leftover", strconv.FormatInt(l.leftover, 10),
	)
}

func requireEOA(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("pado: must be EOA MsgCall")
	}
	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("pado: bad caller")
	}
	return caller
}

func requireOwner(cur realm) {
	caller := requireEOA(cur)
	if !owner.IsValid() || caller != owner {
		panic("pado: owner only")
	}
}

func mustLaunch(id string) *launch {
	v := launches.Get(id)
	if v == nil {
		panic("pado: unknown launch")
	}
	l, ok := v.(*launch)
	if !ok || l == nil {
		panic("pado: bad launch")
	}
	return l
}

func bal(l *launch, addr address) int64 {
	if l.token == nil {
		panic("pado: missing token")
	}
	return l.token.BalanceOf(addr)
}

func mint(l *launch, addr address, amount int64) {
	if l.ledger == nil {
		panic("pado: missing ledger")
	}
	if err := l.ledger.Mint(addr, amount); err != nil {
		panic(err.Error())
	}
}

func burn(l *launch, addr address, amount int64) {
	if err := l.ledger.Burn(addr, amount); err != nil {
		panic(err.Error())
	}
}

func checkSnipe(l *launch, buyer address, tokens int64) {
	if runtime.ChainHeight()-l.created >= AntiSnipeHeights {
		return
	}
	maxTok := TotalSupply * AntiSnipeMaxBuyBPS / 10000
	prev := snipeOf(l, buyer)
	if prev+tokens > maxTok {
		panic("pado: anti-snipe max buy")
	}
	l.snipe.Set(buyer.String(), prev+tokens)
}

func snipeOf(l *launch, buyer address) int64 {
	v := l.snipe.Get(buyer.String())
	if v == nil {
		return 0
	}
	n, ok := v.(int64)
	if !ok {
		panic("pado: bad snipe book")
	}
	return n
}

func reservedWugnot() int64 {
	n := totalPrepaid
	launches.Iterate("", "", func(_ string, value any) bool {
		l, ok := value.(*launch)
		if !ok || l == nil {
			panic("pado: bad launch")
		}
		if l.status == StatusCurve {
			n += l.raisedUgnot
		}
		if l.status == StatusGraduated {
			n += l.poolUgnot
		}
		return false
	})
	return n
}

func bankBal() int64 {
	if testSkipBanker {
		return testBank
	}
	return wugnot.BalanceOf(padAddr)
}

func freeWugnot() int64 {
	have := bankBal()
	res := reservedWugnot()
	if have < res {
		panic("pado: reserve exceeds balance")
	}
	return have - res
}

// creditOrigin attributes this tx's ugnot to the caller in tests, where
// OriginSend stands in for a prior wugnot.Transfer.
func creditOrigin(cur realm) {
	if !testSkipBanker {
		return
	}
	sent := unsafe.OriginSend().AmountOf(DenomUgnot)
	if sent < 0 {
		panic("pado: bad origin send")
	}
	if sent == 0 {
		return
	}
	addPrepaid(cur.Previous().Address(), sent)
	testBank += sent
}

func lockPrepaid(user address, amount int64) {
	have := prepaidOf(user)
	if have >= amount {
		return
	}
	need := amount - have
	if freeWugnot() < need {
		panic("pado: transfer WUGNOT to this realm, then buy")
	}
	addPrepaid(user, need)
}

func prepaidOf(addr address) int64 {
	if !addr.IsValid() {
		return 0
	}
	v := prepaid.Get(addr.String())
	if v == nil {
		return 0
	}
	n, ok := v.(int64)
	if !ok {
		panic("pado: bad prepaid book")
	}
	return n
}

func addPrepaid(addr address, amount int64) {
	if amount <= 0 {
		return
	}
	next := prepaidOf(addr) + amount
	prepaid.Set(addr.String(), next)
	totalPrepaid += amount
}

func subPrepaid(addr address, amount int64) {
	if amount <= 0 {
		return
	}
	have := prepaidOf(addr)
	if have < amount {
		panic("pado: prepaid underfunded")
	}
	next := have - amount
	if next == 0 {
		prepaid.Remove(addr.String())
	} else {
		prepaid.Set(addr.String(), next)
	}
	totalPrepaid -= amount
}

func payOut(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	if freeWugnot() < amount {
		panic("pado: insufficient free WUGNOT")
	}
	if testSkipBanker {
		testBank -= amount
		if testBank < 0 {
			panic("pado: negative test bank")
		}
		return
	}
	wugnot.Transfer(cross(cur), to, amount)
}

func formatID(n seqid.ID) string {
	s := strconv.FormatUint(uint64(n), 10)
	for len(s) < 7 {
		s = "0" + s
	}
	return s
}
