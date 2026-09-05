package zdex

import (
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	switch path {
	case "", "home":
		return renderHome()
	case "book":
		return renderBook()
	default:
		if len(path) > 5 && path[:5] == "pool/" {
			return renderPool(path[5:])
		}
		if len(path) > 6 && path[:6] == "token/" {
			return renderToken(path[6:])
		}
		return "> [!WARNING]\n> Path not found.\n"
	}
}

func renderHome() string {
	out := "# zdex\n\n"
	out += "Singleton AMM on Gno.land. Native `ugnot` (no wrap), vested launches, "
	out += "snipe caps, escrowed limit orders.\n\n"
	if paused {
		out += "> [!CAUTION]\n> Protocol is paused.\n\n"
	}
	out += ufmt.Sprintf("* Pools: **%d**\n* Open orders: **%d**\n* Admin: `%s`\n\n",
		pools.Size(), orders.Size(), admin.String())

	out += "## Pools\n\n"
	if pools.Size() == 0 {
		out += "_None yet. Launch a coin below._\n\n"
	} else {
		out += "| Pair | ugnot | token | virtual | fee | launch |\n|---|---:|---:|---:|---:|---|\n"
		pools.Iterate("", "", func(_ string, v any) bool {
			p := v.(*Pool)
			out += ufmt.Sprintf("| [%s](pool/%s) | %d | %d | %d | %d bps | %s |\n",
				sanitize.InlineText(p.Symbol), p.ID, p.ReserveU, p.ReserveT, p.VirtualU, p.FeeBps, yesno(p.Launched))
			return false
		})
		out += "\n"
	}

	out += "## Swap\n\n"
	out += "<gno-form exec=\"SwapExactIn\">\n"
	out += "<gno-input name=\"poolID\" placeholder=\"ugnot|SYMBOL\" required=\"true\" />\n"
	out += "<gno-input name=\"tokenIn\" placeholder=\"ugnot or SYMBOL\" required=\"true\" />\n"
	out += "<gno-input name=\"amountIn\" type=\"number\" placeholder=\"amount in\" required=\"true\" />\n"
	out += "<gno-input name=\"minOut\" type=\"number\" placeholder=\"min out\" required=\"true\" />\n"
	out += "<gno-input name=\"maxHeight\" type=\"number\" placeholder=\"deadline height (0=none)\" />\n"
	out += "</gno-form>\n\n"

	out += "## Launch a coin\n\n"
	out += "Creator keep is capped at 20% and **vests**. LP is locked. First-block buys are capped.\n\n"
	out += "<gno-form exec=\"Launch\">\n"
	out += "<gno-input name=\"name\" placeholder=\"Name\" required=\"true\" />\n"
	out += "<gno-input name=\"symbol\" placeholder=\"SYMBOL\" required=\"true\" />\n"
	out += "<gno-input name=\"decimals\" type=\"number\" placeholder=\"0\" required=\"true\" />\n"
	out += "<gno-input name=\"totalSupply\" type=\"number\" placeholder=\"1000000000\" required=\"true\" />\n"
	out += "<gno-input name=\"creatorKeepBps\" type=\"number\" placeholder=\"1000 = 10%\" required=\"true\" />\n"
	out += "<gno-input name=\"virtualUgnot\" type=\"number\" placeholder=\"starting virtual ugnot\" required=\"true\" />\n"
	out += "<gno-input name=\"vestBlocks\" type=\"number\" placeholder=\"28800 (~1 day)\" required=\"true\" />\n"
	out += "<gno-input name=\"lockBlocks\" type=\"number\" placeholder=\"28800\" required=\"true\" />\n"
	out += "<gno-input name=\"snipeBlocks\" type=\"number\" placeholder=\"1000\" required=\"true\" />\n"
	out += "<gno-input name=\"snipeMaxBps\" type=\"number\" placeholder=\"200 = 2%\" required=\"true\" />\n"
	out += "</gno-form>\n\n"

	out += "[Order book](book)\n"
	return out
}

