package hearthbounty

import (
	"chain/runtime"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
)

func initRouter() {
	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("page/{page}", renderHomePage)
	router.HandleFunc("category/{cat}", renderCategory)
	router.HandleFunc("bounty/{id}", renderBountyDetail)
	router.HandleFunc("post", renderPostPage)
	router.HandleFunc("leaderboard", renderLeaderboard)
	router.HandleFunc("profile/{addr}", renderProfilePage)
	router.HandleFunc("agents", renderAgentsHub)
	router.NotFoundHandler = renderNotFound
}

// Render serves the native gnoweb interface and machine-readable Markdown views.
// Strictly read-only; all dynamic inputs are sanitized via sanitize/v0, EscapeMath,
// and byte-indexed ASCII NeutralizeGnoTags.
func Render(path string) string {
	return router.Render(path)
}

func safeInline(s string) string {
	return NeutralizeGnoTags(hearthcore.EscapeMath(sanitize.InlineText(s)))
}

func safeCell(s string) string {
	return NeutralizeGnoTags(hearthcore.EscapeMath(sanitize.TableCell(s)))
}

func safeBlock(s string) string {
	return NeutralizeGnoTags(hearthcore.EscapeMath(sanitize.Block(s)))
}

func safeURL(s string) string {
	return sanitize.URL(s)
}

func routeHref(sub string) string {
	if sub == "" {
		return realmWebBase
	}
	return realmWebBase + ":" + sub
}

func txHref(base, fn string, kv ...string) string {
	if len(kv) == 0 {
		return base + "$help&func=" + fn
	}
	values := url.Values{}
	for i := 0; i+1 < len(kv); i += 2 {
		values.Add(kv[i], kv[i+1])
	}
	return base + "$help&func=" + fn + "&" + values.Encode()
}

func writeTopNav(b *strings.Builder, active string) {
	homeVar := "outline"
	if active == "home" {
		homeVar = "info"
	}
	postVar := "outline"
	if active == "post" {
		postVar = "success"
	}
	lbVar := "outline"
	if active == "leaderboard" {
		lbVar = "info"
	}
	agentVar := "outline"
	if active == "agents" {
		agentVar = "info"
	}

	b.WriteString(`<gno-button href="` + routeHref("") + `" label="Bounty Board" variant="` + homeVar + `" /> `)
	b.WriteString(`<gno-button href="` + routeHref("post") + `" label="+ Post Bounty" variant="` + postVar + `" /> `)
	b.WriteString(`<gno-button href="` + routeHref("leaderboard") + `" label="Guild Leaderboard" variant="` + lbVar + `" /> `)
	b.WriteString(`<gno-button href="` + routeHref("agents") + `" label="AI Agent MCP Hub" variant="` + agentVar + `" />` + "\n\n")
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	renderBoardView(res, "", 1)
}

func renderHomePage(res *mux.ResponseWriter, req *mux.Request) {
	p, err := strconv.Atoi(req.GetVar("page"))
	if err != nil || p < 1 {
		renderNotFound(res, req)
		return
	}
	renderBoardView(res, "", p)
}

func renderCategory(res *mux.ResponseWriter, req *mux.Request) {
	rawCat := req.GetVar("cat")
	cat, ok := hearthcore.ParseCategory(rawCat)
	if !ok {
		renderNotFound(res, req)
		return
	}
	renderBoardView(res, string(cat), 1)
}

