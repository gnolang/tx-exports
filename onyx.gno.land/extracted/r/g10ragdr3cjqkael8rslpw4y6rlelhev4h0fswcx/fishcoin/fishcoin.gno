// Package shoaltoken is the Shoal FISH ledger. Init mints a fixed supply and
// no later call can mint. Wallet Transfer, Approve, and TransferFrom move the
// full amount. BuyTaxBps and SellTaxBps are stored for a later pool realm.
// They do not tax a wallet transfer, a cheer, a season reward, or a community claim.
//
// The symbol is FISH, the same letters as the fish NFT collection. A wallet
// that keys only on the symbol can confuse the two. The chain identity is
// TokenID: the realm path, the symbol, and the sequence.
//
// Deployed on onyx-1 at gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/shoal/shoaltoken.
// An earlier copy remains at gno.land/r/g10ragdr3cjqkael8rslpw4y6rlelhev4h0fswcx/shoaltoken.
// Init is a separate call. It does not register this token.
package fishcoin

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ownable/v0"
)

const (
	unit            int64 = 1_000_000
	supplyWhole     int64 = 100_000_000
	seasonWhole     int64 = 43_000_000
	liquidityWhole  int64 = 20_000_000
	ecosystemWhole  int64 = 15_000_000
	communityWhole  int64 = 12_000_000
	teamWhole       int64 = 10_000_000
	maxBuyTaxBps    int64 = 500
	maxSellTaxBps   int64 = 1000
	defaultBuyTax   int64 = 200
	defaultSellTax  int64 = 400
)

var (
	token     *grc20.Token
	ledger    *grc20.PrivateLedger
	admin     *ownable.Ownable
	inited     bool
	sealed     bool
	spender    address
	spenderSet bool
	buyTaxBps  int64 = defaultBuyTax
	sellTaxBps int64 = defaultSellTax
)

