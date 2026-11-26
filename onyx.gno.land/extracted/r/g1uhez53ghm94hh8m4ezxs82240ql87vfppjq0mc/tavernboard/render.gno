package tavernboard

import (
	"sort"
	"strconv"
	"strings"

	"gno.land/p/moul/mdtable/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/pager/v0"
	"gno.land/p/nt/avl/rotree/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mdalert/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/g1uhez53ghm94hh8m4ezxs82240ql87vfppjq0mc/tavernkit"
	"gno.land/r/sys/users"
)

var router *mux.Router

func initRouter() {
	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("bounty/{id}", renderBountyDetail)
	router.HandleFunc("guild", renderGuildHall)
	router.HandleFunc("builder/{addr}", renderBuilderProfile)
	router.HandleFunc("guide", renderGuide)
	router.NotFoundHandler = renderNotFound
}

// Render serves TavernBoard's full multi-route Markdown & SVG interface
// natively inside gnoweb without requiring any external backend server.
func Render(path string) string {
	return router.Render(path)
}

func realmRoutePrefix() string {
	idx := strings.Index(realmPkgPath, "/r/")
	if idx >= 0 {
		return realmPkgPath[idx:]
	}
	return "/r/tavernboard/tavernboard"
}

func navBar(active string) string {
	base := realmRoutePrefix()
	postURL := txlink.NewLink("PostBounty").SetSend("1000000ugnot").URL()

	items := []struct {
		key   string
		label string
		href  string
	}{
		{"home", "Quest Board", base},
		{"open", "Open Quests", base + ":?status=open"},
		{"review", "In Review", base + ":?status=review"},
		{"disputed", "Disputed", base + ":?status=disputed"},
		{"guild", "Guild Hall", base + ":guild"},
		{"guide", "Architecture & Guide", base + ":guide"},
	}

	parts := make([]string, 0, len(items)+1)
	for _, it := range items {
		if it.key == active {
			parts = append(parts, "**"+it.label+"**")
		} else {
			parts = append(parts, "["+it.label+"]("+it.href+")")
		}
	}
	parts = append(parts, "[+ Post a Quest]("+postURL+")")
	return strings.Join(parts, " · ")
}

func resolveDisplayName(addr address) string {
	if addr == "" {
		return "_Unclaimed_"
	}
	if u := users.ResolveAddress(addr); !u.IsDeleted() {
		return "@" + u.Name()
	}
	return tavernkit.ShortAddr(addr)
}

func builderLink(addr address) string {
	if addr == "" {
		return "_Unclaimed_"
	}
	label := sanitize.InlineText(resolveDisplayName(addr))
	return "[" + label + "](" + realmRoutePrefix() + ":builder/" + sanitize.URL(addr.String()) + ")"
}