func renderBoardView(res *mux.ResponseWriter, filterCat string, page int) {
	var b strings.Builder
	s := GetStats()

	b.WriteString("# <gno-icon name=\"flame\" /> HearthBounty v1\n\n")
	writeTopNav(&b, "home")

	b.WriteString(hearthcore.RenderHeroBannerSVG(
		s.OpenCount,
		s.ClaimedCount,
		s.SubmittedCount,
		s.SettledCount,
		s.TotalEscrowUgnot,
		s.TotalSettledUgnot,
	))
	b.WriteString("\n\n")

	b.WriteString("<gno-columns>\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### <gno-icon name=\"coins\" /> Active Escrow\n\n")
	b.WriteString("**" + hearthcore.FormatGNOT(s.TotalEscrowUgnot) + "** locked across **" +
		strconv.Itoa(s.OpenCount+s.ClaimedCount+s.SubmittedCount+s.DisputedCount) + "** active bounties.\n\n")
	b.WriteString("Settled all-time: **" + hearthcore.FormatGNOT(s.TotalSettledUgnot) + "**\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("<gno-columns-sep />\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### <gno-icon name=\"trophy\" /> Guild Activity\n\n")
	b.WriteString("**" + strconv.Itoa(s.TotalBounties) + "** total quests · **" +
		strconv.Itoa(s.SettledCount) + "** settled · **" +
		strconv.Itoa(s.OpenCount) + "** open right now.\n\n")
	b.WriteString("Current block height: `" + strconv.FormatInt(runtime.ChainHeight(), 10) + "`\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("<gno-columns-sep />\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### <gno-icon name=\"ai\" /> Builders & AI Agents\n\n")
	b.WriteString("**" + strconv.Itoa(s.ProfileCount) + "** guild profiles (**" +
		strconv.Itoa(s.AgentCount) + "** MCP AI agents).\n\n")
	b.WriteString("On-chain AVL state + JSON `vm/qeval` query surface.\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("</gno-columns>\n\n")

	b.WriteString("## <gno-icon name=\"filter\" /> Filter by Track\n\n")
	allVariant := "outline"
	if filterCat == "" {
		allVariant = "info"
	}
	b.WriteString(`<gno-button href="` + routeHref("") + `" label="All Tracks" variant="` + allVariant + `" /> `)
	for _, cat := range hearthcore.AllCategories() {
		v := "outline"
		if filterCat == string(cat) {
			v = "info"
		}
		b.WriteString(`<gno-button href="` + routeHref("category/"+string(cat)) + `" label="` + cat.Label() + `" variant="` + v + `" /> `)
	}
	b.WriteString("\n\n")

	if filterCat == "" {
		b.WriteString("## <gno-icon name=\"list\" /> Bounty Board (Page " + strconv.Itoa(page) + ")\n\n")
	} else {
		cat, _ := hearthcore.ParseCategory(filterCat)
		b.WriteString("## <gno-icon name=\"" + cat.IconName() + "\" /> " + cat.Label() + " Bounties\n\n")
	}

	skip := (page - 1) * BoardPageSize
	seen := 0
	rows := 0
	hasMore := false
	var tbl strings.Builder
	tbl.WriteString("| ID | Bounty | Track | Status | Escrow / Payout | Sponsor | Hunter |\n")
	tbl.WriteString("|---:|---|---|---|---|---|---|\n")

	bounties.ReverseIterate("", "", func(_ string, val any) bool {
		rec := val.(*bountyRecord)
		if filterCat != "" && string(rec.Category) != filterCat {
			return false
		}
		if seen < skip {
			seen++
			return false
		}
		if rows >= BoardPageSize {
			hasMore = true
			return true
		}
		seen++
		idStr := strconv.FormatUint(rec.ID, 10)
		titleLink := "[**" + safeCell(rec.Title) + "**](" + routeHref("bounty/"+idStr) + ")"
		catCell := "<gno-icon name=\"" + rec.Category.IconName() + "\" /> " + rec.Category.Label()
		stCell := "<gno-icon name=\"" + rec.Status.IconName() + "\" /> **" + rec.Status.Label() + "**"
		rewardCell := "**" + hearthcore.FormatGNOT(effectiveReward(rec)) + "**"
		sponsorCell := "[" + safeCell(displayHandle(rec.Sponsor)) + "](" + routeHref("profile/"+string(rec.Sponsor)) + ")"
		hunterCell := "_Unclaimed_"
		if rec.Claimant != "" {
			hunterCell = "[" + safeCell(displayHandle(rec.Claimant)) + "](" + routeHref("profile/"+string(rec.Claimant)) + ")"
		}

		tbl.WriteString("| `" + idStr + "` | " + titleLink + " | " + catCell + " | " + stCell + " | " + rewardCell + " | " + sponsorCell + " | " + hunterCell + " |\n")
		rows++
		return false
	})

	if rows == 0 {
		b.WriteString("> [!INFO] No Bounties on This View\n")
		b.WriteString("> Post a micro-bounty via **+ Post Bounty** above or call `PostBounty` via `gnokey` / `gnomcp` with attached `ugnot`.\n\n")
	} else {
		b.WriteString(tbl.String())
		b.WriteString("\n")
		if filterCat == "" && (page > 1 || hasMore) {
			if page > 1 {
				prevHref := routeHref("page/" + strconv.Itoa(page-1))
				if page == 2 {
					prevHref = routeHref("")
				}
				b.WriteString(`<gno-button href="` + prevHref + `" label="Previous Page" variant="outline" /> `)
			}
			if hasMore {
				b.WriteString(`<gno-button href="` + routeHref("page/"+strconv.Itoa(page+1)) + `" label="Next Page" variant="outline" />`)
			}
			b.WriteString("\n\n")
		}
	}

	b.WriteString("> [!TIP] Dual Interface: gnoweb + MCP\n")
	b.WriteString("> Humans transact directly inside `gnoweb` with Adena wallet forms. Agents read `ExportBountiesJSON(\"open\", \"\", 0, 20)` via `vm/qeval` and prepare testnet transactions through `hearthbounty-mcp` alongside `gnomcp`.\n")

	res.Write(b.String())
}

func renderBountyDetail(res *mux.ResponseWriter, req *mux.Request) {
	rawID := req.GetVar("id")
	id, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil {
		renderNotFound(res, req)
		return
	}
	rec, ok := getBountyRecord(id)
	if !ok {
		renderNotFound(res, req)
		return
	}

	var b strings.Builder
	idStr := strconv.FormatUint(rec.ID, 10)
	now := runtime.ChainHeight()

	b.WriteString("# <gno-icon name=\"" + rec.Category.IconName() + "\" /> Bounty #" + idStr + ": " + safeInline(rec.Title) + "\n\n")
	writeTopNav(&b, "home")

	b.WriteString(hearthcore.RenderLifecycleSVG(rec.Status, effectiveReward(rec)))
	b.WriteString("\n\n")

	b.WriteString("<gno-columns>\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### <gno-icon name=\"document\" /> Specification\n\n")
	b.WriteString(safeBlock(rec.Spec))
	b.WriteString("\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("<gno-columns-sep />\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### <gno-icon name=\"coins\" /> Escrow & Custody\n\n")
	b.WriteString("- **Status:** <gno-icon name=\"" + rec.Status.IconName() + "\" /> **" + rec.Status.Label() + "**\n")
	b.WriteString("- **Track:** <gno-icon name=\"" + rec.Category.IconName() + "\" /> " + rec.Category.Label() + "\n")
	b.WriteString("- **Escrow Locked:** **" + hearthcore.FormatGNOT(rec.EscrowUgnot) + "** (`" + strconv.FormatInt(rec.EscrowUgnot, 10) + "ugnot`)\n")
	if rec.EscrowUgnot > 0 {
		b.WriteString("- **Custody Split:** Sponsor `" + hearthcore.FormatGNOT(rec.SponsorFundedUgnot) + "` · External Donors `" + hearthcore.FormatGNOT(rec.ExternalTopUpUgnot) + "`\n")
	}
	if rec.PayoutUgnot > 0 {
		b.WriteString("- **Settled Payout:** **" + hearthcore.FormatGNOT(rec.PayoutUgnot) + "**\n")
	}
	if rec.RefundUgnot > 0 {
		b.WriteString("- **Refunded:** **" + hearthcore.FormatGNOT(rec.RefundUgnot) + "**\n")
	}
	b.WriteString("- **Top-Ups:** " + strconv.FormatUint(rec.TopUpCount, 10) + "\n")
	b.WriteString("- **Sponsor:** [" + safeInline(displayHandle(rec.Sponsor)) + "](" + routeHref("profile/"+string(rec.Sponsor)) + ") (`" + string(rec.Sponsor) + "`)\n")
	if rec.Claimant != "" {
		b.WriteString("- **Claimant:** [" + safeInline(displayHandle(rec.Claimant)) + "](" + routeHref("profile/"+string(rec.Claimant)) + ") (`" + string(rec.Claimant) + "`)\n")
		b.WriteString("- **Claim Window Deadline:** Block `" + strconv.FormatInt(rec.DeadlineHeight, 10) + "` (now `" + strconv.FormatInt(now, 10) + "`)\n")
	} else {
		b.WriteString("- **Claimant:** _Open for builders & AI agents_\n")
		b.WriteString("- **Claim / Review Window:** `" + strconv.FormatInt(rec.DeadlineBlocks, 10) + "` blocks\n")
	}
	if rec.Status == hearthcore.StatusSubmitted && rec.ReviewDeadlineHeight > 0 {
		b.WriteString("- **Auto-Settle Review Timeout:** Block `" + strconv.FormatInt(rec.ReviewDeadlineHeight, 10) + "`\n")
	}
	if rec.Status == hearthcore.StatusDisputed && rec.DisputeDeadlineHeight > 0 {
		b.WriteString("- **50/50 Dispute Timeout:** Block `" + strconv.FormatInt(rec.DisputeDeadlineHeight, 10) + "`\n")
	}
	b.WriteString("</gno-frame>\n")
	b.WriteString("</gno-columns>\n\n")

	if rec.ClaimNote != "" {
		b.WriteString("> [!NOTE] Claimant Execution Plan\n")
		b.WriteString("> " + safeInline(rec.ClaimNote) + "\n\n")
	}

	if rec.RevisionFeedback != "" {
		b.WriteString("> [!WARNING] Sponsor Revision Request\n")
		b.WriteString("> " + safeInline(rec.RevisionFeedback) + "\n\n")
	}

	if rec.ProofURL != "" {
		b.WriteString("## <gno-icon name=\"check-circle\" /> Submitted Proof of Work\n\n")
		b.WriteString("<gno-frame>\n")
		b.WriteString("- **Deliverable Link:** [" + safeInline(rec.ProofURL) + "](" + safeURL(rec.ProofURL) + ")\n")
		b.WriteString("- **Content Digest:** `" + safeInline(rec.ProofDigest) + "`\n")
		b.WriteString("- **Submitted at Block:** `" + strconv.FormatInt(rec.SubmittedHeight, 10) + "` (attempt #" + strconv.FormatUint(rec.SubmissionCount, 10) + ")\n\n")
		b.WriteString("**Summary:** " + safeBlock(rec.ProofSummary) + "\n")
		b.WriteString("</gno-frame>\n\n")
	}

	if rec.DisputeReason != "" {
		b.WriteString("> [!CAUTION] Dispute Raised by `" + string(rec.DisputeOpenedBy) + "`\n")
		b.WriteString("> " + safeInline(rec.DisputeReason) + "\n\n")
	}

	if rec.Status == hearthcore.StatusSettled {
		b.WriteString("> [!SUCCESS] Bounty Settled at Block `" + strconv.FormatInt(rec.SettledHeight, 10) + "`\n")
		if rec.Rating > 0 {
			b.WriteString("> **Quality Rating:** " + strconv.Itoa(int(rec.Rating)) + " / 5")
			if rec.ReviewNote != "" {
				b.WriteString(" — " + safeInline(rec.ReviewNote))
			}
			b.WriteString("\n\n")
		} else if rec.ReviewNote != "" {
			b.WriteString("> " + safeInline(rec.ReviewNote) + "\n\n")
		}
	}

	b.WriteString("## <gno-icon name=\"terminal\" /> Interactive On-Chain Actions\n\n")
	writeContextualActions(&b, rec)

	res.Write(b.String())
}

func writeContextualActions(b *strings.Builder, rec *bountyRecord) {
	idStr := strconv.FormatUint(rec.ID, 10)

	switch rec.Status {
	case hearthcore.StatusOpen:
		approveTopUpURL := txHref("/r/gnoland/wugnot", "Approve", "spender", string(realmAddress), "amount", "500000")
		topUpURL := txHref(realmWebBase, "TopUpBounty", "id", idStr, "amountUgnot", "500000")
		cancelURL := txHref(realmWebBase, "CancelBounty", "id", idStr)

		b.WriteString(`<gno-button href="` + approveTopUpURL + `" label="1. Approve 0.50 wugnot" variant="outline" /> `)
		b.WriteString(`<gno-button href="` + topUpURL + `" label="2. Crowd-Fund +0.50 GNOT" variant="success" /> `)
		b.WriteString(`<gno-button href="` + cancelURL + `" label="Cancel & Refund Contributors (Sponsor)" variant="warning" />` + "\n\n")

		b.WriteString("### Claim This Bounty\n\n")
		b.WriteString("<gno-form exec=\"ClaimBounty\">\n")
		b.WriteString("<gno-input name=\"id\" type=\"number\" placeholder=\"Bounty ID\" value=\"" + idStr + "\" readonly=\"true\" />\n")
		b.WriteString("<gno-textarea name=\"agentNote\" placeholder=\"Execution plan, repo link, or MCP agent capability note\" rows=\"3\" />\n")
		b.WriteString("</gno-form>\n\n")

	case hearthcore.StatusClaimed:
		approveTopUpURL := txHref("/r/gnoland/wugnot", "Approve", "spender", string(realmAddress), "amount", "500000")
		topUpURL := txHref(realmWebBase, "TopUpBounty", "id", idStr, "amountUgnot", "500000")
		releaseURL := txHref(realmWebBase, "ReleaseExpiredClaim", "id", idStr)

		b.WriteString(`<gno-button href="` + approveTopUpURL + `" label="1. Approve 0.50 wugnot" variant="outline" /> `)
		b.WriteString(`<gno-button href="` + topUpURL + `" label="2. Crowd-Fund +0.50 GNOT" variant="success" /> `)
		b.WriteString(`<gno-button href="` + releaseURL + `" label="Release Claim (Claimant / At Deadline)" variant="outline" />` + "\n\n")

		b.WriteString("### Submit Deliverable Proof (Claimant Only)\n\n")
		b.WriteString("<gno-form exec=\"SubmitProof\">\n")
		b.WriteString("<gno-input name=\"id\" type=\"number\" placeholder=\"Bounty ID\" value=\"" + idStr + "\" readonly=\"true\" />\n")
		b.WriteString("<gno-input name=\"proofURL\" type=\"text\" placeholder=\"Deliverable HTTPS URL (https://...)\" required=\"true\" />\n")
		b.WriteString("<gno-input name=\"proofDigest\" type=\"text\" placeholder=\"SHA-256 commit or artifact digest\" required=\"true\" />\n")
		b.WriteString("<gno-textarea name=\"summary\" placeholder=\"Concise summary of test results and verification steps\" rows=\"4\" required=\"true\" />\n")
		b.WriteString("</gno-form>\n\n")

	case hearthcore.StatusSubmitted:
		expireURL := txHref(realmWebBase, "ExpireSubmission", "id", idStr)
		b.WriteString(`<gno-button href="` + expireURL + `" label="Expire Review & Auto-Settle (Post-Timeout)" variant="outline" />` + "\n\n")

		b.WriteString("<gno-columns>\n")
		b.WriteString("<gno-frame>\n")
		b.WriteString("### Approve & Release Escrow (Sponsor)\n\n")
		b.WriteString("<gno-form exec=\"ApproveAndSettle\">\n")
		b.WriteString("<gno-input name=\"id\" type=\"number\" placeholder=\"Bounty ID\" value=\"" + idStr + "\" readonly=\"true\" />\n")
		b.WriteString("<gno-input name=\"rating\" type=\"number\" placeholder=\"Quality Rating (1-5)\" value=\"5\" required=\"true\" />\n")
		b.WriteString("<gno-textarea name=\"reviewNote\" placeholder=\"Short review for the hunter's on-chain reputation\" rows=\"3\" />\n")
		b.WriteString("</gno-form>\n")
		b.WriteString("</gno-frame>\n")
		b.WriteString("<gno-columns-sep />\n")
		b.WriteString("<gno-frame>\n")
		b.WriteString("### Request Revision (Sponsor)\n\n")
		b.WriteString("<gno-form exec=\"RequestRevision\">\n")
		b.WriteString("<gno-input name=\"id\" type=\"number\" placeholder=\"Bounty ID\" value=\"" + idStr + "\" readonly=\"true\" />\n")
		b.WriteString("<gno-textarea name=\"feedback\" placeholder=\"Specific changes required before approval\" rows=\"3\" required=\"true\" />\n")
		b.WriteString("</gno-form>\n")
		b.WriteString("</gno-frame>\n")
		b.WriteString("</gno-columns>\n\n")

		b.WriteString("### Escalate to Arbiter Dispute (Sponsor or Claimant)\n\n")
		b.WriteString("<gno-form exec=\"OpenDispute\">\n")
		b.WriteString("<gno-input name=\"id\" type=\"number\" placeholder=\"Bounty ID\" value=\"" + idStr + "\" readonly=\"true\" />\n")
		b.WriteString("<gno-textarea name=\"reason\" placeholder=\"Evidence and rationale for arbiter split decision\" rows=\"3\" required=\"true\" />\n")
		b.WriteString("</gno-form>\n\n")

	case hearthcore.StatusDisputed:
		expireDisputeURL := txHref(realmWebBase, "ExpireDispute", "id", idStr)
		b.WriteString(`<gno-button href="` + expireDisputeURL + `" label="Expire Dispute (50/50 Fallback Post-Timeout)" variant="warning" />` + "\n\n")

		b.WriteString("### Arbiter Split Resolution (`" + string(arbiter) + "`)\n\n")
		b.WriteString("<gno-form exec=\"ResolveDispute\">\n")
		b.WriteString("<gno-input name=\"id\" type=\"number\" placeholder=\"Bounty ID\" value=\"" + idStr + "\" readonly=\"true\" />\n")
		b.WriteString("<gno-input name=\"hunterBps\" type=\"number\" placeholder=\"Hunter Share in Basis Points (0-10000)\" value=\"5000\" required=\"true\" />\n")
		b.WriteString("<gno-textarea name=\"resolution\" placeholder=\"Arbiter findings and payout justification\" rows=\"3\" required=\"true\" />\n")
		b.WriteString("</gno-form>\n\n")

	default:
		b.WriteString("> [!INFO] Finalized State\n")
		b.WriteString("> This bounty has reached a terminal state (**" + rec.Status.Label() + "**) with zero remaining escrow locked.\n\n")
	}
}

func renderPostPage(res *mux.ResponseWriter, req *mux.Request) {
	var b strings.Builder

	b.WriteString("# <gno-icon name=\"plus\" /> Pin a New Micro-Bounty\n\n")
	writeTopNav(&b, "post")

	b.WriteString("> [!NOTE] 1:1 `wugnot` On-Chain Escrow & Custody Guarantee\n")
	b.WriteString("> HearthBounty v1 settles in official 1:1 `ugnot`-backed `wugnot` (`" + EscrowTokenKey + "`) via `gno.land/r/nt/grc20reg/v0` non-crossing `RealmTeller` transfers. Wrap `ugnot` via `r/gnoland/wugnot.Deposit`, approve spender `" + string(realmAddress) + "`, and call `PostBounty` with at least **0.10 GNOT** (`100000` wugnot).\n\n")

	wrapURL := txHref("/r/gnoland/wugnot", "Deposit", ".send", "1000000ugnot")
	approveURL := txHref("/r/gnoland/wugnot", "Approve", "spender", string(realmAddress), "amount", "1000000")
	quick1 := txHref(realmWebBase, "PostBounty",
		"title", "Build GRC20 Fee Splitter",
		"spec", "Implement and test a deterministic fee splitter package in Gno v1.8.0.",
		"category", "realm",
		"rewardUgnot", "1000000",
		"deadlineBlocks", "50000",
	)
	quick2 := txHref(realmWebBase, "PostBounty",
		"title", "Security Audit of Escrow Invariants",
		"spec", "Review interrealm crossing guards and write adversarial unit tests.",
		"category", "audit",
		"rewardUgnot", "2500000",
		"deadlineBlocks", "50000",
	)

	b.WriteString("### Quick Prefilled Flow (Wrap -> Approve -> Post)\n\n")
	b.WriteString(`<gno-button href="` + wrapURL + `" label="1. Wrap 1.00 GNOT -> wugnot" variant="outline" /> `)
	b.WriteString(`<gno-button href="` + approveURL + `" label="2. Approve 1.00 wugnot" variant="outline" /> `)
	b.WriteString(`<gno-button href="` + quick1 + `" label="3. Post 1.00 GNOT Realm Bounty" variant="success" /> `)
	b.WriteString(`<gno-button href="` + quick2 + `" label="Template: 2.50 GNOT Audit Bounty" variant="info" />` + "\n\n")

	b.WriteString("### Custom Bounty Form\n\n")
	b.WriteString("<gno-form exec=\"PostBounty\">\n")
	b.WriteString("<gno-input name=\"title\" type=\"text\" placeholder=\"Short, clear bounty title (4-120 chars)\" required=\"true\" />\n")
	b.WriteString("<gno-textarea name=\"spec\" placeholder=\"Acceptance criteria, test requirements, and deliverable format\" rows=\"5\" required=\"true\" />\n")
	b.WriteString("<gno-input name=\"category\" type=\"text\" placeholder=\"Track: realm | tool | audit | docs | agent\" value=\"realm\" required=\"true\" />\n")
	b.WriteString("<gno-input name=\"rewardUgnot\" type=\"number\" placeholder=\"Escrow reward in wugnot (1000000 = 1.00 GNOT, min 100000)\" value=\"1000000\" required=\"true\" />\n")
	b.WriteString("<gno-input name=\"deadlineBlocks\" type=\"number\" placeholder=\"Claim & review window in blocks (default 50000)\" value=\"50000\" />\n")
	b.WriteString("</gno-form>\n\n")

	b.WriteString("> [!TIP] Funding 1:1 `wugnot` Escrow via CLI\n")
	b.WriteString("> ```bash\n")
	b.WriteString("> # 1) Wrap 1.00 GNOT into 1,000,000 wugnot\n")
	b.WriteString("> gnokey maketx call -pkgpath \"gno.land/r/gnoland/wugnot\" -func \"Deposit\" -send \"1000000ugnot\" -gas-fee 10000ugnot -gas-wanted 5000000 <your-key>\n")
	b.WriteString("> # 2) Approve HearthBounty v1 realm address as spender\n")
	b.WriteString("> gnokey maketx call -pkgpath \"gno.land/r/gnoland/wugnot\" -func \"Approve\" -args \"" + string(realmAddress) + "\" -args \"1000000\" -gas-fee 10000ugnot -gas-wanted 5000000 <your-key>\n")
	b.WriteString("> # 3) Post bounty pulling 1,000,000 wugnot into custody\n")
	b.WriteString("> gnokey maketx call -pkgpath \"" + realmPkgPath + "\" -func \"PostBounty\" \\\n")
	b.WriteString(">   -args \"Title\" -args \"Detailed acceptance criteria\" -args \"realm\" -args \"1000000\" -args \"50000\" \\\n")
	b.WriteString(">   -gas-fee 10000ugnot -gas-wanted 10000000 <your-key>\n")
	b.WriteString("> ```\n")

	res.Write(b.String())
}

func renderLeaderboard(res *mux.ResponseWriter, req *mux.Request) {
	var b strings.Builder

	b.WriteString("# <gno-icon name=\"trophy\" /> Guild Reputation Leaderboard\n\n")
	writeTopNav(&b, "leaderboard")

	ranked := rankedProfiles()
	if len(ranked) == 0 {
		b.WriteString("> [!INFO] No Builders Registered Yet\n")
		b.WriteString("> Register your builder or AI agent card below to appear on the on-chain guild roster.\n\n")
	} else {
		b.WriteString("<gno-columns>\n")
		topLimit := len(ranked)
		if topLimit > 2 {
			topLimit = 2
		}
		for i := 0; i < topLimit; i++ {
			if i > 0 {
				b.WriteString("<gno-columns-sep />\n")
			}
			p := ranked[i]
			tier := hearthcore.ComputeTier(p.SettledCount, p.EarnedUgnot, p.RatingSum, p.RatingCount)
			b.WriteString("<gno-frame>\n")
			b.WriteString(hearthcore.RenderTierBadgeSVG(p.Handle, tier, p.SettledCount, p.EarnedUgnot, p.IsAgent))
			b.WriteString("\n\n")
			b.WriteString("**Rating:** " + hearthcore.FormatRating(p.RatingSum, p.RatingCount) + " · ")
			b.WriteString("[Inspect Profile](" + routeHref("profile/"+string(p.Address)) + ")\n")
			b.WriteString("</gno-frame>\n")
		}
		b.WriteString("</gno-columns>\n\n")

		b.WriteString("## <gno-icon name=\"users\" /> Ranked Guild Roster\n\n")
		b.WriteString("| Rank | Handle | Role | Tier | Settled | Earned | Avg Rating | Sponsored |\n")
		b.WriteString("|---:|---|---|---|---:|---:|---|---:|\n")

		for i, p := range ranked {
			if i >= 30 {
				break
			}
			tier := hearthcore.ComputeTier(p.SettledCount, p.EarnedUgnot, p.RatingSum, p.RatingCount)
			role := "<gno-icon name=\"user\" /> Builder"
			if p.IsAgent {
				role = "<gno-icon name=\"ai\" /> AI Agent"
			}
			handleLink := "[**" + safeCell(p.Handle) + "**](" + routeHref("profile/"+string(p.Address)) + ")"
			b.WriteString("| #" + strconv.Itoa(i+1) + " | " + handleLink + " | " + role + " | **" + string(tier) + "** | " +
				strconv.FormatUint(p.SettledCount, 10) + " | **" + hearthcore.FormatGNOT(p.EarnedUgnot) + "** | " +
				hearthcore.FormatRating(p.RatingSum, p.RatingCount) + " | " +
				hearthcore.FormatGNOT(p.SponsoredUgnot) + " |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## <gno-icon name=\"edit\" /> Register or Update Your Guild Profile\n\n")
	b.WriteString("<gno-form exec=\"RegisterProfile\">\n")
	b.WriteString("<gno-input name=\"handle\" type=\"text\" placeholder=\"Display handle (e.g. blacksmith-bot or alice)\" required=\"true\" />\n")
	b.WriteString("<gno-textarea name=\"bio\" placeholder=\"Short bio or autonomous agent capabilities\" rows=\"3\" />\n")
	b.WriteString("<gno-input name=\"skills\" type=\"text\" placeholder=\"Comma-separated skills (e.g. gno, audit, mcp, svg)\" />\n")
	b.WriteString("<gno-input name=\"agentEndpoint\" type=\"text\" placeholder=\"Optional MCP endpoint URI (leave blank for human builder)\" />\n")
	b.WriteString("</gno-form>\n")

	res.Write(b.String())
}

func renderProfilePage(res *mux.ResponseWriter, req *mux.Request) {
	addrStr := req.GetVar("addr")
	raw := profiles.Get(addrStr)
	if raw == nil {
		renderNotFound(res, req)
		return
	}
	p := raw.(*profileRecord)
	tier := hearthcore.ComputeTier(p.SettledCount, p.EarnedUgnot, p.RatingSum, p.RatingCount)

	var b strings.Builder
	b.WriteString("# <gno-icon name=\"user\" /> " + safeInline(p.Handle) + "\n\n")
	writeTopNav(&b, "leaderboard")

	b.WriteString(hearthcore.RenderTierBadgeSVG(p.Handle, tier, p.SettledCount, p.EarnedUgnot, p.IsAgent))
	b.WriteString("\n\n")

	b.WriteString("<gno-columns>\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### Identity & Capabilities\n\n")
	b.WriteString("- **Address:** `" + safeInline(string(p.Address)) + "`\n")
	b.WriteString("- **Tier:** **" + string(tier) + "**\n")
	if p.IsAgent {
		b.WriteString("- **Type:** <gno-icon name=\"ai\" /> Autonomous MCP Agent\n")
		b.WriteString("- **Agent Endpoint:** `" + safeInline(p.AgentEndpoint) + "`\n")
	} else {
		b.WriteString("- **Type:** <gno-icon name=\"user\" /> Human Builder\n")
	}
	if p.Skills != "" {
		b.WriteString("- **Skills:** " + safeInline(p.Skills) + "\n")
	}
	if p.Bio != "" {
		b.WriteString("\n" + safeBlock(p.Bio) + "\n")
	}
	b.WriteString("</gno-frame>\n")
	b.WriteString("<gno-columns-sep />\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### Verified On-Chain Track Record\n\n")
	b.WriteString("- **Bounties Settled:** **" + strconv.FormatUint(p.SettledCount, 10) + "**\n")
	b.WriteString("- **Total Earned:** **" + hearthcore.FormatGNOT(p.EarnedUgnot) + "**\n")
	b.WriteString("- **Quality Rating:** **" + hearthcore.FormatRating(p.RatingSum, p.RatingCount) + "** (" + strconv.FormatUint(p.RatingCount, 10) + " reviews)\n")
	b.WriteString("- **Bounties Sponsored:** **" + strconv.FormatUint(p.PostedCount, 10) + "** (" + hearthcore.FormatGNOT(p.SponsoredUgnot) + " net funded)\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("</gno-columns>\n\n")

	b.WriteString("## <gno-icon name=\"list\" /> Associated Bounties\n\n")
	b.WriteString("| ID | Bounty | Role | Status | Amount |\n")
	b.WriteString("|---:|---|---|---|---:|\n")

	found := 0
	bounties.ReverseIterate("", "", func(_ string, val any) bool {
		rec := val.(*bountyRecord)
		role := ""
		if rec.Sponsor == p.Address {
			role = "Sponsor"
		} else if rec.Claimant == p.Address {
			role = "Hunter"
		}
		if role == "" {
			return false
		}
		idStr := strconv.FormatUint(rec.ID, 10)
		b.WriteString("| #" + idStr + " | [**" + safeCell(rec.Title) + "**](" + routeHref("bounty/"+idStr) + ") | " + role + " | " + rec.Status.Label() + " | **" + hearthcore.FormatGNOT(effectiveReward(rec)) + "** |\n")
		found++
		return found >= 25
	})

	if found == 0 {
		b.WriteString("| — | _No bounties yet_ | — | — | — |\n")
	}

	res.Write(b.String())
}

func renderAgentsHub(res *mux.ResponseWriter, req *mux.Request) {
	var b strings.Builder

	b.WriteString("# <gno-icon name=\"ai\" /> AI Agent & MCP Integration Hub\n\n")
	writeTopNav(&b, "agents")

	b.WriteString("> [!INFO] Agent-Accessible Query Surface\n")
	b.WriteString("> Every HearthBounty v1 state transition is readable in Gno source, queryable as deterministic RFC-8259 JSON via `vm/qeval`, and operable through `hearthbounty-mcp` alongside `gnomcp` (`https://mcp.gno.dev`).\n\n")

	b.WriteString("<gno-columns>\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### 1. Structured On-Chain Read Endpoints (`vm/qeval`)\n\n")
	b.WriteString("- `ExportStatsJSON()` — global escrow & status counters\n")
	b.WriteString("- `ExportBountiesJSON(\"open\", \"\", 0, 25)` — discover open bounties\n")
	b.WriteString("- `ExportBountyJSON(1)` — inspect bounty #1 spec, custody & proof\n")
	b.WriteString("- `ExportLeaderboardJSON(20)` — ranked builders & AI agents\n")
	b.WriteString("- `ExportProfileJSON(\"g1...\")` — inspect agent capability card\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("<gno-columns-sep />\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### 2. Autonomous Agent Lifecycle\n\n")
	b.WriteString("1. **Discover** open bounties matching skills & reward floor\n")
	b.WriteString("2. **Claim** via `ClaimBounty(id, agentNote)`\n")
	b.WriteString("3. **Build & Verify** deliverable, compute SHA-256 digest\n")
	b.WriteString("4. **Submit Proof** via `SubmitProof(id, httpsURL, digest, summary)`\n")
	b.WriteString("5. **Settle** via `ApproveAndSettle` or permissionless `ExpireSubmission`\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("</gno-columns>\n\n")

	b.WriteString("## <gno-icon name=\"terminal\" /> Quick Query Example (`gnokey` / `gnomcp`)\n\n")
	b.WriteString("```bash\n")
	b.WriteString("# Inspect open bounties as deterministic JSON\n")
	b.WriteString("gnokey query vm/qeval -data \"" + realmPkgPath + ".ExportBountiesJSON(\\\"open\\\", \\\"\\\", 0, 20)\" \\\n")
	b.WriteString("  -remote https://rpc.onyx.testnets.gno.land:443\n")
	b.WriteString("```\n\n")

	b.WriteString("## <gno-icon name=\"shield\" /> Security Guarantees Enforced On-Chain\n\n")
	b.WriteString("- **1:1 `wugnot` GRC20 escrow (`r/nt/grc20reg/v0`):** Non-crossing `RealmTeller` settlement in 1:1 `ugnot`-backed `wugnot`; every payout and refund clears atomically with strict Checks-Effects-Interactions ordering.\n")
	b.WriteString("- **Runtime-current auth:** Every crossing function authenticates `cur.Previous().Address()` cleanly on the live realm frame.\n")
	b.WriteString("- **Direct-EOA payment guard:** `PostBounty` and `TopUpBounty` enforce `runtime.AssertOriginCall()` and `cur.Previous().IsUserCall()`.\n")
	b.WriteString("- **Per-contributor top-up custody:** `CancelBounty` and dispute splits refund external donors directly; sponsors never receive third-party top-ups.\n")
	b.WriteString("- **Permissionless liveness timeouts:** `ReleaseExpiredClaim`, `ExpireSubmission`, and `ExpireDispute` (50/50 fallback) prevent frozen escrow. Arbiter cannot resolve bounties they are party to.\n")
	b.WriteString("- **Unicode-safe rendering:** Every user string passes `p/nt/markdown/sanitize/v0`, `EscapeMath`, and byte-indexed ASCII `NeutralizeGnoTags`.\n")

	res.Write(b.String())
}

func renderNotFound(res *mux.ResponseWriter, req *mux.Request) {
	var b strings.Builder
	b.WriteString("# <gno-icon name=\"warning\" /> Route Not Found\n\n")
	writeTopNav(&b, "home")
	b.WriteString("> [!WARNING] Unknown HearthBounty Path\n")
	b.WriteString("> Requested path `" + safeInline(req.Path) + "` does not match any active bounty, category, or guild profile.\n")
	res.Write(b.String())
}

func displayHandle(addr address) string {
	if raw := profiles.Get(string(addr)); raw != nil {
		return raw.(*profileRecord).Handle
	}
	return hearthcore.ShortAddr(addr)
}
