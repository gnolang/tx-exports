package markets

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

// appURL is the exchange interface; the realm page links to it for trading.
const appURL = "https://the67.click"

// pagePath is this realm's gnoweb path, captured at deployment so links between
// its pages work on any chain and namespace.
var pagePath = strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land")

const historyRows = 10

// Render draws the realm's public page on gnoweb: the market list at the root
// and one page per market at ":<id>". It is informational; the app reads JSON.
func Render(path string) string {
	if path == "" {
		return renderIndex()
	}
	r := records[path]
	if r == nil {
		return "# Market not found\n\nThere is no market `" + escapeCode(path) + "` in this realm.\n\n[All markets](" + pagePath + ")\n"
	}
	return renderMarket(r)
}

func renderIndex() string {
	var out strings.Builder
	out.WriteString("# 67\n\n")
	out.WriteString("Questions about the world, priced in GNOT. A share in the outcome that happens pays 1 GNOT.\n\n")
	out.WriteString("[Trade on 67 with the Adena wallet](" + appURL + "/#/markets)\n\n")
	if realmPaused {
		out.WriteString("> [!WARNING] Paused\n> New purchases are paused in every market. Claims are never paused.\n\n")
	}
	if len(marketIDs) == 0 {
		out.WriteString("No markets are listed yet.\n\n")
	} else {
		out.WriteString("| Question | Yes, GNOT | No, GNOT | Status |\n")
		out.WriteString("| :--- | ---: | ---: | :--- |\n")
		for _, id := range marketIDs {
			m := records[id].market
			yes, no := priceText(m.YesPricePpm), priceText(m.NoPricePpm)
			if m.State == StateFinal || m.State == StateProposed {
				yes, no = "–", "–"
			}
			out.WriteString("| [" + escapeText(m.Question) + "](" + pagePath + ":" + id + ") | " + yes + " | " + no + " | " + status(m) + " |\n")
		}
		out.WriteString("\n")
	}
	if runtime.ChainID() != "gnoland-1" {
		out.WriteString("> [!NOTE] Testnet\n")
		out.WriteString("> This is " + runtime.ChainID() + ", a test network: test GNOT has no value.\n\n")
	}
	out.WriteString("Questions, rules and results come from Polymarket. 67 is independent and not affiliated with Polymarket.\n\n")
	out.WriteString("## How a market settles\n\n")
	out.WriteString("The question, its rules, the fee rate and the oracle are fixed when a market is listed. ")
	out.WriteString("Every purchase is fully collateralized: the realm refuses a sale it could not pay out. ")
	out.WriteString("When Polymarket's result is final, the market's oracle proposes it here and trading stops. ")
	out.WriteString("After 24 hours anyone can make it final, and holders of the winning side claim 1 GNOT per share. ")
	out.WriteString("A 50-50 result is void: every holder takes back what they paid, the fee included. ")
	out.WriteString("If nothing is final 60 days after trading ends, anyone can void the market.\n\n")
	out.WriteString("## The fee\n\n")
	out.WriteString("Each purchase pays a service fee of θ × shares × price × (1 − price) GNOT, rounded up to the ugnot. ")
	out.WriteString("θ is fixed per market and can never exceed 0.07. The fee is held until the market is final and returned on void.\n\n")
	out.WriteString("[Functions](" + pagePath + "$help) and [source](" + pagePath + "$source) of this realm.\n")
	return out.String()
}

