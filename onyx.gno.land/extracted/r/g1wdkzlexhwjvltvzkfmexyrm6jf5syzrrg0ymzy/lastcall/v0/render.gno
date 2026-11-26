package lastcall

import (
	"strconv"
	"strings"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapmath/v0"
	"gno.land/r/g1wdkzlexhwjvltvzkfmexyrm6jf5syzrrg0ymzy/tapster/v0"
)

// Render pages:
//
//	(empty)              open games, games ready to settle, recent results, leaderboard
//	player/<address>     a player's bets and what they can claim
//	json                 open and recent games as JSON
func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case path == "":
		return renderHome()
	case parts[0] == "player" && len(parts) == 2:
		return renderPlayer(address(parts[1]))
	case parts[0] == "json":
		return renderJSON()
	}
	return "# 404\n\n[Back](" + realmPath() + ")"
}

func realmPath() string {
	l := txlink.Call("Bet")
	if i := strings.Index(l, "$"); i >= 0 {
		return l[:i]
	}
	return l
}

func price(p int64, dec int) string {
	keep := 2
	if p < tapmath.Pow10(dec) {
		keep = dec
	}
	return "$" + tapmath.FormatRounded(p, dec, keep)
}

// multiplier shows what 1 GNOT on a side would pay if that side wins now.
func multiplier(side, other int64) string {
	if side == 0 {
		if other == 0 {
			return "—"
		}
		return "first bet takes the pot"
	}
	if other == 0 {
		return "no takers yet"
	}
	total := side + other
	payable := total - tapmath.ApplyBps(total, tipBps)
	// x100 for two decimals
	m := mulDiv(100, payable, side)
	return ufmt.Sprintf("%d.%02dx", m/100, m%100)
}

func ago(t int64) string {
	d := now() - t
	switch {
	case d < 120:
		return ufmt.Sprintf("%ds ago", d)
	case d < 7200:
		return ufmt.Sprintf("%dm ago", d/60)
	}
	return ufmt.Sprintf("%dh ago", d/3600)
}

func betLink(pair string, up bool, amount int64) string {
	return txlink.NewLink("Bet").AddArgs("pair", pair, "up", strconv.FormatBool(up)).SetSend(strconv.FormatInt(amount, 10) + "ugnot").URL()
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 🔔 Last Call\n\n")
	b.WriteString("**Will the price be higher or lower in about 15 minutes?** Bet GNOT on UP or DOWN. ")
	b.WriteString("Games are priced and settled by [Tapster](/" + strings.TrimPrefix(strings.Replace(realmPath(), "/lastcall/v0", "/tapster/v0", 1), "/") + ") price feeds. ")
	b.WriteString("Winners split the pot. No house edge; the settler earns 0.5%.\n\n")
	b.WriteString(ufmt.Sprintf("%d games · %d bets · %s wagered\n\n", totalGames, totalBets, gnot(totalVolume)))

	b.WriteString("## Open games\n\n| Feed | Opening price | Round | UP pot | DOWN pot | Bet |\n|---|---|---|---|---|---|\n")
	for _, pair := range strings.Split(tapster.Pairs(), ",") {
		p, dec, at, round, ok := tapster.Latest(pair)
		if !ok {
			b.WriteString("| " + pair + " | waiting for Tapster | | | | |\n")
			continue
		}
		if now()-at > maxPriceAge {
			b.WriteString("| " + pair + " | " + price(p, dec) + " (stale) | " + strconv.FormatInt(round, 10) + " | | | paused |\n")
			continue
		}
		var up, down int64
		if v := games.Get(gameKey(pair, round)); v != nil {
			g := v.(*Game)
			up, down = g.UpPot, g.DownPot
		}
		b.WriteString(ufmt.Sprintf("| **%s** | %s | %d | %s (%s) | %s (%s) | [⬆ UP 1 GNOT](%s) · [⬇ DOWN 1 GNOT](%s) |\n",
			pair, price(p, dec), round, gnot(up), multiplier(up, down), gnot(down), multiplier(down, up),
			betLink(pair, true, 1000000), betLink(pair, false, 1000000)))
	}
	b.WriteString("\nA game takes bets while its opening price is Tapster's latest answer, then settles on an answer at least 3 rounds later.\n\n")

	// Ready to settle
	var ready []string
	open.Iterate("", "", func(k string, _ any) bool {
		g := games.Get(k).(*Game)
		_, _, _, latest, ok := tapster.Latest(g.Pair)
		if ok && latest >= g.Round+settleAfter {
			ready = append(ready, ufmt.Sprintf("| %s | %d | %s | %d | [Settle and earn the tip](%s) |",
				g.Pair, g.Round, gnot(g.UpPot+g.DownPot), g.Bettors,
				txlink.NewLink("Settle").AddArgs("pair", g.Pair, "round", strconv.FormatInt(g.Round, 10)).URL()))
		}
		return len(ready) >= 20
	})
	if len(ready) > 0 {
		b.WriteString("## Ready to settle\n\n| Feed | Round | Pot | Bettors | |\n|---|---|---|---|---|\n")
		b.WriteString(strings.Join(ready, "\n") + "\n\n")
	}

	// Recent results
	b.WriteString("## Recent results\n\n| Feed | Round | Open → Close | Result | Pot |\n|---|---|---|---|---|\n")
	n := 0
	for i := len(settledLog) - 1; i >= 0 && n < 15; i-- {
		g := games.Get(settledLog[i]).(*Game)
		b.WriteString(ufmt.Sprintf("| %s | %d | %s → %s | %s | %s |\n", g.Pair, g.Round,
			price(g.StartPrice, g.Decimals), price(g.EndPrice, g.Decimals), badge(g.Outcome), gnot(g.UpPot+g.DownPot)))
		n++
	}
	if n == 0 {
		b.WriteString("| No settled games yet | | | | |\n")
	}

	// Leaderboard by profit
	b.WriteString("\n## Leaderboard\n\n| # | Player | Bets | Wins | Wagered | Profit |\n|---|---|---|---|---|---|\n")
	var list []*Player
	players.Iterate("", "", func(_ string, v any) bool {
		list = append(list, v.(*Player))
		return false
	})
	for i := 1; i < len(list); i++ {
		p := list[i]
		j := i - 1
		for j >= 0 && list[j].Won-list[j].Wagered < p.Won-p.Wagered {
			list[j+1] = list[j]
			j--
		}
		list[j+1] = p
	}
	for i, p := range list {
		if i >= 10 {
			break
		}
		profit := p.Won - p.Wagered
		sign := "+"
		if profit < 0 {
			sign = "-"
			profit = -profit
		}
		b.WriteString(ufmt.Sprintf("| %d | [%s](%s:player/%s) | %d | %d | %s | %s%s |\n",
			i+1, shortAddr(p.Addr), realmPath(), p.Addr.String(), p.Bets, p.Wins, gnot(p.Wagered), sign, gnot(profit)))
	}
	if len(list) == 0 {
		b.WriteString("| | No players yet | | | | |\n")
	}
	b.WriteString("\nSee your bets and claims at `" + realmPath() + ":player/<your address>`.\n")
	return b.String()
}

