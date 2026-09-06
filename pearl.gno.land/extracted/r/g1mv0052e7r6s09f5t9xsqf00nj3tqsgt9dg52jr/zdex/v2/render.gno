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
	out := "# zdex v2\n\n"
	out += "GNOT-native AMM generation 2. Two-sided pools, native `ugnot` (no wrap), escrow limit orders.\n"
	out += "Swap fee 0.30% default (tiers 0.05% / 0.30% / 1.00%). Protocol ~1/6 of the fee.\n\n"
	if paused {
		out += "> [!CAUTION]\n> Protocol is paused.\n\n"
	}
	out += ufmt.Sprintf("* Version: **%s**\n* Package: `%s`\n", Version(), thisPkg())
	if nextPkg != "" {
		out += ufmt.Sprintf("* Next: `%s`\n", sanitize.InlineText(nextPkg))
	}
	out += ufmt.Sprintf("* Pools: **%d**\n* Open orders: **%d**\n* Admin: `%s`\n\n",
		pools.Size(), orders.Size(), admin.String())

	out += "## Pools\n\n"
	if pools.Size() == 0 {
		out += "_None yet. Create a two-sided pool._\n\n"
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

	out += "## Create a pool\n\n"
	out += "Two-sided ugnot/GRC20. Min **1 GNOT**. Fee tiers 5 / 30 / 100 bps. Protocol takes ~1/6 of the swap fee; the rest stays as LP.\n\n"
	out += "<gno-form exec=\"CreatePool\">\n"
	out += "<gno-input name=\"tokenKey\" placeholder=\"GRC20 registry key\" required=\"true\" />\n"
	out += "<gno-input name=\"symbol\" placeholder=\"SYMBOL\" required=\"true\" />\n"
	out += "<gno-input name=\"amountU\" type=\"number\" placeholder=\"ugnot (>= 1000000)\" required=\"true\" />\n"
	out += "<gno-input name=\"amountT\" type=\"number\" placeholder=\"token amount\" required=\"true\" />\n"
	out += "<gno-input name=\"feeBps\" type=\"number\" placeholder=\"30 = 0.30%\" required=\"true\" />\n"
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
