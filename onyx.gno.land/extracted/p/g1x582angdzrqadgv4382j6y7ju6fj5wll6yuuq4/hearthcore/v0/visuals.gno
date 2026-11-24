package hearthcore

import (
	"strconv"
	"strings"

	"gno.land/p/nt/svg/v0"
)

// EscapeXML escapes special XML characters before embedding dynamic text inside
// deterministic on-chain SVG documents.
func EscapeXML(s string) string {
	r := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		`"`, "&quot;",
		"'", "&#39;",
	)
	return r.Replace(s)
}

// RenderHeroBannerSVG builds a deterministic on-chain SVG hero banner and
// stacked bounty distribution chart for gnoweb using gno.land/p/nt/svg/v0.
func RenderHeroBannerSVG(openCount, claimedCount, submittedCount, settledCount int, totalEscrowUgnot, totalSettledUgnot int64) string {
	c := svg.NewCanvas(860, 210).WithViewBox(0, 0, 860, 210)
	c.AddStyle("text", "font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;")

	// Deep slate tavern backdrop with subtle border frame.
	bg := svg.NewRectangle(0, 0, 860, 210, "#0f172a")
	bg.RX = 14
	bg.RY = 14
	bg.Attr.Stroke = "#334155"
	bg.Attr.StrokeWidth = "2"
	c.Append(bg)

	// Warm hearth accent bar on left edge.
	accent := svg.NewRectangle(0, 0, 10, 210, "#f59e0b")
	accent.RX = 5
	c.Append(accent)

	// Brand emblem circle + ember spark.
	emblem := svg.NewCircle(54, 56, 22, "#1e293b")
	emblem.Attr.Stroke = "#f59e0b"
	emblem.Attr.StrokeWidth = "2.5"
	c.Append(emblem)
	c.Append(svg.NewCircle(54, 56, 9, "#f59e0b"))
	c.Append(svg.NewCircle(54, 53, 4, "#fef3c7"))

	// Title and subtitle.
	title := svg.NewText(92, 52, "HEARTHBOUNTY", "#f8fafc")
	title.Attr.Style = "font-size:24px;font-weight:800;letter-spacing:1.4px;"
	c.Append(title)

	sub := svg.NewText(92, 74, "On-Chain Micro-Bounty Escrow &amp; AI Agent Guild", "#94a3b8")
	sub.Attr.Style = "font-size:13px;font-weight:500;"
	c.Append(sub)

	// Live metric pill cards on top right.
	drawMetricBox(c, 525, 22, 152, 62, "ESCROW LOCKED", EscapeXML(FormatGNOT(totalEscrowUgnot)), "#f59e0b")
	drawMetricBox(c, 690, 22, 152, 62, "SETTLED VOLUME", EscapeXML(FormatGNOT(totalSettledUgnot)), "#34d399")

	// Stacked status distribution bar.
	barX := 34
	barY := 118
	barW := 792
	barH := 24

	track := svg.NewRectangle(barX, barY, barW, barH, "#1e293b")
	track.RX = 6
	track.RY = 6
	c.Append(track)

	total := openCount + claimedCount + submittedCount + settledCount
	if total > 0 {
		wOpen := (barW * openCount) / total
		wClaimed := (barW * claimedCount) / total
		wSubmitted := (barW * submittedCount) / total
		wSettled := barW - wOpen - wClaimed - wSubmitted
		if settledCount == 0 {
			wSettled = 0
		}

		curX := barX
		if wOpen > 0 {
			r := svg.NewRectangle(curX, barY, wOpen, barH, "#f59e0b")
			r.RX = 4
			c.Append(r)
			curX += wOpen
		}
		if wClaimed > 0 {
			r := svg.NewRectangle(curX, barY, wClaimed, barH, "#38bdf8")
			c.Append(r)
			curX += wClaimed
		}
		if wSubmitted > 0 {
			r := svg.NewRectangle(curX, barY, wSubmitted, barH, "#a78bfa")
			c.Append(r)
			curX += wSubmitted
		}
		if wSettled > 0 {
			r := svg.NewRectangle(curX, barY, wSettled, barH, "#34d399")
			r.RX = 4
			c.Append(r)
		}
	}

	// Legend row.
	drawLegendDot(c, 38, 174, "#f59e0b", "Open: "+strconv.Itoa(openCount))
	drawLegendDot(c, 195, 174, "#38bdf8", "Claimed: "+strconv.Itoa(claimedCount))
	drawLegendDot(c, 375, 174, "#a78bfa", "Submitted: "+strconv.Itoa(submittedCount))
	drawLegendDot(c, 575, 174, "#34d399", "Settled: "+strconv.Itoa(settledCount))

	badge := svg.NewText(718, 178, "MCP + gnoweb v1.8", "#64748b")
	badge.Attr.Style = "font-size:11px;font-weight:600;"
	c.Append(badge)

	return c.Render("HearthBounty Live On-Chain Escrow Dashboard")
}

func drawMetricBox(c *svg.Canvas, x, y, w, h int, label, value, color string) {
	box := svg.NewRectangle(x, y, w, h, "#1e293b")
	box.RX = 8
	box.RY = 8
	box.Attr.Stroke = "#334155"
	box.Attr.StrokeWidth = "1.5"
	c.Append(box)

	lbl := svg.NewText(x+12, y+22, label, "#94a3b8")
	lbl.Attr.Style = "font-size:10px;font-weight:700;letter-spacing:0.8px;"
	c.Append(lbl)

	val := svg.NewText(x+12, y+47, value, color)
	val.Attr.Style = "font-size:16px;font-weight:800;"
	c.Append(val)
}

