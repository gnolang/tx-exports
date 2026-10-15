package markets

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

// appURL is the exchange interface; the realm page links to it for trading.
const appURL = "https://six-seven-67-phi.vercel.app"

// pagePath is this realm's gnoweb path ("/r/<namespace>/markets"), captured at
// deployment so links between its pages work on any chain and namespace.
var pagePath = strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land")

// historyRows is how many recent quotes a market page lists.
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
	if len(marketIDs) == 0 {
		out.WriteString("No markets are listed yet.\n\n")
	} else {
		out.WriteString("| Question | Yes, GNOT | No, GNOT | Status |\n")
		out.WriteString("| :--- | ---: | ---: | :--- |\n")
		for _, id := range marketIDs {
			m := records[id].market
			out.WriteString("| [" + escapeText(m.Question) + "](" + pagePath + ":" + id + ") | ")
			out.WriteString(priceText(m.YesPricePpm) + " | " + priceText(scale-m.YesPricePpm) + " | " + status(m) + " |\n")
		}
		out.WriteString("\n")
	}
	if runtime.ChainID() != "gnoland-1" {
		out.WriteString("> [!NOTE] Testnet\n")
		out.WriteString("> This is " + runtime.ChainID() + ", a test network: test GNOT has no value.\n\n")
	}
	out.WriteString("Questions, rules and results come from Polymarket. 67 is independent and not affiliated with Polymarket.\n\n")
	out.WriteString("## How a market settles\n\n")
	out.WriteString("The question and its rules are fixed in this realm when a market is listed. ")
	out.WriteString("Every purchase is fully collateralized: the realm refuses a sale it could not pay out, and nobody can withdraw the collateral. ")
	out.WriteString("When Polymarket's result is final, the market's oracle records it here, and holders of the winning side claim 1 GNOT per share.\n\n")
	out.WriteString("[Functions](" + pagePath + "$help) and [source](" + pagePath + "$source) of this realm.\n")
	return out.String()
}

func renderMarket(r *marketRecord) string {
	m := r.market
	var out strings.Builder
	out.WriteString("# " + escapeText(m.Question) + "\n\n")

	out.WriteString("<gno-columns>\n")
	out.WriteString("**Yes**\n\n" + priceText(m.YesPricePpm) + " GNOT\n\n<gno-columns-sep>\n\n")
	out.WriteString("**No**\n\n" + priceText(scale-m.YesPricePpm) + " GNOT\n\n<gno-columns-sep>\n\n")
	out.WriteString("**Status**\n\n" + status(m) + "\n")
	out.WriteString("</gno-columns>\n\n")

	if m.Finalized {
		out.WriteString("## Result\n\n")
		out.WriteString(m.Winner + " won. The oracle recorded it on " + dayText(m.FinalizedAt) + ". ")
		out.WriteString("Holders of " + m.Winner + " claim 1 GNOT per share in [the app](" + appURL + "/#/portfolio); " + priceText(m.PaidUgnot) + " GNOT has been paid so far.\n\n")
		out.WriteString("Evidence hash `" + m.EvidenceHash + "`\n\n")
	} else {
		out.WriteString("[Buy Yes or No on 67](" + appURL + "/#/market/" + m.ID + ")\n\n")
	}

	out.WriteString("## Rules\n\n")
	for _, line := range strings.Split(m.Rules, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			out.WriteString(escapeText(line) + "\n\n")
		}
	}

	out.WriteString("## Source\n\n")
	out.WriteString("- Polymarket condition `" + m.ConditionID + "`\n")
	out.WriteString("- Rules hash `" + m.RulesHash + "`, the SHA-256 of the question and the rules above\n")
	out.WriteString("- Oracle, fixed for this market: " + string(m.Oracle) + "\n\n")

	out.WriteString("## Record\n\n")
	out.WriteString("- " + countText(m.Trades, "trade", "trades") + ", " + priceText(m.VolumeUgnot) + " GNOT bought\n")
	out.WriteString("- Collateral " + priceText(m.EscrowUgnot) + " GNOT\n")
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
		out.WriteString("| " + timeText(point.At) + " | " + priceText(point.YesPricePpm) + " | " + priceText(scale-point.YesPricePpm) + " |\n")
	}
	out.WriteString("\n[All markets](" + pagePath + ")\n")
	return out.String()
}

func status(m Market) string {
	if m.Finalized {
		return m.Winner + " won"
	}
	if time.Now().Unix() >= m.ClosesAt {
		return "Awaiting the result"
	}
	return "Open until " + dayText(m.ClosesAt)
}

// priceText formats millionths like the app: at least two decimals, no
// trailing zeros beyond them (420000 is "0.42", 425000 is "0.425").
func priceText(value int64) string {
	text := ppmPrice(value)
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
