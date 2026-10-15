// Package home is 67's site on gno.land: what the exchange is, the open
// markets read live from the markets realm, how a market works and what the
// contract does. It holds no funds and no keys. It is private, so the same
// deployer can publish a new version at the same address.
package home

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strings"
	"time"

	"gno.land/r/nym-sixseven067/markets"
)

// appURL is the exchange interface, where Adena signs purchases and claims.
const appURL = "https://the67.click"

const tick = "`"

// homePath and marketsPath are gnoweb paths, captured at deployment.
var (
	homePath    = strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land")
	marketsPath = strings.TrimSuffix(homePath, "/home") + "/markets"
)

// Render serves three pages: the home page, ":how" and ":contract".
func Render(path string) string {
	switch path {
	case "":
		return renderHome()
	case "how":
		return renderHow()
	case "contract":
		return renderContract()
	}
	return "# Page not found\n\nThere is nothing at this address.\n\n[Home](" + homePath + ")\n"
}

func renderHome() string {
	var out strings.Builder
	out.WriteString("# 67\n\n")
	out.WriteString("Questions about the world, priced in GNOT. A share in the outcome that happens pays 1 GNOT.\n\n")
	out.WriteString("[Open the exchange](" + appURL + "/#/markets)\n\n")

	out.WriteString("## Markets\n\n")
	list := markets.ListMarkets()
	if len(list) == 0 {
		out.WriteString("No markets are listed yet.\n\n")
	} else {
		out.WriteString("| Question | Yes, GNOT | No, GNOT | Status |\n")
		out.WriteString("| :--- | ---: | ---: | :--- |\n")
		for _, m := range list {
			out.WriteString("| [" + escapeText(m.Question) + "](" + marketsPath + ":" + m.ID + ") | ")
			if m.Finalized {
				out.WriteString("– | – | " + status(m) + " |\n")
			} else {
				out.WriteString(priceText(m.YesPricePpm) + " | " + priceText(1000000-m.YesPricePpm) + " | " + status(m) + " |\n")
			}
		}
		out.WriteString("\n")
	}

	out.WriteString("## Four calls settle a market\n\n")
	out.WriteString("<gno-columns>\n")
	out.WriteString("**CreateMarket**\n\nThe question, its rules and the oracle are fixed in the realm. Nothing edits them later.\n\n<gno-columns-sep>\n\n")
	out.WriteString("**Buy**\n\nYou pay the exact quoted price. The realm refuses a sale it could not pay out.\n\n<gno-columns-sep>\n\n")
	out.WriteString("**FinalizeByOracle**\n\nWhen Polymarket's result is final, the market's oracle records it, once.\n\n<gno-columns-sep>\n\n")
	out.WriteString("**Claim**\n\nEach winning share pays 1 GNOT from the market's collateral, straight to your address.\n")
	out.WriteString("</gno-columns>\n\n")

	out.WriteString("[How it works](" + homePath + ":how) and [what the contract does](" + homePath + ":contract), in full.\n\n")
	out.WriteString(footer())
	return out.String()
}

