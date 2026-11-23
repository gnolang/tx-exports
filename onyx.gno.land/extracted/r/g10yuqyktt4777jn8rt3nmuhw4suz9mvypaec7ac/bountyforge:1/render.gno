package bountyforge

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/escrowmath"
	"gno.land/p/jeronimoalbi/mdform/v0"
	"gno.land/p/moul/md/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/pager/v0"
	"gno.land/p/nt/avl/rotree/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mdalert/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/svg/v0"
	"gno.land/p/nt/ufmt/v0"
)

const fallbackRealmWebPath = "/r/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/bountyforge"

// ---------------------------------------------------------------------------
// gnoweb Markdown Render Entrypoint & Router
// ---------------------------------------------------------------------------

func initRouter() {
	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("new", renderCreateForm)
	router.HandleFunc("bounty/{id}", renderBountyDetail)
	router.HandleFunc("builder/{addr}", renderBuilderProfile)
	router.HandleFunc("leaderboard", renderLeaderboard)
	router.HandleFunc("stats", renderStats)
	router.SetNotFoundHandler(func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write("# BountyForge — 404 Not Found\n\n")
		res.Write("Unknown route " + sanitize.InlineCode(escrowmath.TruncateRunes(req.Path, 80)) + ".\n\n")
		res.Write(gnoButton(routeURL(""), "Back to Board", "outline") + "\n")
	})
}

// Render serves human- and AI-readable Gno-Flavored Markdown over gnoweb.
func Render(path string) string {
	return router.Render(path)
}

// realmWebPath resolves the current realm's root-relative path (e.g. "/r/<addr>/bountyforge")
// so every link passes gnoweb v1.8.0's net/url parser cleanly (never leading ":").
func realmWebPath() string {
	pkg := unsafe.CurrentRealm().PkgPath()
	if pkg == "" {
		return fallbackRealmWebPath
	}
	trimmed := strings.TrimPrefix(pkg, runtime.ChainDomain())
	if !strings.HasPrefix(trimmed, "/") {
		return fallbackRealmWebPath
	}
	return trimmed
}

func routeURL(sub string) string {
	base := realmWebPath()
	if sub == "" {
		return base + ":"
	}
	return base + ":" + sub
}

func txRealm() txlink.Realm {
	return txlink.Realm(runtime.ChainDomain() + realmWebPath())
}

func gnoButton(href, label, variant string) string {
	safeHref := sanitize.HTMLEscape(href)
	safeLabel := sanitize.HTMLEscape(label)
	if variant == "" {
		return ufmt.Sprintf(`<gno-button href="%s" label="%s" />`, safeHref, safeLabel)
	}
	return ufmt.Sprintf(`<gno-button href="%s" label="%s" variant="%s" />`, safeHref, safeLabel, sanitize.HTMLEscape(variant))
}

func parseClampedPage(req *mux.Request) (int, int) {
	pageNum := 1
	if raw := strings.TrimSpace(req.Query.Get("page")); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v >= 1 {
			pageNum = v
		}
	}
	pageSize := DefaultPageSize
	if raw := strings.TrimSpace(req.Query.Get("size")); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v >= 1 {
			pageSize = v
		}
	}
	return clampPaging(pageNum, pageSize)
}

