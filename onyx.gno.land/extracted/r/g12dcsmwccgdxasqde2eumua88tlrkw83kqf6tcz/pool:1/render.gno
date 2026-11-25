package pool

import (
	"strconv"
	"strings"
	"time"

	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
	"gno.land/p/nt/ufmt/v0"
)

var stateNames = []string{"Open", "Proposed", "Disputed", "Resolved"}

func outcomeName(m *Market, o int) string {
	switch o {
	case SideA:
		return mimir.Escape(m.LabelA)
	case SideB:
		return mimir.Escape(m.LabelB)
	case Draw:
		return "Draw (refund)"
	case Unresolvable:
		return "Unresolvable (refund)"
	}
	return "-"
}

func pct(a, b int64) int64 {
	if a+b == 0 {
		return 50
	}
	return mimir.MulDiv(a, 100, a+b)
}

func when(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04 UTC")
}

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil || id < 1 || id > marketCount {
		return "# Not found\n\n[All markets](:)\n"
	}
	return renderMarket(getMarket(id))
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Mimir pools\n\n")
	b.WriteString("Claim markets that settle themselves. Stake mUSD on either side of a question; ")
	b.WriteString("an AI oracle proposes the result after the deadline, anyone in the market can dispute it, ")
	b.WriteString("and draws or unclear questions refund everyone.\n\n")
	b.WriteString(ufmt.Sprintf("%d markets · minimum stake %s mUSD · dispute bond %s mUSD · dispute window %d min\n\n",
		marketCount, mimir.FormatUSD(MinStake), mimir.FormatUSD(DisputeBond), disputeWindow/60))
	if marketCount == 0 {
		b.WriteString("No markets yet.\n")
		return b.String()
	}
	b.WriteString("| # | Question | Sides | Pool (mUSD) | State | Closes |\n|---|---|---|---|---|---|\n")
	markets.ReverseIterateByOffset(0, 50, func(_ string, v any) bool {
		m := v.(*Market)
		b.WriteString(ufmt.Sprintf("| [%d](:%d) | %s | %s %d%% · %s %d%% | %s | %s | %s |\n",
			m.ID, m.ID, mimir.Escape(m.Question),
			mimir.Escape(m.LabelA), pct(m.TotalA, m.TotalB), mimir.Escape(m.LabelB), pct(m.TotalB, m.TotalA),
			mimir.FormatUSD(m.TotalA+m.TotalB), stateNames[m.State], when(m.Deadline)))
		return false
	})
	return b.String()
}

func renderMarket(m *Market) string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# %s\n\n", mimir.Escape(m.Question)))
	b.WriteString(ufmt.Sprintf("Market #%d · %s · %s\n\n", m.ID, mimir.Escape(m.Category), stateNames[m.State]))
	b.WriteString(ufmt.Sprintf("| Side | Pool (mUSD) | Implied |\n|---|---|---|\n| A: %s | %s | %d%% |\n| B: %s | %s | %d%% |\n\n",
		mimir.Escape(m.LabelA), mimir.FormatUSD(m.TotalA), pct(m.TotalA, m.TotalB),
		mimir.Escape(m.LabelB), mimir.FormatUSD(m.TotalB), pct(m.TotalB, m.TotalA)))
	b.WriteString(ufmt.Sprintf("- Closes: %s\n- Source: %s\n- Creator: %s\n- Participants: %d\n",
		when(m.Deadline), mimir.Escape(m.ResolutionURL), m.Creator.String(), m.positions.Size()))
	if m.LockAt != 0 {
		b.WriteString(ufmt.Sprintf("- Staking locks early: %s\n", when(m.LockAt)))
	}
	switch m.State {
	case StProposed:
		b.WriteString(ufmt.Sprintf("\n## Proposed: %s\n\nDisputable until %s.\n\n> %s\n\nEvidence: %s\n",
			outcomeName(m, m.Proposed), when(m.ProposedAt+disputeWindow), mimir.Escape(m.Summary), hashOrNone(m.EvidenceHash)))
	case StDisputed:
		b.WriteString(ufmt.Sprintf("\n## Disputed\n\nThe oracle proposed %s; the arbiter rules.\n\n> %s\n",
			outcomeName(m, m.Proposed), mimir.Escape(m.Summary)))
	case StResolved:
		b.WriteString(ufmt.Sprintf("\n## Result: %s\n\n> %s\n\nEvidence: %s\n",
			outcomeName(m, m.Outcome), mimir.Escape(m.Summary), hashOrNone(m.EvidenceHash)))
	}
	b.WriteString("\n## Act\n\n")
	b.WriteString("Approve this realm on mUSD first, then call:\n\n")
	b.WriteString(ufmt.Sprintf("- [Stake](%s) · [Claim](%s) · [Finalize](%s) · [Dispute](%s)\n\n[All markets](:)\n",
		helpLink("Stake", m.ID), helpLink("Claim", m.ID), helpLink("Finalize", m.ID), helpLink("Dispute", m.ID)))
	return b.String()
}

func helpLink(fn string, id int64) string {
	return ufmt.Sprintf("$help&func=%s&id=%d", fn, id)
}

func hashOrNone(h string) string {
	if h == "" {
		return "none"
	}
	return "`" + h + "`"
}
