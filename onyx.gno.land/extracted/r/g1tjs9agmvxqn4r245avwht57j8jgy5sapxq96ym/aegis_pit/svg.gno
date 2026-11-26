package aegis_pit

import (
	"encoding/base64"
	"strconv"

	core "gno.land/p/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_core"
)

// All visuals are generated on-chain and embedded as data-URI images,
// so gnoweb shows them with no external hosting.

const (
	cBg     = "#14110f"
	cPanel  = "#221c17"
	cGold   = "#e8b44a"
	cRed    = "#d9534f"
	cTeal   = "#3fb6a8"
	cText   = "#f3e9dc"
	cMuted  = "#9c8f80"
	svgFont = "font-family='ui-monospace,Menlo,monospace'"
)

func itoa(i int) string { return strconv.Itoa(i) }

func svgImage(alt, body string, w, h int) string {
	s := "<svg xmlns='http://www.w3.org/2000/svg' width='" + itoa(w) + "' height='" + itoa(h) +
		"' viewBox='0 0 " + itoa(w) + " " + itoa(h) + "'>" +
		"<rect width='100%' height='100%' rx='14' fill='" + cBg + "'/>" + body + "</svg>"
	return "![" + alt + "](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(s)) + ")"
}

func text(x, y int, size int, fill, anchor, s string) string {
	return "<text x='" + itoa(x) + "' y='" + itoa(y) + "' font-size='" + itoa(size) + "' fill='" + fill +
		"' text-anchor='" + anchor + "' " + svgFont + ">" + escape(s) + "</text>"
}

func rect(x, y, w, h int, fill string) string {
	return "<rect x='" + itoa(x) + "' y='" + itoa(y) + "' width='" + itoa(w) + "' height='" + itoa(h) +
		"' rx='4' fill='" + fill + "'/>"
}

func escape(s string) string {
	out := ""
	for _, r := range s {
		switch r {
		case '<':
			out += "&lt;"
		case '>':
			out += "&gt;"
		case '&':
			out += "&amp;"
		case '\'':
			out += "&#39;"
		default:
			out += string(r)
		}
	}
	return out
}

func hpBar(x, y, w, hp int, fill string) string {
	filled := w * hp / core.StartHP
	return rect(x, y, w, 14, cPanel) + rect(x, y, filled, 14, fill) +
		text(x+w/2, y+11, 11, cText, "middle", itoa(hp)+" HP")
}

// matchCardSVG draws the duel board: names, HP bars, pool split, phase.
func matchCardSVG(m *Match) string {
	fa := getFighter(m.A)
	nameB := "waiting…"
	if m.B != 0 {
		nameB = getFighter(m.B).Name
	}
	hpA, hpB := core.StartHP, core.StartHP
	if len(m.Log) > 0 {
		last := m.Log[len(m.Log)-1]
		hpA, hpB = last.HPA, last.HPB
	}
	if m.Status == StatusForfeit {
		if m.Winner == 1 {
			hpB = 0
		} else if m.Winner == 2 {
			hpA = 0
		} else {
			hpA, hpB = 0, 0
		}
	}
	body := text(20, 30, 13, cMuted, "start", "MATCH #"+itoa(m.ID)+" · "+modeLabel(m)+" · "+phase(m))
	body += text(20, 62, 18, cGold, "start", fa.Name)
	body += text(460, 62, 18, cTeal, "end", nameB)
	body += text(240, 62, 16, cMuted, "middle", "VS")
	body += hpBar(20, 74, 190, hpA, cGold)
	body += hpBar(270, 74, 190, hpB, cTeal)

	total := m.PoolA + m.PoolB
	wA := 220
	if total > 0 {
		wA = int(int64(440) * m.PoolA / total)
	}
	body += rect(20, 104, 440, 10, cTeal) + rect(20, 104, wA, 10, cGold)
	body += text(20, 134, 12, cText, "start", strconv.FormatInt(m.PoolA, 10)+" ugnot")
	body += text(460, 134, 12, cText, "end", strconv.FormatInt(m.PoolB, 10)+" ugnot")
	if m.Status == StatusResolved || m.Status == StatusForfeit {
		w := "DRAW"
		if m.Winner == 1 {
			w = fa.Name + " WINS"
		} else if m.Winner == 2 {
			w = nameB + " WINS"
		}
		body += text(240, 134, 13, cRed, "middle", w)
	}
	return svgImage("match "+itoa(m.ID), body, 480, 150)
}

func badgeSVG(name string) string {
	color := cGold
	switch name {
	case "Untouched":
		color = cTeal
	case "Giant Slayer":
		color = cRed
	}
	body := "<circle cx='40' cy='34' r='24' fill='" + cPanel + "' stroke='" + color + "' stroke-width='3'/>" +
		"<polygon points='40,18 45,30 58,31 48,39 51,52 40,45 29,52 32,39 22,31 35,30' fill='" + color + "'/>" +
		text(40, 78, 10, cText, "middle", name)
	return svgImage(name, body, 80, 88)
}

func modeLabel(m *Match) string {
	if m.Ranked {
		return "RANKED"
	}
	return "FRIENDLY"
}

func phase(m *Match) string {
	switch m.Status {
	case StatusLive:
		if height() <= m.CommitDeadline {
			return "COMMIT + BETS until #" + strconv.FormatInt(m.CommitDeadline, 10)
		}
		return "REVEAL until #" + strconv.FormatInt(m.RevealDeadline, 10)
	}
	return upper(m.Status)
}

func upper(s string) string {
	out := ""
	for _, r := range s {
		if r >= 'a' && r <= 'z' {
			r = r - 'a' + 'A'
		}
		out += string(r)
	}
	return out
}