func renderPool(id string) string {
	id = sanitize.InlineText(id)
	p := tryPool(id)
	if p == nil {
		return "> [!WARNING]\n> Pool not found.\n"
	}
	out := ufmt.Sprintf("# Pool %s\n\n", sanitize.InlineText(p.Symbol))
	out += ufmt.Sprintf("* Token: `%s`\n* Real ugnot: **%d**\n* Real token: **%d**\n* Virtual ugnot: **%d**\n",
		p.Token, p.ReserveU, p.ReserveT, p.VirtualU)
	out += ufmt.Sprintf("* Fee: %d bps (creator share %d, protocol %d)\n* LP: %d\n* Unlock height: %d (now %d)\n",
		p.FeeBps, p.CreatorBps, p.ProtocolBps, p.TotalLP, p.UnlockHeight, height())
	if p.SnipeUntil > height() {
		out += ufmt.Sprintf("* Snipe cap: %d bps until height %d\n", p.SnipeMaxBps, p.SnipeUntil)
	}
	out += "\n## Swap on this pool\n\n"
	out += "<gno-form exec=\"SwapExactIn\">\n"
	out += ufmt.Sprintf("<gno-input name=\"poolID\" value=\"%s\" required=\"true\" />\n", p.ID)
	out += "<gno-input name=\"tokenIn\" placeholder=\"ugnot or symbol\" required=\"true\" />\n"
	out += "<gno-input name=\"amountIn\" type=\"number\" required=\"true\" />\n"
	out += "<gno-input name=\"minOut\" type=\"number\" required=\"true\" />\n"
	out += "<gno-input name=\"maxHeight\" type=\"number\" />\n"
	out += "</gno-form>\n"
	return out
}

func renderToken(symbol string) string {
	symbol = sanitize.InlineText(symbol)
	rec := tryTok(symbol)
	out := ufmt.Sprintf("# %s\n\n", symbol)
	if rec != nil {
		out += rec.token.RenderHome() + "\n"
	}
	p := tryPool(poolIDFor(symbol))
	if p != nil {
		out += ufmt.Sprintf("[Open pool](pool/%s)\n", p.ID)
	}
	return out
}

func renderBook() string {
	out := "# Order book\n\n"
	if orders.Size() == 0 {
		out += "_No resting orders._\n\n"
	} else {
		out += "| id | side | pool | give | want | maker |\n|---:|---|---|---:|---:|---|\n"
		orders.Iterate("", "", func(_ string, v any) bool {
			o := v.(*Order)
			side := "ask"
			if o.GiveUgnot {
				side = "bid"
			}
			out += ufmt.Sprintf("| %d | %s | %s | %d | %d | `%s` |\n",
				o.ID, side, o.PoolID, o.GiveAmt, o.WantAmt, o.Maker.String())
			return false
		})
		out += "\n"
	}
	out += "## Place bid (pay ugnot, receive token)\n\n"
	out += "<gno-form exec=\"PlaceBid\">\n"
	out += "<gno-input name=\"poolID\" required=\"true\" />\n"
	out += "<gno-input name=\"giveU\" type=\"number\" placeholder=\"ugnot escrowed\" required=\"true\" />\n"
	out += "<gno-input name=\"wantAmt\" type=\"number\" placeholder=\"tokens wanted\" required=\"true\" />\n"
	out += "<gno-input name=\"expireH\" type=\"number\" placeholder=\"0 = never\" />\n"
	out += "<gno-input name=\"allOrNone\" placeholder=\"false\" />\n"
	out += "</gno-form>\n\n"
	out += "## Place ask (pay token, receive ugnot)\n\n"
	out += "<gno-form exec=\"PlaceAsk\">\n"
	out += "<gno-input name=\"poolID\" required=\"true\" />\n"
	out += "<gno-input name=\"giveT\" type=\"number\" placeholder=\"token escrowed\" required=\"true\" />\n"
	out += "<gno-input name=\"wantU\" type=\"number\" placeholder=\"ugnot wanted\" required=\"true\" />\n"
	out += "<gno-input name=\"expireH\" type=\"number\" />\n"
	out += "<gno-input name=\"allOrNone\" placeholder=\"false\" />\n"
	out += "</gno-form>\n"
	return out
}

func yesno(v bool) string {
	if v {
		return "yes"
	}
	return "no"
}
