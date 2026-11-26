// Gnome Tavern — an on-chain tavern on Gno.land.
//
// Patrons claim free Tavern Ale (ALE, a GRC20 token) from a rate-limited
// faucet, buy drinks from the menu with ALE, and every tab lives on-chain.
// The realm's Render() page is the tavern itself: menu, top patrons, and
// per-address balance / tab lookups.
//
// Deployed on the Onyx testnet (chain-id onyx-1) at:
//   gno.land/r/g1x7gechxs30vum6u5mwsg4xkv2m7g2kkas7vzj6/tavern
package tavern

import (
	"strings"
	"time"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	decimals       = 6
	oneALE         = 1_000_000 // 1 ALE = 1_000_000 base units
	faucetAmount   = 100 * oneALE
	faucetCap      = 100_000 * oneALE
	faucetCooldown = 24 * time.Hour
	initialSupply  = 1_000_000 * oneALE
)

var (
	Token         *grc20.Token
	privateLedger *grc20.PrivateLedger
	userTeller    grc20.Teller
	// Ownable is the tavern keeper: the deployer. It owns the till and
	// the mint/burn admin functions.
	Ownable = ownable.NewWithAddress("g1x7gechxs30vum6u5mwsg4xkv2m7g2kkas7vzj6")
)

// drink is one item on the tavern menu. price is in ALE base units.
type drink struct {
	name  string
	price int64
}

var menu = []drink{
	{"Gnome Stout", 50 * oneALE},
	{"Fairy Fizz", 30 * oneALE},
	{"Dragon's Breath Ale", 120 * oneALE},
	{"Mushroom Mead", 80 * oneALE},
	{"Tavern Water", 5 * oneALE},
}

var (
	// lastClaim records the last faucet claim per address (block time).
	lastClaim map[address]time.Time
	// faucetMinted tracks total ALE minted by the faucet (capped).
	faucetMinted int64
	// tabDrinks counts drinks per patron, keyed "address|drink name".
	tabDrinks map[string]int
	// tabSpent totals ALE spent per patron (base units).
	tabSpent map[address]int64
	// patrons lists every address that ever bought a drink, in order.
	patrons  []address
	isPatron map[address]bool
)

func init(cur realm) {
	Token, privateLedger = grc20.NewToken("Tavern Ale", "ALE", decimals, 0, cur)
	userTeller = privateLedger.CallerTeller()
	privateLedger.Mint(Ownable.Owner(), initialSupply)
	grc20reg.Register(cross(cur), Token, "")
	lastClaim = make(map[address]time.Time)
	tabDrinks = make(map[string]int)
	tabSpent = make(map[address]int64)
	isPatron = make(map[address]bool)
}

// formatALE renders base units as "123.456789 ALE".
// (Gno's ufmt does not zero-pad %06d, so the fraction is padded by hand.)
func formatALE(amount int64) string {
	frac := ufmt.Sprintf("%d", amount%oneALE)
	for len(frac) < 6 {
		frac = "0" + frac
	}
	return ufmt.Sprintf("%d.%s ALE", amount/oneALE, frac)
}

// menuPrice looks a drink up by exact name.
func menuPrice(name string) (int64, bool) {
	for _, d := range menu {
		if d.name == name {
			return d.price, true
		}
	}
	return 0, false
}

// Faucet gives the caller 100 ALE, at most once every 24 hours per address,
// until 100,000 ALE have been handed out in total. Returns the amount minted.
func Faucet(cur realm) int64 {
	caller := cur.Previous().Address()
	now := time.Now()
	if last, ok := lastClaim[caller]; ok {
		if now.Sub(last) < faucetCooldown {
			panic("faucet cooldown: one claim per address every 24h")
		}
	}
	if faucetMinted+faucetAmount > faucetCap {
		panic("faucet empty: cap reached")
	}
	lastClaim[caller] = now
	faucetMinted += faucetAmount
	checkErr(privateLedger.Mint(caller, faucetAmount))
	return faucetAmount
}

// BuyDrink pays for a drink from the menu with the caller's ALE and adds it
// to their tab. The ALE goes to the tavern till (the owner). Returns a
// confirmation with the new tab total.
func BuyDrink(cur realm, name string) string {
	caller := cur.Previous().Address()
	price, ok := menuPrice(name)
	if !ok {
		panic("unknown drink: " + name)
	}
	checkErr(userTeller.Transfer(0, cur, Ownable.Owner(), price))
	tabDrinks[caller.String()+"|"+name]++
	tabSpent[caller] += price
	if !isPatron[caller] {
		isPatron[caller] = true
		patrons = append(patrons, caller)
	}
	return ufmt.Sprintf("Enjoy your %s! Tab total: %s.", name, formatALE(tabSpent[caller]))
}

