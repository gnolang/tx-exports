package nandloom

import (
	"encoding/base64"
	"strings"

	"gno.land/p/nt/svg/v0"
	"gno.land/p/nt/ufmt/v0"
)

func xmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	s = strings.ReplaceAll(s, "'", "&#39;")
	return s
}

type point struct {
	x int
	y int
}

// RenderSchematicRawSVG produces a deterministic blueprint-style SVG schematic
// of cc evaluated on trace (trace may be nil for static unpowered rendering).
func RenderSchematicRawSVG(title string, cc *CompiledCircuit, trace *Trace) string {
	if cc == nil || cc.AST == nil {
		return ""
	}
	c := cc.AST
	numCols := cc.MaxCol + 2 // col 0 = inputs, 1..MaxCol = statements, MaxCol+1 = outputs

	// Group top-level statements by visual column depth.
	cols := make([][]int, cc.MaxCol+1)
	maxRows := len(c.Inputs)
	if len(c.Outputs) > maxRows {
		maxRows = len(c.Outputs)
	}
	for oi := 0; oi < len(cc.TopOrder); oi++ {
		si := cc.TopOrder[oi]
		col := cc.StmtDepth[si]
		cols[col] = append(cols[col], si)
		if len(cols[col]) > maxRows {
			maxRows = len(cols[col])
		}
	}

	colWidth := 168
	leftPad := 24
	topHeader := 54
	rowPitch := 68
	if maxRows > 6 {
		rowPitch = 56
	}
	width := leftPad*2 + numCols*colWidth
	if width < 640 {
		width = 640
	}
	height := topHeader + maxRows*rowPitch + 34
	if height < 240 {
		height = 240
	}

	canvas := svg.NewCanvas(width, height).WithViewBox(0, 0, width, height)
	canvas.AddStyle("text", "font-family:ui-monospace,SFMono-Regular,Menlo,monospace")

	// Blueprint background & subtle vertical column guides.
	bg := svg.NewRectangle(0, 0, width, height, "#0b1120")
	bg.RX = 10
	bg.RY = 10
	canvas.Append(bg)

	// Header strip
	hdr := svg.NewRectangle(0, 0, width, 40, "#111c33")
	hdr.RX = 10
	hdr.RY = 10
	canvas.Append(hdr)
	hdrBottom := svg.NewRectangle(0, 30, width, 10, "#111c33")
	canvas.Append(hdrBottom)
	hdrLine := svg.NewPath(ufmt.Sprintf("M 0 40 L %d 40", width), "none")
	hdrLine.Attr.Stroke = "#1e293b"
	hdrLine.Attr.StrokeWidth = "1"
	canvas.Append(hdrLine)

	titleTxt := svg.NewText(18, 25, xmlEscape(title), "#f8fafc")
	titleTxt.Attr.Style = "font-size:13px;font-weight:700"
	canvas.Append(titleTxt)

	metaStr := ufmt.Sprintf("NANDs: %d  |  Depth: %d  |  Modules: %d", cc.NANDCount, cc.MaxDepth, cc.ModuleCount)
	if trace != nil {
		metaStr = ufmt.Sprintf("%s  |  %s -> %s", metaStr, trace.InputBits, trace.OutputBits)
	}
	metaTxt := svg.NewText(width-18, 25, xmlEscape(metaStr), "#94a3b8")
	metaTxt.Attr.Style = "font-size:11px;text-anchor:end"
	canvas.Append(metaTxt)

	// Column helper x-centers.
	colCenterX := func(col int) int {
		if numCols <= 1 {
			return width / 2
		}
		usable := width - leftPad*2 - 110
		return leftPad + 55 + (col*usable)/(numCols-1)
	}
	rowCenterY := func(idx, count int) int {
		avail := height - topHeader - 24
		return topHeader + (avail*(idx+1))/(count+1)
	}

	// Subtle blueprint grid lines.
	for gx := 40; gx < width; gx += 40 {
		gl := svg.NewPath(ufmt.Sprintf("M %d 41 L %d %d", gx, gx, height-1), "none")
		gl.Attr.Stroke = "#162036"
		gl.Attr.StrokeWidth = "1"
		canvas.Append(gl)
	}

	// Track output anchor position for every visible wire so wires route cleanly.
	wireSrc := make(map[string]point)

	// Pre-compute input pin positions (column 0).
	inPos := make([]point, len(c.Inputs))
	for i := 0; i < len(c.Inputs); i++ {
		cx := colCenterX(0)
		cy := rowCenterY(i, len(c.Inputs))
		inPos[i] = point{x: cx, y: cy}
		wireSrc[c.Inputs[i]] = point{x: cx + 44, y: cy}
	}

	// Pre-compute statement box positions (columns 1..MaxCol).
	stmtPos := make([]point, len(c.Statements))
	stmtBoxW := make([]int, len(c.Statements))
	stmtBoxH := make([]int, len(c.Statements))
	for col := 1; col <= cc.MaxCol; col++ {
		list := cols[col]
		cx := colCenterX(col)
		for idx := 0; idx < len(list); idx++ {
			si := list[idx]
			st := c.Statements[si]
			cy := rowCenterY(idx, len(list))
			stmtPos[si] = point{x: cx, y: cy}
			bw := 84
			bh := 36
			if st.Op == OpChip {
				bw = 114
				bh = 44
				if len(st.Outputs) > 2 || len(st.Args) > 3 {
					bh = 52
				}
			}
			stmtBoxW[si] = bw
			stmtBoxH[si] = bh
			// Register output port anchor for each output wire of this statement.
			outCount := len(st.Outputs)
			for oi := 0; oi < outCount; oi++ {
				oy := cy
				if outCount > 1 {
					oy = cy - bh/2 + ((oi+1)*bh)/(outCount+1)
				}
				anchorX := cx + bw/2
				if st.Op == OpNAND {
					anchorX = cx + bw/2 + 8 // after inversion bubble
				}
				wireSrc[st.Outputs[oi]] = point{x: anchorX, y: oy}
			}
		}
	}

	// Pre-compute output pin positions (last column).
	outPos := make([]point, len(c.Outputs))
	for i := 0; i < len(c.Outputs); i++ {
		cx := colCenterX(numCols - 1)
		cy := rowCenterY(i, len(c.Outputs))
		outPos[i] = point{x: cx, y: cy}
	}

	wireColor := func(w string) (string, string) {
		if trace == nil {
			return "#64748b", "1.8"
		}
		if trace.WireValues[w] {
			return "#10b981", "2.6"
		}
		return "#475569", "1.5"
	}

	// Helper to draw clean cubic-bezier signal traces from p1 -> p2.
	drawWire := func(w string, p1, p2 point) {
		col, sw := wireColor(w)
		midX := (p1.x + p2.x) / 2
		d := ufmt.Sprintf("M %d %d C %d %d, %d %d, %d %d", p1.x, p1.y, midX, p1.y, midX, p2.y, p2.x, p2.y)
		p := svg.NewPath(d, "none")
		p.Attr.Stroke = col
		p.Attr.StrokeWidth = sw
		canvas.Append(p)
	}

	// 1. Draw wires first so nodes sit cleanly on top.
	for oi := 0; oi < len(cc.TopOrder); oi++ {
		si := cc.TopOrder[oi]
		st := c.Statements[si]
		cx := stmtPos[si].x
		cy := stmtPos[si].y
		bw := stmtBoxW[si]
		bh := stmtBoxH[si]
		argCount := len(st.Args)
		for ai := 0; ai < argCount; ai++ {
			src, ok := wireSrc[st.Args[ai]]
			if !ok {
				continue
			}
			iy := cy
			if argCount > 1 {
				iy = cy - bh/2 + ((ai+1)*bh)/(argCount+1)
			}
			dst := point{x: cx - bw/2, y: iy}
			drawWire(st.Args[ai], src, dst)
		}
	}
	// Wires to primary output pads.
	for i := 0; i < len(c.Outputs); i++ {
		outName := c.Outputs[i]
		src, ok := wireSrc[outName]
		if !ok {
			continue
		}
		dst := point{x: outPos[i].x - 44, y: outPos[i].y}
		drawWire(outName, src, dst)
	}

	// 2. Draw primary input pins (column 0).
	for i := 0; i < len(c.Inputs); i++ {
		name := c.Inputs[i]
		p := inPos[i]
		high := trace != nil && trace.WireValues[name]
		border := "#475569"
		pillFill := "#1e293b"
		bitLabel := "-"
		bitColor := "#94a3b8"
		if trace != nil {
			if high {
				border = "#10b981"
				pillFill = "#064e3b"
				bitLabel = "1"
				bitColor = "#6ee7b7"
			} else {
				bitLabel = "0"
				bitColor = "#94a3b8"
			}
		}
		box := svg.NewRectangle(p.x-44, p.y-15, 88, 30, pillFill)
		box.RX = 6
		box.RY = 6
		box.Attr.Stroke = border
		box.Attr.StrokeWidth = "1.6"
		canvas.Append(box)

		lbl := svg.NewText(p.x-34, p.y+4, xmlEscape(name), "#e2e8f0")
		lbl.Attr.Style = "font-size:11px;font-weight:600"
		canvas.Append(lbl)

		val := svg.NewText(p.x+34, p.y+4, bitLabel, bitColor)
		val.Attr.Style = "font-size:12px;font-weight:700;text-anchor:end"
		canvas.Append(val)
	}

	// 3. Draw logic gates and composite IC chips.
	for oi := 0; oi < len(cc.TopOrder); oi++ {
		si := cc.TopOrder[oi]
		st := c.Statements[si]
		cx := stmtPos[si].x
		cy := stmtPos[si].y
		bw := stmtBoxW[si]
		bh := stmtBoxH[si]

		if st.Op == OpNAND {
			high := trace != nil && trace.WireValues[st.Outputs[0]]
			fill := "#172554"
			stroke := "#3b82f6"
			if high {
				fill = "#064e3b"
				stroke = "#10b981"
			}
			// Classic D-shaped NAND gate body.
			x0 := cx - bw/2
			y0 := cy - bh/2
			xMid := cx + bw/2 - bh/2
			r := bh / 2
			d := ufmt.Sprintf("M %d %d L %d %d A %d %d 0 0 1 %d %d L %d %d Z",
				x0, y0, xMid, y0, r, r, xMid, y0+bh, x0, y0+bh)
			body := svg.NewPath(d, fill)
			body.Attr.Stroke = stroke
			body.Attr.StrokeWidth = "1.8"
			canvas.Append(body)

			// Inversion bubble.
			bub := svg.NewCircle(cx+bw/2+4, cy, 4, fill)
			bub.Attr.Stroke = stroke
			bub.Attr.StrokeWidth = "1.8"
			canvas.Append(bub)

			glbl := svg.NewText(cx-4, cy-1, "NAND", "#e2e8f0")
			glbl.Attr.Style = "font-size:10px;font-weight:700;text-anchor:middle"
			canvas.Append(glbl)

			wlbl := svg.NewText(cx-4, cy+11, xmlEscape(st.Outputs[0]), "#94a3b8")
			wlbl.Attr.Style = "font-size:9px;text-anchor:middle"
			canvas.Append(wlbl)
		} else if st.Op == OpChip {
			// Composite imported IC chip package in warm amber/gold.
			anyHigh := false
			if trace != nil {
				for k := 0; k < len(st.Outputs); k++ {
					if trace.WireValues[st.Outputs[k]] {
						anyHigh = true
					}
				}
			}
			fill := "#1c1917"
			stroke := "#f59e0b"
			if anyHigh {
				fill = "#292014"
				stroke = "#fbbf24"
			}
			box := svg.NewRectangle(cx-bw/2, cy-bh/2, bw, bh, fill)
			box.RX = 6
			box.RY = 6
			box.Attr.Stroke = stroke
			box.Attr.StrokeWidth = "2"
			canvas.Append(box)

			// IC notch accent at top center.
			notch := svg.NewCircle(cx, cy-bh/2, 3, "#0b1120")
			notch.Attr.Stroke = stroke
			notch.Attr.StrokeWidth = "1.4"
			canvas.Append(notch)

			chipLabel := st.ChipSlug
			if len(chipLabel) > 14 {
				chipLabel = chipLabel[:13] + "."
			}
			t1 := svg.NewText(cx, cy-2, xmlEscape(chipLabel), "#fef3c7")
			t1.Attr.Style = "font-size:10px;font-weight:700;text-anchor:middle"
			canvas.Append(t1)

			t2 := svg.NewText(cx, cy+12, ufmt.Sprintf("IC · %d NAND", cc.StmtNANDs[si]), "#f59e0b")
			t2.Attr.Style = "font-size:9px;text-anchor:middle"
			canvas.Append(t2)
		} else {
			// OpBuf / OpConst0 / OpConst1 compact block.
			box := svg.NewRectangle(cx-bw/2, cy-bh/2, bw, bh, "#1e293b")
			box.RX = 6
			box.RY = 6
			box.Attr.Stroke = "#64748b"
			box.Attr.StrokeWidth = "1.5"
			canvas.Append(box)

			t1 := svg.NewText(cx, cy+4, xmlEscape(st.Op.String()+" -> "+st.Outputs[0]), "#cbd5e1")
			t1.Attr.Style = "font-size:9px;text-anchor:middle"
			canvas.Append(t1)
		}
	}

	// 4. Draw primary output LED pads (last column).
	for i := 0; i < len(c.Outputs); i++ {
		name := c.Outputs[i]
		p := outPos[i]
		high := trace != nil && trace.WireValues[name]
		border := "#475569"
		fill := "#1e293b"
		ledFill := "#334155"
		bitLabel := "-"
		if trace != nil {
			if high {
				border = "#10b981"
				fill = "#064e3b"
				ledFill = "#10b981"
				bitLabel = "1"
			} else {
				ledFill = "#475569"
				bitLabel = "0"
			}
		}
		box := svg.NewRectangle(p.x-44, p.y-15, 88, 30, fill)
		box.RX = 15
		box.RY = 15
		box.Attr.Stroke = border
		box.Attr.StrokeWidth = "1.8"
		canvas.Append(box)

		led := svg.NewCircle(p.x-28, p.y, 5, ledFill)
		canvas.Append(led)

		lbl := svg.NewText(p.x-16, p.y+4, xmlEscape(name), "#f8fafc")
		lbl.Attr.Style = "font-size:11px;font-weight:600"
		canvas.Append(lbl)

		val := svg.NewText(p.x+34, p.y+4, bitLabel, "#f8fafc")
		val.Attr.Style = "font-size:12px;font-weight:700;text-anchor:end"
		canvas.Append(val)
	}

	return canvas.String()
}