func badge(o string) string {
	switch o {
	case Up:
		return "⬆ UP won"
	case Down:
		return "⬇ DOWN won"
	case Tie:
		return "= tie, refunded"
	case OneSided:
		return "one-sided, refunded"
	case Unsettled:
		return "expired, refunded"
	}
	return o
}

func renderPlayer(a address) string {
	var b strings.Builder
	b.WriteString("# Player " + shortAddr(a) + "\n\n[All games](" + realmPath() + ")\n\n")
	pv := players.Get(a.String())
	if pv == nil {
		b.WriteString("No bets yet.\n")
		return b.String()
	}
	p := pv.(*Player)
	b.WriteString(ufmt.Sprintf("%d bets · %d wins · %s wagered · %s paid out\n\n", p.Bets, p.Wins, gnot(p.Wagered), gnot(p.Won)))
	b.WriteString("| Feed | Round | Side | Stake | Result | |\n|---|---|---|---|---|---|\n")
	n := 0
	games.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*Game)
		bv := g.bets.Get(a.String())
		if bv == nil {
			return false
		}
		bt := bv.(*Position)
		side := "⬇ DOWN"
		if bt.Up {
			side = "⬆ UP"
		}
		action := ""
		switch {
		case g.Outcome == Open:
			action = "waiting"
		case bt.Claimed:
			action = "claimed " + gnot(bt.Payout)
		default:
			if owed := payoutFor(g, bt); owed > 0 {
				action = "[Claim " + gnot(owed) + "](" + txlink.NewLink("Claim").AddArgs("pair", g.Pair, "round", strconv.FormatInt(g.Round, 10)).URL() + ")"
			} else {
				action = "lost"
			}
		}
		res := badge(g.Outcome)
		if g.Outcome == Open {
			res = "open"
		}
		b.WriteString(ufmt.Sprintf("| %s | %d | %s | %s | %s | %s |\n", g.Pair, g.Round, side, gnot(bt.Amount), res, action))
		n++
		return n >= 50
	})
	return b.String()
}

func renderJSON() string {
	var items []string
	n := 0
	games.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*Game)
		var bets []string
		g.bets.Iterate("", "", func(_ string, bv any) bool {
			bt := bv.(*Position)
			bets = append(bets, ufmt.Sprintf("{\"addr\":\"%s\",\"up\":%t,\"amount\":%d,\"claimed\":%t,\"owed\":%d}",
				bt.Addr.String(), bt.Up, bt.Amount, bt.Claimed, func() int64 {
					if g.Outcome == Open || bt.Claimed {
						return 0
					}
					return payoutFor(g, bt)
				}()))
			return false
		})
		items = append(items, ufmt.Sprintf("{\"pair\":\"%s\",\"round\":%d,\"startPrice\":%d,\"decimals\":%d,\"openedAt\":%d,\"upPot\":%d,\"downPot\":%d,\"outcome\":\"%s\",\"endRound\":%d,\"endPrice\":%d,\"settleAt\":%d,\"bets\":[%s]}",
			g.Pair, g.Round, g.StartPrice, g.Decimals, g.OpenedAt, g.UpPot, g.DownPot, g.Outcome, g.EndRound, g.EndPrice, g.Round+settleAfter, strings.Join(bets, ",")))
		n++
		return n >= 60
	})
	return ufmt.Sprintf("{\"games\":%d,\"bets\":%d,\"volume\":%d,\"settleAfter\":%d,\"minBet\":%d,\"maxBet\":%d,\"list\":[%s]}",
		totalGames, totalBets, totalVolume, settleAfter, minBet, maxBet, strings.Join(items, ","))
}