func renderHow() string {
	var out strings.Builder
	out.WriteString("# A share pays 1 GNOT if it's right\n\n")
	out.WriteString("Everything else on 67 follows from that sentence: what a price means, why every market holds collateral, and when you get paid.\n\n")

	out.WriteString("## The question\n\n")
	out.WriteString("Every question is copied word for word from a Polymarket market, rules included. When it is listed, the realm stores the question, the rules, their hash, the Polymarket condition and both outcome tokens. None of it can be edited later.\n\n")
	out.WriteString("Copying the words is not a link to Polymarket's money: there is no shared order book and no shared liquidity.\n\n")

	out.WriteString("## The price\n\n")
	out.WriteString("Prices are 67's own fixed quotes. The operator follows Polymarket's midpoint for the Yes token and publishes a new quote when it moves. Each quote is numbered and kept in the market's history.\n\n")
	out.WriteString("Yes and No always add up to 1 GNOT, so a Yes price of 0.42 is also a 42% quote. It is a price, not a forecast.\n\n")
	out.WriteString("```\nshares = floor(spend × 1,000,000 ÷ price)\ncost   = ceil(shares × price ÷ 1,000,000)\n```\n\n")

	out.WriteString("## The review\n\n")
	out.WriteString("A purchase carries the price the buyer reviewed and pays the exact cost. If the quote moved in the meantime, the realm refuses and only the network fee is spent.\n\n")

	out.WriteString("## The collateral\n\n")
	out.WriteString("Each market holds its own collateral: reserve funding first, then the cost of every purchase. The realm refuses any purchase after which the larger side could not be paid in full.\n\n")
	out.WriteString("Only winning claims take collateral out. There is no withdrawal function, not even for the administrator.\n\n")
	out.WriteString("```\nmax(Yes shares, No shares) ≤ collateral   (all in ugnot)\n```\n\n")

	out.WriteString("## The result\n\n")
	out.WriteString("Each market names its oracle when it is listed. Only that address can finalize it, once, and only by repeating the market's full source binding with a hash of the evidence. Trading stops in the same transaction.\n\n")
	out.WriteString("A Polymarket price near 100% is not a result. Until the oracle finalizes, nothing pays.\n\n")

	out.WriteString("## The claim\n\n")
	out.WriteString("When a market is final, each winning share pays 1 GNOT from that market's collateral, straight to your address. A losing position closes with zero, and a second claim is refused.\n\n")

	out.WriteString("## Where to trade\n\n")
	out.WriteString("In [the app](" + appURL + "/#/markets), where the Adena wallet signs each purchase after you review it. ")
	out.WriteString("Or directly with gnokey: ask the realm for the exact cost with " + tick + "Quote(id, outcome, microShares)" + tick + ", then call [Buy](" + marketsPath + "$help&func=Buy) with that amount.\n\n")
	out.WriteString("There is no selling yet: a position is held until its market is final.\n\n")

	out.WriteString("[Home](" + homePath + ")\n")
	return out.String()
}

type call struct {
	name, who, signature, text string
	refusals                   []string
}

var calls = []call{
	{"CreateMarket", "Administrator", "CreateMarket(cur, id, question, rules, conditionID, yesTokenID, noTokenID string, closesAt, yesPricePpm int64, oracle address)",
		"Lists a market and freezes every field used to match the external result: the question, the rules and their hash, the Polymarket condition, both outcome tokens, the closing time and the oracle. There is no function that edits any of them afterwards.",
		[]string{"administrator only", "market already exists", "closing time must be in the future", "invalid fixed price"}},
	{"Fund", "Anyone", "Fund(cur, id string)",
		"Adds reserve collateral to one market. The money belongs to that market only and nothing withdraws it, not even the administrator.",
		[]string{"market funding closed"}},
	{"SetQuote", "Administrator", "SetQuote(cur, id string, yesPricePpm, expectedVersion int64)",
		"Publishes a new fixed Yes price while trading is open and adds it to the quote history. The expected version stops an operator from overwriting a quote they have not seen.",
		[]string{"trading closed", "quote version changed", "quote unchanged"}},
	{"Buy", "Any account", "Buy(cur, id, outcome string, microShares, expectedPricePpm int64)",
		"Buys Yes or No shares at the price the buyer reviewed. The payment must be the exact cost, and the market's collateral must cover the larger side if it wins.",
		[]string{"trading closed", "price does not match review", "send the exact quoted ugnot amount", "insufficient market collateral"}},
	{"FinalizeByOracle", "The market's oracle", "FinalizeByOracle(cur, id, conditionID, rulesHash, yesTokenID, noTokenID, winner, evidenceHash string)",
		"Records the final outcome once, with a hash of the evidence. The call must repeat the market's whole source binding, so a result for another question cannot land here. Trading stops in the same transaction.",
		[]string{"oracle only", "outcome already final", "source binding mismatch"}},
	{"Claim", "A position holder", "Claim(cur, id string) int64",
		"Pays the caller's winning shares, 1 GNOT each, from that market's collateral. A losing position closes with zero; a second claim is refused.",
		[]string{"outcome is not final", "no position", "position already claimed"}},
	{"ProposeAdministrator", "Administrator", "ProposeAdministrator(cur, next address)",
		"Starts a two-step handover. Nothing changes until the proposed address accepts from its own account, so a mistyped address cannot take over. Markets keep the oracle they were created with.",
		[]string{"administrator only", "invalid administrator"}},
	{"AcceptAdministrator", "The proposed address", "AcceptAdministrator(cur)",
		"Completes the handover.",
		[]string{"pending administrator only"}},
}

