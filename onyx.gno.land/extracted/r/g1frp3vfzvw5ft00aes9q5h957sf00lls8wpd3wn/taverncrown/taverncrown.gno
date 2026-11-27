// Package taverncrown is a king-of-the-hill game realm for gno.land.
//
// Anyone can seize the Crown by paying the current price in ugnot into
// the pot. Every seizure raises the price by 10% and resets the round
// timer. When the timer expires, the last Crown holder wins the whole
// pot. Payout uses the pull-payment pattern: after the deadline anyone
// can call ClaimPot to settle the round and pay the winner.
//
// The realm is immutable and has no admin keys: the rules below are the
// whole game. State is intentionally small (holder, pot, price,
// deadline, and a capped winners list) to keep storage deposits low.
package taverncrown

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const (
	denom       = "ugnot"
	basePrice   = int64(1_000_000) // 1 GNOT, the price of the first seizure each round
	priceNum    = int64(11)        // price grows by x11/10 per seizure (+10%)
	priceDen    = int64(10)
	roundBlocks = int64(720) // round length in blocks (~1 hour at ~5s blocks)
	maxWinners  = 20         // hall-of-fame cap, bounds storage growth
)

// winner records one settled round.
type winner struct {
	addr   address
	amount int64
	round  int
}

var (
	holder   address // current Crown holder; zero when no round is active
	pot      int64   // ugnot accumulated this round
	price    int64   // current price to seize the Crown, in ugnot
	deadline int64   // block height at which the round expires
	round    int     // current round number, starting at 1
	seizures int     // seizures so far this round
	winners  []winner
)

func init() {
	price = basePrice
	round = 1
}

// SeizeCrown takes the Crown for the caller.
//
// The caller must attach at least the current price in ugnot to the
// call (-send). Any excess over the price is refunded immediately. On a
// successful seizure the caller becomes the Crown holder, the price
// rises by 10%, and the round timer resets.
//
// If the previous round already expired, it is settled first (the old
// holder is paid) and the seizure opens a fresh round at the base price.
//
// Only direct user calls (maketx call) are accepted: the payment check
// relies on the origin-send envelope, which only describes a real
// receipt at this realm when the caller is a plain account.
func SeizeCrown(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	sender := cur.Previous().Address()

	// Settle an expired round before pricing the new seizure.
	if holder != "" && runtime.ChainHeight() >= deadline {
		settle(cur)
	}

	sent := unsafe.OriginSend().AmountOf(denom)
	if sent < price {
		panic("payment below current crown price")
	}

	// Refund any excess over the price.
	if sent > price {
		pay(cur, sender, sent-price)
	}

	pot += price
	holder = sender
	seizures++
	price = price * priceNum / priceDen
	deadline = runtime.ChainHeight() + roundBlocks

	chain.Emit("CrownSeized",
		"holder", string(sender),
		"round", strconv.Itoa(round),
		"paid", strconv.FormatInt(pot, 10),
		"nextPrice", strconv.FormatInt(price, 10),
		"deadline", strconv.FormatInt(deadline, 10),
	)
}

// ClaimPot settles the current round once its deadline has passed,
// paying the whole pot to the Crown holder. Anyone may call it; the
// payout always goes to the holder of record, never to the caller.
func ClaimPot(cur realm) {
	if holder == "" {
		panic("no active round")
	}
	if runtime.ChainHeight() < deadline {
		panic("round not finished yet")
	}
	settle(cur)
}

// settle pays the pot to the current holder, records the winner, and
// resets the round. State is reset before the payout so the realm is
// consistent even if the transfer were to fail partway (it cannot:
// the pot is fully backed by received coins).
func settle(cur realm) {
	w := holder
	amount := pot
	wonRound := round

	winners = append(winners, winner{addr: w, amount: amount, round: wonRound})
	if len(winners) > maxWinners {
		winners = winners[len(winners)-maxWinners:]
	}

	holder = ""
	pot = 0
	price = basePrice
	seizures = 0
	deadline = 0
	round++

	chain.Emit("PotClaimed",
		"winner", string(w),
		"round", strconv.Itoa(wonRound),
		"amount", strconv.FormatInt(amount, 10),
	)

	if amount > 0 {
		pay(cur, w, amount)
	}
}

// pay sends amount ugnot from the realm to the given address.
func pay(cur realm, to address, amount int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(denom, amount)))
}

// GetHolder returns the current Crown holder (zero address if no round).
func GetHolder() address { return holder }

// GetPot returns the current pot in ugnot.
func GetPot() int64 { return pot }

// GetPrice returns the current seizure price in ugnot.
func GetPrice() int64 { return price }