// ---------------------------------------------------------------------------
// Home Board (Paginated Status-Indexed AVL + KPI Columns + Interactive CTAs)
// ---------------------------------------------------------------------------

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	filter := strings.ToUpper(strings.TrimSpace(req.Query.Get("status")))
	pageNum, pageSize := parseClampedPage(req)

	res.Write("# BountyForge — On-Chain Micro-Bounty Escrow & Builder Reputation\n\n")
	res.Write("Trustless GNOT escrow, overflow-proof basis-point contributor splits, sponsor-safe crowdfunding refunds, DAO-composable canonical bankers, and verifiable on-chain SVG builder credentials on Gno.land.\n\n")

	// Interactive primary CTAs (gno-button + txlink)
	createLink := txRealm().NewLink("CreateBounty").SetSend("5000000ugnot").URL()
	res.Write(
		gnoButton(createLink, "Fund New Bounty", "success") + " " +
			gnoButton(routeURL("new"), "Interactive Create Form", "info") + " " +
			gnoButton(routeURL("leaderboard"), "Leaderboard", "outline") + " " +
			gnoButton(routeURL("stats"), "Protocol Stats", "outline") + "\n\n",
	)

	// KPI cards via <gno-columns>
	res.Write(md.Columns([]string{
		"### Locked Escrow\n**" + escrowmath.FormatGNOT(totalEscrowed) + "**\n" + strconv.Itoa(openCount) + " open · " + strconv.Itoa(disputedCount) + " disputed",
		"### Total Paid Out\n**" + escrowmath.FormatGNOT(totalPaidOut) + "**\n" + strconv.Itoa(paidCount) + " settled quests",
		"### Verified Builders\n**" + strconv.Itoa(builders.Size()) + "**\n[View Leaderboard](" + routeURL("leaderboard") + ")",
		"### Chain Height\n**#" + strconv.FormatInt(runtime.ChainHeight(), 10) + "**\n[Protocol Stats](" + routeURL("stats") + ")",
	}, false) + "\n")

	// Filter navigation (valid /r/...: paths!)
	res.Write(ufmt.Sprintf(
		"[All (%d)](%s) · [Open (%d)](%s) · [Paid (%d)](%s) · [Disputed (%d)](%s) · [Cancelled (%d)](%s)\n\n",
		bounties.Size(), routeURL(""),
		openCount, routeURL("?status=OPEN"),
		paidCount, routeURL("?status=PAID"),
		disputedCount, routeURL("?status=DISPUTED"),
		cancelledCnt, routeURL("?status=CANCELLED"),
	))

	if bounties.Size() == 0 {
		res.Write(mdalert.Info("Launch the First Quest", "No bounties posted yet. Click **Fund New Bounty** above or open the [Interactive Create Form]("+routeURL("new")+") to escrow GNOT on-chain.") + "\n")
		return
	}

	tree := bounties
	if filter != "" {
		tree = statusTree(filter)
		if tree == nil {
			res.Write(mdalert.Warning("Unknown Filter", "No status index matches "+sanitize.InlineCode(escrowmath.TruncateRunes(filter, 20))+".") + "\n")
			return
		}
	}

	if tree.Size() == 0 {
		res.Write("\n_No bounties currently in status " + sanitize.InlineCode(filter) + "._\n")
		return
	}

	p := pager.NewPager(rotree.Wrap(tree, nil), pageSize, true)
	pg := p.GetPage(pageNum)

	res.Write("| ID | Title | Reward | Status | Submissions | Sponsors | Tags |\n")
	res.Write("|---|---|---|---|---|---|---|\n")
	for _, item := range pg.Items {
		b := item.Value.(*Bounty)
		res.Write(ufmt.Sprintf(
			"| [#%d](%s) | %s | %s | %s | %d | %d | %s |\n",
			b.ID,
			routeURL("bounty/"+strconv.FormatUint(b.ID, 10)),
			sanitize.TableCell(escrowmath.TruncateRunes(b.Title, 80)),
			escrowmath.FormatGNOT(b.RewardUgnot),
			sanitize.InlineCode(b.Status),
			b.activeSubmissionCount(),
			len(b.Contributions),
			sanitize.TableCell(escrowmath.TruncateRunes(b.Tags, 40)),
		))
	}

	if picker := pg.Picker(req.RawPath); picker != "" {
		res.Write("\n**Page:** " + picker + "\n")
	}
}

// ---------------------------------------------------------------------------
// Interactive Bounty Creation Route (:new) using <gno-form>
// ---------------------------------------------------------------------------

