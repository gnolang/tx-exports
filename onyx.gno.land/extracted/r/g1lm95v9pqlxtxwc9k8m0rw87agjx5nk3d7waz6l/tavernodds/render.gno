// Render is the gnoweb UI for Tavern Odds: a market list at the realm
// root and a per-market detail page at /<id>.
//
// The question is user-supplied text, so it is passed through
// sanitize.InlineText before being interpolated into the markdown —
// Render input (and stored questions) are attacker-controlled, and raw
// markdown from users can inject links, headings, or HTML.
package tavernodds

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	path = strings.TrimPrefix(path, "/")
	if path == "" {
		return renderHome()
	}
	parts := strings.Split(path, "/")
	id, err := strconv.Atoi(parts[0])
	if err != nil || id <= 0 {
		return renderHome()
	}
	return renderMarket(uint64(id))
}

func fmtTime(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04:05 UTC")
}

func fmtPct(bps int64) string {
	return ufmt.Sprintf("%d.%02d%%", bps/100, bps%100)
}

func marketStatus(m MarketView) string {
	now := nowUnix()
	if !m.Resolved {
		if now < m.CloseTime {
			return "OPEN — trading live"
		}
		return "CLOSED — awaiting resolution"
	}
	if now < m.DisputeEndTime {
		return "RESOLVED — dispute window open until " + fmtTime(m.DisputeEndTime)
	}
	return "REDEEMABLE — winners can claim 1 ugnot per share"
}

func outcomeStr(outcome int) string {
	if outcome == OutcomeYes {
		return "YES"
	}
	if outcome == OutcomeNo {
		return "NO"
	}
	return "unresolved"
}

func renderHome() string {
	out := "# Tavern Odds\n\n"
	out += "Binary prediction markets priced by an LMSR. Buy YES or NO shares "
	out += "in ugnot; winners redeem 1 ugnot per share after the dispute window.\n\n"
	out += "## Markets\n\n"
	if len(markets) == 0 {
		out += "_No markets yet — be the first to create one._\n\n"
	} else {
		for _, m := range markets {
			v := GetMarket(m.ID)
			out += ufmt.Sprintf("### #%d — %s\n\n", v.ID, sanitize.InlineText(v.Question))
			out += ufmt.Sprintf("- YES **%s** · NO **%s**\n", fmtPct(v.YesPriceBps), fmtPct(v.NoPriceBps))
			out += ufmt.Sprintf("- Shares: YES %d · NO %d\n", v.QYes, v.QNo)
			out += ufmt.Sprintf("- Status: %s\n", marketStatus(v))
			out += ufmt.Sprintf("- Closes: %s\n\n", fmtTime(v.CloseTime))
			out += ufmt.Sprintf("[Details](/%d)\n\n", v.ID)
		}
	}
	out += "## How to play\n\n"
	out += "1. **Create a market**: pick a yes/no question, a close time (unix seconds), "
	out += "a liquidity parameter `b`, and a resolver address. Attach at least `b*ln(2)` "
	out += "ugnot with `-send` — that seed is what guarantees winners always get paid.\n"
	out += "2. **Trade**: buy YES if you believe it, NO if you don't. The price moves "
	out += "with every trade (LMSR). Sell any time before close to lock in a price.\n"
	out += "3. **Resolve**: after close, the designated resolver sets the outcome. "
	out += "A 24h dispute window follows, during which nobody can redeem.\n"
	out += "4. **Redeem**: after the dispute window, winners claim 1 ugnot per winning "
	out += "share. Losing shares are worth 0.\n\n"
	out += "All amounts are in **ugnot** (1 GNOT = 1,000,000 ugnot). "
	out += "Trade with `gnokey maketx call` — see a market's detail page for the exact commands.\n"
	return out
}

func renderMarket(id uint64) string {
	if id == 0 || id > uint64(len(markets)) {
		return "# Tavern Odds\n\n_Market not found._\n\n[Back to all markets](/)"
	}
	v := GetMarket(id)
	out := ufmt.Sprintf("# #%d — %s\n\n", v.ID, sanitize.InlineText(v.Question))
	out += ufmt.Sprintf("- Status: **%s**\n", marketStatus(v))
	out += ufmt.Sprintf("- Outcome: **%s**\n", outcomeStr(v.Outcome))
	out += ufmt.Sprintf("- YES price: **%s** · NO price: **%s**\n", fmtPct(v.YesPriceBps), fmtPct(v.NoPriceBps))
	out += ufmt.Sprintf("- Outstanding shares: YES %d · NO %d\n", v.QYes, v.QNo)
	out += ufmt.Sprintf("- Liquidity b: %d ugnot · seeded: %d ugnot · vault: %d ugnot\n",
		v.LiquidityB, v.SeededCollateral, VaultBalance())
	out += ufmt.Sprintf("- Creator: `%s`\n", v.Creator.String())
	out += ufmt.Sprintf("- Resolver: `%s`\n", v.Resolver.String())
	out += ufmt.Sprintf("- Closes: %s\n", fmtTime(v.CloseTime))
	if v.Resolved {
		out += ufmt.Sprintf("- Resolved: %s · redeemable after: %s\n",
			fmtTime(v.ResolveTime), fmtTime(v.DisputeEndTime))
	}
	out += "\n## Trade\n\n"
	out += "```\n"
	out += ufmt.Sprintf("# buy 100 YES shares (attach the exact quoted cost with -send)\n")
	out += ufmt.Sprintf("gnokey maketx call -send <cost>ugnot -gas-fee 5000ugnot -gas-wanted 5000000 -chainid onyx-1 -remote https://rpc.latest.testnets.gno.land:443 <your-key> Buy %d 1 100 <maxCost>\n", v.ID)
	out += ufmt.Sprintf("# sell 100 YES shares\n")
	out += ufmt.Sprintf("gnokey maketx call -gas-fee 5000ugnot -gas-wanted 5000000 -chainid onyx-1 -remote https://rpc.latest.testnets.gno.land:443 <your-key> Sell %d 1 100 0\n", v.ID)
	out += ufmt.Sprintf("# resolve (resolver only, after close) / redeem (after dispute window)\n")
	out += ufmt.Sprintf("gnokey maketx call -gas-fee 5000ugnot -gas-wanted 5000000 -chainid onyx-1 -remote https://rpc.latest.testnets.gno.land:443 <your-key> Resolve %d 1\n", v.ID)
	out += ufmt.Sprintf("gnokey maketx call -gas-fee 5000ugnot -gas-wanted 5000000 -chainid onyx-1 -remote https://rpc.latest.testnets.gno.land:443 <your-key> Redeem %d\n", v.ID)
	out += "```\n\n"
	out += "[Back to all markets](/) \n"
	return out
}