func safeCell(raw string) string {
	flat := strings.ReplaceAll(raw, "\r", " ")
	flat = strings.ReplaceAll(flat, "\n", " ")
	flat = strings.ReplaceAll(flat, "\t", " ")
	return sanitize.InlineText(strings.TrimSpace(flat))
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	statusFilter := strings.ToLower(strings.TrimSpace(req.Query.Get("status")))
	activeNav := "home"
	if statusFilter == "open" || statusFilter == "review" || statusFilter == "disputed" {
		activeNav = statusFilter
	}

	st := GetStats()
	base := realmRoutePrefix()

	var sb strings.Builder
	sb.WriteString("# TavernBoard — On-Chain Quest Escrow & Guild Reputation\n\n")
	sb.WriteString(navBar(activeNav) + "\n\n")
	sb.WriteString("Pure on-chain micro-bounties powered by **Gno.land v1.8 Sub-Realm Escrow Vaults** (`cur.Sub(\"escrow/<id>\")`), **Stake-Backed Reviewer Quorums**, **On-Chain SVG Guild Crests**, and **Composable Reputation**.\n\n")

	// Protocol summary table.
	statsTbl := mdtable.Table{
		Headers: []string{"Total Quests", "Open", "Active Escrow TVL", "Total Paid Out", "Disputes Settled", "Ranked Guild Members"},
	}
	statsTbl.Append([]string{
		strconv.FormatInt(st.TotalBounties, 10),
		strconv.FormatInt(st.OpenBounties, 10),
		"**" + tavernkit.FormatGNOT(st.ActiveEscrowUgnot) + "**",
		tavernkit.FormatGNOT(st.TotalPaidUgnot),
		strconv.FormatInt(st.DisputesResolved, 10),
		strconv.Itoa(st.RankedBuilders),
	})
	sb.WriteString(statsTbl.String() + "\n")

	if bounties.Size() == 0 {
		postURL := txlink.NewLink("PostBounty").SetSend("1000000ugnot").URL()
		sb.WriteString(mdalert.Tip(
			"The Quest Board Awaits Its First Contract",
			"Post the first funded bounty directly from gnoweb: [Post a 1 GNOT Quest]("+postURL+"). Every quest mints its own isolated sub-realm escrow vault.",
		) + "\n")
		res.Write(sb.String())
		return
	}

	heading := "## Active & Recent Quests"
	if statusFilter != "" {
		heading = "## Quests — Filter: `" + sanitize.InlineText(statusFilter) + "`"
	}
	sb.WriteString(heading + "\n\n")

	tbl := mdtable.Table{
		Headers: []string{"ID", "Quest", "Status", "Reward", "Milestones", "Sponsor", "Builder", "Deadline"},
	}

	if statusFilter == "" {
		// O(log n) paginated view over all bounties (newest first).
		ro := rotree.Wrap(bounties, nil)
		pg := pager.NewPager(ro, 10, true)
		page, err := pg.GetPageByPath(req.RawPath)
		if err != nil {
			page = pg.GetPage(1)
		}
		for _, item := range page.Items {
			b := item.Value.(*bounty)
			tbl.Append(bountyTableRow(base, b))
		}
		sb.WriteString(tbl.String() + "\n")
		if picker := page.Picker(req.RawPath); picker != "" {
			sb.WriteString("Pages: " + picker + "\n\n")
		}
	} else {
		matched := 0
		bounties.ReverseIterate("", "", func(_ string, val any) bool {
			b := val.(*bounty)
			if matchesStatusFilter(b.status, statusFilter) {
				tbl.Append(bountyTableRow(base, b))
				matched++
				if matched >= 25 {
					return true
				}
			}
			return false
		})
		if matched == 0 {
			sb.WriteString(mdalert.Info("No Matching Quests", "No quests match this filter right now. [View all quests]("+base+").") + "\n")
		} else {
			sb.WriteString(tbl.String() + "\n")
		}
	}

	sb.WriteString(mdalert.Note(
		"Composable Reputation API",
		"External Gno realms can import `tavernboard` and gate permissions via `tavernboard.HasCraftTier(caller, tavernkit.TierArtisan)` or read live JSON state via `vm/qeval` on `GetBoardJSON(20)`.",
	))

	res.Write(sb.String())
}

func matchesStatusFilter(st tavernkit.Status, filter string) bool {
	switch filter {
	case "open":
		return st == tavernkit.StatusOpen
	case "claimed":
		return st == tavernkit.StatusClaimed
	case "review":
		return st == tavernkit.StatusInReview
	case "disputed":
		return st == tavernkit.StatusDisputed
	case "completed":
		return st == tavernkit.StatusCompleted
	default:
		return true
	}
}