func renderMarket(r *marketRecord) string {
	m := r.market
	var out strings.Builder
	out.WriteString("# " + escapeText(m.Question) + "\n\n")

	if m.State == StateFinal {
		out.WriteString("<gno-columns>\n")
		out.WriteString("**Result**\n\n" + outcomeName(m, m.Outcome) + "\n\n<gno-columns-sep>\n\n")
		out.WriteString("**Final on**\n\n" + dayText(m.FinalizedAt) + "\n")
		out.WriteString("</gno-columns>\n\n")
	} else {
		out.WriteString("<gno-columns>\n")
		out.WriteString("**" + m.YesLabel + "**\n\n" + priceText(m.YesPricePpm) + " GNOT\n\n<gno-columns-sep>\n\n")
		out.WriteString("**" + m.NoLabel + "**\n\n" + priceText(m.NoPricePpm) + " GNOT\n\n<gno-columns-sep>\n\n")
		out.WriteString("**Status**\n\n" + status(m) + "\n")
		out.WriteString("</gno-columns>\n\n")
	}

	switch m.State {
	case StateFinal:
		out.WriteString("## Result\n\n")
		if m.Outcome == "Void" {
			out.WriteString("The market is void. Every holder takes back what they paid, the fee included, in [the app](" + appURL + "/#/portfolio).\n\n")
		} else {
			out.WriteString(outcomeName(m, m.Outcome) + " won. Holders of " + outcomeName(m, m.Outcome) + " claim 1 GNOT per share in [the app](" + appURL + "/#/portfolio); " + priceText(m.PaidUgnot) + " GNOT has been paid so far.\n\n")
		}
		if m.EvidenceHash != "" {
			out.WriteString("Evidence hash `" + m.EvidenceHash + "`\n\n")
		}
	case StateProposed:
		out.WriteString("## Proposed result\n\n")
		out.WriteString("The oracle proposed " + outcomeName(m, m.Outcome) + " on " + timeText(m.ProposedAt) + " UTC. ")
		out.WriteString("Anyone can make it final from " + timeText(m.ProposedAt+DisputeWindow) + " UTC; until then the guardian can cancel it. Trading has stopped.\n\n")
		out.WriteString("Evidence hash `" + m.EvidenceHash + "`\n\n")
	default:
		out.WriteString("[Buy " + m.YesLabel + " or " + m.NoLabel + " on 67](" + appURL + "/#/market/" + m.ID + ")\n\n")
	}

	out.WriteString("## Rules\n\n")
	for _, line := range strings.Split(m.Rules, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			out.WriteString(escapeText(line) + "\n\n")
		}
	}

	out.WriteString("## Terms fixed at listing\n\n")
	out.WriteString("- Polymarket condition `" + m.ConditionID + "`\n")
	out.WriteString("- Rules hash `" + m.RulesHash + "`, the SHA-256 of the question and the rules above\n")
	out.WriteString("- Oracle " + string(m.Oracle) + "\n")
	out.WriteString("- Fee rate θ = " + priceText(m.FeePpm) + "\n")
	out.WriteString("- Trading ends " + timeText(m.TradingEndsAt) + " UTC; void if nothing is final by " + dayText(m.AbandonAt) + "\n")
	out.WriteString("- Surplus and fees go to " + string(m.Treasury) + ", only after the market is final\n\n")

	out.WriteString("## Record\n\n")
	out.WriteString("- " + countText(m.Trades, "trade", "trades") + ", " + priceText(m.VolumeUgnot) + " GNOT bought, " + priceText(m.FeesCollectedUgnot) + " GNOT in fees\n")
	out.WriteString("- Collateral " + priceText(m.EscrowUgnot) + " GNOT, of which " + priceText(m.ReserveUgnot) + " GNOT was the reserve\n")
	out.WriteString("- Listed on " + dayText(m.CreatedAt) + "\n\n")

	out.WriteString("## Quotes\n\n")
	out.WriteString("| Published, UTC | Yes, GNOT | No, GNOT |\n")
	out.WriteString("| :--- | ---: | ---: |\n")
	from := len(r.history) - historyRows
	if from < 0 {
		from = 0
	}
	for i := len(r.history) - 1; i >= from; i-- {
		point := r.history[i]
		out.WriteString("| " + timeText(point.At) + " | " + priceText(point.YesPricePpm) + " | " + priceText(point.NoPricePpm) + " |\n")
	}
	out.WriteString("\n[All markets](" + pagePath + ")\n")
	return out.String()
}

func status(m Market) string {
	switch m.State {
	case StateFinal:
		if m.Outcome == "Void" {
			return "Void, refunds open"
		}
		return m.Outcome + " won"
	case StateProposed:
		return outcomeName(m, m.Outcome) + " proposed, final from " + dayText(m.ProposedAt+DisputeWindow)
	}
	if time.Now().Unix() >= m.TradingEndsAt {
		return "Awaiting the result"
	}
	if m.State == StatePaused || realmPaused {
		return "Paused"
	}
	return "Open until " + dayText(m.TradingEndsAt)
}

// outcomeName is the outcome as the market names it: Yes and No are the first
// and second token, shown by their names fixed at listing.
func outcomeName(m Market, outcome string) string {
	switch outcome {
	case "Yes":
		return m.YesLabel
	case "No":
		return m.NoLabel
	}
	return outcome
}

// priceText formats millionths like the app: at least two decimals, no
// trailing zeros beyond them (420000 is "0.42", 425000 is "0.425").
func priceText(value int64) string {
	whole := value / scale
	fraction := strconv.FormatInt(value%scale, 10)
	for len(fraction) < 6 {
		fraction = "0" + fraction
	}
	text := strconv.FormatInt(whole, 10) + "." + fraction
	for strings.HasSuffix(text, "0") && len(text)-strings.Index(text, ".") > 3 {
		text = text[:len(text)-1]
	}
	return text
}

func dayText(unix int64) string { return time.Unix(unix, 0).UTC().Format("2 January 2006") }
func timeText(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2 January 2006, 15:04")
}

func countText(n int64, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.FormatInt(n, 10) + " " + many
}

// escapeText keeps question and rules text literal in Markdown, tables included.
func escapeText(s string) string {
	var out strings.Builder
	for _, c := range s {
		switch c {
		case '\\', '`', '*', '_', '[', ']', '<', '>', '|', '#', '~', '!':
			out.WriteByte('\\')
		}
		out.WriteRune(c)
	}
	return out.String()
}

// escapeCode keeps an untrusted path inside one inline code span.
func escapeCode(s string) string {
	s = strings.ReplaceAll(s, "`", "'")
	if len(s) > 64 {
		s = s[:64]
	}
	return s
}
