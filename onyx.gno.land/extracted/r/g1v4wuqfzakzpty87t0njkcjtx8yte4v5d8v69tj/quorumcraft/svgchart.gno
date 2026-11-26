package quorumcraft

import (
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/svg/v0"
	"gno.land/p/nt/ufmt/v0"
)

func truncLabel(s string, maxLen int) string {
	s = sanitize.HTMLEscape(s)
	if len(s) <= maxLen {
		return s
	}
	if maxLen <= 3 {
		return s[:maxLen]
	}
	return s[:maxLen-3] + "..."
}

func formatGnot(ugnot int64) string {
	neg := ""
	if ugnot < 0 {
		neg = "-"
		ugnot = -ugnot
	}
	whole := ugnot / 1_000_000
	frac := (ugnot % 1_000_000) / 10_000 // 2 decimal places
	return ufmt.Sprintf("%s%d.%02d GNOT", neg, whole, frac)
}

// buildRoundChartCanvas generates a native on-chain SVG horizontal bar chart
// comparing Direct Community Donations vs Pairwise-QF Matched Grants per proposal.
func buildRoundChartCanvas(r *Round, matched []int64) *svg.Canvas {
	const (
		width    = 760
		rowH     = 54
		headerH  = 64
		footerH  = 34
		labelX   = 20
		barX     = 220
		maxBarW  = 390
		valueX   = 622
	)
	n := len(r.Proposals)
	if n == 0 {
		c := svg.NewCanvas(width, 110).WithViewBox(0, 0, width, 110)
		c.Append(
			&svg.Rectangle{X: 0, Y: 0, Width: width, Height: 110, RX: 10, RY: 10, Fill: "#0B0D11"},
			&svg.Text{X: 24, Y: 62, Text: "No proposals submitted yet in this round.", Fill: "#94A3B8", Attr: svg.BaseAttrs{Style: "font-family:monospace;font-size:13px"}},
		)
		return c
	}

	// Determine max combined bar value for linear scaling.
	var maxVal int64 = 1
	for i, p := range r.Proposals {
		m := int64(0)
		if i < len(matched) {
			m = matched[i]
		}
		if p.DirectTotal+m > maxVal {
			maxVal = p.DirectTotal + m
		}
	}

	height := headerH + n*rowH + footerH
	c := svg.NewCanvas(width, height).WithViewBox(0, 0, width, height)

	// Dark slate obsidian background + subtle frame border
	c.Append(&svg.Rectangle{
		X: 0, Y: 0, Width: width, Height: height, RX: 12, RY: 12, Fill: "#0B0D11",
		Attr: svg.BaseAttrs{Stroke: "#222938", StrokeWidth: "1"},
	})

	// Title + Legend
	modeLabel := r.Mode.String()
	c.Append(&svg.Text{
		X: 20, Y: 28,
		Text: ufmt.Sprintf("Round #%d — Direct vs %s Matched Grants", r.ID, modeLabel),
		Fill: "#F8FAFC",
		Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:14px;font-weight:700"},
	})
	// Legend swatches
	c.Append(
		&svg.Rectangle{X: 20, Y: 40, Width: 10, Height: 10, RX: 2, RY: 2, Fill: "#38BDF8"},
		&svg.Text{X: 36, Y: 49, Text: "Direct Donations", Fill: "#94A3B8", Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:11px"}},
		&svg.Rectangle{X: 155, Y: 40, Width: 10, Height: 10, RX: 2, RY: 2, Fill: "#10B981"},
		&svg.Text{X: 171, Y: 49, Text: modeLabel + " Matched Grant", Fill: "#94A3B8", Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:11px"}},
	)

	for i, p := range r.Proposals {
		y := headerH + i*rowH
		m := int64(0)
		if i < len(matched) {
			m = matched[i]
		}
		total := p.DirectTotal + m

		// Alternating subtle row card
		rowBg := "#131720"
		if i%2 == 1 {
			rowBg = "#10141C"
		}
		c.Append(&svg.Rectangle{X: 12, Y: y, Width: width - 24, Height: rowH - 8, RX: 6, RY: 6, Fill: rowBg})

		// Proposal label
		c.Append(&svg.Text{
			X: labelX, Y: y + 20,
			Text: ufmt.Sprintf("#%d %s", p.ID, truncLabel(p.Title, 22)),
			Fill: "#E2E8F0",
			Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:12px;font-weight:600"},
		})
		c.Append(&svg.Text{
			X: labelX, Y: y + 36,
			Text: ufmt.Sprintf("%d donors", p.DonorContribs.Size()),
			Fill: "#64748B",
			Attr: svg.BaseAttrs{Style: "font-family:monospace;font-size:10px"},
		})

		// Track background
		c.Append(&svg.Rectangle{X: barX, Y: y + 12, Width: maxBarW, Height: 20, RX: 4, RY: 4, Fill: "#1E2534"})

		// Direct segment + Matched segment
		directW := int((p.DirectTotal * int64(maxBarW)) / maxVal)
		matchW := int((m * int64(maxBarW)) / maxVal)
		if p.DirectTotal > 0 && directW < 4 {
			directW = 4
		}
		if m > 0 && matchW < 4 {
			matchW = 4
		}
		if directW+matchW > maxBarW {
			matchW = maxBarW - directW
			if matchW < 0 {
				matchW = 0
			}
		}

		if directW > 0 {
			c.Append(&svg.Rectangle{X: barX, Y: y + 12, Width: directW, Height: 20, RX: 3, RY: 3, Fill: "#38BDF8"})
		}
		if matchW > 0 {
			c.Append(&svg.Rectangle{X: barX + directW, Y: y + 12, Width: matchW, Height: 20, RX: 3, RY: 3, Fill: "#10B981"})
		}

		// Right-side total figure
		c.Append(&svg.Text{
			X: valueX, Y: y + 20,
			Text: formatGnot(total),
			Fill: "#F8FAFC",
			Attr: svg.BaseAttrs{Style: "font-family:monospace;font-size:12px;font-weight:700"},
		})
		c.Append(&svg.Text{
			X: valueX, Y: y + 36,
			Text: ufmt.Sprintf("+%s QF", formatGnot(m)),
			Fill: "#10B981",
			Attr: svg.BaseAttrs{Style: "font-family:monospace;font-size:10px"},
		})
	}

	c.Append(&svg.Text{
		X: 20, Y: height - 12,
		Text: "Deterministic on-chain SVG rendered by QuorumCraft (gno.land/p/nt/svg/v0 + p/qfmath)",
		Fill: "#64748B",
		Attr: svg.BaseAttrs{Style: "font-family:monospace;font-size:10px"},
	})
	return c
}

// buildEscrowBarCanvas generates an on-chain SVG Milestone Escrow Progress Bar
// showing each tranche's weight and live status (Released / Submitted / Disputed / Pending).
func buildEscrowBarCanvas(r *Round, p *Proposal) *svg.Canvas {
	const (
		width  = 760
		height = 132
		barX   = 20
		barY   = 52
		barW   = 720
		barH   = 28
	)
	c := svg.NewCanvas(width, height).WithViewBox(0, 0, width, height)
	c.Append(&svg.Rectangle{
		X: 0, Y: 0, Width: width, Height: height, RX: 12, RY: 12, Fill: "#0B0D11",
		Attr: svg.BaseAttrs{Stroke: "#222938", StrokeWidth: "1"},
	})

	c.Append(&svg.Text{
		X: 20, Y: 28,
		Text: ufmt.Sprintf("Milestone Escrow — %s (%s Total)", truncLabel(p.Title, 38), formatGnot(p.TotalGrant())),
		Fill: "#F8FAFC",
		Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:14px;font-weight:700"},
	})

	// Track
	c.Append(&svg.Rectangle{X: barX, Y: barY, Width: barW, Height: barH, RX: 6, RY: 6, Fill: "#1E2534"})

	curX := barX
	for i, m := range p.Milestones {
		segW := int((m.Bps * int64(barW)) / bpsFull)
		if i == len(p.Milestones)-1 {
			segW = (barX + barW) - curX
		}
		if segW < 2 {
			segW = 2
		}

		fill := "#334155" // PENDING
		switch m.Status {
		case MilestoneReleased:
			fill = "#10B981" // Emerald
		case MilestoneSubmitted:
			fill = "#F59E0B" // Amber awaiting quorum
		case MilestoneDisputed:
			fill = "#EF4444" // Crimson
		case MilestoneRefunded:
			fill = "#6366F1" // Indigo refunded
		}

		// Leave 2px crisp gap between tranches
		drawW := segW
		if i < len(p.Milestones)-1 && drawW > 4 {
			drawW -= 2
		}
		c.Append(&svg.Rectangle{
			X: curX, Y: barY, Width: drawW, Height: barH, RX: 4, RY: 4, Fill: fill,
		})

		pct := m.Bps / 100
		label := ufmt.Sprintf("M%d (%d%%)", i+1, pct)
		if drawW >= 68 {
			c.Append(&svg.Text{
				X: curX + 8, Y: barY + 18,
				Text: label,
				Fill: "#FFFFFF",
				Attr: svg.BaseAttrs{Style: "font-family:monospace;font-size:11px;font-weight:700"},
			})
		}
		curX += segW
	}

	// Status legend row
	c.Append(
		&svg.Rectangle{X: 20, Y: 96, Width: 10, Height: 10, RX: 2, RY: 2, Fill: "#10B981"},
		&svg.Text{X: 36, Y: 105, Text: "Released", Fill: "#94A3B8", Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:11px"}},
		&svg.Rectangle{X: 112, Y: 96, Width: 10, Height: 10, RX: 2, RY: 2, Fill: "#F59E0B"},
		&svg.Text{X: 128, Y: 105, Text: "Proof Submitted / Quorum", Fill: "#94A3B8", Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:11px"}},
		&svg.Rectangle{X: 288, Y: 96, Width: 10, Height: 10, RX: 2, RY: 2, Fill: "#334155"},
		&svg.Text{X: 304, Y: 105, Text: "Pending", Fill: "#94A3B8", Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:11px"}},
		&svg.Rectangle{X: 374, Y: 96, Width: 10, Height: 10, RX: 2, RY: 2, Fill: "#EF4444"},
		&svg.Text{X: 390, Y: 105, Text: "Disputed", Fill: "#94A3B8", Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:11px"}},
		&svg.Rectangle{X: 464, Y: 96, Width: 10, Height: 10, RX: 2, RY: 2, Fill: "#6366F1"},
		&svg.Text{X: 480, Y: 105, Text: "Refunded", Fill: "#94A3B8", Attr: svg.BaseAttrs{Style: "font-family:sans-serif;font-size:11px"}},
		&svg.Text{
			X: 570, Y: 105,
			Text: ufmt.Sprintf("Quorum: %d.%02d%%", r.QuorumBps/100, r.QuorumBps%100),
			Fill: "#38BDF8",
			Attr: svg.BaseAttrs{Style: "font-family:monospace;font-size:11px;font-weight:700"},
		},
	)
	return c
}

// RenderRoundChartSVG returns the raw <svg> markup for a round's QF bar chart.
func RenderRoundChartSVG(roundID int) string {
	r := mustGetRound(roundID)
	stdAlloc, pwAlloc := PreviewRoundMatching(roundID)
	matched := stdAlloc
	if r.Mode == ModePairwiseQF {
		matched = pwAlloc
	}
	if r.Status == RoundFinalized {
		matched = make([]int64, len(r.Proposals))
		for i, p := range r.Proposals {
			matched[i] = p.MatchedGrant
		}
	}
	return buildRoundChartCanvas(r, matched).String()
}

// RenderEscrowSVG returns the raw <svg> markup for a proposal's milestone escrow progress bar.
func RenderEscrowSVG(roundID, proposalID int) string {
	r := mustGetRound(roundID)
	p := mustGetProposal(r, proposalID)
	return buildEscrowBarCanvas(r, p).String()
}