// Init mints the fixed supply once and seals the ledger. The five treasuries must be distinct.
func Init(cur realm, season, liquidity, ecosystem, community, team address) {
	if !cur.IsCurrent() {
		panic("shoaltoken: realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("shoaltoken: eoa")
	}
	takeExact(0)
	if inited {
		panic("shoaltoken: init")
	}
	if !distinct(season, liquidity, ecosystem, community, team) {
		panic("shoaltoken: addr")
	}
	tok, led := grc20.NewToken("Shoal FISH", "FISH", 6, 0, cur)
	credit(led, season, seasonWhole*unit)
	credit(led, liquidity, liquidityWhole*unit)
	credit(led, ecosystem, ecosystemWhole*unit)
	credit(led, community, communityWhole*unit)
	credit(led, team, teamWhole*unit)
	if tok.TotalSupply() != supplyWhole*unit {
		panic("shoaltoken: supply")
	}
	token = tok
	ledger = led
	admin = ownable.NewWithAddress(cur.Previous().Address())
	inited = true
	sealed = true
	chain.Emit(
		"Init",
		"token", tok.ID(),
		"admin", cur.Previous().Address().String(),
		"supply", strconv.FormatInt(supplyWhole*unit, 10),
	)
}

// Transfer moves FISH from the caller to to. The amount is not taxed.
func Transfer(cur realm, to address, amount int64) {
	requireUser(cur)
	takeExact(0)
	requireReady()
	must(ledger.CallerTeller().Transfer(0, cur, to, amount))
	chain.Emit("Send", "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// Approve lets spender move up to amount from the caller. This replaces the previous allowance.
func Approve(cur realm, spender address, amount int64) {
	requireUser(cur)
	takeExact(0)
	requireReady()
	must(ledger.CallerTeller().Approve(0, cur, spender, amount))
	chain.Emit("Approve", "spender", spender.String(), "amount", strconv.FormatInt(amount, 10))
}

// TransferFrom moves amount from owner to to, using the caller's allowance. The amount is not taxed.
func TransferFrom(cur realm, owner, to address, amount int64) {
	requireUser(cur)
	takeExact(0)
	requireReady()
	must(ledger.CallerTeller().TransferFrom(0, cur, owner, to, amount))
	chain.Emit("SendFrom", "owner", owner.String(), "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// SetBuyTaxBps stores the buy tax for a later pool. The cap is 500 bps. This does not tax wallets.
func SetBuyTaxBps(cur realm, next int64) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	if !admin.OwnedBy(caller) {
		panic("shoaltoken: admin")
	}
	if next < 0 || next > maxBuyTaxBps {
		panic("shoaltoken: tax")
	}
	buyTaxBps = next
	chain.Emit("SetBuyTaxBps", "bps", strconv.FormatInt(next, 10))
}

// SetSellTaxBps stores the sell tax for a later pool. The cap is 1000 bps. This does not tax wallets.
func SetSellTaxBps(cur realm, next int64) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	if !admin.OwnedBy(caller) {
		panic("shoaltoken: admin")
	}
	if next < 0 || next > maxSellTaxBps {
		panic("shoaltoken: tax")
	}
	sellTaxBps = next
	chain.Emit("SetSellTaxBps", "bps", strconv.FormatInt(next, 10))
}

// TransferAdmin hands the tax hook to next. Balances stay where they are.
func TransferAdmin(cur realm, next address) {
	requireUser(cur)
	takeExact(0)
	requireReady()
	if !next.IsValid() {
		panic("shoaltoken: admin")
	}
	if err := admin.TransferOwnership(0, cur, next); err != nil {
		panic("shoaltoken: admin")
	}
	chain.Emit("TransferAdmin", "next", next.String())
}

func Name() string {
	requireReady()
	return token.GetName()
}

func Symbol() string {
	requireReady()
	return token.GetSymbol()
}

func Decimals() int {
	requireReady()
	return token.GetDecimals()
}

func TotalSupply() int64 {
	requireReady()
	return token.TotalSupply()
}

func BalanceOf(who address) int64 {
	requireReady()
	return token.BalanceOf(who)
}

func Allowance(owner, spender address) int64 {
	requireReady()
	return token.Allowance(owner, spender)
}

func TokenID() string {
	requireReady()
	return token.ID()
}

func BuyTaxBps() int64  { return buyTaxBps }
func SellTaxBps() int64 { return sellTaxBps }
func Version() string   { return "shoaltoken-1" }
func Sealed() bool      { return sealed }

// Spender is the one realm allowed to Draw. It is empty until SetSpender.
func Spender() address { return spender }

// SetSpender records the fish realm once. A later call cannot replace it.
func SetSpender(cur realm, who address) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	if !admin.OwnedBy(caller) {
		panic("shoaltoken: admin")
	}
	if spenderSet || !who.IsValid() {
		panic("shoaltoken: spender")
	}
	spender = who
	spenderSet = true
	chain.Emit("SetSpender", "who", who.String())
}

// Draw moves min(amount, balance, allowance) from owner to to.
// Only the recorded spender may call it. The owner must have approved that spender.
// A short balance or allowance moves nothing and does not panic. This does not mint.
func Draw(cur realm, owner, to address, amount int64) int64 {
	if !cur.IsCurrent() {
		panic("shoaltoken: realm")
	}
	if !spenderSet || cur.Previous().Address() != spender {
		panic("shoaltoken: spender")
	}
	takeExact(0)
	requireReady()
	if amount <= 0 || !owner.IsValid() || !to.IsValid() {
		return 0
	}
	bal := token.BalanceOf(owner)
	if amount > bal {
		amount = bal
	}
	allow := token.Allowance(owner, spender)
	if amount > allow {
		amount = allow
	}
	if amount <= 0 {
		return 0
	}
	must(ledger.CallerTeller().TransferFrom(0, cur, owner, to, amount))
	chain.Emit("Draw", "owner", owner.String(), "to", to.String(), "amount", strconv.FormatInt(amount, 10))
	return amount
}

func Admin() address {
	if admin == nil {
		return address("")
	}
	return admin.Owner()
}

func Render(path string) string {
	if path != "" {
		return "# Shoal FISH\n\nUnknown path.\n"
	}
	return "# Shoal FISH\n\nFixed supply. Wallet transfers are not taxed.\n\nThe symbol FISH shares its letters with the fish NFT collection. TokenID is the chain identity.\n"
}

func credit(led *grc20.PrivateLedger, who address, amount int64) {
	if err := led.Mint(who, amount); err != nil {
		panic(err)
	}
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func requireReady() {
	if !inited || !sealed || token == nil || ledger == nil || admin == nil {
		panic("shoaltoken: init")
	}
}

func requireUser(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("shoaltoken: eoa")
	}
	return cur.Previous().Address()
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("shoaltoken: payment")
		}
		return
	}
	panic("shoaltoken: payment")
}

func distinct(xs ...address) bool {
	for i, a := range xs {
		if !a.IsValid() {
			return false
		}
		for j := 0; j < i; j++ {
			if xs[j] == a {
				return false
			}
		}
	}
	return true
}