func bountyTableRow(base string, b *bounty) []string {
	idStr := strconv.FormatUint(b.id, 10)
	titleLink := "[" + safeCell(b.title) + "](" + base + ":bounty/" + idStr + ")"
	settled := 0
	for _, m := range b.milestones {
		if m.status.IsTerminal() {
			settled++
		}
	}
	return []string{
		"#" + idStr,
		titleLink,
		"`" + b.status.String() + "`",
		"**" + tavernkit.FormatGNOT(b.totalFundedUgnot) + "**",
		strconv.Itoa(settled) + "/" + strconv.Itoa(len(b.milestones)),
		builderLink(b.sponsor),
		builderLink(b.builder),
		b.deadline.Format("2006-01-02"),
	}
}

func renderBountyDetail(res *mux.ResponseWriter, req *mux.Request) {
	idRaw := req.GetVar("id")
	id, err := strconv.ParseUint(idRaw, 10, 64)
	if err != nil || id == 0 {
		renderNotFound(res, req)
		return
	}
	b := getBounty(id)
	if b == nil {
		renderNotFound(res, req)
		return
	}

	idStr := strconv.FormatUint(b.id, 10)
	escrowAddr := DeriveEscrowAddress(b.id)
	stakeAddr := DeriveStakeAddress(b.id)
	liveEscrow := liveVaultUgnot(escrowAddr)
	liveStake := liveVaultUgnot(stakeAddr)

	settled := 0
	for _, m := range b.milestones {
		if m.status.IsTerminal() {
			settled++
		}
	}

	var sb strings.Builder
	sb.WriteString("# Quest #" + idStr + ": " + sanitize.InlineText(b.title) + "\n\n")
	sb.WriteString(navBar("") + "\n\n")

	// Live on-chain SVG Escrow Vault Card.
	sb.WriteString(tavernkit.RenderEscrowCardSVG(
		idStr,
		b.status,
		b.totalFundedUgnot,
		b.totalReleasedUgnot,
		settled,
		len(b.milestones),
	) + "\n\n")

	if b.archived {
		sb.WriteString(mdalert.Info(
			"Archived Tombstone (Storage Deposit Reclaimed)",
			"Heavy prose fields for this closed quest were pruned to refund on-chain GnoVM storage deposits while preserving financial settlement and reputation history.",
		) + "\n")
	} else {
		sb.WriteString("## Quest Brief\n\n")
		sb.WriteString(sanitize.Block(b.summary) + "\n\n")
	}

	// Vault & metadata table.
	meta := mdtable.Table{
		Headers: []string{"Field", "Value"},
	}
	meta.Append([]string{"Status", "`" + b.status.String() + "`"})
	meta.Append([]string{"Sponsor", builderLink(b.sponsor)})
	meta.Append([]string{"Assigned Builder", builderLink(b.builder)})
	if b.tags != "" {
		meta.Append([]string{"Tags", "`" + safeCell(b.tags) + "`"})
	}
	meta.Append([]string{"Escrow Sub-Vault (`escrow/" + idStr + "`)", "`" + escrowAddr.String() + "` (live: **" + tavernkit.FormatGNOT(liveEscrow) + "**)"})
	meta.Append([]string{"Stake Sub-Vault (`stake/" + idStr + "`)", "`" + stakeAddr.String() + "` (live: " + tavernkit.FormatGNOT(liveStake) + ")"})
	meta.Append([]string{"Dispute Quorum", strconv.Itoa(b.reviewerQuorum) + " reviewers · min stake " + tavernkit.FormatGNOT(b.minReviewerStakeUgnot)})
	meta.Append([]string{"Deadline (UTC)", b.deadline.Format("2006-01-02 15:04 UTC")})
	sb.WriteString(meta.String() + "\n")

	if b.builderPitch != "" {
		sb.WriteString("**Builder Pitch:**\n")
		sb.WriteString(sanitize.Blockquote(b.builderPitch) + "\n\n")
	}

	// Context-aware one-click gnoweb txlink action bar.
	sb.WriteString("## Quick Actions\n\n")
	actions := []string{}
	if b.status == tavernkit.StatusOpen {
		actions = append(actions, "[Claim Quest]("+txlink.NewLink("ClaimBounty").AddArgs("bountyID", idStr).URL()+")")
		actions = append(actions, "[Cancel & Refund]("+txlink.NewLink("CancelOrReclaimExpired").AddArgs("bountyID", idStr).URL()+")")
	}
	if b.status == tavernkit.StatusOpen || b.status == tavernkit.StatusClaimed || b.status == tavernkit.StatusInReview {
		actions = append(actions, "[Top Up +1 GNOT]("+txlink.NewLink("TopUpBounty").AddArgs("bountyID", idStr).SetSend("1000000ugnot").URL()+")")
		if liveEscrow > b.vaultAccountedUgnot {
			actions = append(actions, "[Sync Direct Vault Deposit]("+txlink.NewLink("SyncBountyVault").AddArgs("bountyID", idStr).URL()+")")
		}
	}
	if b.status == tavernkit.StatusClaimed {
		actions = append(actions, "[Release Claim]("+txlink.NewLink("ReleaseClaim").AddArgs("bountyID", idStr).URL()+")")
	}
	if (b.status == tavernkit.StatusCompleted || b.status == tavernkit.StatusCancelled) && !b.archived && b.vaultAccountedUgnot == 0 {
		actions = append(actions, "[Archive & Reclaim Storage Deposit]("+txlink.NewLink("ArchiveClosedBounty").AddArgs("bountyID", idStr).URL()+")")
	}
	if len(actions) > 0 {
		sb.WriteString(strings.Join(actions, " · ") + "\n\n")
	}

	// Milestones table.
	sb.WriteString("## Milestones\n\n")
	mtbl := mdtable.Table{
		Headers: []string{"#", "Deliverable", "Weight", "Payout", "Status", "Proof", "Action"},
	}
	for _, m := range b.milestones {
		idxStr := strconv.Itoa(m.index)
		proofCell := "—"
		if m.proofURL != "" {
			safeHref := sanitize.URL(m.proofURL)
			if safeHref != "" {
				proofCell = "[View Proof](" + safeHref + ")"
			}
		}
		actCell := "—"
		switch m.status {
		case tavernkit.MilestonePending, tavernkit.MilestoneRevisionRequested:
			if b.builder != "" && b.status != tavernkit.StatusCancelled && b.status != tavernkit.StatusArchived {
				submitLink := txlink.NewLink("SubmitMilestone").AddArgs("bountyID", idStr, "milestoneIdx", idxStr).URL()
				actCell = "[Submit Proof](" + submitLink + ")"
				if m.status == tavernkit.MilestoneRevisionRequested {
					dispLink := txlink.NewLink("OpenDispute").AddArgs("bountyID", idStr, "milestoneIdx", idxStr).URL()
					actCell += " · [Dispute](" + dispLink + ")"
				}
			}
		case tavernkit.MilestoneSubmitted:
			approveLink := txlink.NewLink("ApproveMilestone").AddArgs("bountyID", idStr, "milestoneIdx", idxStr).URL()
			revLink := txlink.NewLink("RequestRevision").AddArgs("bountyID", idStr, "milestoneIdx", idxStr).URL()
			dispLink := txlink.NewLink("OpenDispute").AddArgs("bountyID", idStr, "milestoneIdx", idxStr).URL()
			actCell = "[Approve & Pay](" + approveLink + ") · [Revise](" + revLink + ") · [Dispute](" + dispLink + ")"
		case tavernkit.MilestoneDisputed:
			stakeStr := strconv.FormatInt(b.minReviewerStakeUgnot, 10) + nativeDenom
			voteApprove := txlink.NewLink("StakeAndVoteDispute").AddArgs("bountyID", idStr, "milestoneIdx", idxStr, "approveBuilder", "true").SetSend(stakeStr).URL()
			voteReject := txlink.NewLink("StakeAndVoteDispute").AddArgs("bountyID", idStr, "milestoneIdx", idxStr, "approveBuilder", "false").SetSend(stakeStr).URL()
			actCell = "[Stake & Vote Builder](" + voteApprove + ") · [Stake & Vote Sponsor](" + voteReject + ")"
		}
		mtbl.Append([]string{
			idxStr,
			safeCell(m.title),
			tavernkit.FormatBpsPercent(m.weightBps),
			"**" + tavernkit.FormatGNOT(m.payoutUgnot) + "**",
			"`" + m.status.String() + "`",
			proofCell,
			actCell,
		})
	}
	sb.WriteString(mtbl.String() + "\n")

	// Render delivery notes, sponsor feedback, and active/resolved disputes.
	for _, m := range b.milestones {
		if m.deliveryNotes != "" || m.sponsorFeedback != "" || m.dispute != nil {
			sb.WriteString(ufmt.Sprintf("### Milestone #%d — %s\n\n", m.index, sanitize.InlineText(m.title)))
			if m.deliveryNotes != "" {
				sb.WriteString("**Delivery Notes:**\n" + sanitize.Block(m.deliveryNotes) + "\n\n")
			}
			if m.sponsorFeedback != "" {
				sb.WriteString("**Sponsor Feedback:**\n" + sanitize.Blockquote(m.sponsorFeedback) + "\n\n")
			}
			if m.dispute != nil {
				renderDisputeSection(&sb, b, m)
			}
		}
	}

	res.Write(sb.String())
}

