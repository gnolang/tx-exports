package oathledger

import (
	"strconv"
	"strings"

	"gno.land/p/g1ty0rp975ndkcse760v0zt659f4phs4z8lueud7/escrowmath"
	"gno.land/p/moul/md/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Render serves deterministic, sanitized, multi-route Markdown for gnoweb:
//   - ""               : Dashboard overview, live telemetry & active pacts table
//   - "pact/<id>"      : Detailed pact view with milestone progress & one-click txlinks
//   - "builder/<addr>" : Immutable Proof-of-Contribution builder resume
//   - "leaderboard"    : Top verified builders ranked by on-chain PoC XP
func Render(path string) string {
	path = strings.Trim(strings.TrimSpace(path), "/")
	if path == "" {
		return renderHome()
	}
	if path == "leaderboard" {
		return renderLeaderboard()
	}
	if strings.HasPrefix(path, "pact/") {
		idStr := strings.TrimPrefix(path, "pact/")
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil {
			return md.H1("Invalid Pact ID") + "Use `/pact/<id>`."
		}
		return renderPactDetail(id)
	}
	if strings.HasPrefix(path, "builder/") {
		addrStr := strings.TrimPrefix(path, "builder/")
		return renderBuilderProfile(addrStr)
	}
	return md.H1("Route Not Found") + "Supported routes: `/`, `/pact/<id>`, `/builder/<addr>`, `/leaderboard`."
}

func renderHome() string {
	var b strings.Builder
	b.WriteString(md.H1("OathLedger — Trustless Milestone Escrow & PoC Board"))
	b.WriteString("> Native Gno.land multi-milestone `ugnot` escrow with M-of-N peer-reviewer quorums, trustless dispute arbitration, and immutable Proof-of-Contribution builder reputation.\n\n")

	b.WriteString(md.H2("Protocol Telemetry"))
	b.WriteString(ufmt.Sprintf("- **Total Pacts**: %d (%d completed, %d disputed)\n", nextPactID-1, completedPactsCount, disputedPactsCount))
	b.WriteString(ufmt.Sprintf("- **Active Escrow Locked**: `%s` (`%d ugnot`)\n", escrowmath.FormatGnot(activeLockedUgnot), activeLockedUgnot))
	b.WriteString(ufmt.Sprintf("- **Total Released to Builders**: `%s`\n", escrowmath.FormatGnot(totalReleasedUgnot)))
	b.WriteString(ufmt.Sprintf("- **Verified Builders**: %d — %s\n\n", builders.Size(), md.Link("View PoC Leaderboard", ":leaderboard")))

	b.WriteString(md.H2("Escrow Pacts"))
	if pacts.Size() == 0 {
		b.WriteString("_No pacts created yet. Use `CreatePact` with `-send <amount>ugnot` to lock your first milestone bounty._\n")
		return b.String()
	}

	b.WriteString("| ID | Title | Progress | Escrow | Quorum | Status |\n")
	b.WriteString("|---|---|---|---|---|---|\n")
	pacts.ReverseIterate("", "", func(_ string, val any) bool {
		p := val.(*Pact)
		idStr := strconv.FormatInt(p.ID, 10)
		link := md.Link("#"+idStr+" "+p.Title, ":pact/"+idStr)
		bar := escrowmath.ProgressBar(p.ReleasedUgnot, p.TotalUgnot, 8)
		b.WriteString(ufmt.Sprintf("| #%s | %s | `%s` | `%s` | %d/%d | **%s** |\n",
			idStr,
			link,
			bar,
			escrowmath.FormatGnot(p.TotalUgnot),
			p.Quorum,
			len(p.Reviewers),
			string(p.Status),
		))
		return false
	})

	b.WriteString("\n" + md.H3("Quick Navigation"))
	b.WriteString("- " + md.Link("Proof-of-Contribution Leaderboard", ":leaderboard") + "\n")
	return b.String()
}

func renderPactDetail(id int64) string {
	v := pacts.Get(padID(id))
	if v == nil {
		return md.H1("Pact Not Found") + md.Link("Back to OathLedger", ":")
	}
	p := v.(*Pact)
	idStr := strconv.FormatInt(p.ID, 10)

	var b strings.Builder
	b.WriteString(md.H1(ufmt.Sprintf("Pact #%d — %s", p.ID, sanitize.InlineText(p.Title))))
	b.WriteString(sanitize.InlineText(p.Summary) + "\n\n")

	b.WriteString(ufmt.Sprintf("- **Status**: `%s`\n", string(p.Status)))
	b.WriteString(ufmt.Sprintf("- **Progress**: `%s` (`%s` / `%s`)\n",
		escrowmath.ProgressBar(p.ReleasedUgnot, p.TotalUgnot, 12),
		escrowmath.FormatGnot(p.ReleasedUgnot),
		escrowmath.FormatGnot(p.TotalUgnot),
	))
	b.WriteString(ufmt.Sprintf("- **Sponsor**: `%s`\n", p.Sponsor.String()))
	if p.Builder != "" {
		b.WriteString(ufmt.Sprintf("- **Builder**: %s\n", md.Link(p.Builder.String(), ":builder/"+p.Builder.String())))
	} else {
		claimURL := txlink.NewLink("ClaimPact").AddArgs("pactID", idStr).URL()
		b.WriteString(ufmt.Sprintf("- **Builder**: _Unclaimed_ — %s\n", md.Link("Claim This Pact", claimURL)))
	}
	b.WriteString(ufmt.Sprintf("- **Reviewer Quorum**: %d of %d reviewers\n", p.Quorum, len(p.Reviewers)))
	b.WriteString(ufmt.Sprintf("- **Deadline**: `%s`\n\n", p.Deadline.UTC().Format("2006-01-02 15:04 UTC")))

	b.WriteString(md.H2("Milestones"))
	b.WriteString("| # | Milestone | Split | Payout | Status | Approvals | Proof / Action |\n")
	b.WriteString("|---|---|---|---|---|---|---|\n")
	for _, m := range p.Milestones {
		idxStr := strconv.Itoa(m.Index)
		action := "-"
		switch m.Status {
		case MilestonePending:
			if p.Status == StatusActive {
				subURL := txlink.NewLink("SubmitMilestone").AddArgs("pactID", idStr, "milestoneIdx", idxStr).URL()
				action = md.Link("Submit Proof", subURL)
			}
		case MilestoneSubmitted:
			appURL := txlink.NewLink("ApproveMilestone").AddArgs("pactID", idStr, "milestoneIdx", idxStr).URL()
			action = ufmt.Sprintf("`%s` · %s", sanitize.InlineText(m.ProofURI), md.Link("Approve", appURL))
		case MilestonePaid:
			action = ufmt.Sprintf("`%s` (Paid)", sanitize.InlineText(m.ProofURI))
		}
		b.WriteString(ufmt.Sprintf("| %d | %s | %d.%02d%% | `%s` | **%s** | %d/%d | %s |\n",
			m.Index+1,
			sanitize.InlineText(m.Title),
			m.SplitBps/100,
			m.SplitBps%100,
			escrowmath.FormatGnot(m.AmountUgnot),
			string(m.Status),
			len(m.Approvals),
			p.Quorum,
			action,
		))
	}

	if p.Status == StatusDisputed {
		b.WriteString("\n" + md.H2("Active Dispute"))
		b.WriteString(ufmt.Sprintf("- **Reason**: %s\n", sanitize.InlineText(p.DisputeReason)))
		b.WriteString(ufmt.Sprintf("- **Resolution Votes Cast**: %d / %d quorum\n", len(p.DisputeVotes), p.Quorum))
	}

	b.WriteString("\n" + md.Link("← Back to All Pacts", ":"))
	return b.String()
}

func renderBuilderProfile(addrStr string) string {
	v := builders.Get(addrStr)
	if v == nil {
		return md.H1("Builder Not Found") + md.Link("Back to Leaderboard", ":leaderboard")
	}
	prof := v.(*BuilderProfile)

	var b strings.Builder
	b.WriteString(md.H1("Builder Proof-of-Contribution Resume"))
	b.WriteString(ufmt.Sprintf("- **Address**: `%s`\n", prof.Address.String()))
	b.WriteString(ufmt.Sprintf("- **PoC Tier**: **%s** (`%d XP`)\n", escrowmath.TierForXP(prof.XP), prof.XP))
	b.WriteString(ufmt.Sprintf("- **Total Verified Earnings**: `%s`\n", escrowmath.FormatGnot(prof.TotalEarnedUgnot)))
	b.WriteString(ufmt.Sprintf("- **Milestones Paid**: %d | **Pacts Completed**: %d | **Disputes**: %d\n\n",
		prof.MilestonesCompleted, prof.PactsCompleted, prof.DisputesCount))
	b.WriteString(md.Link("← Back to Leaderboard", ":leaderboard"))
	return b.String()
}

func renderLeaderboard() string {
	var b strings.Builder
	b.WriteString(md.H1("OathLedger — Proof-of-Contribution Leaderboard"))
	if builders.Size() == 0 {
		b.WriteString("_No builders ranked yet._\n\n" + md.Link("← Back to OathLedger", ":"))
		return b.String()
	}

	b.WriteString("| Builder | Tier | PoC XP | Milestones | Total Earned |\n")
	b.WriteString("|---|---|---|---|---|\n")
	builders.Iterate("", "", func(key string, val any) bool {
		prof := val.(*BuilderProfile)
		b.WriteString(ufmt.Sprintf("| %s | **%s** | `%d` | %d | `%s` |\n",
			md.Link(key, ":builder/"+key),
			escrowmath.TierForXP(prof.XP),
			prof.XP,
			prof.MilestonesCompleted,
			escrowmath.FormatGnot(prof.TotalEarnedUgnot),
		))
		return false
	})
	b.WriteString("\n" + md.Link("← Back to All Pacts", ":"))
	return b.String()
}