func renderCreateForm(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# Create a Trustless Micro-Bounty\n\n")
	res.Write(mdalert.Tip("Escrow Deposit Required", "Attach at least `1000ugnot` (`0.001 GNOT`) via `-send` (or Adena Wallet) when executing `CreateBounty`. All crowdfund top-ups are tracked per-sponsor and refunded proportionally if cancelled.") + "\n")

	form := mdform.New("exec", "CreateBounty")
	form.Input("title", "placeholder", "Short imperative quest title (max 120 chars)", "required", "true")
	form.Textarea("summary", "placeholder", "Clear acceptance criteria, repository links, and verification steps...", "rows", "5", "required", "true")
	form.Input("tags", "placeholder", "gno,security,tooling")
	form.Input("arbiterStr", "placeholder", "Optional dispute arbiter address (g1...)")
	form.Input("deadlineBlocks", "type", "number", "placeholder", "0 for no expiry, or blocks (e.g. 20000)", "value", "20000")
	res.Write(form.String() + "\n\n")

	directLink := txRealm().NewLink("CreateBounty").SetSend("5000000ugnot").URL()
	res.Write(gnoButton(directLink, "Open txlink Helper (5 GNOT)", "success") + " " + gnoButton(routeURL(""), "Back to Board", "outline") + "\n")
}

// ---------------------------------------------------------------------------
// Bounty Detail Page (:bounty/{id})
// ---------------------------------------------------------------------------