func drawLegendDot(c *svg.Canvas, x, y int, color, text string) {
	c.Append(svg.NewCircle(x, y-4, 6, color))
	t := svg.NewText(x+14, y, text, "#e2e8f0")
	t.Attr.Style = "font-size:13px;font-weight:600;"
	c.Append(t)
}

// RenderLifecycleSVG renders an on-chain 4-step bounty progression strip.
func RenderLifecycleSVG(status Status, rewardUgnot int64) string {
	c := svg.NewCanvas(820, 108).WithViewBox(0, 0, 820, 108)
	c.AddStyle("text", "font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;")

	bg := svg.NewRectangle(0, 0, 820, 108, "#0f172a")
	bg.RX = 12
	bg.RY = 12
	bg.Attr.Stroke = "#334155"
	bg.Attr.StrokeWidth = "1.5"
	c.Append(bg)

	steps := []string{"1. OPEN", "2. CLAIMED", "3. SUBMITTED", "4. SETTLED"}
	activeIdx := status.StepIndex()

	// Connector rail.
	rail := svg.NewRectangle(72, 42, 480, 4, "#334155")
	rail.RX = 2
	c.Append(rail)

	for i, label := range steps {
		cx := 72 + i*160
		fill := "#1e293b"
		stroke := "#475569"
		textColor := "#94a3b8"

		if status == StatusCancelled {
			stroke = "#ef4444"
		} else if status == StatusDisputed && i == 2 {
			fill = "#f97316"
			stroke = "#fdba74"
			textColor = "#f8fafc"
		} else if activeIdx >= 0 && i < activeIdx {
			fill = "#10b981"
			stroke = "#34d399"
			textColor = "#e2e8f0"
		} else if activeIdx == i {
			fill = "#f59e0b"
			stroke = "#fde68a"
			textColor = "#f8fafc"
		}

		node := svg.NewCircle(cx, 44, 15, fill)
		node.Attr.Stroke = stroke
		node.Attr.StrokeWidth = "2.5"
		c.Append(node)

		numColor := "#0f172a"
		if activeIdx < i || status == StatusCancelled {
			numColor = "#cbd5e1"
		}
		num := svg.NewText(cx-4, 49, strconv.Itoa(i+1), numColor)
		num.Attr.Style = "font-size:13px;font-weight:800;"
		c.Append(num)

		lbl := svg.NewText(cx-34, 82, label, textColor)
		lbl.Attr.Style = "font-size:11px;font-weight:700;letter-spacing:0.6px;"
		c.Append(lbl)
	}

	// Reward badge on right side.
	pill := svg.NewRectangle(618, 22, 182, 64, "#1e293b")
	pill.RX = 10
	pill.RY = 10
	pill.Attr.Stroke = "#f59e0b"
	pill.Attr.StrokeWidth = "2"
	c.Append(pill)

	st := svg.NewText(634, 44, "ESCROW: "+EscapeXML(strings.ToUpper(status.Label())), "#94a3b8")
	st.Attr.Style = "font-size:10px;font-weight:700;letter-spacing:0.7px;"
	c.Append(st)

	rew := svg.NewText(634, 70, EscapeXML(FormatGNOT(rewardUgnot)), "#fbbf24")
	rew.Attr.Style = "font-size:17px;font-weight:800;"
	c.Append(rew)

	return c.Render("Bounty Lifecycle Progress")
}

// RenderTierBadgeSVG creates a compact builder/agent reputation shield card.
func RenderTierBadgeSVG(handle string, tier Tier, settledCount uint64, earnedUgnot int64, isAgent bool) string {
	c := svg.NewCanvas(520, 86).WithViewBox(0, 0, 520, 86)
	c.AddStyle("text", "font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;")

	bg := svg.NewRectangle(0, 0, 520, 86, "#0f172a")
	bg.RX = 10
	bg.RY = 10
	bg.Attr.Stroke = tier.Color()
	bg.Attr.StrokeWidth = "2"
	c.Append(bg)

	// Left rank circle.
	rankDot := svg.NewCircle(42, 43, 22, "#1e293b")
	rankDot.Attr.Stroke = tier.Color()
	rankDot.Attr.StrokeWidth = "2.5"
	c.Append(rankDot)

	initial := "B"
	initX := 36
	if isAgent {
		initial = "AI"
		initX = 33
	}
	initTxt := svg.NewText(initX, 49, initial, tier.Color())
	initTxt.Attr.Style = "font-size:15px;font-weight:800;"
	c.Append(initTxt)

	nameTxt := svg.NewText(80, 36, EscapeXML(handle), "#f8fafc")
	nameTxt.Attr.Style = "font-size:17px;font-weight:800;"
	c.Append(nameTxt)

	role := "Builder"
	if isAgent {
		role = "Autonomous AI Agent"
	}
	meta := string(tier) + " · " + role + " · " + strconv.FormatUint(settledCount, 10) + " settled"
	metaTxt := svg.NewText(80, 59, EscapeXML(meta), "#94a3b8")
	metaTxt.Attr.Style = "font-size:12px;font-weight:600;"
	c.Append(metaTxt)

	earnedTxt := svg.NewText(370, 49, EscapeXML(FormatGNOT(earnedUgnot)), tier.Color())
	earnedTxt.Attr.Style = "font-size:16px;font-weight:800;"
	c.Append(earnedTxt)

	return c.Render("HearthBounty Reputation Badge")
}
