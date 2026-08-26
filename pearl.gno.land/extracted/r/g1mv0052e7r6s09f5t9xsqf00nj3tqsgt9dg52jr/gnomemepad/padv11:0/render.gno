package padv11

import (
	"strconv"
	"strings"

	ammmath "gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gnomemepad/ammmathv2"
	"gno.land/p/nt/ufmt/v0"
)

// Render provides on-chain discovery (gnoweb). Read-only by convention.
//
// Paths:
//
//	""              â€” home / list
//	token/{id}      â€” launch detail
//	help            â€” API help
func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderHome()
	}
	if path == "help" {
		return renderHelp()
	}
	if strings.HasPrefix(path, "token/") {
		id := strings.TrimPrefix(path, "token/")
		return renderToken(id)
	}
	return "> [!WARNING]\n> Path not found: " + sanitize(path) + "\n"
}

func sanitize(s string) string {
	s = strings.ReplaceAll(s, "`", "'")
	s = strings.ReplaceAll(s, "<", "")
	s = strings.ReplaceAll(s, ">", "")
	return s
}

func renderHome() string {
	out := "# gnomemepad\n\n"
	out += "Meme launchpad â€” bonding curve â†’ remaining tokens + raised liquid (Gnoswap auto-list when funded).\n\n"
	if !inited {
		out += "> [!CAUTION]\n> Protocol not initialized. Call Init first.\n\n"
		return out
	}
	out += ufmt.Sprintf("- Launches: **%d**\n", launches.Size())
	if protocolAddr.IsValid() {
		out += ufmt.Sprintf("- Protocol treasury: `%s`\n", protocolAddr.String())
	}
	out += ufmt.Sprintf("- Protocol fees pending (claim/push): **%d** ugnot\n", protocolFees)
	out += ufmt.Sprintf("- Protocol fees paid (lifetime): **%d** ugnot\n\n", protocolFeesPaid)
	out += "## Markets\n\n"
	if launches.Size() == 0 {
		out += "_No launches yet. Call Create with name, symbol, uri and bond._\n"
		return out
	}
	launches.Iterate("", "", func(key string, value any) bool {
		l := value.(*Launch)
		st := "curve"
		if l.Status == StatusGraduated {
			st = "graduated"
		}
		out += ufmt.Sprintf("- [%s ($%s)](token/%s) â€” %s â€” raised %d ugnot â€” buyers %d\n",
			sanitize(l.Name), sanitize(l.Symbol), l.ID, st, l.RaisedUgnot, l.BuyerCount)
		return false
	})
	out += "\n[Help](help)\n"
	return out
}

func renderToken(id string) string {
	id = sanitize(id)
	l, ok := launches.Get(id).(*Launch)
	if !ok {
		return "> [!WARNING]\n> Unknown launch " + id + "\n\n[Home](./)\n"
	}
	st := "bonding curve"
	if l.Status == StatusGraduated {
		st = "graduated pool (LP locked)"
	}
	out := ufmt.Sprintf("# %s ($%s)\n\n", sanitize(l.Name), sanitize(l.Symbol))
	out += ufmt.Sprintf("- **ID:** %s\n", l.ID)
	out += ufmt.Sprintf("- **Status:** %s\n", st)
	out += ufmt.Sprintf("- **Creator:** %s\n", l.Creator.String())
	if l.URI != "" {
		out += ufmt.Sprintf("- **URI:** %s\n", sanitize(l.URI))
	}
	out += ufmt.Sprintf("- **Unique buyers:** %d\n", l.BuyerCount)
	out += ufmt.Sprintf("- **Creator fees (claimable):** %d ugnot\n\n", l.CreatorFees)

	if l.Status == StatusCurve {
		remaining := CurveSupply - l.RealSold
		pct := int64(0)
		if GraduationThreshold > 0 {
			pct = l.RaisedUgnot * 100 / GraduationThreshold
			if pct > 100 {
				pct = 100
			}
		}
		spot := ammmath.SpotPriceUgnotPerToken(l.VirtualUgnot, l.VirtualToken)
		out += "## Bonding curve\n\n"
		out += ufmt.Sprintf("- Raised: **%d** / %d ugnot (%d%%)\n", l.RaisedUgnot, GraduationThreshold, pct)
		out += ufmt.Sprintf("- Tokens sold: **%d** / %d\n", l.RealSold, CurveSupply)
		out += ufmt.Sprintf("- Remaining on curve: **%d**\n", remaining)
		out += ufmt.Sprintf("- Spot (ugnot/token x1e6): **%d**\n", spot)
		out += "\nProgress toward graduation:\n\n"
		out += progressBar(pct) + "\n"
	} else {
		spot := ammmath.SpotPriceUgnotPerToken(l.PoolUgnot, l.PoolToken)
		out += "## Liquidity (post-graduate)\n\n"
		out += ufmt.Sprintf("- Raised capital (record): **%d** ugnot\n", l.PoolUgnot)
		out += ufmt.Sprintf("- Remaining tokens seeded: **%d**\n", l.PoolToken)
		out += ufmt.Sprintf("- Spot (ugnot/token x1e6): **%d**\n", spot)
		if l.GnoswapListed {
			out += ufmt.Sprintf("- **Gnoswap listed:** `%s`\n", sanitize(l.GnoswapPoolPath))
			out += ufmt.Sprintf("- Position NFT id: **%d** (pad-owned, locked)\n", l.GnoswapPositionID)
			out += ufmt.Sprintf("- Fee WUGNOT spent: **%d** Â· LP WUGNOT: **%d**\n", l.FeeWugnotSpent, l.LiqWugnotUsed)
			out += "\n> [!NOTE]\n> Trade on Gnoswap router â€” pad SwapBuy/SwapSell disabled after auto-list.\n"
		} else {
			out += ufmt.Sprintf("- Gnoswap: %s\n", sanitize(l.GnoswapNote))
			out += "\n> [!NOTE]\n> Internal CPMM locked (fallback). Fund pad WUGNOT inventory before graduate for auto-list.\n"
		}
	}

	out += "\n## Trade\n\n"
	out += "Use wallet MsgCall (payable txs):\n\n"
	if l.Status == StatusCurve {
		out += ufmt.Sprintf("- Buy(id) with -send ugnot â€” id=%s\n", l.ID)
		out += "- Sell(id, tokensIn)\n"
		out += "- Graduate(id) when threshold met\n"
	} else {
		out += "- SwapBuy(id) with -send ugnot\n"
		out += "- SwapSell(id, tokensIn)\n"
	}
	out += "\n[Home](./) Â· [Help](help)\n"
	return out
}

