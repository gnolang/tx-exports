package vs

import (
	"strconv"
	"strings"
	"time"

	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
	"gno.land/p/nt/ufmt/v0"
)

var stateNames = []string{"Open", "Active", "Resolved", "Cancelled", "Proposed", "Disputed"}

func sideName(c *Claim, s int) string {
	switch s {
	case SideCreator:
		return "Creator: " + mimir.Escape(c.CreatorPosition)
	case SideChallengers:
		return "Challengers: " + mimir.Escape(c.CounterPosition)
	case SideDraw:
		return "Draw (refund)"
	case SideUnresolvable:
		return "Unresolvable (refund)"
	}
	return "-"
}

func when(unix int64) string { return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04 UTC") }

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil || id < 1 || id > claimCount {
		return "# Not found\n\n[All duels](:)\n"
	}
	return renderClaim(getClaim(id))
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Mimir VS\n\n")
	b.WriteString("Personal duels. A creator stakes mUSD on a position; challengers take the other side. ")
	b.WriteString("An AI oracle proposes the result after the deadline and pays everyone in one transaction.\n\n")
	b.WriteString(ufmt.Sprintf("%d duels · %d resolved · minimum stake %s mUSD · dispute bond %s mUSD\n\n",
		claimCount, totalResolved, mimir.FormatUSD(MinStake), mimir.FormatUSD(DisputeBond)))
	if claimCount == 0 {
		b.WriteString("No duels yet.\n")
		return b.String()
	}
	b.WriteString("| # | Question | Creator stake | Challengers | Odds | State | Closes |\n|---|---|---|---|---|---|---|\n")
	claims.ReverseIterateByOffset(0, 50, func(_ string, v any) bool {
		c := v.(*Claim)
		b.WriteString(ufmt.Sprintf("| [%d](:%d) | %s | %s | %d · %s | %s | %s | %s |\n",
			c.ID, c.ID, mimir.Escape(c.Question), mimir.FormatUSD(c.CreatorStake),
			len(c.challengers), mimir.FormatUSD(c.TotalChallengerStake), c.OddsMode,
			stateNames[c.State], when(c.Deadline)))
		return false
	})
	return b.String()
}

func renderClaim(c *Claim) string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# %s\n\n", mimir.Escape(c.Question)))
	b.WriteString(ufmt.Sprintf("Duel #%d · %s · %s · %s odds", c.ID, mimir.Escape(c.Category), stateNames[c.State], c.OddsMode))
	if c.OddsMode == "fixed" {
		b.WriteString(ufmt.Sprintf(" (pays %s)", bpsX(c.ChallengerPayoutBps)))
	}
	if c.IsPrivate {
		b.WriteString(" · private")
	}
	b.WriteString("\n\n")
	b.WriteString(ufmt.Sprintf("| Side | Position | Stake (mUSD) |\n|---|---|---|\n| Creator | %s | %s |\n| Challengers (%d/%d) | %s | %s |\n\n",
		mimir.Escape(c.CreatorPosition), mimir.FormatUSD(c.CreatorStake),
		len(c.challengers), c.MaxChallengers, mimir.Escape(c.CounterPosition), mimir.FormatUSD(c.TotalChallengerStake)))
	b.WriteString(ufmt.Sprintf("- Closes: %s\n- Source: %s\n- Creator: %s\n",
		when(c.Deadline), mimir.Escape(c.ResolutionURL), c.Creator.String()))
	if c.SettlementRule != "" {
		b.WriteString("- Rule: " + mimir.Escape(c.SettlementRule) + "\n")
	}
	p := c.Proposal
	switch c.State {
	case StProposed:
		b.WriteString(ufmt.Sprintf("\n## Proposed: %s (%d%% confidence)\n\nDisputable until %s.\n\n> %s\n\nEvidence: %s\n",
			sideName(c, p.WinnerSide), p.Confidence, when(p.ProposedAt+disputeWindow), mimir.Escape(p.Summary), hashOrNone(p.EvidenceHash)))
	case StDisputed:
		b.WriteString(ufmt.Sprintf("\n## Disputed\n\nThe oracle proposed %s; the arbiter rules.\n", sideName(c, p.WinnerSide)))
	case StResolved:
		b.WriteString(ufmt.Sprintf("\n## Result: %s (%d%% confidence)\n\n> %s\n\nEvidence: %s\n",
			sideName(c, c.WinnerSide), c.Confidence, mimir.Escape(c.ResolutionSummary), hashOrNone(c.EvidenceHash)))
	}
	b.WriteString(ufmt.Sprintf("\n## Act\n\nApprove this realm on mUSD first, then: [Challenge]($help&func=ChallengeClaim&claimID=%d) · [Finalize]($help&func=FinalizeResolution&claimID=%d) · [Dispute]($help&func=DisputeResolution&claimID=%d)\n\n[All duels](:)\n",
		c.ID, c.ID, c.ID))
	return b.String()
}

func bpsX(bps int64) string {
	cents := (bps % 10_000) / 100
	pad := ""
	if cents < 10 {
		pad = "0"
	}
	return ufmt.Sprintf("%d.%s%dx", bps/10_000, pad, cents)
}

func hashOrNone(h string) string {
	if h == "" {
		return "none"
	}
	return "`" + h + "`"
}