func renderDisputeSection(sb *strings.Builder, b *bounty, m *milestone) {
	d := m.dispute
	statusMsg := ufmt.Sprintf("Quorum progress: %d approve / %d reject (quorum: %d, stake pool: %s)",
		d.approveCount, d.rejectCount, b.reviewerQuorum, tavernkit.FormatGNOT(d.stakePoolUgnot))
	if d.resolved {
		winner := "Sponsor (Refunded)"
		if d.builderWon {
			winner = "Builder (Paid)"
		}
		sb.WriteString(mdalert.Success("Dispute Resolved — "+winner, statusMsg) + "\n")
	} else {
		sb.WriteString(mdalert.Warning("Active Stake-Backed Reviewer Quorum", statusMsg) + "\n")
	}
	if d.reason != "" {
		sb.WriteString("**Dispute Reason** (opened by " + builderLink(d.openedBy) + "):\n" + sanitize.Blockquote(d.reason) + "\n\n")
	}
	if len(d.votes) > 0 {
		vtbl := mdtable.Table{
			Headers: []string{"Reviewer", "Vote", "Stake", "Rationale"},
		}
		for _, v := range d.votes {
			voteLabel := "Reject (Sponsor)"
			if v.approveBuilder {
				voteLabel = "Approve (Builder)"
			}
			rat := "_(archived)_"
			if v.rationale != "" {
				rat = safeCell(v.rationale)
			}
			vtbl.Append([]string{
				builderLink(v.reviewer),
				voteLabel,
				tavernkit.FormatGNOT(v.stakeUgnot),
				rat,
			})
		}
		sb.WriteString(vtbl.String() + "\n")
	}
}

