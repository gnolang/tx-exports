// Package fishtoken is the unreleased GnoFish FISH ledger.
// Init mints a fixed supply once. No later call can mint.
// While transfers are closed, a normal wallet cannot send FISH, so it cannot
// fund a pool or sell through a market. The deploy wallet opens transfers.
// The five treasury wallets, the deploy wallet, and a reward realm the deploy
// wallet has granted may still send. This realm has no pool and no trade.
// Public-sale FISH is minted to the deploy wallet. fishtoken-1.
package fishtoken

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	unit            int64 = 1_000_000
	supplyWhole     int64 = 100_000_000
	seasonWhole     int64 = 43_000_000
	liquidityWhole  int64 = 20_000_000
	ecosystemWhole  int64 = 15_000_000
	communityWhole  int64 = 12_000_000
	teamWhole       int64 = 5_000_000
	saleWhole       int64 = 5_000_000
)

var (
	seasonAddr    = address("g1m6z3l9q577dltj73ym8fu0068peupqg468r5xe")
	liquidityAddr = address("g1lepzz7lehwfnwng0ddxaglz2kzmsf6pyy5f6tw")
	ecosystemAddr = address("g1p4cylgemajmw93e9a0nr0fmph60gee2yhkn2kz")
	communityAddr = address("g1dpklfykp2mrhcwccek54scv43kamtxlszya2z8")
	teamAddr      = address("g15ejerz2n0xn5x94zezhquvwvp98m3jgkcwdrya")
)

var (
	token     *grc20.Token
	ledger    *grc20.PrivateLedger
	seq       seqid.ID
	inited    bool
	open      bool
	admin     address
	mover     map[address]bool
	payer     map[address]bool
)

// Init mints the fixed supply once. The caller is the deploy wallet and receives the public-sale FISH. No coins.
func Init(cur realm) {
	caller := requireUser(cur)
	takeExact(0)
	if inited {
		panic("fishtoken: init")
	}
	if !distinct(caller, seasonAddr, liquidityAddr, ecosystemAddr, communityAddr, teamAddr) {
		panic("fishtoken: addr")
	}
	tok, led := grc20.NewToken("FISH", "FISH", 6, seq.Next(), cur)
	credit(led, seasonAddr, seasonWhole*unit)
	credit(led, liquidityAddr, liquidityWhole*unit)
	credit(led, ecosystemAddr, ecosystemWhole*unit)
	credit(led, communityAddr, communityWhole*unit)
	credit(led, teamAddr, teamWhole*unit)
	credit(led, caller, saleWhole*unit)
	if tok.TotalSupply() != supplyWhole*unit {
		panic("fishtoken: supply")
	}
	token = tok
	ledger = led
	admin = caller
	open = false
	mover = map[address]bool{
		caller:        true,
		seasonAddr:    true,
		liquidityAddr: true,
		ecosystemAddr: true,
		communityAddr: true,
		teamAddr:      true,
	}
	payer = map[address]bool{}
	inited = true
	chain.Emit("Init", "admin", caller.String(), "supply", strconv.FormatInt(supplyWhole*unit, 10))
}

// SetTransfers opens or closes ordinary wallet sends. The deploy wallet only. No coins.
func SetTransfers(cur realm, next bool) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	open = next
	chain.Emit("SetTransfers", "open", strconv.FormatBool(next))
}

// GrantMover lets that wallet send FISH while transfers are closed. The deploy wallet only. No coins.
func GrantMover(cur realm, who address) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if !who.IsValid() {
		panic("fishtoken: addr")
	}
	mover[who] = true
	chain.Emit("GrantMover", "who", who.String())
}

// RevokeMover removes that wallet from the closed-transfer list. The deploy wallet only. No coins.
func RevokeMover(cur realm, who address) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if !who.IsValid() {
		panic("fishtoken: addr")
	}
	delete(mover, who)
	chain.Emit("RevokeMover", "who", who.String())
}

