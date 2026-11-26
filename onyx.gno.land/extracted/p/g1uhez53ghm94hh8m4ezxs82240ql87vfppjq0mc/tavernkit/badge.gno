package tavernkit

import (
	"strconv"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/svg/v0"
)

// RenderGuildCrestSVG renders a pure on-chain SVG Guild Crest card for a builder
// or reviewer as a Markdown-embedded base64 data URI suitable for gnoweb.
//
// All user-supplied text is XML/HTML-escaped via p/nt/markdown/sanitize/v0
// before entering SVG <text> nodes.
func RenderGuildCrestSVG(handle string, score ReputationScore, completedBounties int64, earnedUgnot int64) string {
	safeHandle := sanitize.HTMLEscape(truncateString(handle, 26))
	if safeHandle == "" {
		safeHandle = "Anonymous Builder"
	}

	accent := score.Tier.AccentHex()
	tierLabel := score.Tier.String()
	xpLabel := strconv.FormatInt(score.XP, 10) + " XP"
	relLabel := FormatBpsPercent(score.ReliabilityBps) + " reliability"
	statsLabel := strconv.FormatInt(completedBounties, 10) + " quests  |  " + FormatGNOT(earnedUgnot)

	canvas := svg.NewCanvas(420, 128).WithViewBox(0, 0, 420, 128)
	canvas.AddStyle("text", "font-family:ui-monospace,SFMono-Regular,Menlo,monospace")

	// Card background & subtle inner border.
	bg := svg.NewRectangle(2, 2, 416, 124, "#111622")
	bg.RX, bg.RY = 14, 14
	bg.Attr.Stroke = accent
	bg.Attr.StrokeWidth = "2"
	canvas.Append(bg)

	// Left decorative shield emblem.
	shieldBg := svg.NewPolygon("48,22 78,34 74,74 48,96 22,74 18,34", "#1b2436")
	shieldBg.Attr.Stroke = accent
	shieldBg.Attr.StrokeWidth = "2.5"
	canvas.Append(shieldBg)

	shieldCore := svg.NewPolygon("48,34 66,42 63,68 48,82 33,68 30,42", accent)
	shieldCore.Attr.Opacity = "0.22"
	canvas.Append(shieldCore)

	// Tier glyph inside shield.
	tierLetter := tierLabel[:1]
	glyph := svg.NewText(42, 65, tierLetter, accent)
	glyph.Attr.Style = "font-size:24px;font-weight:700"
	canvas.Append(glyph)

	// Top eyebrow: TavernBoard Guild Crest + tier pill.
	eyebrow := svg.NewText(96, 30, "TAVERNBOARD GUILD CREST", "#94a3b8")
	eyebrow.Attr.Style = "font-size:10px;letter-spacing:1.2px"
	canvas.Append(eyebrow)

	pill := svg.NewRectangle(302, 16, 100, 20, accent)
	pill.RX, pill.RY = 10, 10
	pill.Attr.Opacity = "0.2"
	canvas.Append(pill)

	pillTxt := svg.NewText(314, 30, tierLabel, accent)
	pillTxt.Attr.Style = "font-size:11px;font-weight:700"
	canvas.Append(pillTxt)

	// Builder handle.
	nameTxt := svg.NewText(96, 56, safeHandle, "#f8fafc")
	nameTxt.Attr.Style = "font-size:16px;font-weight:700"
	canvas.Append(nameTxt)

	// Stats line.
	statsTxt := svg.NewText(96, 76, statsLabel+"  |  "+relLabel, "#cbd5e1")
	statsTxt.Attr.Style = "font-size:11px"
	canvas.Append(statsTxt)

	// XP progress bar track & fill.
	barTrack := svg.NewRectangle(96, 92, 304, 10, "#1e293b")
	barTrack.RX, barTrack.RY = 5, 5
	canvas.Append(barTrack)

	fillW := int((304 * score.ProgressBps) / BasisPointsTotal)
	if fillW < 10 && score.XP > 0 {
		fillW = 10
	}
	if fillW > 304 {
		fillW = 304
	}
	if fillW > 0 {
		barFill := svg.NewRectangle(96, 92, fillW, 10, accent)
		barFill.RX, barFill.RY = 5, 5
		canvas.Append(barFill)
	}

	xpFooter := svg.NewText(96, 116, xpLabel, accent)
	xpFooter.Attr.Style = "font-size:11px;font-weight:700"
	canvas.Append(xpFooter)

	nextLabel := "MAX TIER ACHIEVED"
	if score.NextTierXP > 0 {
		nextLabel = "Next tier: " + strconv.FormatInt(score.NextTierXP, 10) + " XP"
	}
	nextTxt := svg.NewText(246, 116, nextLabel, "#94a3b8")
	nextTxt.Attr.Style = "font-size:10px"
	canvas.Append(nextTxt)

	return canvas.Render("Guild Crest for " + safeHandle)
}