func renderBountyDetail(res *mux.ResponseWriter, req *mux.Request) {
	rawID := req.GetVar("id")
	idNum, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil || idNum == 0 {
		res.Write("# Invalid Bounty ID\n\n" + gnoButton(routeURL(""), "Back to Board", "outline") + "\n")
		return
	}
	raw := bounties.Get(seqid.ID(idNum).String())
	if raw == nil {
		res.Write(ufmt.Sprintf("# Bounty #%d Not Found\n\n%s\n", idNum, gnoButton(routeURL(""), "Back to Board", "outline")))
		return
	}
	b := raw.(*Bounty)
	idStr := strconv.FormatUint(b.ID, 10)
	nowH := runtime.ChainHeight()

	res.Write(ufmt.Sprintf("# Bounty #%d: %s\n\n", b.ID, sanitize.InlineText(b.Title)))

	// Contextual status banner via mdalert
	switch b.Status {
	case StatusOpen:
		if b.DeadlineH > 0 && nowH > b.DeadlineH {
			cancelAt := b.DeadlineH + ReviewGraceBlocks
			if nowH <= cancelAt {
				res.Write(mdalert.Warning("Review Grace Window", ufmt.Sprintf("Submission deadline (#%d) has passed. Creator may approve/split payouts or either party may open a dispute until block #%d before cancellation unlocks.", b.DeadlineH, cancelAt)) + "\n")
			} else {
				res.Write(mdalert.Info("Deadline & Grace Passed", "Submissions are closed. Creator may settle an active submission or cancel to refund every sponsor exactly.") + "\n")
			}
		}
	case StatusPaid:
		res.Write(mdalert.Success("Settled On-Chain", "Escrowed GNOT has been disbursed and builder reputation XP credited.") + "\n")
	case StatusDisputed:
		expireAt := b.DisputeOpenedH + DisputeTimeoutBlocks
		res.Write(mdalert.Caution("Under Arbiter Review", ufmt.Sprintf("Frozen at block #%d. Designated arbiter `%s` resolves via `ResolveDispute`. If unresolved past block #%d, any contributor or submitter can trigger `ExpireDispute` for exact sponsor refunds.", b.DisputeOpenedH, b.Arbiter.String(), expireAt)) + "\n")
	case StatusCancelled:
		res.Write(mdalert.Note("Cancelled & Refunded", "All contributor deposits have been returned to their original sponsors.") + "\n")
	}

	// Metadata list (all dynamic values safely sanitized per lexical slot)
	res.Write("- **Status:** " + sanitize.InlineCode(b.Status) + "\n")
	res.Write(ufmt.Sprintf("- **Reward Pool:** **%s** (`%d ugnot`) across %d sponsor(s)\n", escrowmath.FormatGNOT(b.RewardUgnot), b.RewardUgnot, len(b.Contributions)))
	res.Write(ufmt.Sprintf("- **Creator:** [%s](%s) (`%s`)\n", shortAddr(b.Creator), routeURL("builder/"+b.Creator.String()), b.Creator.String()))
	if b.Arbiter != "" {
		res.Write(ufmt.Sprintf("- **Dispute Arbiter:** `%s`\n", b.Arbiter.String()))
	} else {
		res.Write("- **Dispute Arbiter:** _None (creator-managed)_\n")
	}
	if b.DeadlineH > 0 {
		res.Write(ufmt.Sprintf("- **Submission Deadline:** Block #%d (review grace through #%d; current #%d)\n", b.DeadlineH, b.DeadlineH+ReviewGraceBlocks, nowH))
	} else {
		res.Write("- **Submission Deadline:** _No expiry_\n")
	}
	if b.Tags != "" {
		res.Write("- **Tags:** " + sanitize.InlineCode(b.Tags) + "\n")
	}

	// Action buttons wired to txlink
	res.Write("\n")
	if b.Status == StatusOpen {
		btns := []string{}
		if b.DeadlineH == 0 || nowH <= b.DeadlineH {
			topUpURL := txRealm().NewLink("TopUpBounty").AddArgs("bountyID", idStr).SetSend("1000000ugnot").URL()
			btns = append(btns, gnoButton(topUpURL, "Top Up +1 GNOT", "success"))
		}
		if b.activeSubmissionCount() > 0 {
			splitURL := txRealm().NewLink("SplitAndPay").AddArgs("bountyID", idStr, "indicesCSV", "0", "bpsCSV", "10000").URL()
			btns = append(btns, gnoButton(splitURL, "Split & Pay", "info"))
			if b.Arbiter != "" {
				dispURL := txRealm().NewLink("OpenDispute").AddArgs("bountyID", idStr, "reason", "Requesting arbiter review").URL()
				btns = append(btns, gnoButton(dispURL, "Open Dispute", "warning"))
			}
		}
		cancelURL := txRealm().NewLink("CancelAndRefund").AddArgs("bountyID", idStr).URL()
		btns = append(btns, gnoButton(cancelURL, "Cancel & Refund", "caution outline"))
		res.Write(strings.Join(btns, " ") + "\n\n")
	} else if b.Status == StatusDisputed {
		resolveURL := txRealm().NewLink("ResolveDispute").AddArgs("bountyID", idStr, "submissionIdx", "0", "builderBps", "7500").URL()
		expireURL := txRealm().NewLink("ExpireDispute").AddArgs("bountyID", idStr).URL()
		res.Write(gnoButton(resolveURL, "Arbiter: Resolve Dispute", "info") + " " + gnoButton(expireURL, "Expire Timed-Out Dispute", "caution outline") + "\n\n")
	}

	// Specification body (strict Block sanitization prevents HTML comments, gno-button phishing, headings hijack)
	res.Write("## Specification\n" + sanitize.Block(b.Summary))

	if b.DisputeReason != "" {
		res.Write("## Dispute Notice\n" + sanitize.Blockquote(b.DisputeReason))
	}

	// Sponsor Contributions Ledger
	res.Write(ufmt.Sprintf("## Crowdfund Escrow Ledger (%d)\n\n", len(b.Contributions)))
	res.Write("| Role | Sponsor | Deposited | Share |\n")
	res.Write("|---|---|---|---|\n")
	for i, c := range b.Contributions {
		role := "Sponsor"
		if i == 0 {
			role = "Creator"
		}
		shareBps := int64(0)
		if b.RewardUgnot > 0 {
			// Safe because c.Amount <= b.RewardUgnot -> use pure integer scaling via ProRataRefund or simple division
			if c.Amount == b.RewardUgnot {
				shareBps = escrowmath.TotalBPS
			} else {
				// Avoid overflow: (c.Amount / (Reward/10000)) or bits math via escrowmath
				shareBps = bpsRatio(c.Amount, b.RewardUgnot)
			}
		}
		res.Write(ufmt.Sprintf(
			"| %s | [%s](%s) | %s | %s |\n",
			role,
			shortAddr(c.Sponsor),
			routeURL("builder/"+c.Sponsor.String()),
			escrowmath.FormatGNOT(c.Amount),
			escrowmath.FormatBPS(shareBps),
		))
	}
	res.Write("\n")

	// Submissions table
	res.Write(ufmt.Sprintf("## Submissions (%d active / %d total)\n\n", b.activeSubmissionCount(), len(b.Submissions)))
	if len(b.Submissions) == 0 {
		res.Write("_No submissions yet._\n\n")
	} else {
		res.Write("| # | Builder | Proof | Notes | Block | Action |\n")
		res.Write("|---|---|---|---|---|---|\n")
		for _, sub := range b.Submissions {
			builderCell := ufmt.Sprintf("[%s](%s)", shortAddr(sub.Builder), routeURL("builder/"+sub.Builder.String()))
			if sub.ViaSession {
				builderCell += " `agent-session`"
			}
			statusCell := "—"
			if sub.Withdrawn {
				statusCell = "`WITHDRAWN`"
			} else if b.Status == StatusOpen {
				approveURL := txRealm().NewLink("ApproveAndPay").AddArgs("bountyID", idStr, "submissionIdx", strconv.Itoa(sub.Index)).URL()
				statusCell = gnoButton(approveURL, "Approve & Pay", "success outline")
			}
			// md.Link sanitizes text and URL internally (wrap once!)
			proofCell := md.Link("View Deliverable", sub.ProofURL)
			res.Write(ufmt.Sprintf(
				"| %d | %s | %s | %s | #%d | %s |\n",
				sub.Index,
				builderCell,
				proofCell,
				sanitize.TableCell(sub.Notes),
				sub.SubmittedH,
				statusCell,
			))
		}
		res.Write("\n")
	}

	// Inline submission form on open bounties within deadline
	if b.Status == StatusOpen && (b.DeadlineH == 0 || nowH <= b.DeadlineH) {
		res.Write("### Submit Proof of Work\n\n")
		form := mdform.New("exec", "SubmitWork")
		form.Input("bountyID", "type", "number", "value", idStr, "readonly", "true")
		form.Input("proofURL", "placeholder", "https://github.com/org/repo/pull/1", "required", "true")
		form.Input("notes", "placeholder", "Summary of deliverables and test verification")
		res.Write(form.String() + "\n\n")
	}

	// Settlement & On-Chain SVG Split Chart
	if len(b.Payouts) > 0 {
		res.Write("## On-Chain Settlement\n\n")
		if len(b.Payouts) > 1 {
			res.Write(renderSplitChartSVG(b.Payouts) + "\n\n")
		}
		res.Write("| Recipient | Share | Amount |\n")
		res.Write("|---|---|---|\n")
		for _, p := range b.Payouts {
			res.Write(ufmt.Sprintf(
				"| [%s](%s) | %s | %s |\n",
				shortAddr(p.Recipient),
				routeURL("builder/"+p.Recipient.String()),
				escrowmath.FormatBPS(p.Bps),
				escrowmath.FormatGNOT(p.Amount),
			))
		}
		res.Write("\n")
	}

	if len(b.Refunds) > 0 {
		res.Write("## Sponsor Refunds\n\n")
		res.Write("| Sponsor | Refunded |\n")
		res.Write("|---|---|\n")
		for _, r := range b.Refunds {
			res.Write(ufmt.Sprintf(
				"| [%s](%s) | %s |\n",
				shortAddr(r.Sponsor),
				routeURL("builder/"+r.Sponsor.String()),
				escrowmath.FormatGNOT(r.Amount),
			))
		}
		res.Write("\n")
	}

	res.Write(gnoButton(routeURL(""), "Back to Board", "outline") + " " + gnoButton(routeURL("leaderboard"), "Leaderboard", "outline") + "\n")
}