func progressBar(pct int64) string {
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	filled := int(pct / 5)
	bar := "["
	for i := 0; i < 20; i++ {
		if i < filled {
			bar += "#"
		} else {
			bar += "."
		}
	}
	bar += "] " + strconv.FormatInt(pct, 10) + "%"
	return bar
}

func renderHelp() string {
	out := "# gnomemepad API\n\n"
	out += "## Lifecycle\n\n"
	out += "1. Init() â€” once; caller becomes protocol treasury\n"
	out += "2. Create(name, symbol, uri) + bond from bond realm (promo/normal)\n"
	out += "3. Buy(id, minTokensOut) / Sell(id, amount, minUgnotOut) â€” bonding curve\n"
	out += "4. Auto or Graduate(id) at threshold\n"
	out += "5. Graduate seeds remaining tokens + raised as liquidity\n"
	out += "   â†’ auto Gnoswap CreatePool+Mint if pad has WUGNOT inventory\n"
	out += "   â†’ else locked internal CPMM (SwapBuy/SwapSell)\n"
	out += "6. Transfer / Approve / TransferFrom â€” GRC20\n"
	out += "7. Fees:\n"
	out += "   - Creator: ClaimCreatorFees(id) â€” only creator, **must claim**\n"
	out += "   - Protocol: ClaimProtocolFees() (treasury) or PushProtocolFees() (anyone â†’ treasury)\n"
	out += "   - TransferProtocol(newAddr) / WithdrawProtocolUgnot(amount) â€” treasury ops\n"
	out += "   - Gnoswap CreatePool GNS fee goes to Gnoswap, not pad treasury\n\n"
	out += "## Params (MVP)\n\n"
	out += ufmt.Sprintf("- Total supply: %d\n", TotalSupply)
	out += ufmt.Sprintf("- Curve sale: %d\n", CurveSupply)
	out += ufmt.Sprintf("- LP tokens at grad: TotalSupply - RealSold (was PoolSeed=%d)\n", PoolSeed)
	out += ufmt.Sprintf("- Graduation: %d ugnot\n", GraduationThreshold)
	out += ufmt.Sprintf("- Fee: %d BPS\n", FeeBPS)
	out += ufmt.Sprintf("- Create bond (live): %d ugnot\n\n", requiredCreateBond())
	out += "## Design\n\n"
	out += "- Remaining tokens + raised GNOT â†’ liquidity at graduate\n"
	out += "- Part of WUGNOT inventory swaps to GNS for CreatePool fee\n"
	out += "- Permanent LP lock (pad holds Gnoswap position NFT)\n"
	out += "- EOA + OriginSend payment guards\n\n"
	out += "[Home](./)\n"
	return out
}
