package verdict

import (
	"chain/runtime"
	"net/url"
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
)

func seqidKey(id uint64) string {
	return seqid.ID(id).String()
}

func realmLink(subpath string) string {
	prefix := strings.TrimPrefix(realmPkgPath, runtime.ChainDomain())
	return prefix + ":" + subpath
}

// safeInline escapes user-supplied text once for inline markdown slots and
// escapes literal '$' so gnoweb math mode cannot be triggered by user text.
func safeInline(s string) string {
	return strings.ReplaceAll(sanitize.InlineText(s), "$", "\\$")
}

func safeTableCell(s string) string {
	return strings.ReplaceAll(sanitize.TableCell(s), "$", "\\$")
}

func safeBlock(s string) string {
	return strings.ReplaceAll(sanitize.Block(s), "$", "\\$")
}

func formatGNOT(ugnot int64) string {
	sign := ""
	if ugnot < 0 {
		sign = "-"
		ugnot = -ugnot
	}
	whole := ugnot / 1_000_000
	frac := (ugnot % 1_000_000) / 100 // 4 decimal places
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 4 {
		fracStr = "0" + fracStr
	}
	return sign + strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

func formatProbPct(bps int64) string {
	tenths := bps / 10
	whole := tenths / 10
	dec := tenths % 10
	return strconv.FormatInt(whole, 10) + "." + strconv.FormatInt(dec, 10) + "%"
}

func formatUnixTime(ts int64) string {
	return time.Unix(ts, 0).UTC().Format("2006-01-02 15:04 UTC")
}

func buildRouter() *mux.Router {
	r := mux.NewRouter()
	r.HandleFunc("", renderHome)
	r.HandleFunc("market/{id}", renderMarket)
	r.HandleFunc("create", renderCreate)
	r.HandleFunc("portfolio/{addr}", renderPortfolio)
	r.SetNotFoundHandler(renderNotFound)
	return r
}

// Render returns Gno-Flavored Markdown rendered by gnoweb for the given route.
func Render(path string) string {
	clearPath, query, hasQuery := strings.Cut(path, "?")
	clearPath = strings.Trim(clearPath, "/")
	normalized := clearPath
	if hasQuery {
		normalized = clearPath + "?" + query
	}
	return router.Render(normalized)
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	stats := GetStats()
	catFilter := strings.TrimSpace(req.Query.Get("cat"))
	page := 1
	if pStr := req.Query.Get("page"); pStr != "" {
		if parsed, err := strconv.Atoi(pStr); err == nil && parsed > 0 {
			page = parsed
		}
	}

	const pageSize = 10
	offset := (page - 1) * pageSize

	var sb strings.Builder
	sb.WriteString("# Verdict — On-Chain Prediction Markets\n\n")
	sb.WriteString("Permissionless binary markets powered by deterministic 128-bit CPMM math, bonded optimistic resolution, and M-of-N arbiter escalation.\n\n")

	sb.WriteString("<gno-columns>\n")
	sb.WriteString("<gno-frame>\n")
	sb.WriteString("### Markets\n\n")
	sb.WriteString("**" + strconv.Itoa(stats.MarketCount) + "** total (" + strconv.Itoa(stats.ResolvedMarketCount) + " resolved)\n")
	sb.WriteString("</gno-frame>\n")
	sb.WriteString("<gno-columns-sep />\n")
	sb.WriteString("<gno-frame>\n")
	sb.WriteString("### Collateral Locked\n\n")
	sb.WriteString("**" + formatGNOT(stats.TotalCollateral) + "**\n")
	sb.WriteString("</gno-frame>\n")
	sb.WriteString("<gno-columns-sep />\n")
	sb.WriteString("<gno-frame>\n")
	sb.WriteString("### Cumulative Volume\n\n")
	sb.WriteString("**" + formatGNOT(stats.TotalVolume) + "** (" + strconv.FormatInt(stats.TotalTrades, 10) + " trades)\n")
	sb.WriteString("</gno-frame>\n")
	sb.WriteString("</gno-columns>\n\n")

	sb.WriteString("<gno-button href=\"" + realmLink("create") + "\" label=\"+ Create Market\" variant=\"success\" /> ")
	sb.WriteString("<gno-button href=\"" + txlink.NewLink("ClaimBonds").URL() + "\" label=\"Claim My Bonds\" variant=\"outline\" />\n\n")

	if catFilter != "" {
		sb.WriteString("Filtered by category: **" + safeInline(catFilter) + "** — [Clear filter](" + realmLink("?page=1") + ")\n\n")
	}

	sb.WriteString("## Active & Recent Markets\n\n")

	all := ListMarkets(offset, pageSize)
	if len(all) == 0 {
		sb.WriteString("> [!NOTE]\n")
		sb.WriteString("> No markets found on this page yet. Create the first binary market using the button above.\n")
		res.Write(sb.String())
		return
	}

	sb.WriteString("| ID | Question | Category | Status | YES / NO | Odds Bar | Liquidity | Volume |\n")
	sb.WriteString("| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n")

	shown := 0
	for _, m := range all {
		if catFilter != "" && !strings.EqualFold(m.Category, catFilter) {
			continue
		}
		shown++
		idStr := strconv.FormatUint(m.ID, 10)
		qLink := "[#" + idStr + " " + safeTableCell(m.Question) + "](" + realmLink("market/"+idStr) + ")"
		catLink := "[" + safeTableCell(m.Category) + "](" + realmLink("?cat="+url.QueryEscape(m.Category)) + ")"
		odds := "**" + formatProbPct(m.YesProbBps) + "** / " + formatProbPct(m.NoProbBps)
		bar := renderMiniOddsBarMarkdown(m.YesProbBps)
		statusStr := m.StatusLabel
		if m.Status == StatusResolved {
			statusStr = "RESOLVED (" + m.FinalOutcomeLabel + ")"
		}
		sb.WriteString("| " + idStr + " | " + qLink + " | " + catLink + " | " + statusStr + " | " + odds + " | " + bar + " | " + formatGNOT(m.Collateral) + " | " + formatGNOT(m.TotalVolume) + " |\n")
	}

	if shown == 0 {
		sb.WriteString("| - | No matching markets in this category | - | - | - | - | - | - |\n")
	}

	sb.WriteString("\n")
	if page > 1 {
		sb.WriteString("[Previous Page](" + realmLink("?page="+strconv.Itoa(page-1)) + ")  ")
	}
	if len(all) == pageSize {
		sb.WriteString("[Next Page](" + realmLink("?page="+strconv.Itoa(page+1)) + ")")
	}
	sb.WriteString("\n")

	res.Write(sb.String())
}

func renderMarket(res *mux.ResponseWriter, req *mux.Request) {
	idStr := req.GetVar("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil || id == 0 {
		renderNotFound(res, req)
		return
	}
	m := getMarketOrNil(id)
	if m == nil {
		renderNotFound(res, req)
		return
	}

	var sb strings.Builder
	sb.WriteString("[← Back to All Markets](" + realmLink("") + ")\n\n")
	sb.WriteString("# #" + idStr + " — " + safeInline(m.question) + "\n\n")
	sb.WriteString("**Category:** `" + safeInline(m.category) + "` · **Creator:** " + m.creator.String() + " · **Closes:** `" + formatUnixTime(m.closeTime) + "` · **Fee:** `" + formatProbPct(m.pool.FeeBps) + "`\n\n")

	if m.description != "" {
		sb.WriteString(safeBlock(m.description))
	}

	sb.WriteString(renderOddsChartMarkdown(m.priceHistory, m.pool.YesProbBps(), m.status, m.finalOutcome) + "\n\n")

	sb.WriteString("<gno-columns>\n")
	sb.WriteString("<gno-frame>\n")
	sb.WriteString("### YES Odds\n\n")
	sb.WriteString("**" + formatProbPct(m.pool.YesProbBps()) + "**\n\nPool YES reserve: `" + formatGNOT(m.pool.ReserveYes) + "`\n")
	sb.WriteString("</gno-frame>\n")
	sb.WriteString("<gno-columns-sep />\n")
	sb.WriteString("<gno-frame>\n")
	sb.WriteString("### NO Odds\n\n")
	sb.WriteString("**" + formatProbPct(m.pool.NoProbBps()) + "**\n\nPool NO reserve: `" + formatGNOT(m.pool.ReserveNo) + "`\n")
	sb.WriteString("</gno-frame>\n")
	sb.WriteString("<gno-columns-sep />\n")
	sb.WriteString("<gno-frame>\n")
	sb.WriteString("### Liquidity & Fees\n\n")
	sb.WriteString("Collateral: `" + formatGNOT(m.collateral) + "`\n\nLP Fees: `" + formatGNOT(m.feePool) + "`\n")
	sb.WriteString("</gno-frame>\n")
	sb.WriteString("</gno-columns>\n\n")

	now := time.Now().Unix()
	switch m.status {
	case StatusOpen:
		if now < m.closeTime {
			sb.WriteString("> [!INFO] Market Open for Trading\n")
			sb.WriteString("> Quick actions below prefill 1 GNOT `MsgCall` transactions, or use the Sell form.\n\n")

			buyYesURL := txlink.NewLink("Buy").AddArgs("marketID", idStr, "buyYes", "true", "minSharesOut", "1").SetSend("1000000ugnot").URL()
			buyNoURL := txlink.NewLink("Buy").AddArgs("marketID", idStr, "buyYes", "false", "minSharesOut", "1").SetSend("1000000ugnot").URL()
			addLPURL := txlink.NewLink("AddLiquidity").AddArgs("marketID", idStr, "minLPMinted", "1").SetSend("1000000ugnot").URL()

			sb.WriteString("<gno-button href=\"" + buyYesURL + "\" label=\"Buy YES (1 GNOT)\" variant=\"success\" /> ")
			sb.WriteString("<gno-button href=\"" + buyNoURL + "\" label=\"Buy NO (1 GNOT)\" variant=\"caution\" /> ")
			sb.WriteString("<gno-button href=\"" + addLPURL + "\" label=\"Add Liquidity (1 GNOT)\" variant=\"outline\" />\n\n")

			sb.WriteString("### Sell Outcome Shares\n\n")
			sb.WriteString("<gno-form exec=\"Sell\">\n")
			sb.WriteString("  <gno-input name=\"marketID\" type=\"number\" value=\"" + idStr + "\" readonly=\"true\" placeholder=\"Market ID\" />\n")
			sb.WriteString("  <gno-select name=\"sellYes\" value=\"true\" selected=\"true\" description=\"true = Sell YES shares, false = Sell NO shares\" />\n")
			sb.WriteString("  <gno-select name=\"sellYes\" value=\"false\" />\n")
			sb.WriteString("  <gno-input name=\"sharesIn\" type=\"number\" placeholder=\"Shares to sell (ugnot units)\" required=\"true\" />\n")
			sb.WriteString("  <gno-input name=\"minCollateralOut\" type=\"number\" value=\"0\" placeholder=\"Min ugnot payout (slippage guard)\" required=\"true\" />\n")
			sb.WriteString("</gno-form>\n\n")
		} else {
			bondSend := strconv.FormatInt(m.bondAmount, 10) + Denom
			sb.WriteString("> [!WARNING] Market Closed — Ready for Optimistic Proposal\n")
			sb.WriteString("> Anyone may propose the final outcome by posting a refundable **" + formatGNOT(m.bondAmount) + "** bond.\n\n")

			propYesURL := txlink.NewLink("ProposeOutcome").AddArgs("marketID", idStr, "outcome", "1").SetSend(bondSend).URL()
			propNoURL := txlink.NewLink("ProposeOutcome").AddArgs("marketID", idStr, "outcome", "2").SetSend(bondSend).URL()
			propInvURL := txlink.NewLink("ProposeOutcome").AddArgs("marketID", idStr, "outcome", "3").SetSend(bondSend).URL()

			sb.WriteString("<gno-button href=\"" + propYesURL + "\" label=\"Propose YES\" variant=\"success\" /> ")
			sb.WriteString("<gno-button href=\"" + propNoURL + "\" label=\"Propose NO\" variant=\"caution\" /> ")
			sb.WriteString("<gno-button href=\"" + propInvURL + "\" label=\"Propose INVALID\" variant=\"outline\" />\n\n")
		}

	case StatusProposed:
		sb.WriteString("> [!WARNING] Outcome Proposed: " + m.proposedOutcome.String() + "\n")
		sb.WriteString("> Proposed by " + m.proposer.String() + " with bond **" + formatGNOT(m.proposerBond) + "**. Dispute deadline: `" + formatUnixTime(m.disputeDeadline) + "`.\n\n")

		if now < m.disputeDeadline {
			bondSend := strconv.FormatInt(m.bondAmount, 10) + Denom
			disputeURL := txlink.NewLink("DisputeOutcome").AddArgs("marketID", idStr).SetSend(bondSend).URL()
			sb.WriteString("<gno-button href=\"" + disputeURL + "\" label=\"Dispute Proposal (" + formatGNOT(m.bondAmount) + " Bond)\" variant=\"caution\" />\n\n")
		} else {
			finalizeURL := txlink.NewLink("FinalizeResolution").AddArgs("marketID", idStr).URL()
			sb.WriteString("<gno-button href=\"" + finalizeURL + "\" label=\"Finalize Resolution\" variant=\"success\" />\n\n")
		}

	case StatusDisputed:
		sb.WriteString("> [!CAUTION] Outcome Disputed — Arbiter Quorum Active\n")
		sb.WriteString("> Disputer: " + m.disputer.String() + " · Votes (YES/NO/INVALID): `" + strconv.Itoa(m.yesVotes) + "/" + strconv.Itoa(m.noVotes) + "/" + strconv.Itoa(m.invalidVotes) + "` (quorum: `" + strconv.Itoa(m.arbiterQuorum) + "`).\n\n")

		voteYesURL := txlink.NewLink("CastArbiterVote").AddArgs("marketID", idStr, "outcome", "1").URL()
		voteNoURL := txlink.NewLink("CastArbiterVote").AddArgs("marketID", idStr, "outcome", "2").URL()
		voteInvURL := txlink.NewLink("CastArbiterVote").AddArgs("marketID", idStr, "outcome", "3").URL()
		sb.WriteString("<gno-button href=\"" + voteYesURL + "\" label=\"Arbiter Vote YES\" variant=\"success\" /> ")
		sb.WriteString("<gno-button href=\"" + voteNoURL + "\" label=\"Arbiter Vote NO\" variant=\"caution\" /> ")
		sb.WriteString("<gno-button href=\"" + voteInvURL + "\" label=\"Arbiter Vote INVALID\" variant=\"outline\" />\n\n")

		if now >= m.disputedAt+ArbiterTimeout {
			expURL := txlink.NewLink("ExpireDispute").AddArgs("marketID", idStr).URL()
			sb.WriteString("<gno-button href=\"" + expURL + "\" label=\"Expire Stalled Dispute (INVALID)\" variant=\"warning\" />\n\n")
		}

	case StatusResolved:
		sb.WriteString("> [!SUCCESS] Resolved: " + m.finalOutcome.String() + "\n")
		sb.WriteString("> Finalized at `" + formatUnixTime(m.resolvedAt) + "`. Winning shareholders and LPs can claim payouts below.\n\n")

		claimURL := txlink.NewLink("Claim").AddArgs("marketID", idStr).URL()
		claimBondsURL := txlink.NewLink("ClaimBonds").URL()
		sb.WriteString("<gno-button href=\"" + claimURL + "\" label=\"Claim Market Payout\" variant=\"success\" /> ")
		sb.WriteString("<gno-button href=\"" + claimBondsURL + "\" label=\"Claim Bonds\" variant=\"outline\" />\n\n")
	}

	sb.WriteString("## Share Supply & Resolution Summary\n\n")
	sb.WriteString("| Metric | Value |\n")
	sb.WriteString("| :--- | :--- |\n")
	sb.WriteString("| Outstanding YES Shares | " + formatGNOT(m.totalYesOut) + " |\n")
	sb.WriteString("| Outstanding NO Shares | " + formatGNOT(m.totalNoOut) + " |\n")
	sb.WriteString("| Total LP Supply | " + formatGNOT(m.pool.TotalLP) + " |\n")
	sb.WriteString("| Total Volume | " + formatGNOT(m.totalVolume) + " |\n")
	sb.WriteString("| Trades | " + strconv.FormatInt(m.tradeCount, 10) + " |\n")
	sb.WriteString("| Required Resolution Bond | " + formatGNOT(m.bondAmount) + " |\n")

	res.Write(sb.String())
}

func renderCreate(res *mux.ResponseWriter, _ *mux.Request) {
	sampleClose := strconv.FormatInt(time.Now().Unix()+7*86400, 10)
	createURL := txlink.NewLink("CreateMarket").
		AddArgs(
			"question", "Will Gno.land ship v1.9 before 2027?",
			"description", "Resolves YES if gnolang/gno tags v1.9.0 or higher before Jan 1, 2027 UTC.",
			"category", "Ecosystem",
			"closeTimeUnix", sampleClose,
			"feeBps", "100",
			"disputeWindowSec", "3600",
		).
		SetSend("1000000ugnot").
		URL()

	var sb strings.Builder
	sb.WriteString("[← Back to All Markets](" + realmLink("") + ")\n\n")
	sb.WriteString("# Create a Binary Market\n\n")
	sb.WriteString("Anyone can launch a new 50/50 CPMM prediction market via `CreateMarket` by attaching at least **0.1 GNOT** (`100000ugnot`).\n\n")
	sb.WriteString("<gno-button href=\"" + createURL + "\" label=\"Launch Sample Market (1 GNOT Seed)\" variant=\"success\" />\n\n")
	sb.WriteString("## Parameter Bounds\n\n")
	sb.WriteString("| Parameter | Constraint |\n")
	sb.WriteString("| :--- | :--- |\n")
	sb.WriteString("| `question` | 1–200 chars |\n")
	sb.WriteString("| `description` | 0–1000 chars |\n")
	sb.WriteString("| `category` | 1–32 chars |\n")
	sb.WriteString("| `closeTimeUnix` | `[now + 60s, now + 365d]` |\n")
	sb.WriteString("| `feeBps` | `0–1000` (0%–10% LP fee) |\n")
	sb.WriteString("| `disputeWindowSec` | `0` (default 3600s) or `[60s, 7d]` |\n")
	sb.WriteString("| `-send` deposit | `>= 100000ugnot` |\n")
	res.Write(sb.String())
}

func renderPortfolio(res *mux.ResponseWriter, req *mux.Request) {
	rawAddr := strings.TrimSpace(req.GetVar("addr"))
	addr := address(rawAddr)
	if !addr.IsValid() {
		var sb strings.Builder
		sb.WriteString("[← Back to All Markets](" + realmLink("") + ")\n\n")
		sb.WriteString("> [!WARNING] Invalid Address\n")
		sb.WriteString("> `" + safeInline(rawAddr) + "` is not a valid Gno address.\n")
		res.Write(sb.String())
		return
	}

	var sb strings.Builder
	sb.WriteString("[← Back to All Markets](" + realmLink("") + ")\n\n")
	sb.WriteString("# Portfolio — " + addr.String() + "\n\n")

	bonds := GetClaimableBonds(addr)
	sb.WriteString("**Claimable Dispute/Resolution Bonds:** `" + formatGNOT(bonds) + "`")
	if bonds > 0 {
		sb.WriteString(" — <gno-button href=\"" + txlink.NewLink("ClaimBonds").URL() + "\" label=\"Claim Bonds\" variant=\"success\" />")
	}
	sb.WriteString("\n\n")

	recent := ListMarkets(0, MaxPageLimit)
	var rows strings.Builder
	count := 0
	for _, m := range recent {
		pos := GetPosition(m.ID, addr)
		if pos.YesShares == 0 && pos.NoShares == 0 && pos.LPShares == 0 && pos.PendingFees == 0 && !pos.Claimed {
			continue
		}
		count++
		idStr := strconv.FormatUint(m.ID, 10)
		action := "-"
		if m.Status == StatusResolved && !pos.Claimed && pos.EstClaimable > 0 {
			claimURL := txlink.NewLink("Claim").AddArgs("marketID", idStr).URL()
			action = "[Claim " + formatGNOT(pos.EstClaimable) + "](" + claimURL + ")"
		} else if pos.Claimed {
			action = "Claimed"
		}
		rows.WriteString("| [#" + idStr + " " + safeTableCell(m.Question) + "](" + realmLink("market/"+idStr) + ") | " + m.StatusLabel + " | " + formatGNOT(pos.YesShares) + " | " + formatGNOT(pos.NoShares) + " | " + formatGNOT(pos.LPShares) + " | " + formatGNOT(pos.PendingFees) + " | " + action + " |\n")
	}

	if count == 0 {
		sb.WriteString("> [!NOTE]\n")
		sb.WriteString("> No active or historical positions found across recent markets.\n")
	} else {
		sb.WriteString("| Market | Status | YES | NO | LP | LP Fees | Action |\n")
		sb.WriteString("| :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n")
		sb.WriteString(rows.String())
	}
	res.Write(sb.String())
}

func renderNotFound(res *mux.ResponseWriter, req *mux.Request) {
	var sb strings.Builder
	sb.WriteString("> [!WARNING] Route Not Found\n")
	sb.WriteString("> Unknown path `" + safeInline(req.Path) + "`.\n\n")
	sb.WriteString("[Return to Verdict Home](" + realmLink("") + ")\n")
	res.Write(sb.String())
}