// Menu returns the drink menu as plain text.
func Menu() string {
	s := ""
	for _, d := range menu {
		s += ufmt.Sprintf("- %s: %s\n", d.name, formatALE(d.price))
	}
	return s
}

// TabOf returns a human-readable tab for an address.
func TabOf(addr address) string {
	if !isPatron[addr] {
		return "No tab yet. Buy a drink first!"
	}
	s := ufmt.Sprintf("Tab total: %s\n", formatALE(tabSpent[addr]))
	for _, d := range menu {
		if n := tabDrinks[addr.String()+"|"+d.name]; n > 0 {
			s += ufmt.Sprintf("- %s x%d\n", d.name, n)
		}
	}
	return s
}

// TopPatrons returns the top 5 patrons by ALE spent, as plain text.
func TopPatrons() string {
	if len(patrons) == 0 {
		return "No patrons yet. Be the first to buy a round!\n"
	}
	picked := make(map[address]bool)
	s := ""
	for n := 0; n < 5 && n < len(patrons); n++ {
		var best address
		var bestSpent int64 = -1
		for _, p := range patrons {
			if picked[p] {
				continue
			}
			if tabSpent[p] > bestSpent {
				bestSpent = tabSpent[p]
				best = p
			}
		}
		if bestSpent < 0 {
			break
		}
		picked[best] = true
		s += ufmt.Sprintf("%d. %s — %s\n", n+1, best.String(), formatALE(bestSpent))
	}
	return s
}

// FaucetInfo reports how much ALE the faucet has left to hand out.
func FaucetInfo() string {
	return ufmt.Sprintf("Faucet: %s claimed of %s cap, %s per claim, one claim per address every 24h.",
		formatALE(faucetMinted), formatALE(faucetCap), formatALE(faucetAmount))
}

// TotalSupply returns the total ALE in existence.
func TotalSupply() int64 {
	return userTeller.TotalSupply()
}

// BalanceOf returns the ALE balance of an address (base units).
func BalanceOf(owner address) int64 {
	return userTeller.BalanceOf(owner)
}

// Allowance returns how much spender may spend on behalf of owner.
func Allowance(owner, spender address) int64 {
	return userTeller.Allowance(owner, spender)
}

// Transfer moves the caller's ALE to another address.
func Transfer(cur realm, to address, amount int64) {
	checkErr(userTeller.Transfer(0, cur, to, amount))
}

// Approve lets spender spend up to amount of the caller's ALE.
func Approve(cur realm, spender address, amount int64) {
	checkErr(userTeller.Approve(0, cur, spender, amount))
}

// TransferFrom moves ALE from one address to another using an allowance.
func TransferFrom(cur realm, from, to address, amount int64) {
	checkErr(userTeller.TransferFrom(0, cur, from, to, amount))
}

// Mint creates new ALE. Tavern keeper only.
func Mint(cur realm, to address, amount int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	checkErr(privateLedger.Mint(to, amount))
}

// Burn destroys ALE from an address. Tavern keeper only.
func Burn(cur realm, from address, amount int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	checkErr(privateLedger.Burn(from, amount))
}

// Render is the tavern's web page, served by gnoweb as Markdown.
// NOTE: path segments are attacker-controlled input; anything echoed back
// is passed through sanitize.InlineText first.
func Render(path string) string {
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		s := "# 🍺 Gnome Tavern\n\n"
		s += "An on-chain tavern on Gno.land. Claim free **Tavern Ale (ALE)**, buy drinks from the menu, and your tab lives on-chain forever.\n\n"
		s += Token.RenderHome()
		s += "\n## Menu\n\n" + Menu()
		s += "\n## How to drink\n\n"
		s += "1. `Faucet()` — claim 100 ALE (once every 24h per address).\n"
		s += "2. `BuyDrink(\"Gnome Stout\")` — pay ALE, get it on your tab.\n"
		s += "3. `TabOf(<your address>)` — see your tab.\n\n"
		s += "## Top patrons\n\n" + TopPatrons()
		s += "\n## Faucet\n\n" + FaucetInfo() + "\n"
		return s
	case len(parts) == 2 && parts[0] == "balance":
		owner := address(parts[1])
		return ufmt.Sprintf("Balance of %s: %s\n", sanitize.InlineText(parts[1]), formatALE(BalanceOf(owner)))
	case len(parts) == 2 && parts[0] == "tab":
		addr := address(parts[1])
		return "Tab of " + sanitize.InlineText(parts[1]) + ":\n\n" + TabOf(addr)
	default:
		return "404\n"
	}
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}
