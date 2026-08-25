package pad

import (
	"strconv"
	"strings"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gnomemepad/ammmath"
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
	out += "Self-contained meme launchpad on gno.land â€” bonding curve to locked CPMM (no external AMM).\n\n"
	if !inited {
		out += "> [!CAUTION]\n> Protocol not initialized. Call Init first.\n\n"
		return out
	}
	out += ufmt.Sprintf("- Launches: **%d**\n", launches.Size())
	out += ufmt.Sprintf("- Protocol fees accrued: **%d** ugnot\n\n", protocolFees)
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
		out += "## Locked pool\n\n"
		out += ufmt.Sprintf("- Pool ugnot: **%d**\n", l.PoolUgnot)
		out += ufmt.Sprintf("- Pool tokens: **%d**\n", l.PoolToken)
		out += ufmt.Sprintf("- Spot (ugnot/token x1e6): **%d**\n", spot)
		out += "\n> [!NOTE]\n> Liquidity is permanently locked â€” there is no remove-liquidity path.\n"
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
	out += "2. Create(name, symbol, uri) + CreateBondUgnot â€” fair launch\n"
	out += "3. Buy(id) / Sell(id, amount) â€” bonding curve\n"
	out += "4. Auto or Graduate(id) at threshold\n"
	out += "5. SwapBuy(id) / SwapSell(id, amount) â€” locked CPMM\n"
	out += "6. ClaimCreatorFees(id) / ClaimProtocolFees()\n\n"
	out += "## Params (MVP)\n\n"
	out += ufmt.Sprintf("- Total supply: %d\n", TotalSupply)
	out += ufmt.Sprintf("- Curve sale: %d\n", CurveSupply)
	out += ufmt.Sprintf("- Pool seed: %d\n", PoolSeed)
	out += ufmt.Sprintf("- Graduation: %d ugnot\n", GraduationThreshold)
	out += ufmt.Sprintf("- Fee: %d BPS\n", FeeBPS)
	out += ufmt.Sprintf("- Create bond: %d ugnot\n\n", CreateBondUgnot)
	out += "## Design\n\n"
	out += "- No external AMM â€” this realm is the market\n"
	out += "- Permanent LP lock after graduation\n"
	out += "- EOA + OriginSend payment guards\n"
	out += "- Factory-managed token balances (GRC20 wrap optional later)\n\n"
	out += "[Home](./)\n"
	return out
}
