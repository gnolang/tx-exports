package tavern_dice

import (
	"strconv"
)

// Render renders the realm for gnoweb. The home page shows the bankroll,
// how to play, recent rolls, and the leaderboard. "/rolls" shows the same
// recent-rolls table on its own. Only bech32 addresses and numbers are
// ever embedded in the output; no user-supplied text is rendered.
func Render(path string) string {
	if path == "rolls" {
		return "# Tavern Dice — Recent Rolls\n\n" + rollsTable() + "\n\n[Back home](.)"
	}
	out := "# 🎲 Tavern Dice\n\n"
	out += "A tiny on-chain dice game. Bet testnet ugnot, roll the dice, " +
		"get paid in the same transaction.\n\n"
	out += "## Bankroll\n\n"
	out += "- **Bankroll:** " + formatAmount(Bankroll()) + "\n"
	out += "- **Minimum bet:** " + formatAmount(minBet) + "\n"
	out += "- **Owner:** " + shortAddr(owner) + "\n\n"
	out += "## How to play\n\n"
	out += "1. Fund the bankroll first if it is empty " +
		"(`Fund` with `-send <amount>ugnot`).\n"
	out += "2. Bet on a number: `BetNumber` with `-send <amount>ugnot`, " +
		"number 1-6. Win pays **5x**.\n"
	out += "3. Or bet odd/even: `BetParity` with `-send <amount>ugnot`. " +
		"Win pays **1.9x**.\n"
	out += "4. The worst-case payout of a single bet is capped at a quarter " +
		"of the bankroll, so the house can always pay.\n\n"
	out += "## Totals\n\n"
	out += "- Bets settled: " + strconv.FormatInt(totalBets, 10) + "\n"
	out += "- Total wagered: " + formatAmount(totalWagered) + "\n"
	out += "- Total paid out: " + formatAmount(totalPaidOut) + "\n"
	out += "- Wins: " + strconv.FormatInt(totalWins, 10) + "\n\n"
	out += "## Recent rolls\n\n" + rollsTable() + "\n\n"
	out += "## Leaderboard (biggest single win)\n\n" + leaderboard() + "\n"
	return out
}

func rollsTable() string {
	if len(rolls) == 0 {
		return "No bets yet. Be the first to roll.\n"
	}
	out := "| # | Player | Bet | Choice | Roll | Payout |\n"
	out += "|---|--------|-----|--------|------|--------|\n"
	for i := len(rolls) - 1; i >= 0; i-- {
		r := rolls[i]
		out += "| " + strconv.FormatInt(r.seq, 10) +
			" | " + shortAddr(r.player) +
			" | " + formatAmount(r.bet) +
			" | " + r.choice +
			" | **" + strconv.Itoa(r.roll) + "**" +
			" | " + formatAmount(r.payout) + " |\n"
	}
	return out
}

func leaderboard() string {
	type entry struct {
		player address
		win    int64
		bets   int64
		wins   int64
	}
	top := []entry{}
	for addr, st := range players {
		if st.biggestWin <= 0 {
			continue
		}
		e := entry{player: addr, win: st.biggestWin, bets: st.bets, wins: st.wins}
		// Insertion sort, biggest first, keep at most 5.
		pos := len(top)
		for pos > 0 && top[pos-1].win < e.win {
			pos--
		}
		top = append(top, entry{})
		copy(top[pos+1:], top[pos:])
		top[pos] = e
		if len(top) > 5 {
			top = top[:5]
		}
	}
	if len(top) == 0 {
		return "No winners yet.\n"
	}
	out := "| # | Player | Biggest win | Bets | Wins |\n"
	out += "|---|--------|-------------|------|------|\n"
	for i, e := range top {
		out += "| " + strconv.Itoa(i+1) +
			" | " + shortAddr(e.player) +
			" | " + formatAmount(e.win) +
			" | " + strconv.FormatInt(e.bets, 10) +
			" | " + strconv.FormatInt(e.wins, 10) + " |\n"
	}
	return out
}

// formatAmount renders an ugnot amount with its unit.
func formatAmount(amount int64) string {
	return strconv.FormatInt(amount, 10) + " ugnot"
}

// shortAddr shortens a bech32 address for display.
func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:10] + "…" + s[len(s)-4:]
}
