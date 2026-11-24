package heirloom

import (
	"encoding/base64"
	"html"
	"math"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

const ringRadius = 52

func countdownRing(w *Will) string {
	label, color, filled := "released", "#7f8c8d", 1.0
	switch w.status() {
	case statusDue:
		label, color = "due", "#c0392b"
	case statusActive:
		filled = math.Min(float64(time.Since(w.LastSeen))/float64(w.Silence), 1)
		label, color = formatDuration(time.Until(w.releaseAt()))+" left", "#27ae60"
		if filled >= 0.75 {
			color = "#d35400"
		}
	}
	circumference := 2 * math.Pi * ringRadius
	svg := ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="140" height="140" viewBox="0 0 140 140">`+
		`<circle cx="70" cy="70" r="%d" fill="none" stroke="#e5e5e5" stroke-width="12"/>`+
		`<circle cx="70" cy="70" r="%d" fill="none" stroke="%s" stroke-width="12" stroke-dasharray="%.1f %.1f" transform="rotate(-90 70 70)"/>`+
		`<text x="70" y="75" text-anchor="middle" font-family="sans-serif" font-size="14" fill="%s">%s</text></svg>`,
		ringRadius, ringRadius, color, filled*circumference, circumference, color, html.EscapeString(label))
	return "![" + label + "](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg)) + ")"
}