type rankedEntry struct {
	profile *builderProfile
	score   tavernkit.ReputationScore
}

type rankedList []rankedEntry

func (r rankedList) Len() int { return len(r) }

func (r rankedList) Less(i, j int) bool {
	if r[i].score.XP != r[j].score.XP {
		return r[i].score.XP > r[j].score.XP
	}
	return r[i].profile.addr < r[j].profile.addr
}

func (r rankedList) Swap(i, j int) {
	r[i], r[j] = r[j], r[i]
}

func renderGuildHall(res *mux.ResponseWriter, _ *mux.Request) {
	var sb strings.Builder
	sb.WriteString("# TavernBoard — Guild Hall & Reputation Leaderboard\n\n")
	sb.WriteString(navBar("guild") + "\n\n")
	sb.WriteString("Reputation XP, Craft Tiers, and Reliability are computed deterministically on-chain from settled deliveries and aligned quorum reviews — never self-reported.\n\n")

	if profiles.Size() == 0 {
		sb.WriteString(mdalert.Info("Guild Hall Is Quiet", "No builders or sponsors have recorded activity yet.") + "\n")
		res.Write(sb.String())
		return
	}

	entries := make(rankedList, 0, profiles.Size())
	profiles.Iterate("", "", func(_ string, val any) bool {
		p := val.(*builderProfile)
		sc := tavernkit.ComputeReputation(profileToReputationInput(p))
		entries = append(entries, rankedEntry{profile: p, score: sc})
		return false
	})

	sort.Sort(entries)

	tbl := mdtable.Table{
		Headers: []string{"Rank", "Member", "Craft Tier", "XP", "Quests Done", "Earned", "Aligned Reviews", "Reliability"},
	}
	limit := len(entries)
	if limit > 30 {
		limit = 30
	}
	for i := 0; i < limit; i++ {
		e := entries[i]
		tbl.Append([]string{
			"#" + strconv.Itoa(i+1),
			builderLink(e.profile.addr),
			"**" + e.score.Tier.String() + "**",
			strconv.FormatInt(e.score.XP, 10),
			strconv.FormatInt(e.profile.completedBounties, 10),
			tavernkit.FormatGNOT(e.profile.totalEarnedUgnot),
			strconv.FormatInt(e.profile.reviewsAligned, 10),
			tavernkit.FormatBpsPercent(e.score.ReliabilityBps),
		})
	}
	sb.WriteString(tbl.String() + "\n")
	res.Write(sb.String())
}