// RenderEscrowCardSVG renders an on-chain SVG Escrow Vault status & milestone
// progress card for a bounty page in gnoweb.
func RenderEscrowCardSVG(bountyID string, status Status, fundedUgnot, releasedUgnot int64, doneMilestones, totalMilestones int) string {
	safeID := sanitize.HTMLEscape(truncateString(bountyID, 20))
	statusColor := status.ColorHex()
	lockedUgnot := fundedUgnot - releasedUgnot
	if lockedUgnot < 0 {
		lockedUgnot = 0
	}

	canvas := svg.NewCanvas(420, 106).WithViewBox(0, 0, 420, 106)
	canvas.AddStyle("text", "font-family:ui-monospace,SFMono-Regular,Menlo,monospace")

	bg := svg.NewRectangle(2, 2, 416, 102, "#0f172a")
	bg.RX, bg.RY = 12, 12
	bg.Attr.Stroke = statusColor
	bg.Attr.StrokeWidth = "2"
	canvas.Append(bg)

	title := svg.NewText(18, 28, "ISOLATED SUB-REALM ESCROW VAULT #"+safeID, "#94a3b8")
	title.Attr.Style = "font-size:10px;letter-spacing:0.8px"
	canvas.Append(title)

	badge := svg.NewRectangle(314, 14, 90, 20, statusColor)
	badge.RX, badge.RY = 10, 10
	badge.Attr.Opacity = "0.22"
	canvas.Append(badge)

	badgeTxt := svg.NewText(324, 28, status.String(), statusColor)
	badgeTxt.Attr.Style = "font-size:10px;font-weight:700"
	canvas.Append(badgeTxt)

	valTxt := svg.NewText(18, 56, "Locked: "+FormatGNOT(lockedUgnot)+"  |  Paid: "+FormatGNOT(releasedUgnot), "#f8fafc")
	valTxt.Attr.Style = "font-size:13px;font-weight:700"
	canvas.Append(valTxt)

	// Segmented milestone progress bar.
	if totalMilestones < 1 {
		totalMilestones = 1
	}
	totalW := 384
	gap := 4
	segW := (totalW - gap*(totalMilestones-1)) / totalMilestones
	if segW < 8 {
		segW = 8
	}
	for i := 0; i < totalMilestones; i++ {
		fill := "#1e293b"
		if i < doneMilestones {
			fill = statusColor
		}
		seg := svg.NewRectangle(18+i*(segW+gap), 70, segW, 12, fill)
		seg.RX, seg.RY = 4, 4
		canvas.Append(seg)
	}

	footer := svg.NewText(18, 96,
		"Milestones settled: "+strconv.Itoa(doneMilestones)+"/"+strconv.Itoa(totalMilestones)+"  |  Total Vault: "+FormatGNOT(fundedUgnot),
		"#cbd5e1",
	)
	footer.Attr.Style = "font-size:10px"
	canvas.Append(footer)

	return canvas.Render("Escrow Vault " + safeID)
}

func truncateString(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen]
}
