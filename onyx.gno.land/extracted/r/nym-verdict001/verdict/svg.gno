package verdict

import (
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nym-verdict001/fpmm"
)

func renderOddsChartMarkdown(pts []pricePoint, yesProbBps int64, status MarketStatus, outcome Outcome) string {
	const (
		width  = 640
		height = 240
		x0     = 48
		x1     = 616
		y0     = 44
		y1     = 204
	)
	plotW := x1 - x0
	plotH := y1 - y0

	yesPct := formatProbPct(yesProbBps)
	noPct := formatProbPct(fpmm.BpsScale - yesProbBps)

	badge := status.String()
	badgeColor := "#10b981"
	if status == StatusProposed {
		badge = "PROPOSED: " + outcome.String()
		badgeColor = "#f59e0b"
	} else if status == StatusDisputed {
		badge = "DISPUTED"
		badgeColor = "#f43f5e"
	} else if status == StatusResolved {
		badge = "RESOLVED: " + outcome.String()
		if outcome == OutcomeNo {
			badgeColor = "#f43f5e"
		} else if outcome == OutcomeInvalid {
			badgeColor = "#94a3b8"
		}
	}

	var poly strings.Builder
	var lastX, lastY int

	n := len(pts)
	if n == 0 {
		y := y0 + ((int(fpmm.BpsScale-yesProbBps) * plotH) / int(fpmm.BpsScale))
		poly.WriteString(strconv.Itoa(x0) + "," + strconv.Itoa(y) + " " + strconv.Itoa(x1) + "," + strconv.Itoa(y))
		lastX, lastY = x1, y
	} else if n == 1 {
		y := y0 + ((int(fpmm.BpsScale-pts[0].yesProbBps) * plotH) / int(fpmm.BpsScale))
		poly.WriteString(strconv.Itoa(x0) + "," + strconv.Itoa(y) + " " + strconv.Itoa(x1) + "," + strconv.Itoa(y))
		lastX, lastY = x1, y
	} else {
		for i := 0; i < n; i++ {
			x := x0 + (i*plotW)/(n-1)
			y := y0 + ((int(fpmm.BpsScale-pts[i].yesProbBps) * plotH) / int(fpmm.BpsScale))
			if i > 0 {
				poly.WriteByte(' ')
			}
			poly.WriteString(strconv.Itoa(x) + "," + strconv.Itoa(y))
			lastX, lastY = x, y
		}
	}

	linePoints := poly.String()
	areaPoints := strconv.Itoa(x0) + "," + strconv.Itoa(y1) + " " + linePoints + " " + strconv.Itoa(x1) + "," + strconv.Itoa(y1)

	y75 := y0 + plotH/4
	y50 := y0 + plotH/2
	y25 := y0 + (3*plotH)/4

	var svg strings.Builder
	svg.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="640" height="240" viewBox="0 0 640 240">`)
	svg.WriteString(`<defs><linearGradient id="yesFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#10b981" stop-opacity="0.38"/><stop offset="100%" stop-color="#10b981" stop-opacity="0.02"/></linearGradient></defs>`)
	svg.WriteString(`<rect x="1" y="1" width="638" height="238" rx="12" fill="#0f172a" stroke="#1e293b" stroke-width="2"/>`)
	svg.WriteString(`<text x="20" y="27" fill="#94a3b8" font-family="ui-monospace,monospace" font-size="11" font-weight="700">VERDICT CPMM  |  ` + badge + `</text>`)
	svg.WriteString(`<text x="616" y="27" text-anchor="end" fill="#34d399" font-family="ui-monospace,monospace" font-size="13" font-weight="700">` + yesPct + ` YES  /  ` + noPct + ` NO</text>`)

	// Gridlines at 75%, 50%, 25%.
	svg.WriteString(`<line x1="48" y1="` + strconv.Itoa(y75) + `" x2="616" y2="` + strconv.Itoa(y75) + `" stroke="#1e293b" stroke-dasharray="4 4"/>`)
	svg.WriteString(`<text x="40" y="` + strconv.Itoa(y75+4) + `" text-anchor="end" fill="#64748b" font-family="ui-monospace,monospace" font-size="10">75%</text>`)
	svg.WriteString(`<line x1="48" y1="` + strconv.Itoa(y50) + `" x2="616" y2="` + strconv.Itoa(y50) + `" stroke="#334155" stroke-dasharray="4 4"/>`)
	svg.WriteString(`<text x="40" y="` + strconv.Itoa(y50+4) + `" text-anchor="end" fill="#94a3b8" font-family="ui-monospace,monospace" font-size="10">50%</text>`)
	svg.WriteString(`<line x1="48" y1="` + strconv.Itoa(y25) + `" x2="616" y2="` + strconv.Itoa(y25) + `" stroke="#1e293b" stroke-dasharray="4 4"/>`)
	svg.WriteString(`<text x="40" y="` + strconv.Itoa(y25+4) + `" text-anchor="end" fill="#64748b" font-family="ui-monospace,monospace" font-size="10">25%</text>`)

	// Baseline axis.
	svg.WriteString(`<line x1="48" y1="204" x2="616" y2="204" stroke="#334155" stroke-width="1"/>`)

	// Probability area & line.
	svg.WriteString(`<polygon points="` + areaPoints + `" fill="url(#yesFill)"/>`)
	svg.WriteString(`<polyline points="` + linePoints + `" fill="none" stroke="#34d399" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`)

	// Terminal live dot.
	svg.WriteString(`<circle cx="` + strconv.Itoa(lastX) + `" cy="` + strconv.Itoa(lastY) + `" r="7" fill="` + badgeColor + `" fill-opacity="0.25"/>`)
	svg.WriteString(`<circle cx="` + strconv.Itoa(lastX) + `" cy="` + strconv.Itoa(lastY) + `" r="4" fill="#34d399" stroke="#0f172a" stroke-width="1.5"/>`)

	svg.WriteString(`<text x="48" y="224" fill="#64748b" font-family="ui-monospace,monospace" font-size="10">OPEN 50.0%</text>`)
	svg.WriteString(`<text x="616" y="224" text-anchor="end" fill="#64748b" font-family="ui-monospace,monospace" font-size="10">` + strconv.Itoa(n) + ` ON-CHAIN TICKS</text>`)
	svg.WriteString(`</svg>`)

	encoded := base64.StdEncoding.EncodeToString([]byte(svg.String()))
	return "![YES Probability Chart](data:image/svg+xml;base64," + encoded + ")"
}

func renderMiniOddsBarMarkdown(yesProbBps int64) string {
	const totalW = 160
	yesW := (int(yesProbBps) * totalW) / int(fpmm.BpsScale)
	if yesW < 4 {
		yesW = 4
	}
	if yesW > totalW-4 {
		yesW = totalW - 4
	}
	var svg strings.Builder
	svg.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="160" height="14" viewBox="0 0 160 14">`)
	svg.WriteString(`<rect x="0" y="2" width="160" height="10" rx="5" fill="#e11d48"/>`)
	svg.WriteString(`<rect x="0" y="2" width="` + strconv.Itoa(yesW) + `" height="10" rx="5" fill="#10b981"/>`)
	svg.WriteString(`</svg>`)
	encoded := base64.StdEncoding.EncodeToString([]byte(svg.String()))
	return "![Odds](data:image/svg+xml;base64," + encoded + ")"
}