// ---------------------------------------------------------------------------
// Builder Profile (:builder/{addr}) with On-Chain SVG Credential Badge
// ---------------------------------------------------------------------------

func renderBuilderProfile(res *mux.ResponseWriter, req *mux.Request) {
	rawAddr := req.GetVar("addr")
	validAddr := sanitize.BechString(rawAddr, "g")
	res.Write("# Builder Profile\n\n")
	if validAddr == "" {
		res.Write(mdalert.Warning("Invalid Address", "Address "+sanitize.InlineCode(escrowmath.TruncateRunes(rawAddr, 64))+" is not a valid Gno bech32 address.") + "\n")
		res.Write(gnoButton(routeURL(""), "Back to Board", "outline") + "\n")
		return
	}

	raw := builders.Get(validAddr)
	var prof *BuilderProfile
	if raw != nil {
		prof = raw.(*BuilderProfile)
	} else {
		prof = &BuilderProfile{Address: address(validAddr)}
	}

	// Render deterministic on-chain SVG Builder Credential Card via p/nt/svg/v0
	res.Write(renderBuilderBadgeSVG(prof) + "\n\n")

	tier, badge := escrowmath.TierForXP(prof.XP)
	nextTarget := nextTierTarget(prof.XP)
	res.Write("- **Address:** " + sanitize.InlineCode(validAddr) + "\n")
	res.Write(ufmt.Sprintf("- **Tier:** %s %s\n", sanitize.InlineCode(badge), tier))
	res.Write(ufmt.Sprintf("- **Reputation XP:** %d %s\n", prof.XP, escrowmath.ProgressBar(int(prof.XP), int(nextTarget), 12)))
	res.Write(ufmt.Sprintf("- **Completed Bounties:** %d (from %d unique creator(s))\n", prof.Completed, prof.UniqueCreators()))
	res.Write(ufmt.Sprintf("- **Total Earned:** %s\n", escrowmath.FormatGNOT(prof.TotalEarned)))
	if prof.LastHeight > 0 {
		res.Write(ufmt.Sprintf("- **Last Active Block:** #%d\n\n", prof.LastHeight))
	} else {
		res.Write("- **Last Active Block:** _No settled payouts yet_\n\n")
	}

	res.Write(gnoButton(routeURL(""), "Back to Board", "outline") + " " + gnoButton(routeURL("leaderboard"), "Leaderboard", "outline") + "\n")
}