func renderBuilderProfile(res *mux.ResponseWriter, req *mux.Request) {
	rawAddr := strings.TrimSpace(req.GetVar("addr"))
	addr := address(rawAddr)
	if !addr.IsValid() {
		renderNotFound(res, req)
		return
	}

	snap := GetProfile(addr)
	displayName := resolveDisplayName(addr)

	var sb strings.Builder
	sb.WriteString("# Guild Member: " + sanitize.InlineText(displayName) + "\n\n")
	sb.WriteString(navBar("guild") + "\n\n")

	// Render pure on-chain SVG Guild Crest card!
	sb.WriteString(tavernkit.RenderGuildCrestSVG(
		displayName,
		snap.Score,
		snap.CompletedBounties,
		snap.TotalEarnedUgnot,
	) + "\n\n")

	tbl := mdtable.Table{
		Headers: []string{"Metric", "Value"},
	}
	tbl.Append([]string{"Address", "`" + sanitize.InlineText(addr.String()) + "`"})
	tbl.Append([]string{"Craft Tier", "**" + snap.Score.Tier.String() + "** (" + strconv.FormatInt(snap.Score.XP, 10) + " XP)"})
	tbl.Append([]string{"Reliability", tavernkit.FormatBpsPercent(snap.Score.ReliabilityBps)})
	tbl.Append([]string{"Completed Quests", strconv.FormatInt(snap.CompletedBounties, 10)})
	tbl.Append([]string{"Approved Milestones", strconv.FormatInt(snap.ApprovedMilestones, 10)})
	tbl.Append([]string{"Total Earned", "**" + tavernkit.FormatGNOT(snap.TotalEarnedUgnot) + "**"})
	tbl.Append([]string{"Quorum Reviews (Aligned / Slashed)", strconv.FormatInt(snap.ReviewsAligned, 10) + " / " + strconv.FormatInt(snap.ReviewsSlashed, 10)})
	tbl.Append([]string{"Disputes (Won / Lost)", strconv.FormatInt(snap.DisputesWon, 10) + " / " + strconv.FormatInt(snap.DisputesLost, 10)})
	tbl.Append([]string{"Quests Posted / Claimed", strconv.FormatInt(snap.BountiesPosted, 10) + " / " + strconv.FormatInt(snap.BountiesClaimed, 10)})
	sb.WriteString(tbl.String() + "\n")

	// Show quests involving this address.
	base := realmRoutePrefix()
	qtbl := mdtable.Table{
		Headers: []string{"ID", "Role", "Quest", "Status", "Reward"},
	}
	found := 0
	bounties.ReverseIterate("", "", func(_ string, val any) bool {
		b := val.(*bounty)
		role := ""
		if b.sponsor == addr {
			role = "Sponsor"
		} else if b.builder == addr {
			role = "Builder"
		}
		if role != "" {
			idStr := strconv.FormatUint(b.id, 10)
			qtbl.Append([]string{
				"#" + idStr,
				role,
				"[" + safeCell(b.title) + "](" + base + ":bounty/" + idStr + ")",
				"`" + b.status.String() + "`",
				tavernkit.FormatGNOT(b.totalFundedUgnot),
			})
			found++
			if found >= 15 {
				return true
			}
		}
		return false
	})
	if found > 0 {
		sb.WriteString("## Quest History\n\n" + qtbl.String() + "\n")
	}

	res.Write(sb.String())
}