// RenderSchematicSVG returns a gnoweb-safe Markdown data:image/svg+xml image.
func RenderSchematicSVG(title string, cc *CompiledCircuit, trace *Trace) string {
	raw := RenderSchematicRawSVG(title, cc, trace)
	if raw == "" {
		return ""
	}
	return wrapSVGMarkdown("Nandloom schematic: "+title, raw)
}

// RenderWaveformRawSVG renders an oscilloscope-style digital timing diagram
// across up to maxSamples test vectors from spec.
func RenderWaveformRawSVG(title string, cc *CompiledCircuit, spec ChallengeSpec, maxSamples int) string {
	if cc == nil || cc.AST == nil || len(spec.Vectors) == 0 {
		return ""
	}
	samples := len(spec.Vectors)
	if maxSamples > 0 && samples > maxSamples {
		samples = maxSamples
	}

	// Build signal channels: all inputs + all outputs.
	nIn := len(cc.AST.Inputs)
	nOut := len(cc.AST.Outputs)
	totalCh := nIn + nOut
	if totalCh == 0 {
		return ""
	}

	// Evaluate each sample vector.
	actualOut := make([][]bool, samples)
	vecPass := make([]bool, samples)
	for s := 0; s < samples; s++ {
		tr, err := Eval(cc, spec.Vectors[s].In)
		if err != nil {
			actualOut[s] = make([]bool, nOut)
			vecPass[s] = false
			continue
		}
		actualOut[s] = tr.OutputVals
		vecPass[s] = tr.OutputBits == FormatBits(spec.Vectors[s].Out)
	}

	labelW := 96
	slotW := 66
	if samples > 8 {
		slotW = 54
	}
	rightPad := 20
	headerH := 42
	chH := 30
	width := labelW + samples*slotW + rightPad
	if width < 560 {
		width = 560
		slotW = (width - labelW - rightPad) / samples
	}
	height := headerH + totalCh*chH + 26

	canvas := svg.NewCanvas(width, height).WithViewBox(0, 0, width, height)
	canvas.AddStyle("text", "font-family:ui-monospace,SFMono-Regular,Menlo,monospace")

	bg := svg.NewRectangle(0, 0, width, height, "#0b1120")
	bg.RX = 10
	bg.RY = 10
	canvas.Append(bg)

	hdr := svg.NewRectangle(0, 0, width, 34, "#111c33")
	hdr.RX = 10
	hdr.RY = 10
	canvas.Append(hdr)
	tHdr := svg.NewText(14, 22, xmlEscape("WAVEFORM · "+title), "#f8fafc")
	tHdr.Attr.Style = "font-size:12px;font-weight:700"
	canvas.Append(tHdr)

	// Column headers per test vector.
	for s := 0; s < samples; s++ {
		x0 := labelW + s*slotW
		gx := svg.NewPath(ufmt.Sprintf("M %d 36 L %d %d", x0, x0, height-14), "none")
		gx.Attr.Stroke = "#1e293b"
		gx.Attr.StrokeWidth = "1"
		canvas.Append(gx)

		col := "#6ee7b7"
		if !vecPass[s] {
			col = "#f87171"
		}
		lbl := spec.Vectors[s].Label
		if len(lbl) > 8 {
			lbl = lbl[:8]
		}
		vt := svg.NewText(x0+slotW/2, height-5, xmlEscape(lbl), col)
		vt.Attr.Style = "font-size:9px;text-anchor:middle"
		canvas.Append(vt)
	}

	// Render each signal trace.
	for ch := 0; ch < totalCh; ch++ {
		yTop := headerH + ch*chH
		yHigh := yTop + 6
		yLow := yTop + chH - 6
		isOut := ch >= nIn

		name := ""
		strokeCol := "#38bdf8"
		if !isOut {
			name = "IN " + cc.AST.Inputs[ch]
		} else {
			name = "OUT " + cc.AST.Outputs[ch-nIn]
			strokeCol = "#10b981"
		}

		// Row separator.
		sep := svg.NewPath(ufmt.Sprintf("M 10 %d L %d %d", yTop+chH, width-10, yTop+chH), "none")
		sep.Attr.Stroke = "#162036"
		sep.Attr.StrokeWidth = "1"
		canvas.Append(sep)

		lbl := svg.NewText(14, yTop+18, xmlEscape(name), strokeCol)
		lbl.Attr.Style = "font-size:10px;font-weight:600"
		canvas.Append(lbl)

		var pts strings.Builder
		anyFail := false
		for s := 0; s < samples; s++ {
			var bit bool
			if !isOut {
				bit = spec.Vectors[s].In[ch]
			} else {
				oi := ch - nIn
				bit = actualOut[s][oi]
				if bit != spec.Vectors[s].Out[oi] {
					anyFail = true
				}
			}
			y := yLow
			if bit {
				y = yHigh
			}
			x0 := labelW + s*slotW
			x1 := x0 + slotW
			if s > 0 {
				pts.WriteString(" ")
			}
			pts.WriteString(ufmt.Sprintf("%d,%d %d,%d", x0, y, x1, y))

			bTxt := "0"
			if bit {
				bTxt = "1"
			}
			bt := svg.NewText(x0+slotW/2, yTop+19, bTxt, "#64748b")
			bt.Attr.Style = "font-size:9px;text-anchor:middle"
			canvas.Append(bt)
		}

		if anyFail {
			strokeCol = "#ef4444"
		}
		wave := svg.NewPolyline(pts.String(), "none")
		wave.Attr.Stroke = strokeCol
		wave.Attr.StrokeWidth = "2.2"
		canvas.Append(wave)
	}

	return canvas.String()
}

// RenderWaveformSVG returns a gnoweb-safe Markdown data:image/svg+xml image.
func RenderWaveformSVG(title string, cc *CompiledCircuit, spec ChallengeSpec, maxSamples int) string {
	raw := RenderWaveformRawSVG(title, cc, spec, maxSamples)
	if raw == "" {
		return ""
	}
	return wrapSVGMarkdown("Nandloom waveform: "+title, raw)
}

// wrapSVGMarkdown encodes a raw <svg> string into a base64 Markdown image.
func wrapSVGMarkdown(alt, rawSVG string) string {
	return ufmt.Sprintf("![%s](data:image/svg+xml;base64,%s)", alt, base64.StdEncoding.EncodeToString([]byte(rawSVG)))
}