// ---------------------------------------------------------------------------
// Paginated O(pageSize) Leaderboard (:leaderboard) — Zero Sorting on Query
// ---------------------------------------------------------------------------

func renderLeaderboard(res *mux.ResponseWriter, req *mux.Request) {
	pageNum, pageSize := parseClampedPage(req)
	res.Write("# BountyForge Builder Leaderboard\n\n")
	if leaderboard.Size() == 0 {
		res.Write("_No settled bounties yet._\n\n" + gnoButton(routeURL(""), "Back to Board", "outline") + "\n")
		return
	}

	p := pager.NewPager(rotree.Wrap(leaderboard, nil), pageSize, false)
	pg := p.GetPage(pageNum)
	rankOffset := (pageNum - 1) * pageSize

	res.Write("| Rank | Builder | Tier | XP | Completed | Unique Creators | Earned |\n")
	res.Write("|---|---|---|---|---|---|---|\n")
	for i, item := range pg.Items {
		prof := item.Value.(*BuilderProfile)
		tier, badge := escrowmath.TierForXP(prof.XP)
		res.Write(ufmt.Sprintf(
			"| #%d | [%s](%s) | %s %s | %d | %d | %d | %s |\n",
			rankOffset+i+1,
			shortAddr(prof.Address),
			routeURL("builder/"+prof.Address.String()),
			sanitize.InlineCode(badge),
			tier,
			prof.XP,
			prof.Completed,
			prof.UniqueCreators(),
			escrowmath.FormatGNOT(prof.TotalEarned),
		))
	}

	if picker := pg.Picker(req.RawPath); picker != "" {
		res.Write("\n**Page:** " + picker + "\n")
	}
	res.Write("\n" + gnoButton(routeURL(""), "Back to Board", "outline") + " " + gnoButton(routeURL("stats"), "Protocol Stats", "outline") + "\n")
}

// ---------------------------------------------------------------------------
// Protocol Stats (:stats)
// ---------------------------------------------------------------------------