func renderGuide(res *mux.ResponseWriter, _ *mux.Request) {
	var sb strings.Builder
	sb.WriteString("# TavernBoard — Sub-Realm Escrow & Quorum Architecture\n\n")
	sb.WriteString(navBar("guide") + "\n\n")

	sb.WriteString("## 1. Isolated Sub-Realm Escrow Vaults (`cur.Sub`)\n\n")
	sb.WriteString("Every quest mints two dedicated Gno.land v1.8 sub-realm addresses:\n\n")
	sb.WriteString("- **`cur.Sub(\"escrow/<id>\")`** — holds that quest's locked `ugnot` reward pool.\n")
	sb.WriteString("- **`cur.Sub(\"stake/<id>\")`** — holds reviewer stakes during an active milestone dispute.\n\n")
	sb.WriteString("Payouts execute through `banker.NewBanker(banker.BankerTypeRealmSend, cur.Sub(\"escrow/<id>\"))`, so the GnoVM banker itself guarantees Quest #1 can never spend a single `ugnot` belonging to Quest #2.\n\n")

	sb.WriteString("## 2. Composable DAO & Cross-Realm Co-Funding\n\n")
	sb.WriteString("Any external DAO realm or user can compute `tavernboard.DeriveEscrowAddress(id)` (via `chain.DerivePkgSubAddr`), transfer `ugnot` directly to that sub-address, and call `SyncBountyVault(cross(cur), id)` to co-fund remaining milestones proportionally.\n\n")

	sb.WriteString("## 3. Stake-Backed Reviewer Quorum\n\n")
	sb.WriteString("- Independent reviewers (neither sponsor nor builder) stake `>= minReviewerStakeUgnot` into `stake/<id>`.\n")
	sb.WriteString("- Once strict majority quorum is met, settlement executes atomically: the milestone pays out or refunds, aligned reviewers reclaim 100% of their stake plus an equal share of the 50% slashed dissenting stakes, and reputation updates on-chain.\n\n")

	sb.WriteString("## 4. Storage-Deposit Hygiene\n\n")
	sb.WriteString("Once a quest closes and its vaults drain to `0 ugnot`, anyone can call `ArchiveClosedBounty(cross(cur), id)` to prune heavy prose strings into a compact tombstone and reclaim Gno.land storage deposits.\n")

	res.Write(sb.String())
}

func renderNotFound(res *mux.ResponseWriter, req *mux.Request) {
	var sb strings.Builder
	sb.WriteString("# TavernBoard — Route Not Found\n\n")
	sb.WriteString(navBar("") + "\n\n")
	sb.WriteString(mdalert.Caution(
		"Unknown Route",
		"No TavernBoard view matched `"+sanitize.InlineText(req.Path)+"`. Return to the [Quest Board]("+realmRoutePrefix()+").",
	))
	res.Write(sb.String())
}