// GrantDistributor lets that realm pay FISH to users while transfers are closed. The deploy wallet only. No coins.
func GrantDistributor(cur realm, who address) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if !who.IsValid() {
		panic("fishtoken: addr")
	}
	payer[who] = true
	chain.Emit("GrantDistributor", "who", who.String())
}

// RevokeDistributor removes that reward realm. The deploy wallet only. No coins.
func RevokeDistributor(cur realm, who address) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if !who.IsValid() {
		panic("fishtoken: addr")
	}
	delete(payer, who)
	chain.Emit("RevokeDistributor", "who", who.String())
}

// TransferAdmin hands the switch to next. Balances stay where they are. No coins.
func TransferAdmin(cur realm, next address) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if !next.IsValid() {
		panic("fishtoken: admin")
	}
	admin = next
	mover[next] = true
	chain.Emit("TransferAdmin", "next", next.String())
}

// Transfer sends FISH from the caller to to.
// A closed ledger rejects an ordinary wallet. Listed wallets and granted reward realms may still send.
func Transfer(cur realm, to address, amount int64) {
	caller := cur.Previous().Address()
	if cur.Previous().IsUserCall() {
		takeExact(0)
	}
	requireReady()
	requireAmount(amount, to)
	if !mayMove(cur, caller, caller) {
		panic("fishtoken: closed")
	}
	must(ledger.CallerTeller().Transfer(0, cur, to, amount))
	chain.Emit("Send", "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// Approve sets the spender allowance. It does not move FISH and does not open trading. No coins from an EOA.
func Approve(cur realm, spender address, amount int64) {
	if cur.Previous().IsUserCall() {
		takeExact(0)
	} else if !payer[cur.Previous().Address()] {
		panic("fishtoken: closed")
	}
	requireReady()
	if amount < 0 || !spender.IsValid() {
		panic("fishtoken: amount")
	}
	must(ledger.CallerTeller().Approve(0, cur, spender, amount))
	chain.Emit("Approve", "spender", spender.String(), "amount", strconv.FormatInt(amount, 10))
}

// TransferFrom sends FISH using the caller's allowance.
// While closed, only a granted reward realm may pull, and only from its own balance or from a listed wallet.
func TransferFrom(cur realm, owner, to address, amount int64) {
	caller := cur.Previous().Address()
	if cur.Previous().IsUserCall() {
		takeExact(0)
	}
	requireReady()
	requireAmount(amount, to)
	if !mayMove(cur, caller, owner) {
		panic("fishtoken: closed")
	}
	must(ledger.CallerTeller().TransferFrom(0, cur, owner, to, amount))
	chain.Emit("SendFrom", "owner", owner.String(), "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

func TransfersOpen() bool { return open }
func IsMover(who address) bool {
	return mover[who]
}
func IsDistributor(who address) bool { return payer[who] }
func Version() string                { return "fishtoken-1" }
func Admin() address                 { return admin }

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

func Render(path string) string {
	if path != "" {
		return "# FISH\n\nUnknown path.\n"
	}
	if !inited {
		return "# FISH\n\nNot opened.\n"
	}
	state := "closed"
	if open {
		state = "open"
	}
	return "# FISH\n\nFixed supply. Transfers are " + state + ". A closed ledger does not fund a pool and does not trade. Listed wallets and granted reward realms can still send. Public-sale FISH was minted to the deploy wallet.\n"
}

func mayMove(cur realm, caller, from address) bool {
	if open {
		return true
	}
	if cur.Previous().IsUserCall() {
		return from == caller && mover[caller]
	}
	if !payer[caller] {
		return false
	}
	return from == caller || mover[from]
}

func requireAdmin(caller address) {
	if caller != admin {
		panic("fishtoken: admin")
	}
}

func requireAmount(amount int64, to address) {
	if amount <= 0 || !to.IsValid() {
		panic("fishtoken: amount")
	}
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
	if !inited || token == nil || ledger == nil {
		panic("fishtoken: init")
	}
}

func requireUser(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("fishtoken: eoa")
	}
	return cur.Previous().Address()
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("fishtoken: payment")
		}
		return
	}
	panic("fishtoken: payment")
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