func renderStats(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# BountyForge Protocol Stats & Security Invariants\n\n")
	res.Write(md.Columns([]string{
		"### Total Locked\n**" + escrowmath.FormatGNOT(totalEscrowed) + "**\n`" + strconv.FormatInt(totalEscrowed, 10) + " ugnot`",
		"### Cumulative Paid\n**" + escrowmath.FormatGNOT(totalPaidOut) + "**\n`" + strconv.FormatInt(totalPaidOut, 10) + " ugnot`",
		"### Quests\n**" + strconv.Itoa(bounties.Size()) + " total**\n" + ufmt.Sprintf("%d Open · %d Paid · %d Disputed · %d Cancelled", openCount, paidCount, disputedCount, cancelledCnt),
	}, false) + "\n")

	res.Write("## Live Protocol Parameters\n\n")
	res.Write(ufmt.Sprintf("- **Verified Builders:** %d\n", builders.Size()))
	res.Write(ufmt.Sprintf("- **Minimum Bounty:** %s (`%d ugnot`)\n", escrowmath.FormatGNOT(MinRewardUgnot), MinRewardUgnot))
	res.Write(ufmt.Sprintf("- **Post-Deadline Review Grace:** %d blocks\n", ReviewGraceBlocks))
	res.Write(ufmt.Sprintf("- **Arbiter Dispute Timeout:** %d blocks\n", DisputeTimeoutBlocks))
	res.Write(ufmt.Sprintf("- **Current Block Height:** #%d\n\n", runtime.ChainHeight()))

	res.Write(gnoButton(routeURL(""), "Back to Board", "outline") + " " + gnoButton(routeURL("leaderboard"), "Leaderboard", "outline") + "\n")
}

// ---------------------------------------------------------------------------
// On-Chain Deterministic SVG Generators (p/nt/svg/v0, zero user XML injection)
// ---------------------------------------------------------------------------

func renderBuilderBadgeSVG(prof *BuilderProfile) string {
	tier, badge := escrowmath.TierForXP(prof.XP)
	accent := escrowmath.TierColor(prof.XP)
	nextTarget := nextTierTarget(prof.XP)

	// Compute progress bar pixel width (0..380) using pure integer math
	barMaxW := 380
	barFillW := barMaxW
	if nextTarget > 0 && prof.XP < nextTarget {
		barFillW = int((prof.XP * int64(barMaxW)) / nextTarget)
		if barFillW < 6 && prof.XP > 0 {
			barFillW = 6
		}
	}
	if prof.XP == 0 {
		barFillW = 0
	}

	c := svg.NewCanvas(460, 170).WithViewBox(0, 0, 460, 170)
	c.AddStyle("text", "font-family:ui-monospace,SFMono-Regular,Menlo,monospace")

	// Card background & tier accent bar
	bg := svg.NewRectangle(2, 2, 456, 166, "#0F172A")
	bg.RX, bg.RY = 14, 14
	bg.Attr.Stroke = accent
	bg.Attr.StrokeWidth = "2"
	c.Append(bg)

	stripe := svg.NewRectangle(2, 2, 10, 166, accent)
	stripe.RX, stripe.RY = 6, 6
	c.Append(stripe)

	// Header label & tier badge pill
	hdr := svg.NewText(28, 34, "BOUNTYFORGE ON-CHAIN BUILDER CREDENTIAL", "#94A3B8")
	hdr.Attr.Style = "font-size:11px;font-weight:700;letter-spacing:1px"
	c.Append(hdr)

	pill := svg.NewRectangle(316, 16, 126, 26, accent)
	pill.RX, pill.RY = 13, 13
	c.Append(pill)
	pillTxt := svg.NewText(330, 33, badge+" "+tier, "#0F172A")
	pillTxt.Attr.Style = "font-size:12px;font-weight:700"
	c.Append(pillTxt)

	// Builder short address (bech32 validated -> strictly safe ASCII)
	addrTxt := svg.NewText(28, 66, shortAddr(prof.Address), "#F8FAFC")
	addrTxt.Attr.Style = "font-size:20px;font-weight:700"
	c.Append(addrTxt)

	// Stats row
	statsLine := ufmt.Sprintf("XP: %d   |   Quests: %d   |   Earned: %s", prof.XP, prof.Completed, escrowmath.FormatGNOT(prof.TotalEarned))
	stTxt := svg.NewText(28, 98, statsLine, "#CBD5E1")
	stTxt.Attr.Style = "font-size:13px"
	c.Append(stTxt)

	// Progress track & fill
	track := svg.NewRectangle(28, 114, barMaxW, 14, "#1E293B")
	track.RX, track.RY = 7, 7
	c.Append(track)
	if barFillW > 0 {
		fill := svg.NewRectangle(28, 114, barFillW, 14, accent)
		fill.RX, fill.RY = 7, 7
		c.Append(fill)
	}

	foot := svg.NewText(28, 150, ufmt.Sprintf("Unique Creators: %d  ·  Verified on Gno.land", prof.UniqueCreators()), "#64748B")
	foot.Attr.Style = "font-size:11px"
	c.Append(foot)

	return c.Render("BountyForge Builder Credential")
}