// GetDeadline returns the block height at which the round expires.
func GetDeadline() int64 { return deadline }

// GetRound returns the current round number.
func GetRound() int { return round }

// GetSeizures returns the number of seizures this round.
func GetSeizures() int { return seizures }

// formatGNOT renders an ugnot amount as a GNOT decimal string.
func formatGNOT(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10)
	}
	fracStr := strconv.FormatInt(frac+1_000_000, 10)[1:] // zero-padded to 6 digits
	fracStr = strings.TrimRight(fracStr, "0")
	return strconv.FormatInt(whole, 10) + "." + fracStr
}

// Render renders the game page in markdown.
//
// Paths: "" (home), "winners" (hall of fame), "rules" (how to play).
// The path is never echoed back, so no user input reaches the output.
func Render(path string) string {
	switch path {
	case "":
		return renderHome()
	case "winners":
		return renderWinners()
	case "rules":
		return renderRules()
	default:
		return "# Tavern Crown\n\nUnknown page. Try the home page, `winners`, or `rules`.\n"
	}
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 👑 Tavern Crown\n\n")
	b.WriteString("King of the hill, on-chain. Seize the Crown, hold it until the timer runs out, take the pot.\n\n")

	if holder == "" {
		b.WriteString("## No reigning monarch\n\n")
		b.WriteString("The Crown sits unclaimed. Round " + strconv.Itoa(round) + " is open — ")
		b.WriteString("seize it for **" + formatGNOT(price) + " GNOT** and start the clock.\n\n")
	} else {
		remaining := deadline - runtime.ChainHeight()
		if remaining < 0 {
			remaining = 0
		}
		b.WriteString("## Current reign\n\n")
		b.WriteString("- **Crown holder:** `" + string(holder) + "`\n")
		b.WriteString("- **Pot:** " + formatGNOT(pot) + " GNOT\n")
		b.WriteString("- **Price to seize:** " + formatGNOT(price) + " GNOT\n")
		b.WriteString("- **Blocks remaining:** " + strconv.FormatInt(remaining, 10) + "\n")
		b.WriteString("- **Round:** " + strconv.Itoa(round) + " (" + strconv.Itoa(seizures) + " seizures)\n\n")
		if remaining == 0 {
			b.WriteString("⏰ The round has expired — call **ClaimPot** to pay the holder and open the next round.\n\n")
		}
	}

	b.WriteString("## How to play\n\n")
	b.WriteString("1. Call **SeizeCrown** with the current price attached (`-send`). Excess is refunded.\n")
	b.WriteString("2. Each seizure raises the price 10% and resets the timer (" + strconv.FormatInt(roundBlocks, 10) + " blocks).\n")
	b.WriteString("3. When the timer expires, the last holder wins the pot — anyone can trigger **ClaimPot**.\n\n")
	b.WriteString("See `rules` for the full rules and `winners` for past champions.\n")
	return b.String()
}

func renderWinners() string {
	var b strings.Builder
	b.WriteString("# 🏆 Hall of Fame\n\n")
	if len(winners) == 0 {
		b.WriteString("No champions yet. The first Crown is still waiting.\n")
		return b.String()
	}
	b.WriteString("| Round | Winner | Pot (GNOT) |\n|---|---|---|\n")
	for i := len(winners) - 1; i >= 0; i-- {
		w := winners[i]
		b.WriteString("| " + strconv.Itoa(w.round) + " | `" + string(w.addr) + "` | " + formatGNOT(w.amount) + " |\n")
	}
	return b.String()
}

func renderRules() string {
	var b strings.Builder
	b.WriteString("# 📜 Tavern Crown — Rules\n\n")
	b.WriteString("- **Seize:** call `SeizeCrown` with at least the current price in ugnot attached. Overpayment is refunded in the same transaction.\n")
	b.WriteString("- **Price curve:** the first seizure of a round costs " + formatGNOT(basePrice) + " GNOT; every seizure multiplies the price by 11/10 (+10%).\n")
	b.WriteString("- **Timer:** each seizure sets the deadline " + strconv.FormatInt(roundBlocks, 10) + " blocks ahead. Seize again before it expires to extend your reign — anyone else can take the Crown from you the same way.\n")
	b.WriteString("- **Winning:** when the deadline passes, the holder of record wins the entire pot. `ClaimPot` (callable by anyone) settles the round; a seizure after expiry also settles the old round first.\n")
	b.WriteString("- **Fair play:** no admin keys, no pause, no upgrades. The realm code is the rulebook. Payments are verified from the transaction envelope; only direct account calls can seize.\n")
	return b.String()
}
