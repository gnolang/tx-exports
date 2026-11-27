package tributary

import (
	"sort"

	"gno.land/p/nt/svg/v0"
	"gno.land/p/nt/ufmt/v0"
)

type nodePos struct {
	x int
	y int
}

// RenderGraphSVG builds a pure on-chain SVG dependency waterfall diagram for rootID
// using gno.land/p/nt/svg/v0, ready to embed directly in gnoweb Markdown.
func (e *Engine) RenderGraphSVG(rootID string) string {
	root := e.GetNode(rootID)
	if root == nil {
		return ""
	}

	order := e.TopologicalOrder(rootID)
	if len(order) == 0 {
		return ""
	}

	// Assign longest-path layer (column) to each node in the reachable subgraph.
	layer := make(map[string]int, len(order))
	maxLayer := 0
	for _, id := range order {
		curL := layer[id]
		if curL > maxLayer {
			maxLayer = curL
		}
		n := e.GetNode(id)
		for _, ed := range n.Edges {
			if layer[ed.TargetID] < curL+1 {
				layer[ed.TargetID] = curL + 1
			}
		}
	}

	columns := make([][]string, maxLayer+1)
	for _, id := range order {
		l := layer[id]
		columns[l] = append(columns[l], id)
	}
	maxRows := 1
	for i := range columns {
		sort.Strings(columns[i])
		if len(columns[i]) > maxRows {
			maxRows = len(columns[i])
		}
	}

	const (
		boxW    = 176
		boxH    = 64
		colGap  = 90
		rowGap  = 34
		padX    = 28
		padY    = 46
	)

	width := padX*2 + (maxLayer+1)*boxW + maxLayer*colGap
	if width < 560 {
		width = 560
	}
	height := padY*2 + maxRows*boxH + (maxRows-1)*rowGap + 24
	if height < 220 {
		height = 220
	}

	pos := make(map[string]nodePos, len(order))
	for c, col := range columns {
		colH := len(col)*boxH + (len(col)-1)*rowGap
		startY := padY + ((height - padY*2 - 20) - colH)/2
		if startY < padY {
			startY = padY
		}
		x := padX + c*(boxW+colGap)
		for r, id := range col {
			pos[id] = nodePos{
				x: x,
				y: startY + r*(boxH+rowGap),
			}
		}
	}

	canvas := svg.NewCanvas(width, height).WithViewBox(0, 0, width, height)

	// Dark obsidian backdrop
	bg := svg.NewRectangle(0, 0, width, height, "#0B1120")
	bg.RX = 12
	bg.RY = 12
	bg.Attr.Stroke = "#1E293B"
	bg.Attr.StrokeWidth = "2"
	canvas.Append(bg)

	// Header banner text
	hdr := svg.NewText(24, 28, "TRIBUTARY WATERFALL DAG :: "+root.Title, "#38BDF8")
	hdr.Attr.Style = "font-family:monospace;font-size:13px;font-weight:bold"
	canvas.Append(hdr)

	sub := svg.NewText(width-24, 28, ufmt.Sprintf("Routed: %d ugnot", root.TotalInflow), "#10B981")
	sub.Attr.Style = "font-family:monospace;font-size:12px;text-anchor:end"
	canvas.Append(sub)

	// Draw directed cubic Bezier flow pipes first (underneath nodes)
	for _, id := range order {
		n := e.GetNode(id)
		from := pos[id]
		x1 := from.x + boxW
		y1 := from.y + boxH/2
		for _, ed := range n.Edges {
			to := pos[ed.TargetID]
			x2 := to.x
			y2 := to.y + boxH/2
			mx := (x1 + x2) / 2

			strokeW := 2
			if ed.BPS >= 2500 {
				strokeW = 4
			} else if ed.BPS >= 1000 {
				strokeW = 3
			}

			d := ufmt.Sprintf("M %d %d C %d %d, %d %d, %d %d", x1, y1, mx, y1, mx, y2, x2, y2)
			pipe := svg.NewPath(d, "none")
			pipe.Attr.Stroke = "#22D3EE"
			pipe.Attr.StrokeWidth = ufmt.Sprintf("%d", strokeW)
			pipe.Attr.Opacity = "0.78"
			canvas.Append(pipe)

			// Arrow dot at target ingress
			dot := svg.NewCircle(x2, y2, 4, "#10B981")
			canvas.Append(dot)

			// Percentage pill at midpoint
			lblX := mx
			lblY := (y1+y2)/2 - 6
			pill := svg.NewRectangle(lblX-24, lblY-11, 48, 16, "#0F172A")
			pill.RX = 4
			pill.RY = 4
			pill.Attr.Stroke = "#22D3EE"
			pill.Attr.StrokeWidth = "1"
			canvas.Append(pill)

			pct := svg.NewText(lblX, lblY+1, formatBPS(ed.BPS), "#E0F2FE")
			pct.Attr.Style = "font-family:monospace;font-size:10px;text-anchor:middle"
			canvas.Append(pct)
		}
	}

	// Draw node cards on top
	for _, id := range order {
		n := e.GetNode(id)
		p := pos[id]

		fill := "#111827"
		stroke := "#38BDF8"
		if id == rootID {
			fill = "#0F2942"
			stroke = "#22D3EE"
		} else if len(n.Edges) == 0 {
			fill = "#0D2622"
			stroke = "#10B981"
		}

		card := svg.NewRectangle(p.x, p.y, boxW, boxH, fill)
		card.RX = 8
		card.RY = 8
		card.Attr.Stroke = stroke
		card.Attr.StrokeWidth = "2"
		canvas.Append(card)

		title := trimLabel(n.Title, 20)
		if n.Locked {
			title = title + " [LOCK]"
		}
		t1 := svg.NewText(p.x+10, p.y+21, title, "#F8FAFC")
		t1.Attr.Style = "font-family:monospace;font-size:11px;font-weight:bold"
		canvas.Append(t1)

		t2 := svg.NewText(p.x+10, p.y+39, ufmt.Sprintf("keep %s | fwd %s", formatBPS(n.RetainedBPS()), formatBPS(n.ForwardedBPS())), "#94A3B8")
		t2.Attr.Style = "font-family:monospace;font-size:10px"
		canvas.Append(t2)

		t3 := svg.NewText(p.x+10, p.y+54, ufmt.Sprintf("earned: %d ugnot", n.TotalRetained), "#34D399")
		t3.Attr.Style = "font-family:monospace;font-size:10px"
		canvas.Append(t3)
	}

	// Footer legend
	foot := svg.NewText(24, height-12, "Blue: Entry Realm  |  Slate: Midstream Lib  |  Green: Upstream Leaf  |  Zero-Dust Integer Conservation", "#64748B")
	foot.Attr.Style = "font-family:monospace;font-size:10px"
	canvas.Append(foot)

	return canvas.Render("Tributary DAG: " + root.ID)
}

func formatBPS(bps int64) string {
	whole := bps / 100
	frac := bps % 100
	if frac == 0 {
		return ufmt.Sprintf("%d%%", whole)
	}
	if frac < 10 {
		return ufmt.Sprintf("%d.0%d%%", whole, frac)
	}
	return ufmt.Sprintf("%d.%d%%", whole, frac)
}

func trimLabel(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-2] + ".."
}