func renderSplitChartSVG(payouts []*PayoutRecord) string {
	palette := []string{"#06B6D4", "#A855F7", "#10B981", "#F59E0B", "#3B82F6", "#EC4899"}
	height := 68 + len(payouts)*22
	if height > 260 {
		height = 260
	}
	c := svg.NewCanvas(460, height).WithViewBox(0, 0, 460, height)
	c.AddStyle("text", "font-family:ui-monospace,SFMono-Regular,Menlo,monospace")

	bg := svg.NewRectangle(1, 1, 458, height-2, "#0F172A")
	bg.RX, bg.RY = 10, 10
	bg.Attr.Stroke = "#334155"
	bg.Attr.StrokeWidth = "1"
	c.Append(bg)

	title := svg.NewText(16, 24, "MULTI-CONTRIBUTOR PAYOUT SPLIT (ZERO-DUST BPS)", "#94A3B8")
	title.Attr.Style = "font-size:11px;font-weight:700"
	c.Append(title)

	barX := 16
	barW := 428
	curX := barX
	for i, p := range payouts {
		segW := int((p.Bps * int64(barW)) / escrowmath.TotalBPS)
		if i == len(payouts)-1 {
			segW = (barX + barW) - curX
		}
		if segW < 2 {
			segW = 2
		}
		color := palette[i%len(palette)]
		seg := svg.NewRectangle(curX, 34, segW, 18, color)
		c.Append(seg)
		curX += segW

		if i < 8 {
			ly := 72 + i*22
			dot := svg.NewRectangle(16, ly-11, 10, 10, color)
			dot.RX, dot.RY = 2, 2
			c.Append(dot)
			lbl := ufmt.Sprintf("%s  —  %s (%s)", shortAddr(p.Recipient), escrowmath.FormatBPS(p.Bps), escrowmath.FormatGNOT(p.Amount))
			lt := svg.NewText(34, ly-2, lbl, "#E2E8F0")
			lt.Attr.Style = "font-size:12px"
			c.Append(lt)
		}
	}
	return c.Render("BountyForge Payout Split Breakdown")
}

// ---------------------------------------------------------------------------
// Small pure display helpers
// ---------------------------------------------------------------------------

func bpsRatio(part, total int64) int64 {
	if part <= 0 || total <= 0 {
		return 0
	}
	if part >= total {
		return escrowmath.TotalBPS
	}
	// Use ProRataRefund-safe scaling: part <= total <= MaxInt64
	// Since TotalBPS = 10000, use q/r decomposition to prevent overflow on huge part
	q := part / total
	r := part % total
	// Wait: part < total so q == 0, r == part. Divide both by scale if r > MaxInt64/10000.
	if r <= 900_000_000_000_000 {
		return (r * escrowmath.TotalBPS) / total
	}
	scale := total / escrowmath.TotalBPS
	if scale <= 0 {
		return escrowmath.TotalBPS
	}
	return q*escrowmath.TotalBPS + (r / scale)
}

func nextTierTarget(xp int64) int64 {
	switch {
	case xp < 100:
		return 100
	case xp < 300:
		return 300
	case xp < 800:
		return 800
	case xp < 2000:
		return 2000
	case xp < 5000:
		return 5000
	default:
		return xp
	}
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}