func renderContract() string {
	var out strings.Builder
	out.WriteString("# One realm, every rule\n\n")
	out.WriteString("67 is one Gno package, [" + tick + "gno.land" + marketsPath + tick + "](" + marketsPath + "). It holds each market's collateral, the published quotes, every position and the payouts. The app only reads it and asks Adena to sign calls to it.\n\n")
	out.WriteString("Administrator " + string(markets.Administrator()) + "\n\n")

	out.WriteString("## Units\n\n")
	out.WriteString("All amounts are whole " + tick + "ugnot" + tick + ": one GNOT is 1,000,000 ugnot. A share is 1,000,000 micro-shares, and a winning micro-share pays 1 ugnot, so a winning share pays exactly 1 GNOT.\n\n")
	out.WriteString("Prices are parts per million of that payout. A Yes price of " + tick + "420000" + tick + " means 0.42 GNOT per share; the No price is always the rest, " + tick + "580000" + tick + ".\n\n")

	out.WriteString("## What each call does\n\n")
	out.WriteString("Each function checks its own conditions and stops the whole transaction when one fails. The refusals are its exact messages.\n\n")
	for _, c := range calls {
		out.WriteString("### [" + c.name + "](" + marketsPath + "$help&func=" + c.name + ")\n\n")
		out.WriteString(c.who + ". " + c.text + "\n\n")
		out.WriteString(tick + c.signature + tick + "\n\n")
		out.WriteString("Refuses with " + tick + strings.Join(c.refusals, tick+", "+tick) + tick + ".\n\n")
	}

	out.WriteString("## Read without signing\n\n")
	for _, fn := range []string{"MarketsJSON()", "MarketJSON(id)", "PositionsJSON(owner)", "QuoteHistory(id)", "Quote(id, outcome, microShares)", "Render(path)"} {
		out.WriteString("- " + tick + fn + tick + "\n")
	}
	out.WriteString("\nEvents for indexers: " + tick + "MarketCreated" + tick + ", " + tick + "QuoteUpdated" + tick + ", " + tick + "Funded" + tick + ", " + tick + "Bought" + tick + ", " + tick + "Finalized" + tick + ", " + tick + "Claimed" + tick + ", " + tick + "AdministratorProposed" + tick + ", " + tick + "AdministratorAccepted" + tick + ".\n\n")

	out.WriteString("## What it cannot do\n\n")
	out.WriteString("- Edit a question, its rules, its source or its oracle\n")
	out.WriteString("- Withdraw collateral, for anyone\n")
	out.WriteString("- Sell or cancel a position\n")
	out.WriteString("- Learn a result by itself: only the pinned oracle can finalize\n\n")

	out.WriteString("[Source of the realm](" + marketsPath + "$source)\n\n")
	out.WriteString("[Home](" + homePath + ")\n")
	return out.String()
}

func footer() string {
	var out strings.Builder
	if runtime.ChainID() != "gnoland-1" {
		out.WriteString("> [!NOTE] Testnet\n")
		out.WriteString("> This is " + runtime.ChainID() + ", a test network: test GNOT has no value.\n\n")
	}
	out.WriteString("Questions, rules and results come from Polymarket. 67 is independent and not affiliated with Polymarket.\n")
	return out.String()
}

func status(m markets.Market) string {
	if m.Finalized {
		return m.Winner + " won"
	}
	if time.Now().Unix() >= m.ClosesAt {
		return "Awaiting the result"
	}
	return "Open until " + time.Unix(m.ClosesAt, 0).UTC().Format("2 January 2006")
}

// priceText formats millionths like the app: at least two decimals, no
// trailing zeros beyond them (420000 is "0.42", 425000 is "0.425").
func priceText(value int64) string {
	whole := value / 1000000
	fraction := value % 1000000
	text := ""
	for i := 0; i < 6; i++ {
		text = string(rune('0'+fraction%10)) + text
		fraction /= 10
	}
	for len(text) > 2 && strings.HasSuffix(text, "0") {
		text = text[:len(text)-1]
	}
	return itoa(whole) + "." + text
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	text := ""
	for n > 0 {
		text = string(rune('0'+n%10)) + text
		n /= 10
	}
	return text
}

// escapeText keeps question text literal in Markdown, tables included.
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
