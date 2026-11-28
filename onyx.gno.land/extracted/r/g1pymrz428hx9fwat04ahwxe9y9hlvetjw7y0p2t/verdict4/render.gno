package verdict4

import (
	"math/overflow"
	"strconv"
	"strings"

	verdict "gno.land/p/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict"
)

const renderRealmPath = "gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict4"

func formatGnot(amount int64) string {
	sign := ""
	if amount < 0 {
		sign = "-"
		amount = -amount
	}
	fraction := strconv.FormatInt(amount%1000000, 10)
	for len(fraction) < 6 {
		fraction = "0" + fraction
	}
	return sign + strconv.FormatInt(amount/1000000, 10) + "." + fraction
}

func marketOdds(market Market) (int64, int64) {
	yesBps, noBps := verdict.CalculateOdds(market.YesPool, market.NoPool)
	return yesBps / 100, noBps / 100
}

func oddsBar(bps int64) string {
	filled := int(bps * 20 / 10000)
	var b strings.Builder
	for i := 0; i < 20; i++ {
		if i < filled {
			b.WriteByte('#')
		} else {
			b.WriteByte('.')
		}
	}
	return b.String()
}

func realmLink() string {
	return "/r/" + strings.TrimPrefix(renderRealmPath, "gno.land/r/")
}

func marketLink(id uint64) string {
	return realmLink() + ":market/" + strconv.FormatUint(id, 10)
}

func statusLabel(market Market) string {
	if market.Status != MarketResolved {
		return "Open"
	}
	switch market.Outcome {
	case verdict.OutcomeYes:
		return "Resolved YES"
	case verdict.OutcomeNo:
		return "Resolved NO"
	default:
		return "Invalid, refunded"
	}
}

func Render(path string) string {
	route := strings.TrimPrefix(path, "/")
	switch {
	case route == "":
		return renderDashboard()
	case strings.HasPrefix(route, "market/"):
		idText := strings.TrimPrefix(route, "market/")
		id, err := strconv.ParseUint(idText, 10, 64)
		if err != nil {
			return renderUnknown()
		}
		market, ok := marketByID(id)
		if !ok {
			return renderUnknown()
		}
		return renderMarketDetail(market)
	case route == "leaderboard":
		return renderLeaderboard()
	default:
		return renderUnknown()
	}
}

func renderDashboard() string {
	var b strings.Builder
	b.WriteString("# Verdict\n\nBinary markets settled from on-chain state.\n\n")
	var volume int64
	for _, market := range marketsInOrder() {
		next, ok := overflow.Add64(volume, totalPool(market))
		if !ok {
			panic("volume overflow")
		}
		volume = next
	}
	b.WriteString("Total volume: ")
	b.WriteString(formatGnot(volume))
	b.WriteString(" GNOT.\n\n")
	b.WriteString("| Market | YES | NO | Volume | Closes | Status |\n")
	b.WriteString("|---|---:|---:|---:|---:|---|\n")
	markets := marketsInOrder()
	if len(markets) == 0 {
		b.WriteString("| No markets yet | | | | | |\n")
	}
	for _, market := range markets {
		yes, no := marketOdds(market)
		b.WriteString("| [")
		b.WriteString(market.Question)
		b.WriteString("](")
		b.WriteString(marketLink(market.ID))
		b.WriteString(") | ")
		b.WriteString(strconv.FormatInt(yes, 10))
		b.WriteString("% | ")
		b.WriteString(strconv.FormatInt(no, 10))
		b.WriteString("% | ")
		b.WriteString(formatGnot(totalPool(market)))
		b.WriteString(" GNOT | #")
		b.WriteString(strconv.FormatInt(market.CloseHeight, 10))
		b.WriteString(" | ")
		b.WriteString(statusLabel(market))
		b.WriteString(" |\n")
	}
	b.WriteString("\n[Leaderboard](")
	b.WriteString(realmLink())
	b.WriteString(":leaderboard)\n")
	return b.String()
}

func renderMarketDetail(market Market) string {
	var b strings.Builder
	b.WriteString("# ")
	b.WriteString(market.Question)
	b.WriteString("\n\nStatus: ")
	b.WriteString(statusLabel(market))
	b.WriteString("\n\n## Settlement\n\n")
	b.WriteString(resolverDescription(market))
	b.WriteString("\n\n## Pools\n\n| Side | Amount |\n|---|---:|\n| YES | ")
	b.WriteString(formatGnot(market.YesPool))
	b.WriteString(" GNOT |\n| NO | ")
	b.WriteString(formatGnot(market.NoPool))
	b.WriteString(" GNOT |\n")

	yesBps, noBps := verdict.CalculateOdds(market.YesPool, market.NoPool)
	yes, no := marketOdds(market)
	b.WriteString("\nImplied odds:\n\n")
	b.WriteString("`YES ` `")
	b.WriteString(oddsBar(yesBps))
	b.WriteString("` ")
	b.WriteString(strconv.FormatInt(yes, 10))
	b.WriteString("%\n\n`NO  ` `")
	b.WriteString(oddsBar(noBps))
	b.WriteString("` ")
	b.WriteString(strconv.FormatInt(no, 10))
	b.WriteString("%\n")

	b.WriteString("\n## Activity\n\n| Bettor | Side | Amount | Block |\n|---|---|---:|---:|\n")
	list := activitiesNewest(func(activity Activity) bool {
		return activity.MarketID == market.ID
	}, maxActivityLimit)
	if len(list) == 0 {
		b.WriteString("| No bets yet | | | |\n")
	}
	for _, activity := range list {
		b.WriteString("| ")
		b.WriteString(activity.Bettor.String())
		b.WriteString(" | ")
		if activity.Side {
			b.WriteString("YES")
		} else {
			b.WriteString("NO")
		}
		b.WriteString(" | ")
		b.WriteString(formatGnot(activity.Stake))
		b.WriteString(" GNOT | ")
		b.WriteString(strconv.FormatInt(activity.Height, 10))
		b.WriteString(" |\n")
	}

	b.WriteString("\n## Calls\n\n")
	b.WriteString("`Bet(marketID, yes)` attaches ugnot while the market is open. ")
	b.WriteString("`Settle(marketID)` is open to any account after the close block. ")
	b.WriteString("`Claim(marketID)` pays a winning or refunded position.\n\n")
	b.WriteString("[All markets](/r/")
	b.WriteString(strings.TrimPrefix(renderRealmPath, "gno.land/"))
	b.WriteString(")\n")
	return b.String()
}

func renderLeaderboard() string {
	var b strings.Builder
	b.WriteString("# Leaderboard\n\nRealized net GNOT from claimed positions.\n\n")
	b.WriteString("| Rank | Account | Net |\n|---:|---|---:|\n")
	entries := leaderboardEntries(maxListLimit)
	if len(entries) == 0 {
		b.WriteString("| | No results yet | |\n")
	}
	for i, item := range entries {
		b.WriteString("| ")
		b.WriteString(strconv.Itoa(i + 1))
		b.WriteString(" | ")
		b.WriteString(item.account.String())
		b.WriteString(" | ")
		b.WriteString(formatGnot(item.net))
		b.WriteString(" GNOT |\n")
	}
	b.WriteString("\n[All markets](")
	b.WriteString(realmLink())
	b.WriteString(")\n")
	return b.String()
}

func renderUnknown() string {
	return "# Verdict\n\nThat page was not found. [View markets](" + realmLink() + ").\n"
}
